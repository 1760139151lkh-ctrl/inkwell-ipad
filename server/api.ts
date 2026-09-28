// Inkwell cloud backup API (PRD §8.3) — Neon Function `api`.
// One fetch-style handler + a tiny router. Every /api/* route requires
// `Authorization: Bearer $INKWELL_API_TOKEN`; /h/<token>* (agent handoff) is public, the token is the secret.
// Contracts: server/README.md.

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { Pool, type PoolClient } from "pg";
import { attachDatabasePool, waitUntil } from "@neon/functions";
import { S3Client, PutObjectCommand, GetObjectCommand, HeadObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { DIARIZE_ENGINE, TransientError, buildSegments, transcribeWithScribe } from "./diarize.js";
import { DEFAULT_TIME_ZONE, renderJson, renderMarkdown, type BriefingInput, type HandoffPayload } from "./handoff.js";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
const BUCKET = "uploads";
const MAX_BODY_BYTES = 16 * 1024 * 1024; // 16 MiB of JSON (transcripts + strokes index for a long note)
const MAX_UPLOAD_FILES = 100;
const MAX_DOWNLOAD_KEYS = 500;
const UPLOAD_TTL_S = 60 * 60; // 1h
const UPLOAD_TTL_AUDIO_S = 6 * 60 * 60; // 6h: background URLSession may start a big audio upload late
const DOWNLOAD_TTL_S = 60 * 60; // 1h
const LIST_DEFAULT_LIMIT = 200;
const LIST_MAX_LIMIT = 1000;
// Speaker detection (diarization). Neon Functions: waitUntil work may run 15 min; stay under it.
const DIARIZE_PROVIDER_TIMEOUT_MS = 12 * 60 * 1000; // measured ~1 min per 2 h of audio
const DIARIZE_STALE_S = 16 * 60; // a 'running' job older than this died with its isolate → re-claim
const DIARIZE_RETRY_AFTER_S = 30; // back-off before retrying a transient provider failure
const DIARIZE_MAX_ATTEMPTS = 3;
const DIARIZE_MAX_DURATION_S = 4 * 60 * 60; // 4 h (≈ 116 MB at 64 kbps); provider allows 10 h
const DIARIZE_MAX_BYTES = 300 * 1024 * 1024;
// Agent handoff (README § Agent handoff).
const HANDOFF_DEFAULT_DAYS = 30;
const HANDOFF_MAX_DAYS = 365;
const HANDOFF_MAX_PAGES = 1000;
const HANDOFF_MAX_MOMENTS = 5000;
const HANDOFF_FILE_TTL_S = 60 * 60; // /h/<token>/… redirects to a fresh presigned GET valid this long

// pg warns that sslmode=require is treated as verify-full; say so explicitly (same behavior, no warning).
const dbUrl = (process.env.DATABASE_URL ?? "").replace(/sslmode=(require|prefer|verify-ca)/, "sslmode=verify-full");
const pool = new Pool({ connectionString: dbUrl, max: 5 });
attachDatabasePool(pool);

const s3 = new S3Client({
  forcePathStyle: true, // Neon requires path-style addressing
  region: process.env.AWS_REGION,
  endpoint: process.env.AWS_ENDPOINT_URL_S3,
  // Don't bake CRC32 checksum params into presigned URLs (Neon ignores them; clients would have to match).
  requestChecksumCalculation: "WHEN_REQUIRED",
  responseChecksumValidation: "WHEN_REQUIRED",
});

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------
class HttpError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public details?: unknown,
  ) {
    super(message);
  }
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

function errorResponse(e: HttpError): Response {
  const body: Record<string, unknown> = { error: { code: e.code, message: e.message } };
  if (e.details !== undefined) (body.error as Record<string, unknown>).details = e.details;
  return json(e.status, body);
}

const bad = (message: string, details?: unknown) => new HttpError(400, "bad_request", message, details);

function sha256(buf: string | Buffer): Buffer {
  return createHash("sha256").update(buf).digest();
}

function authorized(req: Request): boolean {
  const expected = process.env.INKWELL_API_TOKEN;
  if (!expected) throw new HttpError(500, "misconfigured", "INKWELL_API_TOKEN is not set on the function");
  const header = req.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(.+)$/i.exec(header.trim());
  if (!m) return false;
  // Hash both sides so lengths match; timingSafeEqual then runs in constant time.
  return timingSafeEqual(sha256(m[1]), sha256(expected));
}

async function readJson(req: Request): Promise<any> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) throw new HttpError(413, "payload_too_large", `body exceeds ${MAX_BODY_BYTES} bytes`);
  if (!req.body) throw bad("missing JSON body");
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel().catch(() => {});
      throw new HttpError(413, "payload_too_large", `body exceeds ${MAX_BODY_BYTES} bytes`);
    }
    chunks.push(value);
  }
  const text = Buffer.concat(chunks).toString("utf8");
  if (!text.trim()) throw bad("missing JSON body");
  try {
    return JSON.parse(text);
  } catch {
    throw bad("body is not valid JSON");
  }
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SHA256_RE = /^[0-9a-f]{64}$/;

function isObj(v: unknown): v is Record<string, any> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
function uuid(v: unknown, field: string): string {
  if (typeof v !== "string" || !UUID_RE.test(v)) throw bad(`${field} must be a UUID`);
  return v.toLowerCase();
}
function optUuid(v: unknown, field: string): string | null {
  return v === undefined || v === null ? null : uuid(v, field);
}
function str(v: unknown, field: string): string {
  if (typeof v !== "string") throw bad(`${field} must be a string`);
  return v;
}
function optStr(v: unknown, field: string): string | null {
  return v === undefined || v === null ? null : str(v, field);
}
function int(v: unknown, field: string): number {
  if (typeof v !== "number" || !Number.isInteger(v)) throw bad(`${field} must be an integer`);
  return v;
}
function num(v: unknown, field: string): number {
  if (typeof v !== "number" || !Number.isFinite(v)) throw bad(`${field} must be a number`);
  return v;
}
function ts(v: unknown, field: string): string {
  if (typeof v !== "string" || Number.isNaN(Date.parse(v))) throw bad(`${field} must be an ISO-8601 timestamp`);
  return v;
}
function optTs(v: unknown, field: string): string | null {
  return v === undefined || v === null ? null : ts(v, field);
}
function optSha(v: unknown, field: string): string | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "string" || !SHA256_RE.test(v)) throw bad(`${field} must be 64 lowercase hex chars`);
  return v;
}
function arr(v: unknown, field: string): any[] {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v)) throw bad(`${field} must be an array`);
  return v;
}

// A note's object keys must live under notes/<noteId>/ and follow the path rules below.
function optNoteKey(v: unknown, field: string, noteId: string): string | null {
  const k = optStr(v, field);
  if (k === null) return null;
  const prefix = `notes/${noteId}/`;
  if (!k.startsWith(prefix) || !validPath(k.slice(prefix.length))) {
    throw bad(`${field} must be a key under ${prefix} with an allowed path`);
  }
  return k;
}

