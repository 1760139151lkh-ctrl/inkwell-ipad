// Inkwell cloud backup API (PRD §8.3) — Neon Function `api`.
// One fetch-style handler + a tiny router. Every /api/* route except GET /api/health requires
// `Authorization: Bearer <Neon Auth JWT>` (Managed Better Auth, verified against the branch JWKS); /h/<token>*
// (agent handoff) is public, the token is the secret. Every row belongs to one account (owner_id); requests run
// under Postgres row-level security as that account. Contracts: server/README.md.

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { Pool, type PoolClient } from "pg";
import { attachDatabasePool, waitUntil } from "@neon/functions";
import {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
  DeleteObjectsCommand,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { createRemoteJWKSet, jwtVerify, errors as joseErrors } from "jose";
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
// Billable-duration floor from the object size: no real m4a exceeds 128 kbps = 16000 B/s, so size / 16000 is a lower
// bound on its duration that the client can't shrink (recordings.duration_s is client-supplied).
const DIARIZE_MIN_BYTES_PER_S = 16000;
// Per-file upload caps (the presigned PUT is signed for the exact declared size).
const MAX_AUDIO_FILE_BYTES = 500 * 1000 * 1000;
const MAX_FILE_BYTES = 50 * 1000 * 1000;
// Agent handoff (README § Agent handoff).
const HANDOFF_DEFAULT_DAYS = 30;
const HANDOFF_MAX_DAYS = 365;
const HANDOFF_MAX_PAGES = 1000;
const HANDOFF_MAX_MOMENTS = 5000;
const HANDOFF_FILE_TTL_S = 60 * 60; // /h/<token>/… redirects to a fresh presigned GET valid this long

// Per-account quotas (README § Quotas). Optional Function env; the defaults apply when unset.
function envLimit(name: string, def: number): number {
  const raw = process.env[name];
  const v = Number(raw);
  return raw !== undefined && raw.trim() !== "" && Number.isFinite(v) && v >= 0 ? v : def;
}
const DIARIZE_MINUTES_PER_MONTH = envLimit("DIARIZE_MINUTES_PER_MONTH", 600);
const HANDOFFS_PER_DAY = envLimit("HANDOFFS_PER_DAY", 100);
const STORAGE_BYTES_PER_ACCOUNT = envLimit("STORAGE_BYTES_PER_ACCOUNT", 20 * 1024 ** 3); // 20 GiB

// Tables that carry owner_id (claimed together by POST /api/account/claim-legacy).
const OWNED_TABLES = [
  "subjects", "notes", "recordings", "transcripts", "elements", "strokes_index", "diarization_jobs", "handoffs",
] as const;

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

// Neon Auth (Managed Better Auth). Both vars are injected into the Function because neon.ts declares `auth: true`.
// Real tokens carry iss = aud = the Auth URL's origin (verified on phase4-staging); EdDSA, 15 min expiry.
const AUTH_ISSUER = process.env.NEON_AUTH_BASE_URL ? new URL(process.env.NEON_AUTH_BASE_URL).origin : null;
const jwks = process.env.NEON_AUTH_JWKS_URL
  ? createRemoteJWKSet(new URL(process.env.NEON_AUTH_JWKS_URL), { timeoutDuration: 5000, cooldownDuration: 30_000 })
  : null;

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

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}

function errorResponse(e: HttpError): Response {
  const body: Record<string, unknown> = { error: { code: e.code, message: e.message } };
  if (e.details !== undefined) (body.error as Record<string, unknown>).details = e.details;
  return json(e.status, body, e.status === 401 ? { "www-authenticate": 'Bearer error="invalid_token"' } : {});
}

const bad = (message: string, details?: unknown) => new HttpError(400, "bad_request", message, details);
const notFound = (message: string) => new HttpError(404, "not_found", message);
const unauthorized = (message = "missing or invalid bearer token") => new HttpError(401, "unauthorized", message);

