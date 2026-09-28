// Agent handoff briefing (PRD §10 Phase 3): turns a handoff payload + the backed-up note into one
// Markdown (or JSON) document an LLM agent can read from a plain URL fetch.
// Pure module (no DB / S3 / HTTP); api.ts loads the rows and serves it. Contract: server/README.md § Agent handoff.

export const DEFAULT_TIME_ZONE = "America/New_York"; // used when the iPad didn't send time_zone
const MOMENT_BEFORE_S = 30; // transcript window: from 30 s before Pat started writing …
const MOMENT_AFTER_S = 10; // … to 10 s after he stopped
const MAX_BRIEFING_CHARS = 400_000; // agents cope with ~100k; truncate the transcript only past this
const SPEAKER_PARA_MAX_S = 120; // a same-speaker paragraph restarts (new timestamp) after 2 min
const PLAIN_PARA_MAX_S = 45; // unlabelled transcripts: paragraph = ≤45 s of speech …
const PLAIN_PARA_GAP_S = 2; // … or until a pause longer than 2 s

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------
export interface HandoffPage {
  index: number; // 0-based page index
  png_key: string | null;
  text: string; // OCR'd handwriting
}
export interface HandoffMoment {
  page: number; // 0-based
  bbox: number[] | null; // [x,y,w,h] page-local points (origin = page's top-left; page PNG pixels = points × 2.5)
  t_start: number | null; // NOTE-timeline seconds (recordings end to end, ord order)
  t_end: number | null;
  text: string;
}
export interface HandoffPayload {
  pdf_key: string | null;
  pages: HandoffPage[];
  moments: HandoffMoment[];
  time_zone: string; // IANA
}
export interface BriefingInput {
  link: string; // absolute https://…/h/<token>
  expires_at: Date;
  note: { id: string; title: string; created_at: Date; speaker_names: Record<string, string> };
  subject: string | null;
  // Live (non-tombstoned) recordings in ord order, with the best transcript for each.
  recordings: {
    id: string;
    name: string;
    started_at: Date;
    duration_s: number;
    has_audio: boolean;
    transcript: { engine: string | null; segments: unknown; full_text: string } | null;
  }[];
  payload: HandoffPayload;
}

interface Line {
  rec: number; // 1-based recording number
  t: number; // note-timeline start
  t_end: number;
  rec_t: number; // recording-relative start
  label: string | null; // provider label, e.g. "S1"
  speaker: string | null; // display name
  text: string;
}
interface Para {
  rec: number;
  t: number;
  t_end: number;
  speaker: string | null;
  text: string;
  key: string | null;
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------
function clock(t: number, long: boolean): string {
  const s = Math.max(0, Math.floor(t + 1e-6));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const ss = String(s % 60).padStart(2, "0");
  return long || h > 0 ? `${h}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`;
}

function safeTz(tz: string): string {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return tz;
  } catch {
    return DEFAULT_TIME_ZONE;
  }
}

function wallTime(d: Date, tz: string): string {
  return new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "numeric", minute: "2-digit" }).format(d);
}
function wallDate(d: Date, tz: string): string {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: tz, weekday: "short", month: "short", day: "numeric", year: "numeric",
    hour: "numeric", minute: "2-digit", timeZoneName: "short",
  }).format(d);
}