// Allowed file paths inside a note folder (PRD §8.2).
const EXACT_PATHS = new Set(["drawing.pkdrawing", "thumb.png", "background.pdf", "export/notes.pdf"]);
const DIR_PREFIXES = ["audio/", "transcript/", "images/"];
const SEGMENT_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
// Agent-handoff page renders: export/page-<n>.png, n = 1-based page number.
const EXPORT_PAGE_RE = /^export\/page-[1-9][0-9]{0,3}\.png$/;
function validPath(p: string): boolean {
  if (p.includes("..") || p.includes("//") || p.startsWith("/") || p.includes("\\")) return false;
  if (EXACT_PATHS.has(p) || EXPORT_PAGE_RE.test(p)) return true;
  const dir = DIR_PREFIXES.find((d) => p.startsWith(d));
  return !!dir && SEGMENT_RE.test(p.slice(dir.length));
}
function validKey(k: string): boolean {
  const m = /^notes\/([0-9a-f-]{36})\/(.+)$/.exec(k);
  return !!m && UUID_RE.test(m[1]) && validPath(m[2]);
}

// ---------------------------------------------------------------------------
// DB helpers
// ---------------------------------------------------------------------------
async function tx<T>(fn: (c: PoolClient) => Promise<T>): Promise<T> {
  const c = await pool.connect();
  try {
    await c.query("begin");
    const out = await fn(c);
    await c.query("commit");
    return out;
  } catch (e) {
    await c.query("rollback").catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}

function mapPgError(e: any): HttpError | null {
  switch (e?.code) {
    case "23503": // foreign_key_violation
      return new HttpError(409, "foreign_key_violation", e.detail ?? "referenced row does not exist");
    case "22P02": // invalid_text_representation
    case "22007": // invalid_datetime_format
    case "22008": // datetime_field_overflow
    case "22003": // numeric_value_out_of_range
      return bad(e.message);
    default:
      return null;
  }
}

const iso = (d: Date | null | undefined) => (d ? d.toISOString() : null);

// Row → API shapes (the same shapes the PUT body uses).
function subjectOut(r: any) {
  return {
    id: r.id,
    name: r.name,
    color_hex: r.color_hex,
    sort_index: r.sort_index,
    divider_id: r.divider_id,
    updated_at: iso(r.updated_at),
    deleted_at: iso(r.deleted_at),
  };
}
function noteOut(r: any) {
  return {
    id: r.id,
    subject_id: r.subject_id,
    title: r.title,
    paper: r.paper,
    page_count: r.page_count,
    bookmarked_pages: r.bookmarked_pages,
    created_at: iso(r.created_at),
    modified_at: iso(r.modified_at),
    deleted_at: iso(r.deleted_at),
    drawing_key: r.drawing_key,
    drawing_sha256: r.drawing_sha256,
    thumb_key: r.thumb_key,
    background_key: r.background_key,
    speaker_names: r.speaker_names ?? {},
  };
}
function recordingOut(r: any) {
  return {
    id: r.id,
    ord: r.ord,
    name: r.name,
    started_at: iso(r.started_at),
    duration_s: r.duration_s,
    audio_key: r.audio_key,
    audio_sha256: r.audio_sha256,
    transcript_status: r.transcript_status,
    has_transcript: r.has_transcript ?? undefined,
    deleted_at: iso(r.deleted_at),
  };
}
function elementOut(r: any) {
  return {
    id: r.id,
    kind: r.kind,
    frame: r.frame,
    created_at: iso(r.created_at),
    text: r.text,
    file_key: r.file_key,
    deleted_at: iso(r.deleted_at),
  };
}
function transcriptOut(r: any) {
  return { recording_id: r.recording_id, locale: r.locale, engine: r.engine, segments: r.segments, full_text: r.full_text };
}

function noteFileKeys(n: any, recs: any[], els: any[]): string[] {
  const keys = [n.drawing_key, n.thumb_key, n.background_key];
  for (const r of recs) keys.push(r.audio_key);
  for (const e of els) keys.push(e.file_key);
  return keys.filter((k): k is string => typeof k === "string" && k.length > 0);
}

async function presignGet(key: string) {
  const url = await getSignedUrl(s3, new GetObjectCommand({ Bucket: BUCKET, Key: key }), { expiresIn: DOWNLOAD_TTL_S });
  return { key, url, expires_at: new Date(Date.now() + DOWNLOAD_TTL_S * 1000).toISOString() };
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------
async function health(): Promise<Response> {
  const { rows } = await pool.query("select now() as now");
  return json(200, { ok: true, db: true, time: iso(rows[0].now) });
}

function parseSubject(s: any, field = "subject") {
  if (!isObj(s)) throw bad(`${field} must be an object`);
  return {
    id: uuid(s.id, `${field}.id`),
    name: str(s.name, `${field}.name`),
    color_hex: str(s.color_hex, `${field}.color_hex`),
    sort_index: int(s.sort_index, `${field}.sort_index`),
    divider_id: optUuid(s.divider_id, `${field}.divider_id`),
    updated_at: ts(s.updated_at, `${field}.updated_at`),
    deleted_at: optTs(s.deleted_at, `${field}.deleted_at`),
  };
}

async function upsertSubject(c: PoolClient, s: ReturnType<typeof parseSubject>) {
  await c.query(
    `insert into subjects (id, name, color_hex, sort_index, divider_id, updated_at, deleted_at)
     values ($1,$2,$3,$4,$5,$6,$7)
     on conflict (id) do update set name = excluded.name, color_hex = excluded.color_hex,
       sort_index = excluded.sort_index, divider_id = excluded.divider_id,
       updated_at = excluded.updated_at, deleted_at = excluded.deleted_at`,
    [s.id, s.name, s.color_hex, s.sort_index, s.divider_id, s.updated_at, s.deleted_at],
  );
}

async function putNote(id: string, req: Request): Promise<Response> {
  const body = await readJson(req);
  if (!isObj(body)) throw bad("body must be a JSON object");
  if (!isObj(body.note)) throw bad("note must be an object");

  const n = body.note;
  const noteId = uuid(n.id, "note.id");
  if (noteId !== id) throw bad("note.id must match the :id in the URL");
  if (!isObj(n.paper)) throw bad("note.paper must be an object");
  const note = {
    id: noteId,
    subject_id: optUuid(n.subject_id, "note.subject_id"),
    title: str(n.title, "note.title"),
    paper: n.paper,
    page_count: int(n.page_count, "note.page_count"),
    bookmarked_pages: arr(n.bookmarked_pages, "note.bookmarked_pages").map((p, i) => int(p, `note.bookmarked_pages[${i}]`)),
    created_at: ts(n.created_at, "note.created_at"),
    modified_at: ts(n.modified_at, "note.modified_at"),
    deleted_at: optTs(n.deleted_at, "note.deleted_at"),
    drawing_key: optNoteKey(n.drawing_key, "note.drawing_key", noteId),
    drawing_sha256: optSha(n.drawing_sha256, "note.drawing_sha256"),
    thumb_key: optNoteKey(n.thumb_key, "note.thumb_key", noteId),
    background_key: optNoteKey(n.background_key, "note.background_key", noteId),
  };
  // Omitted → leave the stored names alone (older app builds don't send it); null → clear; object → replace.
  const speakerNames = n.speaker_names === undefined ? undefined : parseSpeakerNames(n.speaker_names);

  const subject = body.subject === undefined || body.subject === null ? null : parseSubject(body.subject);
  if (subject && note.subject_id && subject.id !== note.subject_id) throw bad("subject.id must equal note.subject_id");

  const recordings = arr(body.recordings, "recordings").map((r, i) => {
    const f = `recordings[${i}]`;
    if (!isObj(r)) throw bad(`${f} must be an object`);
    return {
      id: uuid(r.id, `${f}.id`),
      ord: int(r.ord, `${f}.ord`),
      name: str(r.name, `${f}.name`),
      started_at: ts(r.started_at, `${f}.started_at`),
      duration_s: num(r.duration_s, `${f}.duration_s`),
      audio_key: optNoteKey(r.audio_key, `${f}.audio_key`, noteId),
      audio_sha256: optSha(r.audio_sha256, `${f}.audio_sha256`),
      transcript_status: optStr(r.transcript_status, `${f}.transcript_status`),
      deleted_at: optTs(r.deleted_at, `${f}.deleted_at`),
    };
  });
  const recIds = new Set(recordings.map((r) => r.id));
  if (recIds.size !== recordings.length) throw bad("recordings contains duplicate ids");

  const transcripts = arr(body.transcripts, "transcripts").map((t, i) => {
    const f = `transcripts[${i}]`;
    if (!isObj(t)) throw bad(`${f} must be an object`);
    const recording_id = uuid(t.recording_id, `${f}.recording_id`);
    if (!recIds.has(recording_id)) throw bad(`${f}.recording_id must reference a recording in this payload`);
    if (t.segments === undefined || t.segments === null) throw bad(`${f}.segments is required`);
    return {
      recording_id,
      locale: optStr(t.locale, `${f}.locale`),
      engine: optStr(t.engine, `${f}.engine`),
      segments: t.segments,
      full_text: str(t.full_text, `${f}.full_text`),
    };
  });

  let strokes: unknown[] | null = null;
  if (body.strokes_index !== undefined && body.strokes_index !== null) {
    if (!isObj(body.strokes_index) || !Array.isArray(body.strokes_index.strokes)) {
      throw bad("strokes_index must be {strokes:[...]} or null");
    }
    strokes = body.strokes_index.strokes;
  }

  const elements = arr(body.elements, "elements").map((e, i) => {
    const f = `elements[${i}]`;
    if (!isObj(e)) throw bad(`${f} must be an object`);
    if (!isObj(e.frame)) throw bad(`${f}.frame must be an object`);
    return {
      id: uuid(e.id, `${f}.id`),
      kind: str(e.kind, `${f}.kind`),
      frame: e.frame,
      created_at: ts(e.created_at, `${f}.created_at`),
      text: optStr(e.text, `${f}.text`),
      file_key: optNoteKey(e.file_key, `${f}.file_key`, noteId),
      deleted_at: optTs(e.deleted_at, `${f}.deleted_at`),
    };
  });
  if (new Set(elements.map((e) => e.id)).size !== elements.length) throw bad("elements contains duplicate ids");

  const result = await tx(async (c) => {
    if (subject) await upsertSubject(c, subject);

    await c.query(
      `insert into notes (id, subject_id, title, paper, page_count, bookmarked_pages, created_at, modified_at,
                          deleted_at, drawing_key, drawing_sha256, thumb_key, background_key, speaker_names)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13, coalesce($14::jsonb, '{}'::jsonb))
       on conflict (id) do update set subject_id = excluded.subject_id, title = excluded.title,
         paper = excluded.paper, page_count = excluded.page_count, bookmarked_pages = excluded.bookmarked_pages,
         created_at = excluded.created_at, modified_at = excluded.modified_at, deleted_at = excluded.deleted_at,
         drawing_key = excluded.drawing_key, drawing_sha256 = excluded.drawing_sha256,
         thumb_key = excluded.thumb_key, background_key = excluded.background_key,
         speaker_names = case when $14::jsonb is null then notes.speaker_names else excluded.speaker_names end`,
      [
        note.id, note.subject_id, note.title, JSON.stringify(note.paper), note.page_count,
        JSON.stringify(note.bookmarked_pages), note.created_at, note.modified_at, note.deleted_at,
        note.drawing_key, note.drawing_sha256, note.thumb_key, note.background_key,
        speakerNames === undefined ? null : JSON.stringify(speakerNames),
      ],
    );

    for (const r of recordings) {
      // `where recordings.note_id = excluded.note_id` stops a payload from hijacking another note's recording.
      const res = await c.query(
        `insert into recordings (id, note_id, ord, name, started_at, duration_s, audio_key, audio_sha256,
                                 transcript_status, deleted_at)
         values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
         on conflict (id) do update set ord = excluded.ord, name = excluded.name,
           started_at = excluded.started_at, duration_s = excluded.duration_s, audio_key = excluded.audio_key,
           audio_sha256 = excluded.audio_sha256, transcript_status = excluded.transcript_status,
           deleted_at = excluded.deleted_at
         where recordings.note_id = excluded.note_id`,
        [r.id, note.id, r.ord, r.name, r.started_at, r.duration_s, r.audio_key, r.audio_sha256,
          r.transcript_status, r.deleted_at],
      );
      if (res.rowCount === 0) throw new HttpError(409, "id_conflict", `recording ${r.id} belongs to another note`);
    }
    const recTomb = await c.query(
      `update recordings set deleted_at = now()
       where note_id = $1 and deleted_at is null and not (id = any($2::uuid[]))`,
      [note.id, [...recIds]],
    );

    for (const t of transcripts) {
      await c.query(
        `insert into transcripts (recording_id, locale, engine, segments, full_text)
         values ($1,$2,$3,$4,$5)
         on conflict (recording_id) do update set locale = excluded.locale, engine = excluded.engine,
           segments = excluded.segments, full_text = excluded.full_text`,
        [t.recording_id, t.locale, t.engine, JSON.stringify(t.segments), t.full_text],
      );
    }

    if (strokes !== null) {
      await c.query(
        `insert into strokes_index (note_id, strokes) values ($1,$2)
         on conflict (note_id) do update set strokes = excluded.strokes`,
        [note.id, JSON.stringify(strokes)],
      );
    }

    for (const e of elements) {
      const res = await c.query(
        `insert into elements (id, note_id, kind, frame, created_at, text, file_key, deleted_at)
         values ($1,$2,$3,$4,$5,$6,$7,$8)
         on conflict (id) do update set kind = excluded.kind, frame = excluded.frame,
           created_at = excluded.created_at, text = excluded.text, file_key = excluded.file_key,
           deleted_at = excluded.deleted_at
         where elements.note_id = excluded.note_id`,
        [e.id, note.id, e.kind, JSON.stringify(e.frame), e.created_at, e.text, e.file_key, e.deleted_at],
      );
      if (res.rowCount === 0) throw new HttpError(409, "id_conflict", `element ${e.id} belongs to another note`);
    }
    const elTomb = await c.query(
      `update elements set deleted_at = now()
       where note_id = $1 and deleted_at is null and not (id = any($2::uuid[]))`,
      [note.id, elements.map((e) => e.id)],
    );

    const { rows } = await c.query("select now() as now");
    return {
      recordings: { upserted: recordings.length, tombstoned: recTomb.rowCount ?? 0 },
      elements: { upserted: elements.length, tombstoned: elTomb.rowCount ?? 0 },
      transcripts: { upserted: transcripts.length },
      strokes_index: strokes === null ? "unchanged" : "replaced",
      server_time: iso(rows[0].now),
    };
  });

  return json(200, { ok: true, id: note.id, ...result });
}

async function putSubjects(req: Request): Promise<Response> {
  const body = await readJson(req);
  if (!isObj(body) || !Array.isArray(body.subjects)) throw bad("body must be {subjects:[...]}");
  const subjects = body.subjects.map((s: unknown, i: number) => parseSubject(s, `subjects[${i}]`));
  await tx(async (c) => {
    for (const s of subjects) await upsertSubject(c, s);
  });
  return json(200, { ok: true, upserted: subjects.length });
}

async function getNote(id: string): Promise<Response> {
  const noteRes = await pool.query("select * from notes where id = $1", [id]);
  if (noteRes.rowCount === 0) throw new HttpError(404, "not_found", "note not found");
  const n = noteRes.rows[0];
  const [subj, recs, trans, strokes, els] = await Promise.all([
    n.subject_id ? pool.query("select * from subjects where id = $1", [n.subject_id]) : Promise.resolve({ rows: [] as any[] }),
    pool.query("select * from recordings where note_id = $1 order by ord, started_at", [id]),
    pool.query(
      `select t.* from transcripts t join recordings r on r.id = t.recording_id
       where r.note_id = $1 order by r.ord`,
      [id],
    ),
    pool.query("select strokes from strokes_index where note_id = $1", [id]),
    pool.query("select * from elements where note_id = $1 order by created_at", [id]),
  ]);
  return json(200, {
    subject: subj.rows[0] ? subjectOut(subj.rows[0]) : null,
    note: noteOut(n),
    recordings: recs.rows.map(recordingOut),
    transcripts: trans.rows.map(transcriptOut),
    strokes_index: strokes.rows[0] ? { strokes: strokes.rows[0].strokes } : null,
    elements: els.rows.map(elementOut),
    file_keys: noteFileKeys(n, recs.rows, els.rows),
  });
}

// Cursor = base64url(JSON [changed_at_iso, id]) for keyset pagination.
function encodeCursor(changedAt: Date, id: string) {
  return Buffer.from(JSON.stringify([changedAt.toISOString(), id])).toString("base64url");
}
function decodeCursor(c: string): [string, string] {
  try {
    const v = JSON.parse(Buffer.from(c, "base64url").toString("utf8"));
    if (Array.isArray(v) && typeof v[0] === "string" && !Number.isNaN(Date.parse(v[0])) && UUID_RE.test(v[1])) {
      return [v[0], v[1]];
    }
  } catch {}
  throw bad("invalid cursor");
}

async function listNotes(url: URL): Promise<Response> {
  const since = url.searchParams.get("since");
  if (since !== null && Number.isNaN(Date.parse(since))) throw bad("since must be an ISO-8601 timestamp");
  const limitRaw = url.searchParams.get("limit");
  const limit = limitRaw === null ? LIST_DEFAULT_LIMIT : Number(limitRaw);
  if (!Number.isInteger(limit) || limit < 1 || limit > LIST_MAX_LIMIT) throw bad(`limit must be 1..${LIST_MAX_LIMIT}`);
  const cursor = url.searchParams.get("cursor");
  const includeUrls = ["1", "true"].includes(url.searchParams.get("urls") ?? "");

  // A note "changed" when it was modified or tombstoned.
  const changed = "greatest(n.modified_at, coalesce(n.deleted_at, n.modified_at))";
  const params: unknown[] = [];
  const where: string[] = [];
  if (since !== null) {
    params.push(since);
    where.push(`${changed} > $${params.length}`);
  }
  if (cursor) {
    const [cAt, cId] = decodeCursor(cursor);
    params.push(cAt, cId);
    where.push(`(${changed}, n.id) > ($${params.length - 1}::timestamptz, $${params.length}::uuid)`);
  }
  params.push(limit + 1);
  const { rows } = await pool.query(
    `select n.*, ${changed} as changed_at from notes n
     ${where.length ? "where " + where.join(" and ") : ""}
     order by changed_at, n.id limit $${params.length}`,
    params,
  );
  const hasMore = rows.length > limit;
  const page = rows.slice(0, limit);
  const ids = page.map((r) => r.id);

  const [recs, els, subs, now] = await Promise.all([
    pool.query(
      `select r.*, exists(select 1 from transcripts t where t.recording_id = r.id) as has_transcript
       from recordings r where r.note_id = any($1::uuid[]) order by r.ord, r.started_at`,
      [ids],
    ),
    pool.query("select * from elements where note_id = any($1::uuid[]) order by created_at", [ids]),
    // All subjects every time: small, and restore needs empty subjects + sort order too.
    pool.query("select * from subjects order by sort_index, name"),
    pool.query("select now() as now"),
  ]);
  const recsBy = new Map<string, any[]>();
  for (const r of recs.rows) (recsBy.get(r.note_id) ?? recsBy.set(r.note_id, []).get(r.note_id)!).push(r);
  const elsBy = new Map<string, any[]>();
  for (const e of els.rows) (elsBy.get(e.note_id) ?? elsBy.set(e.note_id, []).get(e.note_id)!).push(e);

  const notes = await Promise.all(
    page.map(async (n) => {
      const r = recsBy.get(n.id) ?? [];
      const e = elsBy.get(n.id) ?? [];
      const file_keys = noteFileKeys(n, r, e);
      const out: Record<string, unknown> = {
        note: noteOut(n),
        recordings: r.map(recordingOut),
        elements: e.map(elementOut),
        file_keys,
      };
      if (includeUrls) out.urls = Object.fromEntries((await Promise.all(file_keys.map(presignGet))).map((d) => [d.key, d.url]));
      return out;
    }),
  );
  const last = page[page.length - 1];
  return json(200, {
    notes,
    subjects: subs.rows.map(subjectOut),
    next_cursor: hasMore && last ? encodeCursor(last.changed_at, last.id) : null,
    server_time: iso(now.rows[0].now),
  });
}

async function deleteNote(id: string): Promise<Response> {
  const out = await tx(async (c) => {
    const res = await c.query(
      `update notes set deleted_at = coalesce(deleted_at, now()) where id = $1 returning deleted_at`,
      [id],
    );
    if (res.rowCount === 0) throw new HttpError(404, "not_found", "note not found");
    const deletedAt = res.rows[0].deleted_at;
    const r = await c.query(`update recordings set deleted_at = $2 where note_id = $1 and deleted_at is null`, [id, deletedAt]);
    const e = await c.query(`update elements set deleted_at = $2 where note_id = $1 and deleted_at is null`, [id, deletedAt]);
    return { deleted_at: iso(deletedAt), recordings_tombstoned: r.rowCount ?? 0, elements_tombstoned: e.rowCount ?? 0 };
  });
  return json(200, { ok: true, id, ...out });
}

async function createUploads(req: Request): Promise<Response> {
  const body = await readJson(req);
  if (!isObj(body)) throw bad("body must be a JSON object");
  const noteId = uuid(body.noteId, "noteId");
  if (!Array.isArray(body.files) || body.files.length === 0) throw bad("files must be a non-empty array");
  if (body.files.length > MAX_UPLOAD_FILES) throw bad(`at most ${MAX_UPLOAD_FILES} files per request`);

  const uploads = await Promise.all(
    body.files.map(async (f: unknown, i: number) => {
      const field = `files[${i}]`;
      if (!isObj(f)) throw bad(`${field} must be an object`);
      const path = str(f.path, `${field}.path`);
      if (!validPath(path)) {
        throw bad(`${field}.path is not allowed`, {
          allowed: [...EXACT_PATHS, ...DIR_PREFIXES.map((d) => `${d}<name>`), "export/page-<n>.png"],
        });
      }
      const sha = optSha(f.sha256, `${field}.sha256`);
      if (!sha) throw bad(`${field}.sha256 is required`);
      const contentType = str(f.contentType, `${field}.contentType`);
      if (!/^[\w.+-]+\/[\w.+-]+$/.test(contentType)) throw bad(`${field}.contentType is not a valid MIME type`);

      const key = `notes/${noteId}/${path}`;
      const ttl = path.startsWith("audio/") ? UPLOAD_TTL_AUDIO_S : UPLOAD_TTL_S;
      const url = await getSignedUrl(
        s3,
        new PutObjectCommand({ Bucket: BUCKET, Key: key, ContentType: contentType, Metadata: { sha256: sha } }),
        // Keep x-amz-meta-sha256 as a signed *header* (Neon ignores it as a query param):
        // the client must send it, and the object then carries its hash (visible via HEAD).
        { expiresIn: ttl, unhoistableHeaders: new Set(["x-amz-meta-sha256"]) },
      );
      return {
        path,
        key,
        url,
        method: "PUT",
        headers: { "Content-Type": contentType, "x-amz-meta-sha256": sha },
        expires_at: new Date(Date.now() + ttl * 1000).toISOString(),
      };
    }),
  );
  return json(200, { uploads });
}

async function createDownloads(req: Request): Promise<Response> {
  const body = await readJson(req);
  if (!isObj(body) || !Array.isArray(body.keys)) throw bad("body must be {keys:[...]}");
  if (body.keys.length > MAX_DOWNLOAD_KEYS) throw bad(`at most ${MAX_DOWNLOAD_KEYS} keys per request`);
  const keys = body.keys.map((k: unknown, i: number) => {
    if (typeof k !== "string" || !validKey(k)) throw bad(`keys[${i}] must be a notes/<noteId>/<allowed path> key`);
    return k;
  });
  return json(200, { downloads: await Promise.all(keys.map(presignGet)) });
}

// ---------------------------------------------------------------------------
// Speaker detection (diarization) — README § Speaker detection.
// POST starts a job and returns at once; the provider call runs in waitUntil (≤15 min on Neon).
// No cron: a job whose isolate died is re-claimed by the next POST/GET poll (the iPad polls every ~5 s),
// so the Postgres compute can still scale to zero when nobody is looking.
// ---------------------------------------------------------------------------
const SPEAKER_KEY_RE = /^(?:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):)?S[1-9][0-9]{0,2}$/i;
function parseSpeakerNames(v: unknown): Record<string, string> {
  if (v === null) return {};
  if (!isObj(v)) throw bad("note.speaker_names must be an object like {\"S1\":\"Kunal\"} or null");
  const out: Record<string, string> = {};
  const entries = Object.entries(v);
  if (entries.length > 500) throw bad("note.speaker_names has too many entries (max 500)");
  for (const [k, name] of entries) {
    const m = SPEAKER_KEY_RE.exec(k);
    if (!m) throw bad(`note.speaker_names key "${k.slice(0, 60)}" must be "S<n>" or "<recordingId>:S<n>"`);
    if (typeof name !== "string" || !name.trim() || name.length > 100) {
      throw bad(`note.speaker_names["${k}"] must be a non-empty string of at most 100 chars`);
    }
    const key = m[1] ? `${m[1].toLowerCase()}:S${k.slice(k.lastIndexOf(":") + 2)}` : `S${k.slice(1)}`;
    out[key] = name.trim();
  }
  return out;
}

function diarizationOut(j: any) {
  const out: Record<string, unknown> = {
    recording_id: j.recording_id,
    status: j.status,
    provider: j.provider,
    attempts: j.attempts,
    requested_at: iso(j.requested_at),
    started_at: iso(j.started_at),
    finished_at: iso(j.finished_at),
  };
  if (j.error) out.error = j.error;
  if (j.audio_duration_s != null) out.audio_duration_s = j.audio_duration_s;
  if (j.status === "done" && j.result) out.transcript = j.result;
  return out;
}

async function diarizationJob(recId: string) {
  const { rows } = await pool.query("select * from diarization_jobs where recording_id = $1", [recId]);
  return rows[0] ?? null;
}

/**
 * Claim the job if it is runnable (fresh pending, pending past its retry back-off, or running but stale)
 * and start the provider call in waitUntil. Exhausted retries become 'failed'. Cheap no-op otherwise.
 */
async function kickDiarization(recId: string): Promise<void> {
  await pool.query(
    `update diarization_jobs set status = 'failed', finished_at = now(), updated_at = now(),
       error = coalesce(error, 'worker stopped responding') || ' (gave up after ' || attempts || ' attempts)'
     where recording_id = $1 and attempts >= $2
       and (status = 'pending' or (status = 'running' and started_at < now() - make_interval(secs => $3)))`,
    [recId, DIARIZE_MAX_ATTEMPTS, DIARIZE_STALE_S],
  );
  const { rows } = await pool.query(
    `update diarization_jobs set status = 'running', attempts = attempts + 1, started_at = now(), updated_at = now(),
       claim_id = gen_random_uuid()
     where recording_id = $1 and attempts < $2 and (
       (status = 'pending' and (attempts = 0 or updated_at < now() - make_interval(secs => $4)))
       or (status = 'running' and started_at < now() - make_interval(secs => $3)))
     returning *`,
    [recId, DIARIZE_MAX_ATTEMPTS, DIARIZE_STALE_S, DIARIZE_RETRY_AFTER_S],
  );
  if (rows[0]) waitUntil(runDiarization(rows[0]));
}

async function runDiarization(job: any): Promise<void> {
  const t0 = Date.now();
  try {
    const apiKey = process.env.ELEVENLABS_API_KEY;
    if (!apiKey) throw new Error("ELEVENLABS_API_KEY is not set on the function");
    let bytes: Uint8Array;
    let contentType = "audio/mp4";
    try {
      const obj = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: job.audio_key }));
      bytes = await obj.Body!.transformToByteArray();
      if (obj.ContentType && obj.ContentType !== "application/octet-stream") contentType = obj.ContentType;
    } catch (e: any) {
      if (e?.name === "NoSuchKey" || e?.$metadata?.httpStatusCode === 404) throw new Error("audio object not found in storage");
      throw new TransientError(`storage read failed: ${e?.name ?? e}`);
    }
    const resp = await transcribeWithScribe(bytes, {
      apiKey,
      filename: job.audio_key.slice(job.audio_key.lastIndexOf("/") + 1),
      contentType,
      timeoutMs: DIARIZE_PROVIDER_TIMEOUT_MS,
    });
    const d = buildSegments(resp);
    await tx(async (c) => {
      const prev = await c.query("select locale from transcripts where recording_id = $1", [job.recording_id]);
      const locale: string | null = prev.rows[0]?.locale ?? d.language_code;
      const result = { engine: DIARIZE_ENGINE, locale, segments: d.segments, full_text: d.full_text, speakers: d.speakers };
      const u = await c.query(
        `update diarization_jobs set status = 'done', error = null, finished_at = now(), updated_at = now(),
           audio_duration_s = $3, provider_transcription_id = $4, result = $5
         where recording_id = $1 and claim_id = $2`,
        [job.recording_id, job.claim_id, d.audio_duration_s, d.provider_transcription_id, JSON.stringify(result)],
      );
      if (u.rowCount === 0) return; // superseded by a newer run
      // Don't replace an existing on-device transcript with an empty one (silent audio).
      if (d.segments.length > 0) {
        await c.query(
          `insert into transcripts (recording_id, locale, engine, segments, full_text) values ($1,$2,$3,$4,$5)
           on conflict (recording_id) do update set locale = excluded.locale, engine = excluded.engine,
             segments = excluded.segments, full_text = excluded.full_text`,
          [job.recording_id, locale, DIARIZE_ENGINE, JSON.stringify(d.segments), d.full_text],
        );
      }
    });
    console.log("[diarize] done", job.recording_id, `${d.audio_duration_s ?? "?"}s audio`, `${d.speakers.length} speakers`,
      `${d.segments.length} segments`, `${Date.now() - t0}ms`);
  } catch (e: any) {
    const transient = e instanceof TransientError;
    const msg = String(e?.message ?? e).slice(0, 500);
    console.error("[diarize] failed", job.recording_id, transient ? "(transient)" : "", msg);
    await pool
      .query(
        `update diarization_jobs set error = $3, updated_at = now(),
           status = case when $4 and attempts < $5 then 'pending' else 'failed' end,
           finished_at = case when $4 and attempts < $5 then null else now() end
         where recording_id = $1 and claim_id = $2`,
        [job.recording_id, job.claim_id, msg, transient, DIARIZE_MAX_ATTEMPTS],
      )
      .catch((e2) => console.error("[diarize] could not record failure", e2?.message ?? e2));
  }
}

