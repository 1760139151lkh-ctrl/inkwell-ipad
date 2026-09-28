# Inkwell backup API (Neon Function `api`)

This is the one-way cloud backup for the Inkwell iPad app (PRD §8.3). The iPad is the source of truth. This server holds a copy.

- **Code:** `server/api.ts` is a single fetch handler with a tiny router, deployed as the Neon Function `api`.
- **Data:** Neon Postgres (`server/db/schema.sql`) holds metadata, transcripts, and stroke timing. The private Neon bucket `uploads` holds the large files.
- **Base URL (production branch):** `https://br-lucky-resonance-b44aj51v-api.compute.c-6.us-east-2.aws.neon.tech`
  - The same value is in `.env` as `NEON_FUNCTION_API_BASE_URL`.
  - The URL is not secret.
- **Staging (`phase4-staging`, a copy-on-write copy of production):** Function `https://br-spring-lake-b4qh5w77-api.compute.c-6.us-east-2.aws.neon.tech`, Auth `https://ep-blue-silence-b4f0jsrt.neonauth.c-6.us-east-2.aws.neon.tech/neondb/auth`.

```
iPad ──sign in──▶ Neon Auth (Managed Better Auth) ──▶ JWT (15 min)
iPad ──HTTPS + Bearer JWT──▶ /api/*  (Function) ──▶ Postgres (RLS: one account's rows)
  │                            └─ presigned URLs ─┐
  └──── PUT/GET file bytes directly ──────────────▶ bucket "uploads"
```

## Auth

Accounts are **Neon Auth** (Managed Better Auth): users and sessions live in the branch's `neon_auth` schema. Every `/api/*` route except `GET /api/health` requires a Neon Auth JWT (the public `/h/<token>` handoff links are the other exception, see [Agent handoff](#agent-handoff-phase-3)):

```
Authorization: Bearer <Neon Auth JWT>
```

**Getting a JWT (iPad).** The Auth base URL is `NEON_AUTH_BASE_URL` of the branch (see above; it includes the `/neondb/auth` path).
1. Sign in with **email OTP** (Better Auth `emailOtp`: send a code, then sign in with it). **Email+password is disabled on every branch**, and so are the organization plugin, allow-localhost and the shared Google provider (2026-09-28). Only accounts whose `emailVerified` is true can use the API; an OTP sign-in verifies the address. The session comes back **only as a cookie**: `Set-Cookie: __Secure-neon-auth.session_token=…`. The `token` field in the JSON body does **not** work as a bearer (verified on staging: 401; there is no `set-auth-token` header).
2. Keep that cookie (name=value, verbatim) in the Keychain. It lasts 7 days and refreshes on use.
3. `GET <auth>/token` with header `Cookie: __Secure-neon-auth.session_token=<value>` → `{"token":"<JWT>"}`. Cache the JWT until ~1 min before its `exp` (it lives 15 min), then fetch a new one. On a `401` from the API, fetch a new JWT once and retry; if `/token` itself fails, the session is gone: sign in again.
4. Cookie-authenticated **POSTs** to Auth (e.g. `POST <auth>/sign-out`) also need `Origin: <auth origin>`, or they get `403 MISSING_OR_NULL_ORIGIN`. Unauthenticated POSTs (sign-up, sign-in) don't.

**What the Function checks** (`verifyJwt` in `api.ts`, using `jose`):
- EdDSA signature against the branch JWKS (`NEON_AUTH_JWKS_URL`, injected because `neon.ts` has `auth: true`).
- `iss` **and** `aud` = `new URL(NEON_AUTH_BASE_URL).origin` (real tokens carry the Auth origin in both, e.g. `https://ep-blue-silence-b4f0jsrt.neonauth.c-6.us-east-2.aws.neon.tech`), `exp` with 30 s clock tolerance. The user id is `sub` (a uuid).
- `exp` and `sub` must be present (`requiredClaims`).
- The `neon_auth."user"` row, on every request: a deleted account, one that is `banned` (and not past `banExpires`), or one whose `emailVerified` isn't true gets 401 even while its JWT hasn't expired.
- Missing, malformed, expired, wrongly signed, or `alg:none` tokens get `401` with `WWW-Authenticate: Bearer error="invalid_token"` and `{"error":{"code":"unauthorized","message":"…"}}`.
- If the JWKS can't be fetched, the answer is `503 auth_unavailable` (retry), not 401, so the client doesn't throw away a good session.
- **`INKWELL_API_TOKEN` (the old shared token) no longer authenticates anything.** It's only the second factor for [claiming the pre-accounts backup](#post-apiaccountclaim-legacy). It stays in `.env.local` and `neon.ts`.

Sign-out doesn't revoke a JWT that was already issued; it expires within 15 min. Deleting the account does take effect at once (the user-row check above).

## Conventions

- **Content type:** JSON in and out, `Content-Type: application/json`. The request body limit is **16 MiB**; larger bodies get `413`.
- **Timestamps:** ISO-8601 strings, for example `2026-09-25T16:58:31.632Z`. Send UTC with fractional seconds, using `ISO8601DateFormatter` with `.withFractionalSeconds`. Postgres keeps microseconds, and the API returns milliseconds.
- **IDs:** UUID strings, lowercase. On iOS, `UUID().uuidString` is uppercase, so use `uuidString.lowercased()` everywhere, including inside file paths such as `audio/<recordingId>.m4a`.
  - The server lowercases ids in JSON fields.
  - Bucket keys are case-sensitive, and `*_key` fields must start with `notes/<lowercase noteId>/`. Store the `key` returned by `/api/uploads` exactly as returned, and don't rebuild keys yourself.
  - Compare ids from responses case-insensitively.
- **Snake_case field names.** Use `JSONEncoder.keyEncodingStrategy = .convertToSnakeCase`, except for the `noteId` and `contentType` fields in `/api/uploads`, which are camelCase.
- **Errors:** `{"error":{"code":"…","message":"…","details"?:…}}`.