/** One line of prose: collapse whitespace so it can't break the Markdown structure. */
function inline(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}
/** Multi-line text (OCR): keep line breaks, but stop a leading `#`/`>`/`---` from becoming Markdown structure. */
function block(s: string): string {
  return s
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((l) => l.replace(/\s+$/, "").replace(/^(\s*)(#|>|={3,}|-{3,})/, "$1\\$2"))
    .join("  \n") // hard line breaks: handwriting lines are meaningful
    .replace(/(  \n){3,}/g, "  \n  \n")
    .trim();
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------
function segmentsOf(t: BriefingInput["recordings"][number]["transcript"]): any[] {
  if (!t) return [];
  const s: any = t.segments;
  if (Array.isArray(s)) return s;
  if (s && Array.isArray(s.segments)) return s.segments;
  return [];
}

function segText(seg: any): string {
  if (typeof seg?.text === "string" && seg.text.trim()) return inline(seg.text);
  if (Array.isArray(seg?.words)) {
    return inline(seg.words.map((w: any) => (typeof w?.text === "string" ? w.text : typeof w?.w === "string" ? w.w : "")).join(" "));
  }
  return "";
}

function speakerName(names: Record<string, string>, recId: string, label: string): string {
  const n = /^S(\d+)$/i.exec(label)?.[1];
  const norm = n ? `S${Number(n)}` : label;
  return names[`${recId}:${norm}`] ?? names[norm] ?? (n ? `Speaker ${Number(n)}` : label);
}

export function buildModel(inp: BriefingInput) {
  const tz = safeTz(inp.payload.time_zone || DEFAULT_TIME_ZONE);
  const names = inp.note.speaker_names ?? {};
  let offset = 0;
  const recs = inp.recordings.map((r, i) => {
    const n = i + 1;
    const lines: Line[] = [];
    let untimed: string | null = null;
    const segs = segmentsOf(r.transcript);
    for (const seg of segs) {
      const start = Number(seg?.start);
      if (!Number.isFinite(start)) continue;
      const endRaw = Number(seg?.end);
      const end = Number.isFinite(endRaw) && endRaw >= start ? endRaw : start;
      const text = segText(seg);
      if (!text) continue;
      const label = typeof seg?.speaker === "string" && seg.speaker ? seg.speaker : null;
      lines.push({
        rec: n, t: offset + start, t_end: offset + end, rec_t: start, label,
        speaker: label ? speakerName(names, r.id, label) : null, text,
      });
    }
    lines.sort((a, b) => a.t - b.t);
    // A transcript with text but no usable timed segments: keep the text, untimed.
    if (!lines.length && r.transcript && r.transcript.full_text.trim()) untimed = inline(r.transcript.full_text);
    const out = {
      n, id: r.id, name: r.name, started_at: r.started_at, duration_s: r.duration_s, offset_s: offset,
      has_audio: r.has_audio, has_transcript: !!r.transcript, engine: r.transcript?.engine ?? null, lines, untimed,
    };
    offset += Math.max(0, r.duration_s || 0);
    return out;
  });
  const totalAudio = offset;
  const long = totalAudio >= 3600;
  const allLines = recs.flatMap((r) => r.lines);

  // Speakers in order of first appearance.
  const speakers: string[] = [];
  for (const l of allLines) if (l.speaker && !speakers.includes(l.speaker)) speakers.push(l.speaker);
  // Unnamed labels aren't matched across recordings: warn when that could mislead.
  const recsWithUnnamed = recs.filter((r) => r.lines.some((l) => l.label && l.speaker === speakerName({}, r.id, l.label))).length;

  const pagesByIndex = new Map<number, { index: number; text: string; png_key: string | null; untimed: string[]; timed: number }>();
  const page = (i: number) => {
    let p = pagesByIndex.get(i);
    if (!p) pagesByIndex.set(i, (p = { index: i, text: "", png_key: null, untimed: [], timed: 0 }));
    return p;
  };
  for (const p of inp.payload.pages) Object.assign(page(p.index), { text: p.text, png_key: p.png_key });
  const moments: (HandoffMoment & { t0: number; t1: number; paras: (Para & { during: boolean })[] })[] = [];
  for (const m of inp.payload.moments) {
    if (m.t_start == null) {
      if (inline(m.text)) page(m.page).untimed.push(inline(m.text));
      continue;
    }
    page(m.page).timed++;
    const t0 = m.t_start;
    const t1 = m.t_end == null ? t0 : Math.max(t0, m.t_end);
    const ws = t0 - MOMENT_BEFORE_S;
    const we = t1 + MOMENT_AFTER_S;
    const inWindow = allLines.filter((l) => l.t_end >= ws && l.t <= we);
    const paras = paragraphs(inWindow, 15, 20).map((p) => ({ ...p, during: p.t_end >= t0 && p.t <= t1 }));
    moments.push({ ...m, t0, t1, paras });
  }
  moments.sort((a, b) => a.t0 - b.t0 || a.page - b.page);
  const pages = [...pagesByIndex.values()].sort((a, b) => a.index - b.index);

  return { tz, long, totalAudio, recs, speakers, recsWithUnnamed, pages, moments };
}

/** Merge consecutive lines: same speaker (≤2 min per paragraph), or for unlabelled speech ≤45 s with no long pause. */
function paragraphs(lines: Line[], speakerMaxS = SPEAKER_PARA_MAX_S, plainMaxS = PLAIN_PARA_MAX_S, plainGapS = PLAIN_PARA_GAP_S): Para[] {
  const out: Para[] = [];
  for (const l of lines) {
    const key = l.label ? `${l.rec}:${l.label}` : null;
    const last = out[out.length - 1];
    const same =
      last && last.rec === l.rec && last.key === key &&
      (key ? l.t - last.t <= speakerMaxS : l.t - last.t <= plainMaxS && l.t - last.t_end <= plainGapS);
    if (same) {
      last.text += " " + l.text;
      last.t_end = Math.max(last.t_end, l.t_end);
    } else {
      out.push({ rec: l.rec, t: l.t, t_end: l.t_end, speaker: l.speaker, text: l.text, key });
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Markdown
// ---------------------------------------------------------------------------
export function renderMarkdown(inp: BriefingInput): string {
  const M = buildModel(inp);
  const L = inp.link;
  const T = (t: number) => clock(t, M.long);
  const nRec = M.recs.length;
  const out: string[] = [];

  // Header
  const title = inline(inp.note.title) || "Untitled note";
  out.push(`# ${title.replace(/^#+\s*/, "")}`);
  const when = M.recs[0]?.started_at ?? inp.note.created_at;
  const meta: string[] = [];
  if (inp.subject) meta.push(inline(inp.subject));
  meta.push(wallDate(when, M.tz));
  meta.push(nRec ? `${clock(M.totalAudio, false)} of audio${nRec > 1 ? ` (${nRec} recordings)` : ""}` : "no audio");
  if (M.speakers.length) meta.push(`Speakers: ${M.speakers.join(", ")}`);
  out.push(meta.join(" · "), "");

  const ocr = "his handwritten notes (read by OCR — may contain errors; the PDF is the source of truth)";
  out.push(
    nRec
      ? `> **For the agent:** These are Pat's notes from a call: ${ocr}, what was being said when he wrote each note, and the full ` +
          `${M.speakers.length ? "speaker-labelled " : ""}transcript. Figure out the decisions, action items (owner + due date when stated), ` +
          "and open questions, then help with next steps. If something is ambiguous, check the transcript."
      : `> **For the agent:** These are Pat's notes: ${ocr}. Figure out the decisions, action items (owner + due date when stated), ` +
          "and open questions, then help with next steps.",
    ">",
  );
  if (nRec) {
    out.push(
      `> Timestamps like ${M.long ? "[1:05:30] are hours:minutes:seconds" : "[1:05] are minutes:seconds"} into the note's audio` +
        (nRec > 1 ? " (its recordings laid end to end)" : "") +
        `. All links work without login until ${wallDate(inp.expires_at, M.tz)}; JSON version: ${L}?format=json`,
    );
  } else {
    out.push(`> No audio was recorded for this note, so there is only the handwriting. Links work without login until ${wallDate(inp.expires_at, M.tz)}.`);
  }
  out.push("");

  // Handwritten notes
  out.push("## Handwritten notes");
  const fileLinks: string[] = [];
  if (inp.payload.pdf_key) fileLinks.push(`[PDF of the handwriting](${L}/notes.pdf)`);
  if (!M.pages.length) out.push("_No handwriting text was sent._");
  for (const p of M.pages) {
    out.push("", `### Page ${p.index + 1}`);
    out.push(p.text.trim() ? block(p.text) : "_(no text recognized on this page)_");
    if (p.untimed.length) {
      out.push("", `_Written while no recording was running:_ ${p.untimed.map((t) => `"${t}"`).join(" · ")}`);
    }
    const links = [...(p.index === M.pages[0].index ? fileLinks : [])];
    if (p.png_key) links.push(`[Page ${p.index + 1} image](${L}/page/${p.index + 1}.png)`);
    if (links.length) out.push("", links.join(" · "));
  }
  out.push("");

  // Moments
  if (M.moments.length) {
    out.push(
      "## Moments — what Pat wrote ↔ what was being said",
      `Each moment shows the transcript from ${MOMENT_BEFORE_S} s before Pat started writing to ${MOMENT_AFTER_S} s after he stopped; ▶ marks what was said while he was writing.`,
    );
    for (const m of M.moments) {
      const span = m.t1 - m.t0 >= 1 ? `${T(m.t0)}–${T(m.t1)}` : T(m.t0);
      out.push("", `### ${span} · page ${m.page + 1} · "${inline(m.text) || "(no text recognized)"}"`);
      if (!m.paras.length) out.push("_(no transcript for this stretch of audio)_");
      for (const p of m.paras) {
        out.push(`- ${p.during ? "▶ " : ""}[${T(p.t)}] ${p.speaker ? `**${p.speaker}:** ` : ""}${p.text}`);
      }
    }
    out.push("");
  }

  // Transcript (built last so it can be truncated to fit)
  const tail: string[] = [];
  const audioLinks = M.recs.filter((r) => r.has_audio).map((r) => `[Recording ${r.n} (${clock(r.duration_s, false)})](${L}/audio/${r.n}.m4a)`);
  const pageLinks = M.pages.filter((p) => p.png_key).map((p) => `[Page ${p.index + 1}](${L}/page/${p.index + 1}.png)`);
  if (inp.payload.pdf_key || pageLinks.length || audioLinks.length) {
    tail.push("## Files");
    if (inp.payload.pdf_key) tail.push(`- Handwriting PDF: [notes.pdf](${L}/notes.pdf)`);
    if (pageLinks.length) tail.push(`- Page images: ${pageLinks.join(" · ")}`);
    if (audioLinks.length) tail.push(`- Audio (m4a): ${audioLinks.join(" · ")}`);
    tail.push("", "_Each link redirects to a download URL that is valid for 1 hour; fetch the link again for a fresh one._", "");
  }

  const transcript: string[] = [];
  if (nRec) {
    transcript.push("## Transcript");
    if (M.recsWithUnnamed > 1) {
      transcript.push("_Unnamed speaker labels are per recording: Speaker 1 in one recording is not necessarily Speaker 1 in another._");
    }
    for (const r of M.recs) {
      const custom = r.name && inline(r.name) !== `Recording ${r.n}` ? ` (“${inline(r.name)}”)` : "";
      const parts = [`### Recording ${r.n}${custom}`, clock(r.duration_s, false), `started ${wallTime(r.started_at, M.tz)}`];
      if (nRec > 1) parts.push(`note time ${T(r.offset_s)}–${T(r.offset_s + r.duration_s)}`);
      transcript.push("", parts.join(" · "));
      if (!r.has_transcript) transcript.push("_No transcript for this recording._");
      else if (r.untimed) transcript.push(r.untimed);
      else if (!r.lines.length) transcript.push("_The transcript for this recording is empty._");
      for (const p of paragraphs(r.lines)) transcript.push(`**[${T(p.t)}]${p.speaker ? ` ${p.speaker}:` : ""}** ${p.text}`, "");
    }
    if (transcript[transcript.length - 1] === "") transcript.pop();
    transcript.push("");
  }

  const head = out.join("\n");
  const foot = tail.join("\n");
  let body = transcript.join("\n");
  const budget = MAX_BRIEFING_CHARS - head.length - foot.length - 400;
  if (body.length > budget) {
    const cut = body.lastIndexOf("\n**[", Math.max(0, budget));
    const kept = body.slice(0, cut > 0 ? cut : Math.max(0, budget));
    const lastTs = /\*\*\[([0-9:]+)\]/g;
    let m: RegExpExecArray | null;
    let at = "";
    while ((m = lastTs.exec(kept))) at = m[1];
    body = `${kept}\n\n_Transcript truncated after [${at}] to keep this briefing under ${MAX_BRIEFING_CHARS.toLocaleString("en-US")} characters. The full transcript is in ${L}?format=json and the audio is under Files._\n`;
  }
  return `${head}\n${body}\n${foot}`.replace(/\n{3,}/g, "\n\n").trimEnd() + "\n";
}

// ---------------------------------------------------------------------------
// JSON (?format=json): the same data, structured.
// ---------------------------------------------------------------------------
export function renderJson(inp: BriefingInput) {
  const M = buildModel(inp);
  const L = inp.link;
  const r3 = (x: number) => Math.round(x * 1000) / 1000;
  return {
    note: {
      id: inp.note.id,
      title: inp.note.title,
      subject: inp.subject,
      created_at: inp.note.created_at.toISOString(),
      total_audio_s: r3(M.totalAudio),
      speakers: M.speakers,
    },
    time_zone: M.tz,
    expires_at: inp.expires_at.toISOString(),
    time_base: "t / t_start / t_end are note-timeline seconds: the note's recordings laid end to end in order (recording.offset_s + recording-relative time).",
    markdown_url: L,
    pdf_url: inp.payload.pdf_key ? `${L}/notes.pdf` : null,
    pages: M.pages.map((p) => ({
      page: p.index + 1,
      text: p.text,
      image_url: p.png_key ? `${L}/page/${p.index + 1}.png` : null,
      untimed_notes: p.untimed,
    })),
    moments: M.moments.map((m) => ({
      page: m.page + 1,
      bbox: m.bbox,
      t_start: m.t_start,
      t_end: m.t_end,
      text: m.text,
      transcript: m.paras.map((p) => ({ t: r3(p.t), t_end: r3(p.t_end), recording: p.rec, speaker: p.speaker, text: p.text, while_writing: p.during })),
    })),
    recordings: M.recs.map((r) => ({
      n: r.n,
      id: r.id,
      name: r.name,
      started_at: r.started_at.toISOString(),
      duration_s: r.duration_s,
      offset_s: r3(r.offset_s),
      audio_url: r.has_audio ? `${L}/audio/${r.n}.m4a` : null,
      transcript: r.has_transcript
        ? {
            engine: r.engine,
            full_text_untimed: r.untimed,
            segments: r.lines.map((l) => ({ t: r3(l.t), t_end: r3(l.t_end), start: r3(l.rec_t), speaker_label: l.label, speaker: l.speaker, text: l.text })),
          }
        : null,
    })),
  };
}