async function postDiarize(recId: string, url: URL): Promise<Response> {
  const { rows } = await pool.query("select id, audio_key, audio_sha256, duration_s from recordings where id = $1", [recId]);
  const rec = rows[0];
  if (!rec) throw new HttpError(404, "not_found", "recording not found (PUT the note with this recording first)");
  if (!rec.audio_key) {
    throw new HttpError(409, "audio_not_uploaded", "recording has no audio_key yet: upload the audio, PUT the note, then retry");
  }
  if (rec.duration_s > DIARIZE_MAX_DURATION_S) {
    throw new HttpError(413, "audio_too_long", `recordings longer than ${DIARIZE_MAX_DURATION_S / 3600} h can't be diarized`);
  }
  if (!process.env.ELEVENLABS_API_KEY) throw new HttpError(500, "misconfigured", "ELEVENLABS_API_KEY is not set on the function");
  const force = ["1", "true"].includes(url.searchParams.get("force") ?? "");

  const existing = await diarizationJob(recId);
  const sameAudio =
    existing && existing.audio_key === rec.audio_key && (existing.audio_sha256 ?? "") === (rec.audio_sha256 ?? "");
  if (existing && sameAudio && (existing.status === "pending" || existing.status === "running")) {
    await kickDiarization(recId); // re-claims only if stale
    return json(202, diarizationOut(await diarizationJob(recId)));
  }
  if (existing && sameAudio && existing.status === "done" && !force) return json(200, diarizationOut(existing));

  // New job, a retry after 'failed', a re-run with ?force=1, or the audio changed. Check the object exists first.
  try {
    const head = await s3.send(new HeadObjectCommand({ Bucket: BUCKET, Key: rec.audio_key }));
    if ((head.ContentLength ?? 0) > DIARIZE_MAX_BYTES) {
      throw new HttpError(413, "audio_too_long", `audio object is larger than ${DIARIZE_MAX_BYTES} bytes`);
    }
  } catch (e: any) {
    if (e instanceof HttpError) throw e;
    if (e?.name === "NotFound" || e?.name === "NoSuchKey" || e?.$metadata?.httpStatusCode === 404) {
      throw new HttpError(409, "audio_not_uploaded", "audio object not found in storage yet: finish the upload, then retry");
    }
    throw e;
  }
  await pool.query(
    `insert into diarization_jobs (recording_id, status, provider, audio_key, audio_sha256)
     values ($1, 'pending', $2, $3, $4)
     on conflict (recording_id) do update set status = 'pending', provider = excluded.provider,
       audio_key = excluded.audio_key, audio_sha256 = excluded.audio_sha256, attempts = 0, error = null,
       requested_at = now(), started_at = null, updated_at = now(), finished_at = null, claim_id = null,
       audio_duration_s = null, provider_transcription_id = null, result = null`,
    [recId, DIARIZE_ENGINE, rec.audio_key, rec.audio_sha256],
  );
  await kickDiarization(recId);
  return json(202, diarizationOut(await diarizationJob(recId)));
}