| status | code | when |
|---|---|---|
| 400 | `bad_request` | validation failed, or malformed `%`-encoding in the path. `message` names the field, e.g. `recordings[0].started_at must be an ISO-8601 timestamp` |
| 401 | `unauthorized` | missing / invalid / expired JWT, or the account was deleted or banned. Has `WWW-Authenticate: Bearer error="invalid_token"` |
| 403 | `forbidden` | `claim-legacy` without the right `X-Inkwell-Legacy-Token` |
| 404 | `not_found` | unknown route, **or anything that isn't yours**: another account's note/subject/recording/handoff, an unclaimed pre-accounts row, or something that doesn't exist. Never 403, so ids can't be probed |
| 405 | `method_not_allowed` | wrong method on a known path |
| 409 | `foreign_key_violation` | e.g. `note.subject_id` points to a subject the server has never seen (send `subject` in the body) |
| 409 | `id_conflict` | a recording or element id already belongs to a different note (of yours) |
| 409 | `audio_not_uploaded` | `POST /api/recordings/:id/diarize` before the recording's `audio_key` is set or its object exists |
| 409 | `already_claimed` | `claim-legacy` after another account claimed the pre-accounts backup |
| 413 | `audio_too_long` | diarize on a recording over 4 h (or an object over 300 MB) |
| 413 | `payload_too_large` | body > 16 MiB, or an upload's `files[].size` over its cap (audio 500 MB, other files 50 MB) |
| 429 | `quota_exceeded` | a per-account [quota](#quotas) is used up. `message` is human-readable; `details` has `limit`, `used`, `resets_at` |
| 429 | (Neon, not JSON) | account-wide concurrency cap (100). Retry after `Retry-After` |
| 500 | `internal` / `misconfigured` / `storage_error` | server bug, a missing Function env var, or bucket deletion failed during `DELETE /api/account` (nothing was deleted; retry) |
| 503 | `auth_unavailable` | the Auth JWKS couldn't be fetched; retry |

**Client retry policy:**
- Retry Neon's 429, 5xx, 503, and network errors with exponential backoff.
- On 401: get a fresh JWT once and retry; if that still 401s, sign in again.
- Do not retry 400, 403, 404, 409, or `quota_exceeded` until something changes.

## Bucket key layout (predictable, one folder per note)

Each key mirrors the on-device `Notes/<noteID>/` folder (PRD §8.2):

```
notes/<noteId>/drawing.pkdrawing
notes/<noteId>/thumb.png
notes/<noteId>/background.pdf
notes/<noteId>/audio/<recordingId>.m4a
notes/<noteId>/transcript/<recordingId>.json
notes/<noteId>/images/<elementId>.jpg
notes/<noteId>/export/notes.pdf        # agent handoff: the handwriting as a PDF
notes/<noteId>/export/page-<n>.png     # agent handoff: page n (1-based) as a PNG
```

**Path rules** (for the `path` in `/api/uploads` and every `*_key` field):
- The exact names `drawing.pkdrawing`, `thumb.png`, `background.pdf`, and `export/notes.pdf` are allowed, plus `export/page-<n>.png` where `n` is a 1-based page number (`page-1.png`, not `page-0.png`).
- Otherwise the path is `audio/`, `transcript/`, or `images/` followed by one segment matching `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`.
- No `..`, no `/` inside the segment, and no leading `/`.
- Every `*_key` in `PUT /api/notes/:id` must start with `notes/<that same noteId>/`.

---

## Endpoints

### `GET /api/health` (public, no auth)
```json
200 {"ok":true,"db":true,"time":"2026-09-25T16:58:31.545Z"}
```
This checks the Postgres connection. Use it for the Settings → Backup status light. It needs no token (it reveals nothing but the time); use `GET /api/me` to check that the signed-in session works.

**Every other endpoint below acts only on the caller's own data** (see [Accounts and ownership](#accounts-and-ownership)): anything belonging to another account, or to the unclaimed pre-accounts backup, is `404`.

### `PUT /api/notes/:id` — upsert one note's full metadata

The whole body is written in **one transaction**. Always send the note's complete current state.

**Ownership:** `404` for the whole request if the note id (or its [upload claim](#post-apiuploads--presigned-put-urls)) belongs to another account or to unclaimed legacy data, if `subject` / `note.subject_id` is another account's subject, or if any recording or element id already exists under another account. Otherwise every row written is the caller's.

```json
{
  "subject": {
    "id": "6f1c…", "name": "Physics", "color_hex": "#4A90E2", "sort_index": 0,
    "divider_id": null, "updated_at": "2026-09-25T16:58:31.000Z", "deleted_at": null
  },
  "note": {
    "id": "f284…", "subject_id": "6f1c…", "title": "Lecture 3",
    "paper": {"style": "ruled", "color": "white", "spacing": "medium", "landscape": false},
    "page_count": 2,
    "bookmarked_pages": [1],
    "created_at": "2026-09-25T16:00:00.000Z",
    "modified_at": "2026-09-25T16:58:31.000Z",
    "deleted_at": null,
    "drawing_key": "notes/f284…/drawing.pkdrawing",
    "drawing_sha256": "95bf…(64 hex)",
    "thumb_key": "notes/f284…/thumb.png",
    "background_key": null
  },
  "recordings": [{
    "id": "a1b2…", "ord": 0, "name": "Recording 1",
    "started_at": "2026-09-25T16:05:00.000Z", "duration_s": 3120.4,
    "audio_key": "notes/f284…/audio/a1b2….m4a", "audio_sha256": "…64 hex…",
    "transcript_status": "complete", "deleted_at": null
  }],
  "transcripts": [{
    "recording_id": "a1b2…", "locale": "en-US", "engine": "SpeechAnalyzer",
    "segments": [{"start": 0.0, "end": 1.2, "text": "hello", "words": [{"w": "hello", "s": 0.0, "e": 0.5}]}],
    "full_text": "hello …"
  }],
  "strokes_index": {"strokes": [{"i": 0, "created_at": "2026-09-25T16:05:03.120Z", "t_note": 3.12, "page": 0, "bbox": [10, 20, 30, 40]}]},
  "elements": [{
    "id": "e5f6…", "kind": "text", "frame": {"x": 1, "y": 2, "w": 3, "h": 4},
    "created_at": "2026-09-25T16:10:00.000Z", "text": "hi", "file_key": null, "deleted_at": null
  }]
}
```

**Field rules:**

- `note.id` must equal `:id`. It's required.
- **`note` fields:**
  - Required: `title`, `paper`, `page_count` (int), `created_at`, and `modified_at`.
  - `paper` is a free-form JSON object that is stored as-is. The PRD shape is `{style, color, spacing, landscape}`.
  - Optional: everything else. `bookmarked_pages` defaults to `[]`.
  - Each `*_sha256` is 64 lowercase hex characters, or null.
- **`subject`** is an object or `null`.
  - If you send it, it's upserted first. Its `id` must equal `note.subject_id`.
  - If `note.subject_id` is set but the server has never received that subject, you get a 409. So include `subject` whenever the note has one; it's cheap.
- **`recordings`** is the note's complete list.
  - Any recording the server has for this note that is **missing from the array is tombstoned**: `deleted_at = now()`, if it isn't already set.
  - Re-sending a tombstoned id with `deleted_at: null` restores it.
  - `transcript_status` is `none|live|complete|failed` or null.
- **`transcripts`** are upserted by `recording_id`, and each one must reference a recording in the same payload.
  - Transcripts you omit are left as they are. You can skip re-sending an unchanged 2-hour transcript.
  - `segments` is any JSON that isn't null. Use the §7.6 word-timestamp shape.
- **`strokes_index`** is `{strokes:[…]}` to replace the note's index, or `null` (or omitted) to leave it unchanged. The per-stroke shape is `{i, created_at, t_note, page, bbox:[x,y,w,h]}`, in canvas points. It's stored as-is.
- **`elements`** is the complete list, with the same tombstone rule as recordings.
  - `kind` is `text|image`.
  - `frame` is a JSON object.
  - `file_key` is `notes/<noteId>/images/<elementId>.jpg` for images.
- **A deleted note:** either send the PUT with `note.deleted_at` set, or use `DELETE`.
- **`note.speaker_names`** (optional) is the note's speaker display names, e.g. `{"S1":"Kunal","S2":"Pat"}`. See [Speaker detection](#speaker-detection-diarization).
  - **Omitted** leaves the stored names unchanged, so older builds that don't send it never wipe them. `null` clears them. An object replaces them.
  - Keys are `S<n>`, which applies to every recording in the note, or `<recordingId>:S<n>`, which overrides for one recording. The client resolves the recording-specific key first.
  - Values are non-empty strings of at most 100 chars. There are at most 500 entries.
  - GETs always return `speaker_names`, which is `{}` when none are set.

**Response:**
```json
200 {"ok":true,"id":"f284…",
     "recordings":{"upserted":1,"tombstoned":0},
     "elements":{"upserted":1,"tombstoned":0},
     "transcripts":{"upserted":1},
     "strokes_index":"replaced",
     "server_time":"2026-09-25T16:58:31.632Z"}
```

After a 200 and after the files are uploaded, set `lastBackedUpAt`. See the recommended order below.

### `PUT /api/subjects` — bulk upsert subjects (extra; not in the PRD table)

Use this for subjects with no notes, or for renames and reordering without a note change. It's the same subject shape as above.

```json
{"subjects":[{"id":"…","name":"Physics","color_hex":"#4A90E2","sort_index":0,"divider_id":null,"updated_at":"…","deleted_at":null}]}
→ 200 {"ok":true,"upserted":1}
```

If any subject id exists under another account (or as unclaimed legacy data), the whole request is `404` and nothing is written.

### `POST /api/uploads` — presigned PUT URLs

```json
{"noteId":"f284…","files":[
  {"path":"drawing.pkdrawing","sha256":"95bf…","contentType":"application/octet-stream","size":48213},
  {"path":"audio/a1b2….m4a","sha256":"…","contentType":"audio/mp4","size":30512004}
]}
```

- Each request takes 1–100 files.
- `sha256` is **required**: 64 lowercase hex characters of the exact bytes you will PUT.
- **`size` is required** (2026-09-28): the exact byte count you will PUT, an integer > 0. Caps: `audio/*` 500 MB, everything else 50 MB (`413 payload_too_large`). The URL is signed for exactly that `Content-Length`: a body of any other size gets `403` from storage. The response `headers` include `Content-Length`.
- **Storage quota:** each presigned key is recorded in `object_ledger (key, owner_id, bytes)` (re-presigning a key replaces its size). If the account's total with these files would pass `STORAGE_BYTES_PER_ACCOUNT` (default 20 GiB) → `429 quota_exceeded`. The ledger counts what was presigned, not what finished uploading; account deletion and purge-note remove the entries. Files backed up before accounts existed aren't in the ledger.
- **Ownership:** `noteId` must be yours: a note you've backed up, or a fresh client-generated id. A fresh id is **claimed** for your account here (`note_claims`), because the iPad presigns before its first `PUT /api/notes/:id`; from then on no other account can presign into it or create it. An id owned by another account, or by the unclaimed legacy backup, is `404`.

**Response:**
```json
200 {"uploads":[{
  "path":"drawing.pkdrawing",
  "key":"notes/f284…/drawing.pkdrawing",
  "url":"https://…/uploads/notes/f284…/drawing.pkdrawing?X-Amz-Algorithm=…",
  "method":"PUT",
  "headers":{"Content-Type":"application/octet-stream","Content-Length":"48213","x-amz-meta-sha256":"95bf…"},
  "expires_at":"2026-09-25T17:58:32.377Z"
}]}
```

**How to upload:**
- `PUT` the raw bytes to `url` and set **every header in `headers` exactly**.
- `x-amz-meta-sha256` is a signed header, so leaving it out gives `403 SignatureDoesNotMatch`.
- Success is `200` with an empty body.
- After a successful PUT, put the `key` and `sha256` into the next `PUT /api/notes/:id`. For example, `drawing_key` + `drawing_sha256`, or a recording's `audio_key` + `audio_sha256`.

**URL expiry:**
- `audio/*` URLs last **6 h**, so a background `URLSession` can start late.
- Everything else lasts **1 h**.
- S3 checks expiry when the request starts, so a long upload that started in time finishes. If a URL expired before the upload started, request a new one.

### `POST /api/downloads` — presigned GET URLs (for restore)

```json
{"keys":["notes/f284…/drawing.pkdrawing","notes/f284…/audio/a1b2….m4a"]}
→ 200 {"downloads":[{"key":"notes/f284…/drawing.pkdrawing","url":"https://…","expires_at":"…(1h)"}]}
```

- Each request takes up to 500 keys.
- Keys must follow the key layout above.
- Every key must be under one of **your** notes (backed up or claimed by an upload, including tombstoned ones, so Recently Deleted restores work). One foreign key makes the whole request `404`.
- The server doesn't check that an object exists. A missing object gives `404 NoSuchKey` when you GET the URL.
- The GET response carries the `x-amz-meta-sha256` header, which is the hash declared at upload. Compare it with the hash of the downloaded bytes, or with the `*_sha256` from the note metadata.

### `GET /api/notes?since=<iso>&limit=&cursor=&urls=1` — list for restore

- **`since`** (optional) returns notes that changed after that time, where "changed" means `modified_at` or `deleted_at` is later than `since`. Leave it out to get everything, for a fresh-install restore.
- **Tombstoned notes are included**, with `deleted_at` set. The client decides whether to restore them to Recently Deleted or skip them.
- **`limit`** defaults to 200, with a maximum of 1000. The list is ordered by change time, then id. If `next_cursor` is non-null, call again with `cursor=<next_cursor>` and the same `since`.
- **`urls=1`** adds a `urls` map, `{key: presigned GET url}` with 1 h expiry, to each note. That saves a `/api/downloads` round-trip.
- Only **your** notes are listed. Right after sign-up that's none, even if a pre-accounts backup exists: it appears once you [claim it](#post-apiaccountclaim-legacy).
- **`subjects`** always contains **all of your** subjects, including tombstoned ones.
- Transcripts and the strokes index are **not** in the list, to keep it light. `has_transcript` tells you which recordings have one. Fetch the details with `GET /api/notes/:id`.

```json
200 {
  "notes":[{
    "note":{ …same fields as PUT… },
    "recordings":[{ …same fields as PUT…, "has_transcript":true }],
    "elements":[ … ],
    "file_keys":["notes/f284…/drawing.pkdrawing","notes/f284…/audio/a1b2….m4a"],
    "urls":{"notes/f284…/drawing.pkdrawing":"https://…"}      // only with urls=1
  }],
  "subjects":[{ …subject… }],
  "next_cursor":null,
  "server_time":"2026-09-25T16:58:33.100Z"
}
```

**Tip:** store `server_time` from a list call and use it as the next `since` for incremental checks.

### `GET /api/notes/:id` — the full note

It returns everything for one note, including tombstoned recordings and elements (check `deleted_at`).

```json
200 {
  "subject":{…}|null,
  "note":{…},
  "recordings":[…],
  "transcripts":[{"recording_id":"…","locale":"en-US","engine":"…","segments":[…],"full_text":"…"}],
  "strokes_index":{"strokes":[…]}|null,
  "elements":[…],
  "file_keys":[…]
}
```

- `404` if the note has never been backed up, or isn't yours.
- `400` if `:id` isn't a UUID.

### `DELETE /api/notes/:id` — tombstone

```json
200 {"ok":true,"id":"f284…","deleted_at":"2026-09-25T16:58:33.871Z","recordings_tombstoned":1,"elements_tombstoned":0}
```

- This is idempotent: the original `deleted_at` is kept.
- The note's recordings and elements get the same `deleted_at`.
- Bucket objects are **kept**, so a restore from Recently Deleted still works.
- `404` means the note was never backed up (or isn't yours). Treat that as success on the client.

---

## Speaker detection (diarization)

The iPad records one mixed mono channel with several people in the room, or on a call through the Mac speakers. Apple's on-device transcription can't tell speakers apart. The server can: it sends the uploaded audio to a diarizing speech-to-text API and writes a speaker-labelled transcript back into `transcripts`.

- **Provider:** ElevenLabs **Scribe v2** (`model_id=scribe_v2`, `diarize=true`, `timestamps_granularity=word`). One call returns word-level timestamps plus a speaker id per word. It supports up to 32 speakers and 10 h of audio.
  - **Cost:** **$0.22 per hour of audio**, the same on every tier with no diarization surcharge. A 2 h meeting is about $0.44.
  - **Key:** `ELEVENLABS_API_KEY` is a Function env var, handled exactly like `INKWELL_API_TOKEN`: declared in `neon.ts`, with the value only in `.env.local`.
- **Speed (measured, deployed):**
  - 83 s of audio took 1.6 s server-side.
  - 30 min of audio took 11 s server-side, about 15 s from POST to `done` as seen by the client.
  - Expect roughly 1 min for a 2 h meeting.
- **Engine string:** `elevenlabs/scribe_v2`.

### Segment shape

It's the iOS segment shape plus one optional field, `speaker`:

```json
{"start": 12.40, "end": 17.85, "text": "We should move the launch to Friday.", "speaker": "S1",
 "words": [{"start": 12.40, "end": 12.61, "text": "We"}, …]}
```

- **Times** are seconds, relative to the recording, rounded to milliseconds. Word times come from the provider. They are spread evenly within a gap only if the provider omits them, which it didn't in testing.
- **`speaker`** is stable within one recording. Labels are `S1`, `S2`, … in order of first appearance. Labels are **not** matched across recordings: S1 in recording A isn't necessarily S1 in recording B. Use `<recordingId>:S<n>` names when they differ.
- **Lines** are sentence-ish, one tappable line per segment. A new segment starts on any of these:
  - a speaker change
  - a pause over 1.2 s
  - sentence-ending punctuation, once the line has at least 4 words
  - a comma, once the line has at least 18 words
  - a hard cap of 25 words
- **`full_text`** is the segment texts joined with spaces, with no speaker names, so search works.
- **Audio events** such as `(laughter)` are not tagged.

### `POST /api/recordings/:id/diarize` — start (idempotent)

There is no body. The recording must already be backed up with its audio: upload the file, then `PUT /api/notes/:id` with the recording's `audio_key` and `audio_sha256`.

**Response depends on the existing job:**

| existing job | response |
|---|---|
| none, `failed`, or the recording's `audio_key`/`audio_sha256` changed since the last run | starts a new job, `202` |
| `pending` / `running` | `202` with the current status. A job whose worker died is resumed. It never starts a second provider call. |
| `done` (same audio) | `200` with the result, same body as the GET. Add `?force=1` to re-run, which is billed again. |

```json
202 {"recording_id":"0d15…","status":"running","provider":"elevenlabs/scribe_v2","attempts":1,
     "requested_at":"2026-09-25T22:21:42.829Z","started_at":"2026-09-25T22:21:42.841Z","finished_at":null}
```

**Errors:**
- `404 not_found`: the recording was never backed up, or isn't yours.
- `409 audio_not_uploaded`: there's no `audio_key`, or the object isn't in the bucket yet. Retry after the upload and the PUT.
- `413 audio_too_long`: the recording is longer than 4 h, or the object is over 300 MB. "Longer" uses the **billable estimate** below, not just the client's `duration_s`.
- `429 quota_exceeded`: starting this job would take the account past its [monthly diarization minutes](#quotas). Only POSTs that start a provider run count (new job, retry after `failed`, changed audio, `?force=1`); re-POSTing a running or `done` job is free.
- **Billable estimate** (the client's `duration_s` is never trusted alone): `max(duration_s, object ContentLength / 16000)` seconds (HEAD of the audio object; 16000 B/s = a 128 kbps ceiling). That is charged up front to `usage_events` and **settled** to the provider's `audio_duration_s` when the job finishes (`diarization_jobs.usage_event_id`). A failed job keeps its up-front charge.
- `500 misconfigured`: the key isn't set on the Function.

### `GET /api/recordings/:id/diarization` — poll

```json
200 {"recording_id":"0d15…","status":"done","provider":"elevenlabs/scribe_v2","attempts":1,
     "requested_at":"…","started_at":"…","finished_at":"2026-09-25T22:21:44.5Z","audio_duration_s":82.67,
     "transcript":{"engine":"elevenlabs/scribe_v2","locale":"en-US",
                   "segments":[{"start":0.04,"end":2.68,"text":"Okay. Thanks everyone for jumping on.","speaker":"S1","words":[…]}, …],
                   "full_text":"Okay. Thanks everyone for jumping on. …",
                   "speakers":["S1","S2","S3"]}}
```

**`status` values:**

| status | meaning | client action |
|---|---|---|
| `none` | never requested (the recording exists) | show the "Detect speakers" button |
| `pending` | queued, or waiting ~30 s to retry after a transient provider error (`error` holds the last one) | keep polling |
| `running` | the provider call is in flight | keep polling |
| `done` | `transcript` is present, and the `transcripts` row now holds it | stop polling and replace the local transcript |
| `failed` | `error` says why, e.g. `provider 400: …` or `… (gave up after 3 attempts)` | show the error; POST again to retry |

- `404` means the recording is unknown.
- `error` may also appear on `pending` or `running`. It's the previous attempt's error.
- `transcript.locale` keeps the existing transcript's locale if there was one. Otherwise it's the provider's ISO-639-3 code, e.g. `eng`.

**Polling guidance:**
- Call POST once, then GET every ~5 s while the note is visible.
- Stop on `done` or `failed`.
- A 2 h meeting finishes in about 1–2 min.
- If the app leaves and comes back, just GET again. Polling is also what resumes a stuck job, see below.

### How it runs (Neon limits)

A Neon Function must start responding within 15 min, and `waitUntil` work may run 15 min past the response. So POST claims the job, returns `202` immediately, and runs the job inside `waitUntil`:
1. Read the m4a from the bucket.
2. Send it to Scribe synchronously, with a 12 min timeout.
3. Segment it.
4. In one transaction, write `diarization_jobs.result` and upsert `transcripts`.

At about 1 min per 2 h of audio, that's far inside the limit.

**Async mode not used.** ElevenLabs' async mode delivers results only to a webhook configured in the ElevenLabs dashboard, so it isn't used.

**No chunking.** Splitting the audio would lose consistent speaker labels across chunks.

**Recovery without a cron:**
- If an isolate is evicted mid-job, the row stays `running`. The next POST or GET after 16 min re-claims it.
- Transient failures (429, provider 5xx, network, timeout, storage read) go back to `pending` and are retried by the next POST or GET after 30 s.
- A job gets 3 attempts, then becomes `failed`.
- `claim_id` fences a superseded worker, so it can't overwrite a newer run.
- A schedule trigger would also work, but polling the DB every minute would keep the Postgres compute from ever scaling to zero. The iPad's polling is the driver instead.

**Storage:** `diarization_jobs.result` keeps the diarized transcript even if a later `PUT /api/notes/:id` replaces the `transcripts` row.

**Accounts:** the job row carries the requester's `owner_id`, and the background worker reads and writes under that owner's RLS context. The claim/fencing updates run inside the (owner-scoped) request; the provider call starts only after that request commits.

### What the iOS client must do

- **Adopt the result.** On `done`, replace the recording's local transcript with `transcript`, including `engine` and per-segment `speaker`.
  - Future `PUT /api/notes/:id` calls then round-trip the diarized version.
  - If the app re-sends its old Apple transcript, it **overwrites** the diarized `transcripts` row. The GET still returns the diarized result from the job row, but search and restore see whatever was PUT last.
  - Alternatively, omit that recording from `transcripts` in later PUTs. Omitted transcripts are left alone.
- **Rename speakers.** Store the names in the note's `speaker_names` (`{"S1":"Kunal"}`) and send it in the next PUT. The name for a segment is `speaker_names["<recId>:S1"] ?? speaker_names["S1"] ?? "Speaker 1"`.
- **Handle `409 audio_not_uploaded`.** Diarize only after the background audio upload and the metadata PUT have both succeeded. If you get the 409, retry after the next successful backup.
- **Limits:** a maximum of 4 h per recording, and each run costs $0.22/h of audio. Re-POSTing a `done` job is free, because it returns the stored result. `?force=1` bills again.

---

## Accounts and ownership

### Ownership rules

- Every app row has `owner_id` → `neon_auth."user"(id) on delete cascade`: `subjects`, `notes`, `recordings`, `transcripts`, `elements`, `strokes_index`, `diarization_jobs`, `handoffs` (plus `note_claims` and `usage_events`). Every write sets `owner_id` to the caller.
- **`owner_id IS NULL` = a pre-accounts (legacy) row.** It's invisible to every account until [claimed](#post-apiaccountclaim-legacy). Touching a legacy id (PUT, upload, download, …) is `404`, exactly like another account's data.
- **Not yours → `404`**, never 403: another account's rows, legacy rows, and ids that don't exist look the same. (A `PUT` of a brand-new id still succeeds, so `PUT` necessarily tells you an id is taken; ids are random UUIDs.)
- **Note ids are claimed on first touch.** `note_claims(note_id, owner_id)` binds a client-generated note id to the first account that presigns an upload for it or PUTs it.
- **Hard-deleted note ids are tombstoned forever.** `DELETE /api/account` and `purge-note.mjs` write every note id they remove (notes and claims) to `deleted_note_ids`; `app_foreign_ids()` treats those ids as someone else's, so re-using one is `404` for everybody (nobody can inherit stale objects or handoff links).
- Child ids (recordings, elements) that already exist under another account make the whole `PUT /api/notes/:id` a `404`. A subject id that exists under another account makes `PUT /api/subjects` a `404` (nothing is silently skipped).

### Row-level security (defense in depth)

The Function connects as the branch owner role (`neondb_owner`, which has `BYPASSRLS`). The app checks above are the primary guard; Postgres RLS is the backstop:
- NOLOGIN role **`inkwell_app`** (granted to the owner role `WITH SET TRUE`) has only `select/insert/update/delete` on the app tables and `object_ledger` (`select/insert/update` on `usage_events`, nothing on `legacy_claims`, `deleted_note_ids` or `neon_auth`).
- Every app table has `enable` + `force row level security` and one policy for `inkwell_app`: `using / with check (owner_id = app_uid())`, where `app_uid()` = `nullif(current_setting('app.user_id', true), '')::uuid`. Legacy `NULL` rows never match.
- **Every user request is one transaction:** `begin` → check the `neon_auth."user"` row (exists, email verified, not banned) → `select set_config('app.user_id', $uid, true), set_config('role', 'inkwell_app', true)` → handler → `commit`. Both settings are transaction-local, so they're safe through the pooler. Handlers get the request's client (`ctx.c`); there's no module-level `pool.query` on user paths.
- `app_foreign_ids(table, ids[])` (security definer) answers "is any of these ids someone else's?" so a request can 404 cleanly instead of tripping an RLS error. If RLS ever does refuse a write (SQLSTATE 42501), the API maps it to `404`.
- **Only these run as the owner role, outside RLS:** the public handoff token lookup (token hash → note, owner; the rest then runs under that owner), `claim-legacy`, `DELETE /api/account`, `GET /api/health`, and the maintenance scripts (`db/apply.mjs`, `scripts/purge-note.mjs`). Diarization's background worker runs under the job owner's context.
- Verified on staging with a raw query: under `inkwell_app` with another user's `app.user_id` (or none), every app table shows 0 rows; `UPDATE notes` touches 0 rows; inserting a row owned by someone else fails with `new row violates row-level security policy`.

### `GET /api/me`

```json
200 {"user":{"id":"658928e6-…","email":"pat@…","name":"Pat"},
     "usage":{"diarization_minutes_month":12.4,"diarization_minutes_limit":600,"handoffs_today":3,"handoffs_limit":100,
              "storage_bytes":734003200,"storage_limit_bytes":21474836480}}
```
Use it after sign-in to confirm the session works, and in Settings to show usage. `email`/`name` come from `neon_auth."user"`, not the JWT, so they're current.

### `POST /api/account/claim-legacy`

Moves the **pre-accounts backup** (every row with `owner_id IS NULL`, i.e. everything backed up with the old shared token) to the caller. Needs both the JWT and the old token as a second factor:

```
Authorization: Bearer <JWT>
X-Inkwell-Legacy-Token: <INKWELL_API_TOKEN>
```
```json
200 {"claimed":{"subjects":3,"notes":12,"recordings":18,"transcripts":18,"elements":2,"strokes_index":12,"diarization_jobs":12,"handoffs":2}}
```
- One transaction, as the owner role: `update <table> set owner_id = <uid> where owner_id is null` for all eight tables, and records `legacy_claims` (a one-row table: `claimed_by`, `claimed_at`, `counts` of the first claim).
- The legacy token is compared in constant time. Missing or wrong → `403 forbidden`.
- **Idempotent** for the same account: a second call returns all zeros.
- Once one account has claimed, any other account gets `409 already_claimed`.
- **iPad flow:** on the first sign-in on a device that still has the old token in its Keychain, call this **before the first backup** (otherwise the backup's PUTs of existing note ids get `404`, because those ids are still legacy). On `200` or `409`, delete the old token from the Keychain.

### `DELETE /api/account`

```json
{"confirm":"delete my account"}
→ 200 {"deleted":{"notes":12,"objects":57}}
```
- Any other body → `400`.
- First deletes every bucket object under `notes/<id>/` for every note id the account owns **or has claimed** (so files uploaded before their first PUT go too), including tombstoned notes.
- Then, in the same transaction, tombstones every one of those note ids in `deleted_note_ids` and deletes the `neon_auth."user"` row. The FK cascades remove every app row (including `object_ledger` and `usage_events`), plus the account's sessions and linked logins.
- **Objects first.** If any object deletion fails: `500 storage_error` and nothing else is deleted, so a retry is safe.
- The account's JWTs get `401` immediately afterwards (the per-request user-row check).

### Quotas

Per account, UTC. Diarization and handoffs are counted in the `usage_events` ledger (so deleting a note or revoking a link doesn't refund anything); storage in `object_ledger`:

| env var (optional) | default | counts | window |
|---|---|---|---|
| `DIARIZE_MINUTES_PER_MONTH` | 600 | billable minutes of each diarization POST that starts a provider run (estimate up front, settled to the provider's measured duration; see [Speaker detection](#post-apirecordingsiddiarize--start-idempotent)) | calendar month |
| `HANDOFFS_PER_DAY` | 100 | each successful `POST /api/notes/:id/handoff` | calendar day |
| `STORAGE_BYTES_PER_ACCOUNT` | 21474836480 (20 GiB) | sum of `object_ledger.bytes` (declared sizes of presigned uploads) | total, not windowed |

- Over the limit → `429 {"error":{"code":"quota_exceeded","message":"Speaker detection is limited to 600 minutes of audio per month. You've used 599 and this recording is 2. The limit resets 2026-10-01 (UTC).","details":{"limit":600,"used":599,"requested":2,"resets_at":"2026-10-01T00:00:00.000Z"}}}`. Show `message` as-is.
- The check and the ledger insert run under a per-account advisory lock, so concurrent requests can't both slip under the limit.
- The defaults need no config. To change a limit, add the var to `functions.api.env` in `neon.ts` and to `.env.local`, then deploy.

### Production cutover runbook

Rehearsed on `phase4-staging` (a copy of production). In order:

1. **Neon Auth on production** is already enabled (`neon neon-auth status --branch production` → Base URL `https://ep-patient-haze-b44plhpj.neonauth.c-6.us-east-2.aws.neon.tech/neondb/auth`, checked 2026-09-28). The iPad's production Auth URL is that value. Configure custom SMTP before real users sign up (Neon's shared SMTP is for development).
2. **Apply the schema:** `node server/db/apply.mjs` (the linked branch; check the printed `target:` is production's `ep-patient-haze-…`). It's additive and idempotent: the old Function keeps working (it connects as the owner, which bypasses RLS, and doesn't set `owner_id`). Rows the old Function writes in the meantime stay `NULL` = legacy, and are claimed with the rest.
3. **Deploy the Function:** `npm run typecheck`, then `npm run deploy` (production). From this moment the old shared token is rejected (401) and the iPad must sign in.
4. **Don't smoke-test production with synthetic accounts** (email+password stays off there; see [Smoke-test accounts](#smoke-test-accounts-staging-only)). Run the smoke on staging with the same code, then verify production with the real account from the iPad: `GET /api/me` is 200, `GET /api/notes` lists only that account's notes.
5. **Ship the iPad build** that signs in, then calls `POST /api/account/claim-legacy` with the Keychain's old token before its first backup (see above). Pat signs up / in on his iPad; his 12-ish notes move to his account.
6. **Verify** (owner role): `select claimed_by, claimed_at, counts from legacy_claims;` shows Pat's user id; `select count(*) from notes where owner_id is null;` is 0 (repeat for the other seven tables); `GET /api/notes` on the iPad lists his notes; an old handoff link that hasn't expired works again.
7. **Afterwards:** `INKWELL_API_TOKEN` can stay (it only guards the one-time claim). Once `legacy_claims` is set and no `NULL` rows remain, it has no further use; you may leave it or rotate it to a random value.

Rollback: redeploy the previous `api.ts`. The schema changes don't break it (owner role bypasses RLS; `owner_id` is nullable).

---

## Recommended iOS backup order (per dirty note)

0. Have a fresh JWT (see [Auth](#auth)); after a first sign-in on a device with the old token, [claim the legacy backup](#post-apiaccountclaim-legacy) first.
1. Hash the changed files with SHA-256, comparing against what was last backed up.
2. Call `POST /api/uploads` with only the changed files.
3. PUT the bytes to each URL with the returned headers. Use a background `URLSession` for audio, and upload audio only after the recording stops.
4. Call `PUT /api/notes/:id` with the full metadata, including the new keys and hashes.
5. On 200, set `lastBackedUpAt = modifiedAt` as captured at step 1.

Metadata is written after the files, so the server never points at a missing object.

**Restore:**
1. Call `GET /api/notes` (paginated, with `urls=1`) and download each file in `file_keys`.
2. For notes with `has_transcript` or a strokes index, call `GET /api/notes/:id`.

## Neon quirks the iOS client must know

- **Send the exact `headers` from the upload response.**
  - `x-amz-meta-sha256` is signed and required, or you get 403.
  - `Content-Type` isn't signed, so Neon won't reject a mismatch, but it's stored and returned on GET, so send it.
- **No server-side integrity or size enforcement on presigned PUTs.** Neon ignores `x-amz-checksum-*` and doesn't validate the body against the declared SHA-256. The hash is recorded, not verified. Verify on download (see `/api/downloads`).
- **Size:**
  - Presigned PUT has no size cap from us. S3 semantics allow up to 5 GiB per single PUT.
  - A 30 MiB audio file (about an hour at 64 kbps) was tested end to end: PUT took ~5 s from a desktop connection.
  - There's no multipart upload API here. That's fine for Inkwell's file sizes.
- **Path-style URLs only**, for example `https://<endpoint>/uploads/notes/…`. Use the URL exactly as returned; don't rebuild it.
- **Account-wide 429** from the Function runtime at 100 concurrent invocations. Keep backup concurrency low (≤4 in-flight API calls).
- **Cold start:** the Function scales to zero, so the first call after idle can take a second or two. Use a request timeout of 30 s or more.

---

## Operating it

Everything runs from the repo root. `NEON_API_KEY` is read from `.env` by the npm scripts. Never `source .env`, because `DATABASE_URL` contains `&`.

```bash
npm run db:apply     # apply server/db/schema.sql (idempotent) to the linked branch (prints the target host)
npm run typecheck    # tsc on server/api.ts
npm run dev          # local Functions dev server on http://localhost:8788 (real branch DB + bucket!)
npm run deploy       # neon deploy --env .env.local --no-env-pull  → PRODUCTION (the linked branch)
JWT_A=… JWT_B=… [JWT_C=…] npm run smoke    # end-to-end test against the deployed URL (see below)
SMOKE_DIARIZE=1 …  npm run smoke   # + real speaker-detection run on an 83 s, 3-voice clip (~$0.005, ~10 s; needs ffmpeg)
npm run purge-note -- <noteId> [--subject <subjectId>] [--env-file <file>]   # HARD delete rows + objects (admin only)
```

**Another branch (e.g. `phase4-staging`)** — never `neon checkout`/`neon link` (that re-points the repo):
```bash
K="$(grep ^NEON_API_KEY= .env | cut -d= -f2- | tr -d '"')"
NEON_API_KEY="$K" neon env pull --branch phase4-staging --file /tmp/…/staging.env   # outside the repo
node server/db/apply.mjs --env-file /tmp/…/staging.env
NEON_API_KEY="$K" neon deploy --branch phase4-staging --env .env.local --no-env-pull
SMOKE_ENV_FILE=/tmp/…/staging.env JWT_A=… JWT_B=… JWT_C=… server/smoke.sh
node server/scripts/purge-note.mjs <noteId> --env-file /tmp/…/staging.env
```
`db/apply.mjs` and `purge-note.mjs` also accept `DATABASE_URL=…` in the process env (it then beats any file's `DATABASE_URL_UNPOOLED`). `purge-note.mjs` refuses to run if the DB and `AWS_ENDPOINT_URL_S3` are on different branches, or if the role lacks `BYPASSRLS` (with forced RLS it would silently delete nothing).

- **Deploy loop:** edit `server/api.ts`, then `npm run typecheck`, then `neon config plan --env .env.local`, then deploy (staging first), then smoke.
- **Always deploy with `--env .env.local`.** `neon.ts` reads `process.env.INKWELL_API_TOKEN!`. Without the file, `defineConfig` throws, which is intentional: it's safer than uploading an empty token.
- **`--no-env-pull`** keeps `neon deploy` from rewriting `.env` or `.env.local`.

#### Smoke-test accounts (staging only)

Email+password is disabled on every branch, and the API only accepts verified emails. Don't fake auth by inserting users with SQL. On **staging only**:
1. `NEON_API_KEY=… neon neon-auth config email-password update --branch phase4-staging --enabled true`
2. Sign up throwaway users `inkwell-staging-<x>@example.test` with `POST <auth>/sign-up/email` (send `Origin: <auth origin>`), keeping the passwords outside the repo.
3. Mark only those test users verified: `update neon_auth."user" set "emailVerified" = true where email in (…) and email like '%@example.test'` (owner role). Leave one unverified for `JWT_U`.
4. Get JWTs (sign in → `GET <auth>/token` with the session cookie) and run the smoke.
5. `… email-password update --branch phase4-staging --enabled false`, then `delete from neon_auth."user" where email like 'inkwell-staging-%@example.test'`.

**`smoke.sh`** (~20 s; ~40 s with `SMOKE_DIARIZE=1`) needs two accounts' JWTs: `JWT_A` runs the lifecycle, `JWT_B` must be locked out of it. Optional `JWT_C` is a **throwaway** account the test deletes. `SMOKE_CLAIM=1` also claims the legacy rows for A (staging copies only). `SMOKE_ENV_FILE` picks the branch (base URL + purge credentials). Get a JWT: `POST <auth>/sign-in/email`, then `GET <auth>/token` with the returned `__Secure-neon-auth.session_token` cookie.
- Auth: `/api/health` without a token is 200; no token, a garbage token, the legacy shared token as a bearer, a re-signed expired token and an `alg:none` token are all 401 with `WWW-Authenticate`; with `JWT_U`, a valid JWT of an unverified account is 401; `/api/me` for A and B.
- Uploads: missing / zero `size` → 400, over the caps → 413, a body 1 byte larger than the signed size → 403, `Content-Length` in the returned headers, `/api/me` `storage_bytes`; malformed `%`-encoding in the path → 400.
- A presigns an upload **before** the first PUT (claims the note id) and B can't presign into it; A `PUT /api/subjects`.
- **B vs A (all 404):** get, list (no A notes or subjects), overwrite A's note, a new note carrying A's recording id / element id / subject / subject_id, `PUT /api/subjects` with A's subject, presign, download, delete, diarize, diarization poll, handoff, revoke. Then A's note and handoff link are checked unchanged, and B's own note is invisible to A.
- A diarize request (`202`) and handoff are counted by `/api/me`.
- Legacy claim: no header / wrong token → 403, legacy token without JWT → 401; with `SMOKE_CLAIM=1`: A claims, lists them, B lists none, B's claim is 409, A's second claim is all zeros.
- With `JWT_C`: C uploads + PUTs a note, `DELETE /api/account` without the phrase is 400, with it 200 `{notes:1, objects:1}`, the object's presigned GET is then 404 and C's JWT is 401; A can't presign into or PUT C's deleted (tombstoned) note id (404).
- With `SMOKE_DIARIZE=1`, also checks the charge was settled to the provider's `audio_duration_s`.
- The rest is the pre-accounts suite, as user A:
- Creates a throwaway subject, note, recording, transcript, strokes index, and element.
- Exercises every route, including validation.
- Uploads 4 KiB of random bytes through a presigned URL and downloads them again.
- Compares SHA-256.
- Checks tombstoning on re-PUT and on DELETE.
- Checks `speaker_names` (set, kept when omitted, validated) and the diarize contract (`none`, 409 before the audio exists, 404).
- With `SMOKE_DIARIZE=1`, it builds a meeting from `review/demo-assets` (15 `say` clips, 3 voices, 0.6 s gaps), uploads it, diarizes it, polls, and checks three things: at least 2 speakers, every segment inside one clip within ±0.35 s, and exactly one label per voice.
- Checks the agent handoff: 3 recordings (2 diarized with per-recording name overrides, 1 plain), uploads `export/notes.pdf` + `export/page-1.png`, POSTs a handoff, then fetches `/h/<token>` **without auth** and checks the headers, speaker names, moment windows across recordings 1 and 2, the transcript, the file redirects (bytes compared), `?format=json`, `HEAD`, 404s, and revoke. `SMOKE_HANDOFF_OUT=/path/brief.md` saves the rendered briefing.
- Then **hard-deletes** the test objects and rows with `server/scripts/purge-note.mjs`, including `diarization_jobs`, `handoffs`, `note_claims` and `object_ledger` (and tombstones the ids).
- It reads the legacy token from `.env.local` and never prints tokens.
- Last staging runs (2026-09-28, after the security fixes): with `JWT_C` + `JWT_U` **139 passed, 0 failed**; with `SMOKE_DIARIZE=1` as well, every check passed except the 4 `SMOKE_CLAIM=1` checks, because staging's legacy rows had already been claimed and deleted. The claim flow itself passed earlier (136/0).

**Files:**

| file | purpose |
|---|---|
| `server/api.ts` | the Function |
| `server/diarize.ts` | speaker detection: the Scribe call and the word → segment shaping (pure) |
| `server/handoff.ts` | agent handoff: builds the Markdown / JSON briefing (pure) |
| `server/db/schema.sql` | PRD §8.3 DDL (idempotent) plus additive columns and indexes |
| `server/db/apply.mjs` | applies the schema (`--env-file` / `DATABASE_URL` for another branch) |
| `server/scripts/purge-note.mjs` | hard delete, as the owner role: bucket objects first, then rows + `object_ledger`, then a `deleted_note_ids` tombstone (the core of a future 30-day tombstone purge) |
| `server/scripts/env.mjs` | `.env` reader for scripts (layers: process env > `--env-file` > `.env.local` > `.env`) |
| `server/smoke.sh` | E2E test |

### Schema notes

- **Additions to the PRD DDL.** `schema.sql` is the PRD's DDL verbatim, made idempotent, plus these additive columns so a restore is lossless against the §8.1 SwiftData model:
  - `notes.bookmarked_pages jsonb`
  - `notes.background_key text`
  - `recordings.transcript_status text`
  - `notes.speaker_names jsonb not null default '{}'`, plus the `diarization_jobs` table (one row per recording). See [Speaker detection](#speaker-detection-diarization).
  - The `handoffs` table (`token_hash` pk, `note_id`, `payload`, `created_at`, `expires_at`, `revoked_at`). See [Agent handoff](#agent-handoff-phase-3). Expired rows are harmless; a future purge can delete `expires_at < now() - interval '30 days'`.
- **Accounts** (see [Accounts and ownership](#accounts-and-ownership)): nullable `owner_id uuid references neon_auth."user"(id) on delete cascade` on the eight app tables; tables `note_claims`, `legacy_claims` (one row), `usage_events` (quota ledger, `diarization_jobs.usage_event_id` links a job's charge), `object_ledger` (storage quota), `deleted_note_ids` (permanent tombstones, owner-only); role `inkwell_app`; functions `app_uid()` and `app_foreign_ids()`; forced RLS with an `owner_only` policy per table. `apply.mjs` refuses to run before Neon Auth is enabled (the `neon_auth` schema must exist).
- **Indexes** on `notes(modified_at)`, `notes(owner_id, modified_at)`, `notes(subject_id)`, `recordings(note_id)`, `elements(note_id)`, `owner_id` on every owned table, `handoffs(owner_id, created_at)`, and `usage_events(owner_id, kind, created_at)`.
- **`transcripts.search`** is a generated `tsvector` column with a GIN index. For example: `select … from transcripts where search @@ websearch_to_tsquery('english', 'fourier')`.
- **Dividers (P1)** have no table yet. `subjects.divider_id` is stored, but divider names and order aren't. Add a `dividers` table and a `PUT /api/dividers` when P1 dividers land.
- **Tombstone purge** is not automated yet. The PRD says to keep tombstones for 30 days. A Neon Function Trigger (`type: "schedule"`, daily) could run the `purge-note.mjs` logic for `deleted_at < now() - interval '30 days'`.

## Agent handoff (Phase 3)

After a call, Pat taps **Hand off to agent** on the iPad. The iPad uploads a PDF and page PNGs of the handwriting, POSTs the OCR text and "moments" (what he wrote when), and copies a short prompt with a URL to the clipboard. He pastes it into any agent (Claude.ai, ChatGPT, Claude Code, Codex). The agent fetches the URL and gets one Markdown document with everything it needs: the handwriting, what was being said when each note was written, the full speaker-named transcript, and links to the files.

Many agents can only fetch a URL as plain text (no auth headers, no JavaScript). So the link is **public, unguessable, note-scoped, and expiring**: the token in the path is the credential.

### iPad flow

1. Make sure the note is backed up (`PUT /api/notes/:id` has succeeded; otherwise the handoff is `404`). Back up first if the note is dirty, so the transcript and speaker names are current.
2. Render `export/notes.pdf` and `export/page-<n>.png` (n = 1-based), `POST /api/uploads` for them (`application/pdf`, `image/png`), and PUT the bytes. Re-upload on every handoff: the keys are fixed, so the newest render wins (older links then show the newest render too).
3. `POST /api/notes/:id/handoff` with the OCR text and moments.
4. Copy a prompt containing `url`, for example: `Read my notes from this call and help me with the next steps: <url>`.

### `POST /api/notes/:id/handoff` (Bearer)

```json
{ "pdf_key": "notes/<id>/export/notes.pdf",
  "pages": [ {"index": 0, "png_key": "notes/<id>/export/page-1.png", "text": "OCR'd handwriting on page 1\nsecond line"} ],
  "moments": [ {"page": 0, "bbox": [x,y,w,h], "t_start": 26.4, "t_end": 31.0, "text": "! Stripe webhooks for refunds"} ],
  "expires_in_days": 30,
  "time_zone": "America/New_York" }
```

- **`pdf_key`** (optional, may be null): must be exactly `notes/<id>/export/notes.pdf`.
- **`pages`** (optional): `index` is the 0-based page index (unique). `png_key` (optional) must be an `export/page-<n>.png` key under this note; use `n = index + 1`. `text` is the OCR'd handwriting; line breaks are kept. At most 1000 pages.
- **`moments`** (optional): `page` is 0-based. `bbox` is `[x,y,w,h]` in **page-local** points (origin at that page's top-left, unlike `strokes_index`, which uses canvas points; the page PNG is 2.5 px per point), or null. `t_start` / `t_end` are **note-timeline seconds**: the note's live recordings laid end to end in `ord` order, the same clock as `strokes_index.t_note`. Send `null` for both when no audio was running; those moments appear only under the page they're on ("written while no recording was running"). A missing or smaller `t_end` becomes `t_start`. At most 5000.
- **`expires_in_days`** (optional): 1–365, default 30.
- **`time_zone`** (optional, an addition to the original contract): IANA zone for wall-clock times in the briefing. Send `TimeZone.current.identifier`. Default `America/New_York`. An invalid zone is `400`.
- `404 not_found`: the note was never backed up, it's deleted, or it isn't yours. `400 bad_request`: validation (the message names the field). `429 quota_exceeded`: the account already created its [daily handoff links](#quotas).

```json
200 {"url":"https://br-lucky-resonance-b44aj51v-api.compute.c-6.us-east-2.aws.neon.tech/h/<43-char token>",
     "token":"<43-char token>", "expires_at":"2026-10-28T16:00:57.331Z",
     "warnings":["notes/<id>/export/page-1.png is not in storage yet; its link will 404 until it is uploaded"]}
```

- The token is 32 random bytes, base64url (43 chars). The server stores **only its SHA-256**, so the database can't reproduce a link. Keep `token` on the device if you want to revoke that link later.
- Every call mints a **new** link. Older links stay valid until they expire or are revoked.
- **`warnings`** is present only when a `pdf_key` / `png_key` object isn't in the bucket yet. It is not an error (the handoff is created), but upload the files **before** the POST so the links in the briefing work.
- The payload is stored as sent (a snapshot). The rest of the briefing (title, subject, recordings, transcripts, speaker names) is read **live** from the backup each time the link is fetched, so renaming a speaker and backing up again fixes an existing link.

### `GET /h/<token>` (public, no auth)

- `200 text/markdown; charset=utf-8`: the briefing (below). `?format=json` returns the same data as JSON (`application/json`), with note-timeline and recording-relative times per segment.
- `404 text/plain`: an unknown, malformed, expired, or revoked token, or the note has been deleted. The body is one short sentence.
- **Accounts:** the only query outside RLS maps the token hash to its note and owner (and `404`s if that owner is banned); everything else (note, recordings, transcripts, speaker names, file keys) is read under that owner's RLS context, and the note must belong to that owner. Links minted before accounts existed have no owner and return `404` until the pre-accounts backup is [claimed](#post-apiaccountclaim-legacy); then they work again (if not expired).
- Every `/h/…` response has `X-Robots-Tag: noindex, nofollow`, `Cache-Control: private, no-store`, `Referrer-Policy: no-referrer`, and `Access-Control-Allow-Origin: *`. `HEAD` works too.

### `GET /h/<token>/notes.pdf`, `/h/<token>/page/<n>.png`, `/h/<token>/audio/<n>.m4a` (public)

- `302` to a freshly presigned bucket GET valid for **1 hour**, so the links in the briefing never go stale while the handoff is live.
- `page/<n>.png`: `n` is the 1-based page number (`pages[].index + 1`). `audio/<n>.m4a`: `n` is the 1-based position among the note's live recordings in `ord` order.
- `404` if the handoff is dead, or there is no such file (no `pdf_key`, no `png_key` for that page, or a recording without `audio_key`).

### `DELETE /api/handoffs/<token>` (Bearer)

Revokes one link. It's idempotent: the first `revoked_at` is kept.

```json
200 {"ok":true,"note_id":"f284…","revoked_at":"2026-09-28T16:01:01.912Z"}
```

`404` for an unknown token, or one minted by another account.

### The briefing

Built from the handoff payload plus the backed-up note:
- The note title, subject name, and date: the first recording's start, else the note's creation time, in `time_zone`.
- Live recordings in `ord` order, with durations, `started_at` shown as a wall-clock time, and their offsets on the note timeline. Tombstoned recordings are left out and don't count toward the timeline.
- Transcripts. If the iPad re-sent an unlabelled on-device transcript after speaker detection ran on the same audio, the speaker-labelled result from `diarization_jobs` is used instead.
- **Speaker names:** `speaker_names["<recordingId>:S1"] ?? speaker_names["S1"] ?? "Speaker 1"`. When more than one recording has unnamed speakers, the briefing warns that "Speaker 1" isn't matched across recordings.
- **Times:** segment times are recording-relative in the DB. The briefing adds the sum of the earlier live recordings' durations, so every `[m:ss]` is on the note timeline, the same clock as the moments. It uses `[h:mm:ss]` when the audio is an hour or longer.

Sections:

| section | contents |
|---|---|
| header | `# <title>`, then `<subject> · <date time zone> · <total audio> (<n> recordings) · Speakers: Reed, Karen, Maya`, then a short **For the agent** instruction block that says what the document is and what to produce (decisions, action items with owner + due date, open questions, next steps) |
| `## Handwritten notes` | `### Page n` with the OCR text (a leading `#`/`>`/`---` is escaped so it can't break the structure), untimed moments for that page, and links to the PDF and the page image |
| `## Moments — what Pat wrote ↔ what was being said` | one `### <t_start>–<t_end> · page n · "<text>"` per timed moment, sorted by time, with the transcript lines overlapping **[t_start − 30 s, t_end + 10 s]**, speaker-named. `▶` marks lines spoken while he was writing. Omitted when there are no timed moments |
| `## Transcript` | `### Recording n · <duration> · started <time> · note time a–b` (the note-time range only with 2+ recordings). Consecutive segments by the same speaker are merged into one paragraph with the first timestamp (a new paragraph every 2 min). Unlabelled transcripts are grouped into paragraphs of ≤45 s, split at pauses over 2 s. It handles recordings with no transcript and notes with no audio |
| `## Files` | the PDF, page images, and audio, as `/h/<token>/…` links |

There is no truncation below **400,000 characters**. Past that, the transcript is cut at a paragraph boundary with a note pointing at `?format=json` and the audio (a 2 h meeting is roughly 100k characters).

**Sample** (from `server/smoke.sh`: 3 recordings, two diarized with per-recording name overrides, one plain on-device transcript):

```markdown
# Vendor sync: refunds + QA
Smoke Test · Mon, Sep 28, 2026, 3:17 PM EDT · 3:06 of audio (3 recordings) · Speakers: Reed, Karen, Maya

> **For the agent:** These are Pat's notes from a call: his handwritten notes (read by OCR — may contain errors; the PDF is the source of truth), what was being said when he wrote each note, and the full speaker-labelled transcript. Figure out the decisions, action items (owner + due date when stated), and open questions, then help with next steps. If something is ambiguous, check the transcript.
>
> Timestamps like [1:05] are minutes:seconds into the note's audio (its recordings laid end to end). All links work without login until Wed, Oct 28, 2026, 12:00 PM EDT; JSON version: https://…/h/<token>?format=json

## Handwritten notes

### Page 1
Vendor sync  
! Stripe webhooks for refunds  
QA owner? -> Karen Thu  
\# launch Fri

_Written while no recording was running:_ "Vendor sync"

[PDF of the handwriting](https://…/h/<token>/notes.pdf) · [Page 1 image](https://…/h/<token>/page/1.png)

## Moments — what Pat wrote ↔ what was being said
Each moment shows the transcript from 30 s before Pat started writing to 10 s after he stopped; ▶ marks what was said while he was writing.

### 0:26–0:31 · page 1 · "! Stripe webhooks for refunds"
- [0:00] **Reed:** Okay. Thanks everyone for jumping on. Quick agenda: refunds, then QA.
- [0:19] **Karen:** One risk. Refunds are still manual, support does them by hand in the dashboard.
- ▶ [0:25] **Reed:** Then we should wire up Stripe webhooks for refunds before launch.
- ▶ [0:30] **Maya:** Agreed, I can take that.

### 1:28–1:32 · page 1 · "QA owner? -> Karen Thu"
- [1:10] **Reed:** Last thing before we switch rooms: the launch is still Friday.
- ▶ [1:28] **Karen:** So who owns QA for the release?
- ▶ [1:32] **Reed:** I will, by Thursday. Great, thanks.

## Transcript

### Recording 1 · 1:23 · started 3:17 PM · note time 0:00–1:23
**[0:00] Reed:** Okay. Thanks everyone for jumping on. Quick agenda: refunds, then QA.

**[0:19] Karen:** One risk. Refunds are still manual, support does them by hand in the dashboard.
…
### Recording 3 (“Hallway”) · 0:20 · started 3:25 PM · note time 2:46–3:06
**[2:47]** remember to send the deck

## Files
- Handwriting PDF: [notes.pdf](https://…/h/<token>/notes.pdf)
- Page images: [Page 1](https://…/h/<token>/page/1.png)
- Audio (m4a): [Recording 1 (1:23)](https://…/h/<token>/audio/1.m4a)

_Each link redirects to a download URL that is valid for 1 hour; fetch the link again for a fresh one._
```

### Security notes

- Anyone holding the URL can read the note until it expires, including the audio. That's the point (paste it into any agent). Revoke with `DELETE /api/handoffs/<token>`, or delete the note (a deleted note's links 404 at once).
- The links reach only this note's `export/` files and its live recordings' audio. There is no path parameter that can name another key.
- The token isn't logged by the server. `Referrer-Policy: no-referrer` stops it leaking from the presigned redirect.
- `handoffs` is hard-deleted with the note by `server/scripts/purge-note.mjs`, and with the account by `DELETE /api/account`.
