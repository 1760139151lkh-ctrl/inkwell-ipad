# Inkwell backup API (Neon Function `api`)

This is the one-way cloud backup for the Inkwell iPad app (PRD §8.3). The iPad is the source of truth. This server holds a copy.

- **Code:** `server/api.ts` is a single fetch handler with a tiny router, deployed as the Neon Function `api`.
- **Data:** Neon Postgres (`server/db/schema.sql`) holds metadata, transcripts, and stroke timing. The private Neon bucket `uploads` holds the large files.
- **Base URL (production branch):** `https://br-lucky-resonance-b44aj51v-api.compute.c-6.us-east-2.aws.neon.tech`
  - The same value is in `.env` as `NEON_FUNCTION_API_BASE_URL`.
  - The URL is not secret. The token is.

```
iPad ──HTTPS + Bearer──▶ /api/*  (Function) ──▶ Postgres
  │                         └─ presigned URLs ─┐
  └──── PUT/GET file bytes directly ───────────▶ bucket "uploads"
```

## Auth

Every `/api/*` route, including `/api/health`, requires this header (the public `/h/<token>` handoff links are the only exception, see [Agent handoff](#agent-handoff-phase-3)):

```
Authorization: Bearer <INKWELL_API_TOKEN>
```

- The server compares tokens in constant time.
- A missing or wrong token gets `401 {"error":{"code":"unauthorized","message":"missing or invalid bearer token"}}`.
- **Where the token lives:**
  - In gitignored `.env.local` (`INKWELL_API_TOKEN=…`).
  - As the Function env var (declared in `neon.ts`, uploaded by `neon deploy --env .env.local`).
  - On the iPad, in the Keychain, entered once in Settings → Backup.
- Never put the token in source code, git, or logs.
- **To rotate it:** put a new value in `.env.local`, run `npm run deploy`, then re-enter it on the iPad.

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
| 400 | `bad_request` | validation failed. `message` names the field, e.g. `recordings[0].started_at must be an ISO-8601 timestamp` |
| 401 | `unauthorized` | bad or missing token |
| 404 | `not_found` | unknown route or note |
| 405 | `method_not_allowed` | wrong method on a known path |
| 409 | `foreign_key_violation` | e.g. `note.subject_id` points to a subject the server has never seen (send `subject` in the body) |
| 409 | `id_conflict` | a recording or element id already belongs to a different note |
| 409 | `audio_not_uploaded` | `POST /api/recordings/:id/diarize` before the recording's `audio_key` is set or its object exists |
| 413 | `audio_too_long` | diarize on a recording over 4 h (or an object over 300 MB) |
| 413 | `payload_too_large` | body > 16 MiB |
| 500 | `internal` / `misconfigured` | server bug, or the token isn't set on the Function |
| 429 | (Neon) | account-wide concurrency cap (100). Retry after `Retry-After` |

**Client retry policy:**
- Retry 429, 5xx, and network errors with exponential backoff.
- Do not retry 400, 401, 404, or 409 until something changes.

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

### `GET /api/health`
```json
200 {"ok":true,"db":true,"time":"2026-09-25T16:58:31.545Z"}
```
This checks the Postgres connection. Use it for the Settings → Backup status light.

### `PUT /api/notes/:id` — upsert one note's full metadata

The whole body is written in **one transaction**. Always send the note's complete current state.

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

### `POST /api/uploads` — presigned PUT URLs

```json
{"noteId":"f284…","files":[
  {"path":"drawing.pkdrawing","sha256":"95bf…","contentType":"application/octet-stream"},
  {"path":"audio/a1b2….m4a","sha256":"…","contentType":"audio/mp4"}
]}
```

- Each request takes 1–100 files.
- `sha256` is **required**: 64 lowercase hex characters of the exact bytes you will PUT.

**Response:**
```json
200 {"uploads":[{
  "path":"drawing.pkdrawing",
  "key":"notes/f284…/drawing.pkdrawing",
  "url":"https://…/uploads/notes/f284…/drawing.pkdrawing?X-Amz-Algorithm=…",
  "method":"PUT",
  "headers":{"Content-Type":"application/octet-stream","x-amz-meta-sha256":"95bf…"},
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
- The server doesn't check that an object exists. A missing object gives `404 NoSuchKey` when you GET the URL.
- The GET response carries the `x-amz-meta-sha256` header, which is the hash declared at upload. Compare it with the hash of the downloaded bytes, or with the `*_sha256` from the note metadata.

### `GET /api/notes?since=<iso>&limit=&cursor=&urls=1` — list for restore

- **`since`** (optional) returns notes that changed after that time, where "changed" means `modified_at` or `deleted_at` is later than `since`. Leave it out to get everything, for a fresh-install restore.
- **Tombstoned notes are included**, with `deleted_at` set. The client decides whether to restore them to Recently Deleted or skip them.
- **`limit`** defaults to 200, with a maximum of 1000. The list is ordered by change time, then id. If `next_cursor` is non-null, call again with `cursor=<next_cursor>` and the same `since`.
- **`urls=1`** adds a `urls` map, `{key: presigned GET url}` with 1 h expiry, to each note. That saves a `/api/downloads` round-trip.
- **`subjects`** always contains **all** subjects, including tombstoned ones.
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

- `404` if the note has never been backed up.
- `400` if `:id` isn't a UUID.

### `DELETE /api/notes/:id` — tombstone

```json
200 {"ok":true,"id":"f284…","deleted_at":"2026-09-25T16:58:33.871Z","recordings_tombstoned":1,"elements_tombstoned":0}
```

- This is idempotent: the original `deleted_at` is kept.
- The note's recordings and elements get the same `deleted_at`.
- Bucket objects are **kept**, so a restore from Recently Deleted still works.
- `404` means the note was never backed up. Treat that as success on the client.

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
- `404 not_found`: the recording was never backed up.
- `409 audio_not_uploaded`: there's no `audio_key`, or the object isn't in the bucket yet. Retry after the upload and the PUT.
- `413 audio_too_long`: the recording is longer than 4 h, or the object is over 300 MB.
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

### What the iOS client must do

- **Adopt the result.** On `done`, replace the recording's local transcript with `transcript`, including `engine` and per-segment `speaker`.
  - Future `PUT /api/notes/:id` calls then round-trip the diarized version.
  - If the app re-sends its old Apple transcript, it **overwrites** the diarized `transcripts` row. The GET still returns the diarized result from the job row, but search and restore see whatever was PUT last.
  - Alternatively, omit that recording from `transcripts` in later PUTs. Omitted transcripts are left alone.
- **Rename speakers.** Store the names in the note's `speaker_names` (`{"S1":"Kunal"}`) and send it in the next PUT. The name for a segment is `speaker_names["<recId>:S1"] ?? speaker_names["S1"] ?? "Speaker 1"`.
- **Handle `409 audio_not_uploaded`.** Diarize only after the background audio upload and the metadata PUT have both succeeded. If you get the 409, retry after the next successful backup.
- **Limits:** a maximum of 4 h per recording, and each run costs $0.22/h of audio. Re-POSTing a `done` job is free, because it returns the stored result. `?force=1` bills again.

---

## Recommended iOS backup order (per dirty note)

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
npm run db:apply     # apply server/db/schema.sql (idempotent) to the linked branch
npm run typecheck    # tsc on server/api.ts
npm run dev          # local Functions dev server on http://localhost:8788 (real branch DB + bucket!)
npm run deploy       # neon deploy --env .env.local --no-env-pull  (uploads INKWELL_API_TOKEN)
npm run smoke        # end-to-end test against the deployed URL (or: server/smoke.sh http://localhost:8788)
SMOKE_DIARIZE=1 npm run smoke   # + real speaker-detection run on an 83 s, 3-voice clip (~$0.005, ~10 s; needs ffmpeg)
npm run purge-note -- <noteId> [--subject <subjectId>]   # HARD delete rows + objects (admin only)
```

- **Deploy loop:** edit `server/api.ts`, then `npm run typecheck`, then `neon config plan --env .env.local`, then `npm run deploy`, then `npm run smoke`.
- **Always deploy with `--env .env.local`.** `neon.ts` reads `process.env.INKWELL_API_TOKEN!`. Without the file, `defineConfig` throws, which is intentional: it's safer than uploading an empty token.
- **`--no-env-pull`** keeps `neon deploy` from rewriting `.env` or `.env.local`.

**`smoke.sh`** (~5 s):
- Creates a throwaway subject, note, recording, transcript, strokes index, and element.
- Exercises every route, including auth failures and validation.
- Uploads 4 KiB of random bytes through a presigned URL and downloads them again.
- Compares SHA-256.
- Checks tombstoning on re-PUT and on DELETE.
- Checks `speaker_names` (set, kept when omitted, validated) and the diarize contract (`none`, 409 before the audio exists, 404).
- With `SMOKE_DIARIZE=1`, it builds a meeting from `review/demo-assets` (15 `say` clips, 3 voices, 0.6 s gaps), uploads it, diarizes it, polls, and checks three things: at least 2 speakers, every segment inside one clip within ±0.35 s, and exactly one label per voice.
- Checks the agent handoff: 3 recordings (2 diarized with per-recording name overrides, 1 plain), uploads `export/notes.pdf` + `export/page-1.png`, POSTs a handoff, then fetches `/h/<token>` **without auth** and checks the headers, speaker names, moment windows across recordings 1 and 2, the transcript, the file redirects (bytes compared), `?format=json`, `HEAD`, 404s, and revoke. `SMOKE_HANDOFF_OUT=/path/brief.md` saves the rendered briefing.
- Then **hard-deletes** the test rows and objects with `server/scripts/purge-note.mjs`, including `diarization_jobs` and `handoffs`.
- It reads the token from `.env.local` and never prints it.

**Files:**

| file | purpose |
|---|---|
| `server/api.ts` | the Function |
| `server/diarize.ts` | speaker detection: the Scribe call and the word → segment shaping (pure) |
| `server/handoff.ts` | agent handoff: builds the Markdown / JSON briefing (pure) |
| `server/db/schema.sql` | PRD §8.3 DDL (idempotent) plus additive columns and indexes |
| `server/db/apply.mjs` | applies the schema |
| `server/scripts/purge-note.mjs` | hard delete (the core of a future 30-day tombstone purge) |
| `server/scripts/env.mjs` | `.env` reader for scripts |
| `server/smoke.sh` | E2E test |

### Schema notes

- **Additions to the PRD DDL.** `schema.sql` is the PRD's DDL verbatim, made idempotent, plus these additive columns so a restore is lossless against the §8.1 SwiftData model:
  - `notes.bookmarked_pages jsonb`
  - `notes.background_key text`
  - `recordings.transcript_status text`
  - `notes.speaker_names jsonb not null default '{}'`, plus the `diarization_jobs` table (one row per recording). See [Speaker detection](#speaker-detection-diarization).
  - The `handoffs` table (`token_hash` pk, `note_id`, `payload`, `created_at`, `expires_at`, `revoked_at`). See [Agent handoff](#agent-handoff-phase-3). Expired rows are harmless; a future purge can delete `expires_at < now() - interval '30 days'`.
- **Indexes** on `notes(modified_at)`, `notes(subject_id)`, `recordings(note_id)`, and `elements(note_id)`.
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
- `404 not_found`: the note was never backed up, or it's deleted. `400 bad_request`: validation (the message names the field).

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

`404` for an unknown token.

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
- `handoffs` is hard-deleted with the note by `server/scripts/purge-note.mjs`.