async function getDiarization(recId: string): Promise<Response> {
  let job = await diarizationJob(recId);
  if (!job) {
    const r = await pool.query("select 1 from recordings where id = $1", [recId]);
    if (r.rowCount === 0) throw new HttpError(404, "not_found", "recording not found");
    return json(200, { recording_id: recId, status: "none" });
  }
  if (job.status === "pending" || job.status === "running") {
    await kickDiarization(recId); // resumes a job whose worker died or is due a retry
    job = await diarizationJob(recId);
  }
  return json(200, diarizationOut(job));
}

// ---------------------------------------------------------------------------
// Agent handoff (PRD §10 Phase 3) — README § Agent handoff.
// POST /api/notes/:id/handoff (Bearer) mints an unguessable link; GET /h/<token> is PUBLIC and returns a
// Markdown briefing an agent can read with a plain URL fetch. Only the token's SHA-256 is stored.
// ---------------------------------------------------------------------------
const HANDOFF_TOKEN_RE = /^[A-Za-z0-9_-]{43}$/; // 32 random bytes, base64url
const tokenHash = (token: string) => sha256(token).toString("hex");

/** The public origin of this Function, for absolute links (agents need absolute URLs). */
function publicOrigin(req: Request): string {
  const u = new URL(req.url);
  const local = u.hostname === "localhost" || u.hostname === "127.0.0.1" || u.hostname === "[::1]";
  return `${local ? u.protocol : "https:"}//${u.host}`;
}

