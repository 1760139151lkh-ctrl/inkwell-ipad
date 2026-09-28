// Speaker diarization: provider call (ElevenLabs Scribe) + word → segment shaping.
// Pure module (no DB / S3); the job lifecycle lives in api.ts. Contract: server/README.md § Speaker detection.

export const DIARIZE_PROVIDER = "elevenlabs";
export const DIARIZE_MODEL = "scribe_v2";
export const DIARIZE_ENGINE = `${DIARIZE_PROVIDER}/${DIARIZE_MODEL}`; // stored in transcripts.engine

// Segmenting rules (the iPad shows one tappable line per segment).
const PAUSE_SPLIT_S = 1.2; // a silence longer than this starts a new line
const MAX_WORDS = 25; // hard cap per line
const SOFT_COMMA_WORDS = 18; // past this many words, also break after a comma
const MIN_SENTENCE_WORDS = 4; // don't end a line on "Okay." alone; keep going to the next sentence end

export interface Word {
  start: number;
  end: number;
  text: string;
}
export interface Segment {
  start: number;
  end: number;
  text: string;
  words: Word[];
  speaker?: string;
}
export interface DiarizedTranscript {
  language_code: string | null;
  audio_duration_s: number | null;
  segments: Segment[];
  full_text: string;
  speakers: string[];
  provider_transcription_id: string | null;
}

/** Errors worth retrying (rate limit, provider 5xx, network, timeout). */
export class TransientError extends Error {}

// Provider token shape (ElevenLabs SpeechToTextChunkResponseModel.words[]).
interface ProviderToken {
  text: string;
  type?: "word" | "spacing" | "audio_event" | string;
  start?: number | null;
  end?: number | null;
  speaker_id?: string | null;
}

/**
 * POST the audio bytes to ElevenLabs Scribe with diarization + word timestamps and wait for the result.
 * Measured: 83 s of audio → 1.6 s, 30 min → 12 s (incl. upload). A 2 h meeting is ~1 min.
 */
export async function transcribeWithScribe(
  audio: Uint8Array,
  opts: { apiKey: string; filename: string; contentType: string; timeoutMs: number },
): Promise<any> {
  const form = new FormData();
  form.set("model_id", DIARIZE_MODEL);
  form.set("diarize", "true");
  form.set("timestamps_granularity", "word");
  form.set("tag_audio_events", "false");
  form.set("file", new Blob([audio as BlobPart], { type: opts.contentType }), opts.filename);

  let res: Response;
  try {
    res = await fetch("https://api.elevenlabs.io/v1/speech-to-text", {
      method: "POST",
      headers: { "xi-api-key": opts.apiKey },
      body: form,
      signal: AbortSignal.timeout(opts.timeoutMs),
    });
  } catch (e: any) {
    throw new TransientError(`provider request failed: ${e?.name === "TimeoutError" ? "timeout" : e?.message ?? e}`);
  }
  const text = await res.text();
  if (!res.ok) {
    // Provider error bodies are {detail:{message,status}} and never echo the key.
    let msg = text.slice(0, 300);
    try {
      const j = JSON.parse(text);
      msg = j?.detail?.message ?? j?.detail?.status ?? (typeof j?.detail === "string" ? j.detail : msg);
    } catch {}
    const err = `provider ${res.status}: ${msg}`;
    if (res.status === 429 || res.status >= 500) throw new TransientError(err);
    throw new Error(err);
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new TransientError("provider returned invalid JSON");
  }
}