function sha256(buf: string | Buffer): Buffer {
  return createHash("sha256").update(buf).digest();
}
/** Constant-time string compare (hash both sides so lengths match). */
function secretEquals(given: string, expected: string): boolean {
  return timingSafeEqual(sha256(given), sha256(expected));
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
const KEY_RE = /^notes\/([0-9a-f-]{36})\/(.+)$/;
function validKey(k: string): boolean {
  const m = KEY_RE.exec(k);
  return !!m && UUID_RE.test(m[1]) && validPath(m[2]);
}

// ---------------------------------------------------------------------------
// Auth: Neon Auth JWT → user id
// ---------------------------------------------------------------------------
async function verifyJwt(req: Request): Promise<string> {
  if (!jwks || !AUTH_ISSUER) {
    throw new HttpError(500, "misconfigured", "Neon Auth is not enabled for this Function (NEON_AUTH_JWKS_URL is not set)");
  }
  const m = /^Bearer\s+(\S+)$/i.exec((req.headers.get("authorization") ?? "").trim());
  if (!m) throw unauthorized();
  const token = m[1];
  if (token.split(".").length !== 3) throw unauthorized(); // not a JWT (e.g. the retired shared token)
  let sub: unknown;
  try {
    const { payload } = await jwtVerify(token, jwks, {
      issuer: AUTH_ISSUER,
      audience: AUTH_ISSUER,
      algorithms: ["EdDSA"],
      clockTolerance: 30,
      requiredClaims: ["exp", "sub"],
    });
    sub = payload.sub;
  } catch (e: any) {
    // JWKS unreachable ≠ bad token: don't make the client throw away a good session.
    const jwksDown =
      !(e instanceof joseErrors.JOSEError) || e instanceof joseErrors.JWKSTimeout ||
      e instanceof joseErrors.JWKSInvalid || e.code === "ERR_JOSE_GENERIC";
    if (jwksDown) {
      console.error("[auth] could not load JWKS:", e?.name ?? "", e?.message ?? e);
      throw new HttpError(503, "auth_unavailable", "could not verify the token right now; retry shortly");
    }
    throw unauthorized(e instanceof joseErrors.JWTExpired ? "token expired" : "missing or invalid bearer token");
  }
  if (typeof sub !== "string" || !UUID_RE.test(sub)) throw unauthorized("token has no user id");
  return sub.toLowerCase();
}

// ---------------------------------------------------------------------------
// DB helpers
// ---------------------------------------------------------------------------
type Db = PoolClient;

/** A transaction as the connecting (owner, BYPASSRLS) role. Only for the paths README § RLS lists. */
async function tx<T>(fn: (c: Db) => Promise<T>): Promise<T> {
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

/** Switch the current transaction to the RLS-bound role, acting as `uid`. Both settings end with the transaction. */
async function enterUser(c: Db, uid: string): Promise<void> {
  await c.query("select set_config('app.user_id', $1, true), set_config('role', 'inkwell_app', true)", [uid]);
}

/** A transaction under one account's RLS context, without an auth check (public handoff, background diarization). */
function asUser<T>(uid: string, fn: (c: Db) => Promise<T>): Promise<T> {
  return tx(async (c) => {
    await enterUser(c, uid);
    return fn(c);
  });
}

interface Ctx {
  c: Db;
  uid: string;
  user: { id: string; email: string; name: string };
  /** Work to start after COMMIT (e.g. waitUntil(diarization)), so it never sees uncommitted or rolled-back rows. */
  after: (() => void)[];
}
type Handler = (ctx: Ctx, body: any) => Promise<Response>;
interface Route {
  handler: Handler;
  body?: boolean; // read the JSON body (after the token check, before opening the transaction)
  owner?: boolean; // run as the owner role instead of under RLS (claim-legacy, account deletion)
}

async function runAuthed(req: Request, uid: string, r: Route): Promise<Response> {
  const body = r.body ? await readJson(req) : undefined;
  const after: (() => void)[] = [];
  const res = await tx(async (c) => {
    // A JWT stays valid for up to 15 min after sign-out / ban / account deletion: check the account row every time.
    const { rows } = await c.query(
      `select id, email, name, "emailVerified" as verified,
              (coalesce(banned, false) and ("banExpires" is null or "banExpires" > now())) as banned
       from neon_auth."user" where id = $1`,
      [uid],
    );
    const u = rows[0];
    if (!u) throw unauthorized("account not found");
    if (u.banned) throw unauthorized("account is disabled");
    if (u.verified !== true) throw unauthorized("email address is not verified");
    if (!r.owner) await enterUser(c, uid);
    return r.handler({ c, uid, user: { id: u.id, email: u.email, name: u.name }, after }, body);
  });
  for (const f of after) f();
  return res;
}

function mapPgError(e: any): HttpError | null {
  switch (e?.code) {
    case "23503": // foreign_key_violation
      return new HttpError(409, "foreign_key_violation", e.detail ?? "referenced row does not exist");
    case "42501": // insufficient_privilege: a row-level-security check refused a write the app checks let through
      return notFound("not found");
    case "22P02": // invalid_text_representation
    case "22007": // invalid_datetime_format
    case "22008": // datetime_field_overflow
    case "22003": // numeric_value_out_of_range
      return bad(e.message);
    default:
      return null;
  }
}

/** Ids (of `table`) that exist under another account or as unclaimed legacy rows. Always runs as the owner role. */
async function foreignIds(c: Db, table: "notes" | "subjects" | "recordings" | "elements", ids: string[]): Promise<string[]> {
  if (ids.length === 0) return [];
  const { rows } = await c.query("select id from app_foreign_ids($1, $2::uuid[]) as id", [table, ids]);
  return rows.map((r) => r.id);
}

/**
 * Bind a client-generated note id to the caller (note_claims), or 404 if another account (or legacy data) has it.
 * The iPad presigns uploads before its first PUT, so both paths call this.
 */
async function claimNoteId(c: Db, uid: string, noteId: string): Promise<void> {
  if ((await foreignIds(c, "notes", [noteId])).length) throw notFound("note not found");
  await c.query("insert into note_claims (note_id, owner_id) values ($1, $2) on conflict (note_id) do nothing", [noteId, uid]);
  // Lost a race to another account? Its claim is invisible under RLS, so ours is missing.
  const own = await c.query("select 1 from note_claims where note_id = $1 and owner_id = $2", [noteId, uid]);
  if (own.rowCount === 0) throw notFound("note not found");
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
// Quotas
// ---------------------------------------------------------------------------
async function usageOf(c: Db, uid: string) {
  const { rows } = await c.query(
    `select coalesce(sum(amount) filter (where kind = 'diarize_minutes' and created_at >= date_trunc('month', now(), 'UTC')), 0)::float8 as minutes,
            count(*) filter (where kind = 'handoff' and created_at >= date_trunc('day', now(), 'UTC'))::int as handoffs,
            date_trunc('month', now(), 'UTC') + interval '1 month' as month_resets_at,
            date_trunc('day', now(), 'UTC') + interval '1 day' as day_resets_at,
            (select coalesce(sum(bytes), 0) from object_ledger where owner_id = $1)::float8 as storage_bytes
     from usage_events where owner_id = $1 and created_at >= date_trunc('month', now(), 'UTC') - interval '1 day'`,
    [uid],
  );
  return rows[0] as { minutes: number; handoffs: number; month_resets_at: Date; day_resets_at: Date; storage_bytes: number };
}

/** Serialize one account's quota check + ledger insert (two concurrent requests can't both squeeze under the limit). */
async function lockQuota(c: Db, uid: string) {
  await c.query("select pg_advisory_xact_lock(hashtextextended('inkwell-quota:' || $1, 0))", [uid]);
}

const round1 = (x: number) => Math.round(x * 10) / 10;

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------
async function health(): Promise<Response> {
  const { rows } = await pool.query("select now() as now");
  return json(200, { ok: true, db: true, time: iso(rows[0].now) });
}

async function getMe({ c, uid, user }: Ctx): Promise<Response> {
  const u = await usageOf(c, uid);
  return json(200, {
    user,
    usage: {
      diarization_minutes_month: round1(u.minutes),
      diarization_minutes_limit: DIARIZE_MINUTES_PER_MONTH,
      handoffs_today: u.handoffs,
      handoffs_limit: HANDOFFS_PER_DAY,
      storage_bytes: u.storage_bytes,
      storage_limit_bytes: STORAGE_BYTES_PER_ACCOUNT,
    },
  });
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

async function upsertSubject(c: Db, uid: string, s: ReturnType<typeof parseSubject>) {
  await c.query(
    `insert into subjects (id, name, color_hex, sort_index, divider_id, updated_at, deleted_at, owner_id)
     values ($1,$2,$3,$4,$5,$6,$7,$8)
     on conflict (id) do update set name = excluded.name, color_hex = excluded.color_hex,
       sort_index = excluded.sort_index, divider_id = excluded.divider_id,
       updated_at = excluded.updated_at, deleted_at = excluded.deleted_at`,
    [s.id, s.name, s.color_hex, s.sort_index, s.divider_id, s.updated_at, s.deleted_at, uid],
  );
}

async function putNote({ c, uid }: Ctx, id: string, body: any): Promise<Response> {
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

  // Ownership: every id in the payload must be new or already the caller's. Anything else is 404 for the whole request.
  await claimNoteId(c, uid, note.id);
  const subjectRef = subject?.id ?? note.subject_id;
  if (subjectRef && (await foreignIds(c, "subjects", [subjectRef])).length) throw notFound("subject not found");
  if ((await foreignIds(c, "recordings", [...recIds])).length) throw notFound("recording not found");
  if ((await foreignIds(c, "elements", elements.map((e) => e.id))).length) throw notFound("element not found");

  if (subject) await upsertSubject(c, uid, subject);

  await c.query(
    `insert into notes (id, subject_id, title, paper, page_count, bookmarked_pages, created_at, modified_at,
                        deleted_at, drawing_key, drawing_sha256, thumb_key, background_key, speaker_names, owner_id)
     values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13, coalesce($14::jsonb, '{}'::jsonb), $15)
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
      speakerNames === undefined ? null : JSON.stringify(speakerNames), uid,
    ],
  );

  for (const r of recordings) {
    // `where recordings.note_id = excluded.note_id` stops a payload from hijacking another note's recording.
    const res = await c.query(
      `insert into recordings (id, note_id, ord, name, started_at, duration_s, audio_key, audio_sha256,
                               transcript_status, deleted_at, owner_id)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
       on conflict (id) do update set ord = excluded.ord, name = excluded.name,
         started_at = excluded.started_at, duration_s = excluded.duration_s, audio_key = excluded.audio_key,
         audio_sha256 = excluded.audio_sha256, transcript_status = excluded.transcript_status,
         deleted_at = excluded.deleted_at
       where recordings.note_id = excluded.note_id`,
      [r.id, note.id, r.ord, r.name, r.started_at, r.duration_s, r.audio_key, r.audio_sha256,
        r.transcript_status, r.deleted_at, uid],
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
      `insert into transcripts (recording_id, locale, engine, segments, full_text, owner_id)
       values ($1,$2,$3,$4,$5,$6)
       on conflict (recording_id) do update set locale = excluded.locale, engine = excluded.engine,
         segments = excluded.segments, full_text = excluded.full_text`,
      [t.recording_id, t.locale, t.engine, JSON.stringify(t.segments), t.full_text, uid],
    );
  }

  if (strokes !== null) {
    await c.query(
      `insert into strokes_index (note_id, strokes, owner_id) values ($1,$2,$3)
       on conflict (note_id) do update set strokes = excluded.strokes`,
      [note.id, JSON.stringify(strokes), uid],
    );
  }

  for (const e of elements) {
    const res = await c.query(
      `insert into elements (id, note_id, kind, frame, created_at, text, file_key, deleted_at, owner_id)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9)
       on conflict (id) do update set kind = excluded.kind, frame = excluded.frame,
         created_at = excluded.created_at, text = excluded.text, file_key = excluded.file_key,
         deleted_at = excluded.deleted_at
       where elements.note_id = excluded.note_id`,
      [e.id, note.id, e.kind, JSON.stringify(e.frame), e.created_at, e.text, e.file_key, e.deleted_at, uid],
    );
    if (res.rowCount === 0) throw new HttpError(409, "id_conflict", `element ${e.id} belongs to another note`);
  }
  const elTomb = await c.query(
    `update elements set deleted_at = now()
     where note_id = $1 and deleted_at is null and not (id = any($2::uuid[]))`,
    [note.id, elements.map((e) => e.id)],
  );

  const { rows } = await c.query("select now() as now");
  return json(200, {
    ok: true,
    id: note.id,
    recordings: { upserted: recordings.length, tombstoned: recTomb.rowCount ?? 0 },
    elements: { upserted: elements.length, tombstoned: elTomb.rowCount ?? 0 },
    transcripts: { upserted: transcripts.length },
    strokes_index: strokes === null ? "unchanged" : "replaced",
    server_time: iso(rows[0].now),
  });
}

async function putSubjects({ c, uid }: Ctx, body: any): Promise<Response> {
  if (!isObj(body) || !Array.isArray(body.subjects)) throw bad("body must be {subjects:[...]}");
  const subjects = body.subjects.map((s: unknown, i: number) => parseSubject(s, `subjects[${i}]`));
  const foreign = await foreignIds(c, "subjects", subjects.map((s: { id: string }) => s.id));
  if (foreign.length) throw notFound(`subject ${foreign[0]} not found`);
  for (const s of subjects) await upsertSubject(c, uid, s);
  return json(200, { ok: true, upserted: subjects.length });
}

async function getNote({ c, uid }: Ctx, id: string): Promise<Response> {
  const noteRes = await c.query("select * from notes where id = $1 and owner_id = $2", [id, uid]);
  if (noteRes.rowCount === 0) throw notFound("note not found");
  const n = noteRes.rows[0];
  const [subj, recs, trans, strokes, els] = await Promise.all([
    n.subject_id
      ? c.query("select * from subjects where id = $1 and owner_id = $2", [n.subject_id, uid])
      : Promise.resolve({ rows: [] as any[] }),
    c.query("select * from recordings where note_id = $1 order by ord, started_at", [id]),
    c.query(
      `select t.* from transcripts t join recordings r on r.id = t.recording_id
       where r.note_id = $1 order by r.ord`,
      [id],
    ),
    c.query("select strokes from strokes_index where note_id = $1", [id]),
    c.query("select * from elements where note_id = $1 order by created_at", [id]),
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

async function listNotes({ c, uid }: Ctx, url: URL): Promise<Response> {
  const since = url.searchParams.get("since");
  if (since !== null && Number.isNaN(Date.parse(since))) throw bad("since must be an ISO-8601 timestamp");
  const limitRaw = url.searchParams.get("limit");
  const limit = limitRaw === null ? LIST_DEFAULT_LIMIT : Number(limitRaw);
  if (!Number.isInteger(limit) || limit < 1 || limit > LIST_MAX_LIMIT) throw bad(`limit must be 1..${LIST_MAX_LIMIT}`);
  const cursor = url.searchParams.get("cursor");
  const includeUrls = ["1", "true"].includes(url.searchParams.get("urls") ?? "");

  // A note "changed" when it was modified or tombstoned.
  const changed = "greatest(n.modified_at, coalesce(n.deleted_at, n.modified_at))";
  const params: unknown[] = [uid];
  const where: string[] = ["n.owner_id = $1"];
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
  const { rows } = await c.query(
    `select n.*, ${changed} as changed_at from notes n
     where ${where.join(" and ")}
     order by changed_at, n.id limit $${params.length}`,
    params,
  );
  const hasMore = rows.length > limit;
  const page = rows.slice(0, limit);
  const ids = page.map((r) => r.id);

  const [recs, els, subs, now] = await Promise.all([
    c.query(
      `select r.*, exists(select 1 from transcripts t where t.recording_id = r.id) as has_transcript
       from recordings r where r.note_id = any($1::uuid[]) order by r.ord, r.started_at`,
      [ids],
    ),
    c.query("select * from elements where note_id = any($1::uuid[]) order by created_at", [ids]),
    // All of the caller's subjects every time: small, and restore needs empty subjects + sort order too.
    c.query("select * from subjects where owner_id = $1 order by sort_index, name", [uid]),
    c.query("select now() as now"),
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

async function deleteNote({ c, uid }: Ctx, id: string): Promise<Response> {
  const res = await c.query(
    `update notes set deleted_at = coalesce(deleted_at, now()) where id = $1 and owner_id = $2 returning deleted_at`,
    [id, uid],
  );
  if (res.rowCount === 0) throw notFound("note not found");
  const deletedAt = res.rows[0].deleted_at;
  const r = await c.query(`update recordings set deleted_at = $2 where note_id = $1 and deleted_at is null`, [id, deletedAt]);
  const e = await c.query(`update elements set deleted_at = $2 where note_id = $1 and deleted_at is null`, [id, deletedAt]);
  return json(200, {
    ok: true,
    id,
    deleted_at: iso(deletedAt),
    recordings_tombstoned: r.rowCount ?? 0,
    elements_tombstoned: e.rowCount ?? 0,
  });
}

async function createUploads({ c, uid }: Ctx, body: any): Promise<Response> {
  if (!isObj(body)) throw bad("body must be a JSON object");
  const noteId = uuid(body.noteId, "noteId");
  if (!Array.isArray(body.files) || body.files.length === 0) throw bad("files must be a non-empty array");
  if (body.files.length > MAX_UPLOAD_FILES) throw bad(`at most ${MAX_UPLOAD_FILES} files per request`);
  const files = body.files.map((f: unknown, i: number) => {
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
    const size = int(f.size, `${field}.size`);
    if (size <= 0) throw bad(`${field}.size must be the file's size in bytes (> 0)`);
    const cap = path.startsWith("audio/") ? MAX_AUDIO_FILE_BYTES : MAX_FILE_BYTES;
    if (size > cap) throw new HttpError(413, "payload_too_large", `${field}: ${path} is ${size} bytes; the limit is ${cap}`);
    return { path, sha, contentType, size, key: `notes/${noteId}/${path}` };
  });

  // The note must be the caller's; a fresh client-generated id is claimed for the caller here.
  await claimNoteId(c, uid, noteId);

  // Storage quota: the account's ledger total, with this request's keys replaced by their new sizes.
  const sizes = new Map<string, number>(files.map((f: { key: string; size: number }) => [f.key, f.size]));
  await lockQuota(c, uid);
  const { rows: st } = await c.query(
    `select coalesce(sum(bytes) filter (where not (key = any($2::text[]))), 0)::float8 as others
     from object_ledger where owner_id = $1`,
    [uid, [...sizes.keys()]],
  );
  const after = st[0].others + [...sizes.values()].reduce((a, b) => a + b, 0);
  if (after > STORAGE_BYTES_PER_ACCOUNT) {
    const gib = (b: number) => `${round1(b / 1024 ** 3)} GiB`;
    throw new HttpError(
      429,
      "quota_exceeded",
      `Backup storage is limited to ${gib(STORAGE_BYTES_PER_ACCOUNT)} per account. You're using ${gib(st[0].others)}, ` +
        `and these files would bring it to ${gib(after)}. Delete notes (and empty Recently Deleted) to free space.`,
      { limit: STORAGE_BYTES_PER_ACCOUNT, used: st[0].others, requested: after - st[0].others },
    );
  }
  for (const [key, bytes] of sizes) {
    await c.query(
      `insert into object_ledger (key, owner_id, bytes) values ($1, $2, $3)
       on conflict (key) do update set bytes = excluded.bytes, updated_at = now()`,
      [key, uid, bytes],
    );
  }

  const uploads = await Promise.all(
    files.map(async ({ path, sha, contentType, size, key }: { path: string; sha: string; contentType: string; size: number; key: string }) => {
      const ttl = path.startsWith("audio/") ? UPLOAD_TTL_AUDIO_S : UPLOAD_TTL_S;
      const url = await getSignedUrl(
        s3,
        new PutObjectCommand({ Bucket: BUCKET, Key: key, ContentType: contentType, ContentLength: size, Metadata: { sha256: sha } }),
        // Keep x-amz-meta-sha256 and content-length as signed *headers* (Neon ignores them as query params):
        // the object then carries its hash (visible via HEAD), and a body of any other size is rejected (403).
        { expiresIn: ttl, unhoistableHeaders: new Set(["x-amz-meta-sha256", "content-length"]) },
      );
      return {
        path,
        key,
        url,
        method: "PUT",
        headers: { "Content-Type": contentType, "Content-Length": String(size), "x-amz-meta-sha256": sha },
        expires_at: new Date(Date.now() + ttl * 1000).toISOString(),
      };
    }),
  );
  return json(200, { uploads });
}

async function createDownloads({ c, uid }: Ctx, body: any): Promise<Response> {
  if (!isObj(body) || !Array.isArray(body.keys)) throw bad("body must be {keys:[...]}");
  if (body.keys.length > MAX_DOWNLOAD_KEYS) throw bad(`at most ${MAX_DOWNLOAD_KEYS} keys per request`);
  const keys: string[] = body.keys.map((k: unknown, i: number) => {
    if (typeof k !== "string" || !validKey(k)) throw bad(`keys[${i}] must be a notes/<noteId>/<allowed path> key`);
    return k;
  });
  // Every key must sit under one of the caller's notes (backed up or claimed; tombstoned notes included for restore).
  const noteIds = [...new Set(keys.map((k) => KEY_RE.exec(k)![1].toLowerCase()))];
  if (noteIds.length) {
    const { rows } = await c.query(
      `select id from notes where id = any($1::uuid[]) and owner_id = $2
       union select note_id from note_claims where note_id = any($1::uuid[]) and owner_id = $2`,
      [noteIds, uid],
    );
    // Keys are case-sensitive, but a note id in a key must be the lowercase form the server issued.
    const mine = new Set(rows.map((r) => r.id));
    const bad404 = keys.find((k) => !mine.has(KEY_RE.exec(k)![1]));
    if (bad404) throw notFound("note not found");
  }
  return json(200, { downloads: await Promise.all(keys.map(presignGet)) });
}

// ---------------------------------------------------------------------------
// Speaker detection (diarization) — README § Speaker detection.
// POST starts a job and returns at once; the provider call runs in waitUntil (≤15 min on Neon).
// No cron: a job whose isolate died is re-claimed by the next POST/GET poll (the iPad polls every ~5 s),
// so the Postgres compute can still scale to zero when nobody is looking.
// All job reads/writes run under the job owner's RLS context.
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

async function diarizationJob(c: Db, uid: string, recId: string) {
  const { rows } = await c.query("select * from diarization_jobs where recording_id = $1 and owner_id = $2", [recId, uid]);
  return rows[0] ?? null;
}

/**
 * Claim the job if it is runnable (fresh pending, pending past its retry back-off, or running but stale)
 * and start the provider call in waitUntil after COMMIT. Exhausted retries become 'failed'. Cheap no-op otherwise.
 */
async function kickDiarization({ c, uid, after }: Ctx, recId: string): Promise<void> {
  await c.query(
    `update diarization_jobs set status = 'failed', finished_at = now(), updated_at = now(),
       error = coalesce(error, 'worker stopped responding') || ' (gave up after ' || attempts || ' attempts)'
     where recording_id = $1 and owner_id = $4 and attempts >= $2
       and (status = 'pending' or (status = 'running' and started_at < now() - make_interval(secs => $3)))`,
    [recId, DIARIZE_MAX_ATTEMPTS, DIARIZE_STALE_S, uid],
  );
  const { rows } = await c.query(
    `update diarization_jobs set status = 'running', attempts = attempts + 1, started_at = now(), updated_at = now(),
       claim_id = gen_random_uuid()
     where recording_id = $1 and owner_id = $5 and attempts < $2 and (
       (status = 'pending' and (attempts = 0 or updated_at < now() - make_interval(secs => $4)))
       or (status = 'running' and started_at < now() - make_interval(secs => $3)))
     returning *`,
    [recId, DIARIZE_MAX_ATTEMPTS, DIARIZE_STALE_S, DIARIZE_RETRY_AFTER_S, uid],
  );
  const job = rows[0];
  if (job) after.push(() => waitUntil(runDiarization(job)));
}

async function runDiarization(job: any): Promise<void> {
  const t0 = Date.now();
  const owner: string = job.owner_id;
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
    await asUser(owner, async (c) => {
      const prev = await c.query("select locale from transcripts where recording_id = $1", [job.recording_id]);
      const locale: string | null = prev.rows[0]?.locale ?? d.language_code;
      const result = { engine: DIARIZE_ENGINE, locale, segments: d.segments, full_text: d.full_text, speakers: d.speakers };
      const u = await c.query(
        `update diarization_jobs set status = 'done', error = null, finished_at = now(), updated_at = now(),
           audio_duration_s = $3, provider_transcription_id = $4, result = $5
         where recording_id = $1 and claim_id = $2`,
        [job.recording_id, job.claim_id, d.audio_duration_s, d.provider_transcription_id, JSON.stringify(result)],
      );
      if (u.rowCount === 0) return; // superseded by a newer run (or the account/recording is gone)
      // Settle the up-front charge to what the provider measured.
      if (job.usage_event_id && d.audio_duration_s != null) {
        await c.query("update usage_events set amount = $2 where id = $1", [job.usage_event_id, d.audio_duration_s / 60]);
      }
      // Don't replace an existing on-device transcript with an empty one (silent audio).
      if (d.segments.length > 0) {
        await c.query(
          `insert into transcripts (recording_id, locale, engine, segments, full_text, owner_id) values ($1,$2,$3,$4,$5,$6)
           on conflict (recording_id) do update set locale = excluded.locale, engine = excluded.engine,
             segments = excluded.segments, full_text = excluded.full_text`,
          [job.recording_id, locale, DIARIZE_ENGINE, JSON.stringify(d.segments), d.full_text, owner],
        );
      }
    });
    console.log("[diarize] done", job.recording_id, `${d.audio_duration_s ?? "?"}s audio`, `${d.speakers.length} speakers`,
      `${d.segments.length} segments`, `${Date.now() - t0}ms`);
  } catch (e: any) {
    const transient = e instanceof TransientError;
    const msg = String(e?.message ?? e).slice(0, 500);
    console.error("[diarize] failed", job.recording_id, transient ? "(transient)" : "", msg);
    await asUser(owner, (c) =>
      c.query(
        `update diarization_jobs set error = $3, updated_at = now(),
           status = case when $4 and attempts < $5 then 'pending' else 'failed' end,
           finished_at = case when $4 and attempts < $5 then null else now() end
         where recording_id = $1 and claim_id = $2`,
        [job.recording_id, job.claim_id, msg, transient, DIARIZE_MAX_ATTEMPTS],
      ),
    ).catch((e2) => console.error("[diarize] could not record failure", e2?.message ?? e2));
  }
}

async function postDiarize(ctx: Ctx, recId: string, url: URL): Promise<Response> {
  const { c, uid } = ctx;
  const { rows } = await c.query(
    "select id, audio_key, audio_sha256, duration_s from recordings where id = $1 and owner_id = $2",
    [recId, uid],
  );
  const rec = rows[0];
  if (!rec) throw notFound("recording not found (PUT the note with this recording first)");
  if (!rec.audio_key) {
    throw new HttpError(409, "audio_not_uploaded", "recording has no audio_key yet: upload the audio, PUT the note, then retry");
  }
  if (rec.duration_s > DIARIZE_MAX_DURATION_S) {
    throw new HttpError(413, "audio_too_long", `recordings longer than ${DIARIZE_MAX_DURATION_S / 3600} h can't be diarized`);
  }
  if (!process.env.ELEVENLABS_API_KEY) throw new HttpError(500, "misconfigured", "ELEVENLABS_API_KEY is not set on the function");
  const force = ["1", "true"].includes(url.searchParams.get("force") ?? "");

  const existing = await diarizationJob(c, uid, recId);
  const sameAudio =
    existing && existing.audio_key === rec.audio_key && (existing.audio_sha256 ?? "") === (rec.audio_sha256 ?? "");
  if (existing && sameAudio && (existing.status === "pending" || existing.status === "running")) {
    await kickDiarization(ctx, recId); // re-claims only if stale
    return json(202, diarizationOut(await diarizationJob(c, uid, recId)));
  }
  if (existing && sameAudio && existing.status === "done" && !force) return json(200, diarizationOut(existing));

  // New job, a retry after 'failed', a re-run with ?force=1, or the audio changed. Check the object exists first.
  let objectBytes = 0;
  try {
    const head = await s3.send(new HeadObjectCommand({ Bucket: BUCKET, Key: rec.audio_key }));
    objectBytes = head.ContentLength ?? 0;
    if (objectBytes > DIARIZE_MAX_BYTES) {
      throw new HttpError(413, "audio_too_long", `audio object is larger than ${DIARIZE_MAX_BYTES} bytes`);
    }
  } catch (e: any) {
    if (e instanceof HttpError) throw e;
    if (e?.name === "NotFound" || e?.name === "NoSuchKey" || e?.$metadata?.httpStatusCode === 404) {
      throw new HttpError(409, "audio_not_uploaded", "audio object not found in storage yet: finish the upload, then retry");
    }
    throw e;
  }

  // Billable seconds, not trusting the client's duration_s: at least size / 16000 B/s (a 128 kbps ceiling).
  const billableS = Math.max(Math.max(0, rec.duration_s), objectBytes / DIARIZE_MIN_BYTES_PER_S);
  if (billableS > DIARIZE_MAX_DURATION_S) {
    throw new HttpError(413, "audio_too_long", `recordings longer than ${DIARIZE_MAX_DURATION_S / 3600} h can't be diarized`);
  }

  // Quota: minutes of audio sent to the provider this calendar month (UTC). Charged up front at the estimate, settled
  // to the provider's measured duration when the job finishes (kept as charged if it fails).
  await lockQuota(c, uid);
  const used = await usageOf(c, uid);
  const minutes = billableS / 60;
  if (used.minutes + minutes > DIARIZE_MINUTES_PER_MONTH) {
    throw new HttpError(
      429,
      "quota_exceeded",
      `Speaker detection is limited to ${DIARIZE_MINUTES_PER_MONTH} minutes of audio per month. ` +
        `You've used ${round1(used.minutes)} and this recording is ${round1(minutes)}. ` +
        `The limit resets ${iso(used.month_resets_at)!.slice(0, 10)} (UTC).`,
      { limit: DIARIZE_MINUTES_PER_MONTH, used: round1(used.minutes), requested: round1(minutes), resets_at: iso(used.month_resets_at) },
    );
  }
  const charge = await c.query(
    "insert into usage_events (owner_id, kind, amount) values ($1, 'diarize_minutes', $2) returning id",
    [uid, minutes],
  );

  await c.query(
    `insert into diarization_jobs (recording_id, status, provider, audio_key, audio_sha256, owner_id, usage_event_id)
     values ($1, 'pending', $2, $3, $4, $5, $6)
     on conflict (recording_id) do update set status = 'pending', provider = excluded.provider,
       audio_key = excluded.audio_key, audio_sha256 = excluded.audio_sha256, attempts = 0, error = null,
       requested_at = now(), started_at = null, updated_at = now(), finished_at = null, claim_id = null,
       audio_duration_s = null, provider_transcription_id = null, result = null, usage_event_id = excluded.usage_event_id`,
    [recId, DIARIZE_ENGINE, rec.audio_key, rec.audio_sha256, uid, charge.rows[0].id],
  );
  await kickDiarization(ctx, recId);
  return json(202, diarizationOut(await diarizationJob(c, uid, recId)));
}

async function getDiarization(ctx: Ctx, recId: string): Promise<Response> {
  const { c, uid } = ctx;
  let job = await diarizationJob(c, uid, recId);
  if (!job) {
    const r = await c.query("select 1 from recordings where id = $1 and owner_id = $2", [recId, uid]);
    if (r.rowCount === 0) throw notFound("recording not found");
    return json(200, { recording_id: recId, status: "none" });
  }
  if (job.status === "pending" || job.status === "running") {
    await kickDiarization(ctx, recId); // resumes a job whose worker died or is due a retry
    job = await diarizationJob(c, uid, recId);
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

async function postHandoff({ c, uid }: Ctx, noteId: string, req: Request, body: any): Promise<Response> {
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

  const n = await c.query("select deleted_at from notes where id = $1 and owner_id = $2", [noteId, uid]);
  if (n.rowCount === 0) throw notFound("note not found (back it up with PUT /api/notes/:id first)");
  if (n.rows[0].deleted_at) throw notFound("note is deleted");

  await lockQuota(c, uid);
  const used = await usageOf(c, uid);
  if (used.handoffs + 1 > HANDOFFS_PER_DAY) {
    throw new HttpError(
      429,
      "quota_exceeded",
      `You can create ${HANDOFFS_PER_DAY} handoff links per day. The limit resets at ${iso(used.day_resets_at)} (UTC midnight).`,
      { limit: HANDOFFS_PER_DAY, used: used.handoffs, resets_at: iso(used.day_resets_at) },
    );
  }

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
  const { rows } = await c.query(
    `insert into handoffs (token_hash, note_id, payload, expires_at, owner_id)
     values ($1, $2, $3, now() + make_interval(days => $4), $5) returning expires_at`,
    [tokenHash(token), noteId, JSON.stringify(payload), days, uid],
  );
  await c.query("insert into usage_events (owner_id, kind, amount) values ($1, 'handoff', 1)", [uid]);
  const out: Record<string, unknown> = { url: `${publicOrigin(req)}/h/${token}`, token, expires_at: iso(rows[0].expires_at) };
  if (missing.length) out.warnings = missing.map((k) => `${k} is not in storage yet; its link will 404 until it is uploaded`);
  return json(200, out);
}

async function revokeHandoff({ c, uid }: Ctx, token: string): Promise<Response> {
  if (!HANDOFF_TOKEN_RE.test(token)) throw notFound("handoff not found");
  const { rows } = await c.query(
    `update handoffs set revoked_at = coalesce(revoked_at, now()) where token_hash = $1 and owner_id = $2
     returning note_id, revoked_at`,
    [tokenHash(token), uid],
  );
  if (!rows[0]) throw notFound("handoff not found");
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
  // The one lookup outside RLS: token → (note, owner). By SHA-256 of the token: the stored value never reveals the
  // token, and comparing hashes via the primary-key index leaks nothing useful about the token itself.
  const hr = await pool.query(
    `select h.note_id, h.owner_id, h.payload, h.expires_at from handoffs h
     join neon_auth."user" u on u.id = h.owner_id
     where h.token_hash = $1 and h.revoked_at is null and h.expires_at > now()
       and not (coalesce(u.banned, false) and (u."banExpires" is null or u."banExpires" > now()))`,
    [tokenHash(token)],
  );
  const link = hr.rows[0];
  if (!link || !link.owner_id) return publicNotFound(); // unclaimed legacy links stay dead until claimed
  const owner: string = link.owner_id;

  // Everything else is read as the handoff's owner, and the note must be theirs.
  return asUser(owner, async (c) => {
    const { rows } = await c.query(
      `select n.id, n.title, n.created_at, n.speaker_names, s.name as subject_name
       from notes n left join subjects s on s.id = n.subject_id and s.owner_id = n.owner_id
       where n.id = $1 and n.owner_id = $2 and n.deleted_at is null`,
      [link.note_id, owner],
    );
    const h = rows[0];
    if (!h) return publicNotFound();
    const payload = link.payload as HandoffPayload;

    // File links: 302 to a fresh presigned GET, so links in the briefing never go stale.
    if (m[2]) {
      let key: string | null = null;
      if (m[2] === "notes.pdf") key = payload.pdf_key;
      else if (m[3]) key = payload.pages.find((p) => p.index === Number(m[3]) - 1)?.png_key ?? null;
      else if (m[4]) {
        const recs = await c.query(LIVE_RECORDINGS_SQL, [h.id]);
        key = recs.rows[Number(m[4]) - 1]?.audio_key ?? null;
      }
      if (!key || !key.startsWith(`notes/${h.id}/`)) return publicNotFound();
      const signed = await getSignedUrl(s3, new GetObjectCommand({ Bucket: BUCKET, Key: key }), { expiresIn: HANDOFF_FILE_TTL_S });
      return publicResponse(302, null, { location: signed });
    }

    const recs = (await c.query(LIVE_RECORDINGS_SQL, [h.id])).rows;
    const ids = recs.map((r) => r.id);
    const [trans, jobs] = await Promise.all([
      c.query("select * from transcripts where recording_id = any($1::uuid[])", [ids]),
      c.query("select * from diarization_jobs where recording_id = any($1::uuid[]) and status = 'done'", [ids]),
    ]);
    const tBy = new Map(trans.rows.map((t) => [t.recording_id, t]));
    const jBy = new Map(jobs.rows.map((j) => [j.recording_id, j]));
    const hasSpeakers = (segs: unknown) => Array.isArray(segs) && segs.some((s) => typeof s?.speaker === "string");
    const input: BriefingInput = {
      link: `${publicOrigin(req)}/h/${token}`,
      expires_at: link.expires_at,
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
  });
}

// ---------------------------------------------------------------------------
// Account endpoints (README § Accounts)
// ---------------------------------------------------------------------------
/** Owner role: moves every pre-accounts (owner_id IS NULL) row to the caller. Second factor: the retired shared token. */
async function claimLegacy({ c, uid }: Ctx, req: Request): Promise<Response> {
  const expected = process.env.INKWELL_API_TOKEN;
  const given = req.headers.get("x-inkwell-legacy-token");
  if (!expected || !given || !secretEquals(given, expected)) {
    throw new HttpError(403, "forbidden", "missing or wrong X-Inkwell-Legacy-Token");
  }
  await c.query("insert into legacy_claims (id) values (1) on conflict (id) do nothing");
  const lc = (await c.query("select claimed_by from legacy_claims where id = 1 for update")).rows[0];
  if (lc.claimed_by && lc.claimed_by !== uid) {
    throw new HttpError(409, "already_claimed", "the pre-accounts backup was already claimed by another account");
  }
  const claimed: Record<string, number> = {};
  for (const t of OWNED_TABLES) {
    claimed[t] = (await c.query(`update ${t} set owner_id = $1 where owner_id is null`, [uid])).rowCount ?? 0;
  }
  await c.query(
    `update legacy_claims set counts = case when claimed_by is null then $2::jsonb else counts end,
       claimed_by = $1, claimed_at = coalesce(claimed_at, now()) where id = 1`,
    [uid, JSON.stringify(claimed)],
  );
  console.log("[account] legacy claim", uid, JSON.stringify(claimed));
  return json(200, { claimed });
}

/** Delete every object under `prefix`. Throws on any failure (the caller then deletes nothing else). */
async function deletePrefix(prefix: string): Promise<number> {
  let n = 0;
  let token: string | undefined;
  do {
    const page = await s3.send(new ListObjectsV2Command({ Bucket: BUCKET, Prefix: prefix, ContinuationToken: token }));
    const keys = (page.Contents ?? []).map((o) => ({ Key: o.Key! }));
    if (keys.length) {
      const r = await s3.send(new DeleteObjectsCommand({ Bucket: BUCKET, Delete: { Objects: keys, Quiet: true } }));
      if (r.Errors?.length) throw new Error(`${r.Errors.length} object(s) under ${prefix} failed to delete: ${r.Errors[0].Code}`);
      n += keys.length;
    }
    token = page.IsTruncated ? page.NextContinuationToken : undefined;
  } while (token);
  return n;
}

/** Owner role: bucket objects first, then the neon_auth user row (FK cascades remove every app row + sessions). */
async function deleteAccount({ c, uid }: Ctx, body: any): Promise<Response> {
  if (!isObj(body) || body.confirm !== "delete my account") throw bad('body must be {"confirm":"delete my account"}');
  const { rows } = await c.query(
    "select id from notes where owner_id = $1 union select note_id from note_claims where owner_id = $1",
    [uid],
  );
  const ids: string[] = rows.map((r) => r.id);
  let objects = 0;
  try {
    for (const id of ids) objects += await deletePrefix(`notes/${id}/`);
  } catch (e: any) {
    console.error("[account] object deletion failed", uid, e?.name ?? "", e?.message ?? e);
    throw new HttpError(500, "storage_error", "could not delete your stored files; nothing else was deleted. Retry.");
  }
  // Tombstone every removed note id: nobody can claim it again (and inherit stale links) — see app_foreign_ids().
  await c.query("insert into deleted_note_ids (note_id) select unnest($1::uuid[]) on conflict do nothing", [ids]);
  await c.query(`delete from neon_auth."user" where id = $1`, [uid]);
  console.log("[account] deleted", uid, `${ids.length} notes`, `${objects} objects`);
  return json(200, { deleted: { notes: ids.length, objects } });
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------
const methodNotAllowed = (allowed: string) => new HttpError(405, "method_not_allowed", `use ${allowed}`);
function decodeSegment(v: string): string {
  try {
    return decodeURIComponent(v);
  } catch {
    throw bad("malformed %-encoding in the path");
  }
}

/** Resolve an authenticated /api/* route (throws 404/405/400 for unknown paths, wrong methods, bad ids). */
function resolve(req: Request, url: URL, path: string, m: string): Route {
  if (path === "/api/me") {
    if (m !== "GET") throw methodNotAllowed("GET");
    return { handler: (ctx) => getMe(ctx) };
  }
  if (path === "/api/account/claim-legacy") {
    if (m !== "POST") throw methodNotAllowed("POST");
    return { owner: true, handler: (ctx) => claimLegacy(ctx, req) };
  }
  if (path === "/api/account") {
    if (m !== "DELETE") throw methodNotAllowed("DELETE");
    return { owner: true, body: true, handler: (ctx, body) => deleteAccount(ctx, body) };
  }
  if (path === "/api/notes") {
    if (m !== "GET") throw methodNotAllowed("GET");
    return { handler: (ctx) => listNotes(ctx, url) };
  }
  const noteMatch = /^\/api\/notes\/([^/]+)$/.exec(path);
  if (noteMatch) {
    const id = uuid(decodeSegment(noteMatch[1]), ":id");
    if (m === "GET") return { handler: (ctx) => getNote(ctx, id) };
    if (m === "PUT") return { body: true, handler: (ctx, body) => putNote(ctx, id, body) };
    if (m === "DELETE") return { handler: (ctx) => deleteNote(ctx, id) };
    throw methodNotAllowed("GET, PUT or DELETE");
  }
  const handoffMatch = /^\/api\/notes\/([^/]+)\/handoff$/.exec(path);
  if (handoffMatch) {
    const id = uuid(decodeSegment(handoffMatch[1]), ":id");
    if (m !== "POST") throw methodNotAllowed("POST");
    return { body: true, handler: (ctx, body) => postHandoff(ctx, id, req, body) };
  }
  const revokeMatch = /^\/api\/handoffs\/([^/]+)$/.exec(path);
  if (revokeMatch) {
    if (m !== "DELETE") throw methodNotAllowed("DELETE");
    const token = decodeSegment(revokeMatch[1]);
    return { handler: (ctx) => revokeHandoff(ctx, token) };
  }
  const diarizeMatch = /^\/api\/recordings\/([^/]+)\/(diarize|diarization)$/.exec(path);
  if (diarizeMatch) {
    const recId = uuid(decodeSegment(diarizeMatch[1]), ":id");
    if (diarizeMatch[2] === "diarize") {
      if (m !== "POST") throw methodNotAllowed("POST");
      return { handler: (ctx) => postDiarize(ctx, recId, url) };
    }
    if (m !== "GET") throw methodNotAllowed("GET");
    return { handler: (ctx) => getDiarization(ctx, recId) };
  }
  if (path === "/api/subjects") {
    if (m !== "PUT") throw methodNotAllowed("PUT");
    return { body: true, handler: (ctx, body) => putSubjects(ctx, body) };
  }
  if (path === "/api/uploads") {
    if (m !== "POST") throw methodNotAllowed("POST");
    return { body: true, handler: (ctx, body) => createUploads(ctx, body) };
  }
  if (path === "/api/downloads") {
    if (m !== "POST") throw methodNotAllowed("POST");
    return { body: true, handler: (ctx, body) => createDownloads(ctx, body) };
  }
  throw notFound(`no route for ${m} ${path}`);
}

async function route(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const path = url.pathname.replace(/\/+$/, "") || "/";
  const m = req.method.toUpperCase();

  // Public: the handoff token in the path is the credential (no Bearer).
  if (path === "/h" || path.startsWith("/h/")) return publicHandoff(req, url, path);
  // Public: liveness for the Settings → Backup status light (reveals nothing but the server time).
  if (path === "/api/health") {
    if (m !== "GET") throw methodNotAllowed("GET");
    return health();
  }

  const uid = await verifyJwt(req); // everything else: a valid Neon Auth JWT first, before any routing detail
  return runAuthed(req, uid, resolve(req, url, path, m));
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