function exportKey(v: unknown, field: string, noteId: string, re: RegExp): string | null {
  const k = optNoteKey(v, field, noteId);
  if (k !== null && !re.test(k.slice(`notes/${noteId}/`.length))) throw bad(`${field} must be notes/${noteId}/${re === EXPORT_PAGE_RE ? "export/page-<n>.png" : "export/notes.pdf"}`);
  return k;
}
const optNum = (v: unknown, field: string) => (v === undefined || v === null ? null : num(v, field));

async function objectExists(key: string): Promise<boolean> {
  try {
    await s3.send(new HeadObjectCommand({ Bucket: BUCKET, Key: key }));
    return true;
  } catch (e: any) {
    if (e?.name === "NotFound" || e?.name === "NoSuchKey" || e?.$metadata?.httpStatusCode === 404) return false;
    throw e;
  }
}

async function postHandoff(noteId: string, req: Request): Promise<Response> {
  const body = await readJson(req);
  if (!isObj(body)) throw bad("body must be a JSON object");
  const pdf_key = exportKey(body.pdf_key, "pdf_key", noteId, /^export\/notes\.pdf$/);
  const rawPages = arr(body.pages, "pages");
  if (rawPages.length > HANDOFF_MAX_PAGES) throw bad(`at most ${HANDOFF_MAX_PAGES} pages`);
  const pages = rawPages.map((p, i) => {
    const f = `pages[${i}]`;
    if (!isObj(p)) throw bad(`${f} must be an object`);
    const index = int(p.index, `${f}.index`);
    if (index < 0 || index >= HANDOFF_MAX_PAGES) throw bad(`${f}.index must be a 0-based page index`);
    return { index, png_key: exportKey(p.png_key, `${f}.png_key`, noteId, EXPORT_PAGE_RE), text: optStr(p.text, `${f}.text`) ?? "" };
  });
  if (new Set(pages.map((p) => p.index)).size !== pages.length) throw bad("pages contains duplicate indexes");
  const rawMoments = arr(body.moments, "moments");
  if (rawMoments.length > HANDOFF_MAX_MOMENTS) throw bad(`at most ${HANDOFF_MAX_MOMENTS} moments`);
  const moments = rawMoments.map((m, i) => {
    const f = `moments[${i}]`;
    if (!isObj(m)) throw bad(`${f} must be an object`);
    const page = int(m.page, `${f}.page`);
    if (page < 0) throw bad(`${f}.page must be a 0-based page index`);
    let bbox: number[] | null = null;
    if (m.bbox !== undefined && m.bbox !== null) {
      if (!Array.isArray(m.bbox) || m.bbox.length !== 4) throw bad(`${f}.bbox must be [x,y,w,h]`);
      bbox = m.bbox.map((x: unknown, j: number) => num(x, `${f}.bbox[${j}]`));
    }
    const t_start = optNum(m.t_start, `${f}.t_start`);
    let t_end = optNum(m.t_end, `${f}.t_end`);
    if (t_start === null) t_end = null;
    else if (t_end === null || t_end < t_start) t_end = t_start;
    return { page, bbox, t_start, t_end, text: optStr(m.text, `${f}.text`) ?? "" };
  });
  let days = HANDOFF_DEFAULT_DAYS;
  if (body.expires_in_days !== undefined && body.expires_in_days !== null) {
    days = int(body.expires_in_days, "expires_in_days");
    if (days < 1 || days > HANDOFF_MAX_DAYS) throw bad(`expires_in_days must be 1..${HANDOFF_MAX_DAYS}`);
  }
  // Optional IANA zone for wall-clock times in the briefing (iOS: TimeZone.current.identifier).
  const time_zone = optStr(body.time_zone, "time_zone") ?? DEFAULT_TIME_ZONE;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: time_zone });
  } catch {
    throw bad("time_zone must be an IANA time zone like America/New_York");
  }

  const n = await pool.query("select deleted_at from notes where id = $1", [noteId]);
  if (n.rowCount === 0) throw new HttpError(404, "not_found", "note not found (back it up with PUT /api/notes/:id first)");
  if (n.rows[0].deleted_at) throw new HttpError(404, "not_found", "note is deleted");

  // Not fatal (the iPad may still be uploading), but say so: a missing file is a dead link in the briefing.
  const keys = [pdf_key, ...pages.map((p) => p.png_key)].filter((k): k is string => !!k);
  const missing: string[] = [];
  for (let i = 0; i < keys.length; i += 16) {
    const batch = keys.slice(i, i + 16);
    const found = await Promise.all(batch.map(objectExists));
    batch.forEach((k, j) => found[j] || missing.push(k));
  }

  const payload: HandoffPayload = { pdf_key, pages, moments, time_zone };
  const token = randomBytes(32).toString("base64url");
  const { rows } = await pool.query(
    `insert into handoffs (token_hash, note_id, payload, expires_at)
     values ($1, $2, $3, now() + make_interval(days => $4)) returning expires_at`,
    [tokenHash(token), noteId, JSON.stringify(payload), days],
  );
  const out: Record<string, unknown> = { url: `${publicOrigin(req)}/h/${token}`, token, expires_at: iso(rows[0].expires_at) };
  if (missing.length) out.warnings = missing.map((k) => `${k} is not in storage yet; its link will 404 until it is uploaded`);
  return json(200, out);
}