const round = (n: number) => Math.round(n * 1000) / 1000;
const SENTENCE_END_RE = /[.?!…。？！]["'”’)\]]*$/;

/** Turn a Scribe response into Inkwell segments ({start,end,text,words,speaker}). */
export function buildSegments(resp: any): DiarizedTranscript {
  const duration = typeof resp?.audio_duration_secs === "number" ? resp.audio_duration_secs : null;
  const tokens: ProviderToken[] = Array.isArray(resp?.words) ? resp.words : [];
  // Keep words + the spacing between them (for language-agnostic text rebuild); drop audio events.
  const toks = tokens.filter((t) => t && typeof t.text === "string" && (t.type === "word" || t.type === "spacing" || !t.type));

  // Fill any missing word times: interpolate between known neighbours, else spread evenly over the audio.
  const words = toks.filter((t) => t.type !== "spacing");
  fillMissingTimes(words, duration);

  // Provider speaker ids → S1, S2… in order of first appearance.
  const labelOf = new Map<string, string>();
  const label = (id: string | null | undefined) => {
    const k = id ?? "unknown";
    if (!labelOf.has(k)) labelOf.set(k, `S${labelOf.size + 1}`);
    return labelOf.get(k)!;
  };

  const segments: Segment[] = [];
  let cur: { toks: ProviderToken[]; words: Word[]; speaker: string } | null = null;
  const flush = () => {
    if (!cur || cur.words.length === 0) {
      cur = null;
      return;
    }
    const text = cur.toks.map((t) => t.text).join("").replace(/\s+/g, " ").trim();
    segments.push({
      start: cur.words[0].start,
      end: cur.words[cur.words.length - 1].end,
      text,
      words: cur.words,
      speaker: cur.speaker,
    });
    cur = null;
  };

  let prevEnd: number | null = null;
  for (const t of toks) {
    if (t.type === "spacing") {
      if (cur) cur.toks.push(t);
      continue;
    }
    const speaker = label(t.speaker_id);
    const w: Word = { start: round(t.start as number), end: round(t.end as number), text: t.text.trim() };
    if (!w.text) continue;
    if (cur && (cur.speaker !== speaker || (prevEnd !== null && w.start - prevEnd > PAUSE_SPLIT_S))) flush();
    if (!cur) cur = { toks: [], words: [], speaker };
    cur.toks.push({ ...t, text: t.text });
    cur.words.push(w);
    prevEnd = w.end;
    const n = cur.words.length;
    if (
      n >= MAX_WORDS ||
      (n >= MIN_SENTENCE_WORDS && SENTENCE_END_RE.test(w.text)) ||
      (n >= SOFT_COMMA_WORDS && /[,;:]$/.test(w.text))
    ) {
      flush();
    }
  }
  flush();

  const speakers = [...new Set(segments.map((s) => s.speaker!))];
  return {
    language_code: typeof resp?.language_code === "string" ? resp.language_code : null,
    audio_duration_s: duration,
    segments,
    full_text: segments.map((s) => s.text).join(" "),
    speakers,
    provider_transcription_id: typeof resp?.transcription_id === "string" ? resp.transcription_id : null,
  };
}

function fillMissingTimes(words: ProviderToken[], duration: number | null) {
  const ok = (t: ProviderToken) => typeof t.start === "number" && typeof t.end === "number";
  if (words.every(ok)) return;
  const known = words.map((w, i) => (ok(w) ? i : -1)).filter((i) => i >= 0);
  if (known.length === 0) {
    const total = duration ?? words.length * 0.4;
    const step = words.length ? total / words.length : 0;
    words.forEach((w, i) => {
      w.start = i * step;
      w.end = (i + 1) * step;
    });
    return;
  }
  // Runs of words without times: spread them evenly between the surrounding known words.
  let i = 0;
  while (i < words.length) {
    if (ok(words[i])) {
      i++;
      continue;
    }
    let j = i;
    while (j < words.length && !ok(words[j])) j++;
    const from = i > 0 ? (words[i - 1].end as number) : 0;
    const to = j < words.length ? (words[j].start as number) : (duration ?? from + (j - i) * 0.4);
    const step = (to - from) / (j - i);
    for (let k = i; k < j; k++) {
      words[k].start = from + (k - i) * step;
      words[k].end = from + (k - i + 1) * step;
    }
    i = j;
  }
}