async function revokeHandoff(token: string): Promise<Response> {
  if (!HANDOFF_TOKEN_RE.test(token)) throw new HttpError(404, "not_found", "handoff not found");
  const { rows } = await pool.query(
    `update handoffs set revoked_at = coalesce(revoked_at, now()) where token_hash = $1 returning note_id, revoked_at`,
    [tokenHash(token)],
  );
  if (!rows[0]) throw new HttpError(404, "not_found", "handoff not found");
  return json(200, { ok: true, note_id: rows[0].note_id, revoked_at: iso(rows[0].revoked_at) });
}

const PUBLIC_HEADERS = {
  "x-robots-tag": "noindex, nofollow",
  "cache-control": "private, no-store",
  "referrer-policy": "no-referrer",
  "access-control-allow-origin": "*",
};
function publicResponse(status: number, body: string | null, headers: Record<string, string> = {}): Response {
  return new Response(body, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", ...PUBLIC_HEADERS, ...headers },
  });
}
const publicNotFound = () =>
  publicResponse(404, "Not found. This handoff link is invalid, expired, or revoked. Ask Pat to hand off the note again.\n");

/** Live (non-tombstoned) recordings in note-timeline order: the same order the iPad lays them end to end. */
const LIVE_RECORDINGS_SQL = "select * from recordings where note_id = $1 and deleted_at is null order by ord, started_at";

async function publicHandoff(req: Request, url: URL, path: string): Promise<Response> {
  const m = /^\/h\/([^/]+)(?:\/(notes\.pdf|page\/([0-9]{1,5})\.png|audio\/([0-9]{1,5})\.m4a))?$/.exec(path);
  if (!m) return publicNotFound();
  const method = req.method.toUpperCase();
  if (method === "OPTIONS") return publicResponse(204, null, { "access-control-allow-methods": "GET, HEAD" });
  if (method !== "GET" && method !== "HEAD") return publicResponse(405, "Use GET.\n", { allow: "GET, HEAD" });
  const token = m[1];
  if (!HANDOFF_TOKEN_RE.test(token)) return publicNotFound();
  // Lookup by SHA-256 of the token: the stored value never reveals the token, and comparing hashes via the
  // primary-key index leaks nothing useful about the token itself.
  const { rows } = await pool.query(
    `select h.payload, h.expires_at, n.id, n.title, n.created_at, n.speaker_names, s.name as subject_name
     from handoffs h join notes n on n.id = h.note_id left join subjects s on s.id = n.subject_id
     where h.token_hash = $1 and h.revoked_at is null and h.expires_at > now() and n.deleted_at is null`,
    [tokenHash(token)],
  );
  const h = rows[0];
  if (!h) return publicNotFound();
  const payload = h.payload as HandoffPayload;

  // File links: 302 to a fresh presigned GET, so links in the briefing never go stale.
  if (m[2]) {
    let key: string | null = null;
    if (m[2] === "notes.pdf") key = payload.pdf_key;
    else if (m[3]) key = payload.pages.find((p) => p.index === Number(m[3]) - 1)?.png_key ?? null;
    else if (m[4]) {
      const recs = await pool.query(LIVE_RECORDINGS_SQL, [h.id]);
      key = recs.rows[Number(m[4]) - 1]?.audio_key ?? null;
    }
    if (!key) return publicNotFound();
    const signed = await getSignedUrl(s3, new GetObjectCommand({ Bucket: BUCKET, Key: key }), { expiresIn: HANDOFF_FILE_TTL_S });
    return publicResponse(302, null, { location: signed });
  }

  const recs = (await pool.query(LIVE_RECORDINGS_SQL, [h.id])).rows;
  const ids = recs.map((r) => r.id);
  const [trans, jobs] = await Promise.all([
    pool.query("select * from transcripts where recording_id = any($1::uuid[])", [ids]),
    pool.query("select * from diarization_jobs where recording_id = any($1::uuid[]) and status = 'done'", [ids]),
  ]);
  const tBy = new Map(trans.rows.map((t) => [t.recording_id, t]));
  const jBy = new Map(jobs.rows.map((j) => [j.recording_id, j]));
  const hasSpeakers = (segs: unknown) => Array.isArray(segs) && segs.some((s) => typeof s?.speaker === "string");
  const input: BriefingInput = {
    link: `${publicOrigin(req)}/h/${token}`,
    expires_at: h.expires_at,
    note: { id: h.id, title: h.title, created_at: h.created_at, speaker_names: h.speaker_names ?? {} },
    subject: h.subject_name ?? null,
    payload,
    recordings: recs.map((r) => {
      const t = tBy.get(r.id);
      const j = jBy.get(r.id);
      let transcript: BriefingInput["recordings"][number]["transcript"] = t
        ? { engine: t.engine, segments: t.segments, full_text: t.full_text ?? "" }
        : null;
      // If the iPad re-sent its unlabelled on-device transcript after speaker detection ran on the same
      // audio, the job row still holds the speaker-labelled version: prefer it.
      const sameAudio = j && j.audio_key === r.audio_key && (j.audio_sha256 ?? "") === (r.audio_sha256 ?? "");
      if (sameAudio && j.result && hasSpeakers(j.result.segments) && !hasSpeakers(t?.segments)) {
        transcript = { engine: j.result.engine, segments: j.result.segments, full_text: j.result.full_text ?? "" };
      }
      return { id: r.id, name: r.name, started_at: r.started_at, duration_s: r.duration_s, has_audio: !!r.audio_key, transcript };
    }),
  };
  const head = method === "HEAD";
  if (url.searchParams.get("format") === "json") {
    return publicResponse(200, head ? null : JSON.stringify(renderJson(input), null, 1), { "content-type": "application/json; charset=utf-8" });
  }
  return publicResponse(200, head ? null : renderMarkdown(input), { "content-type": "text/markdown; charset=utf-8" });
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------
async function route(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const path = url.pathname.replace(/\/+$/, "") || "/";
  const m = req.method.toUpperCase();

  // Public: the handoff token in the path is the credential (no Bearer).
  if (path === "/h" || path.startsWith("/h/")) return publicHandoff(req, url, path);

  if (!authorized(req)) return json(401, { error: { code: "unauthorized", message: "missing or invalid bearer token" } });

  if (path === "/api/health") {
    if (m !== "GET") throw new HttpError(405, "method_not_allowed", "use GET");
    return health();
  }
  if (path === "/api/notes") {
    if (m !== "GET") throw new HttpError(405, "method_not_allowed", "use GET");
    return listNotes(url);
  }
  const noteMatch = /^\/api\/notes\/([^/]+)$/.exec(path);
  if (noteMatch) {
    const id = uuid(decodeURIComponent(noteMatch[1]), ":id");
    if (m === "GET") return getNote(id);
    if (m === "PUT") return putNote(id, req);
    if (m === "DELETE") return deleteNote(id);
    throw new HttpError(405, "method_not_allowed", "use GET, PUT or DELETE");
  }
  const handoffMatch = /^\/api\/notes\/([^/]+)\/handoff$/.exec(path);
  if (handoffMatch) {
    const id = uuid(decodeURIComponent(handoffMatch[1]), ":id");
    if (m !== "POST") throw new HttpError(405, "method_not_allowed", "use POST");
    return postHandoff(id, req);
  }
  const revokeMatch = /^\/api\/handoffs\/([^/]+)$/.exec(path);
  if (revokeMatch) {
    if (m !== "DELETE") throw new HttpError(405, "method_not_allowed", "use DELETE");
    return revokeHandoff(decodeURIComponent(revokeMatch[1]));
  }
  const diarizeMatch = /^\/api\/recordings\/([^/]+)\/(diarize|diarization)$/.exec(path);
  if (diarizeMatch) {
    const recId = uuid(decodeURIComponent(diarizeMatch[1]), ":id");
    if (diarizeMatch[2] === "diarize") {
      if (m !== "POST") throw new HttpError(405, "method_not_allowed", "use POST");
      return postDiarize(recId, url);
    }
    if (m !== "GET") throw new HttpError(405, "method_not_allowed", "use GET");
    return getDiarization(recId);
  }
  if (path === "/api/subjects") {
    if (m !== "PUT") throw new HttpError(405, "method_not_allowed", "use PUT");
    return putSubjects(req);
  }
  if (path === "/api/uploads") {
    if (m !== "POST") throw new HttpError(405, "method_not_allowed", "use POST");
    return createUploads(req);
  }
  if (path === "/api/downloads") {
    if (m !== "POST") throw new HttpError(405, "method_not_allowed", "use POST");
    return createDownloads(req);
  }
  throw new HttpError(404, "not_found", `no route for ${m} ${path}`);
}

export default {
  async fetch(req: Request): Promise<Response> {
    try {
      return await route(req);
    } catch (e: any) {
      if (e instanceof HttpError) return errorResponse(e);
      const mapped = mapPgError(e);
      if (mapped) return errorResponse(mapped);
      console.error("[api] unhandled", e?.code ?? "", e?.message ?? e);
      return json(500, { error: { code: "internal", message: "internal error" } });
    }
  },
};
