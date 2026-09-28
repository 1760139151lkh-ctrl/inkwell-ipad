-- Inkwell cloud backup schema (PRD §8.3). Idempotent: safe to re-run.
-- Apply: node server/db/apply.mjs   (reads DATABASE_URL_UNPOOLED/DATABASE_URL from .env)
--
-- One-way backup: the iPad is the source of truth. Timestamps are the client's.
-- Deletes are tombstones (deleted_at); the server keeps them 30 days.

create table if not exists subjects (
  id          uuid primary key,
  name        text not null,
  color_hex   text not null,
  sort_index  int  not null,
  divider_id  uuid,
  updated_at  timestamptz not null,
  deleted_at  timestamptz
);

create table if not exists notes (
  id             uuid primary key,
  subject_id     uuid references subjects(id),
  title          text not null,
  paper          jsonb not null,            -- {style, color, spacing, landscape}
  page_count     int  not null,
  created_at     timestamptz not null,
  modified_at    timestamptz not null,
  deleted_at     timestamptz,
  drawing_key    text,                      -- notes/<noteId>/drawing.pkdrawing
  drawing_sha256 text,
  thumb_key      text                       -- notes/<noteId>/thumb.png
);

create table if not exists recordings (
  id           uuid primary key,
  note_id      uuid not null references notes(id),
  ord          int  not null,
  name         text not null,
  started_at   timestamptz not null,       -- wall-clock anchor (PRD §7.2)
  duration_s   double precision not null,
  audio_key    text,                       -- notes/<noteId>/audio/<recordingId>.m4a
  audio_sha256 text,
  deleted_at   timestamptz
);

create table if not exists transcripts (
  recording_id uuid primary key references recordings(id),
  locale       text,
  engine       text,
  segments     jsonb not null,
  full_text    text  not null,
  search       tsvector generated always as (to_tsvector('english', full_text)) stored
);
create index if not exists transcripts_search_idx on transcripts using gin (search);

-- Phase 3: per-stroke time + bounds, no ink.
create table if not exists strokes_index (
  note_id uuid primary key references notes(id),
  strokes jsonb not null                   -- [{i, created_at, t_note, page, bbox:[x,y,w,h]}]
);

create table if not exists elements (
  id         uuid primary key,
  note_id    uuid not null references notes(id),
  kind       text not null,                -- 'text' | 'image'
  frame      jsonb not null,               -- {x,y,w,h} canvas coordinates
  created_at timestamptz not null,
  text       text,
  file_key   text,                         -- notes/<noteId>/images/<elementId>.jpg
  deleted_at timestamptz
);

-- ---------------------------------------------------------------------------
-- Additive (not in the PRD §8.3 DDL, but needed for a lossless restore of the
-- §8.1 SwiftData model, or for query speed). All nullable/defaulted.
-- ---------------------------------------------------------------------------
alter table notes      add column if not exists bookmarked_pages jsonb not null default '[]'::jsonb; -- Note.bookmarkedPages (P1)
alter table notes      add column if not exists background_key   text;                              -- notes/<noteId>/background.pdf (P1)
alter table recordings add column if not exists transcript_status text;                             -- none|live|complete|failed

create index if not exists notes_modified_at_idx   on notes (modified_at);
create index if not exists notes_deleted_at_idx    on notes (deleted_at) where deleted_at is not null;
create index if not exists notes_subject_id_idx    on notes (subject_id);
create index if not exists recordings_note_id_idx  on recordings (note_id);
create index if not exists elements_note_id_idx    on elements (note_id);

-- ---------------------------------------------------------------------------
-- Speaker detection (diarization). Additive. See README § Speaker detection.
-- ---------------------------------------------------------------------------
-- Per-note speaker display names: {"S1":"Kunal"} applies to every recording in the note;
-- {"<recordingId>:S1":"Kunal"} overrides for one recording. Clients resolve the specific key first.
alter table notes add column if not exists speaker_names jsonb not null default '{}'::jsonb;

-- One diarization job per recording (re-running replaces it).
create table if not exists diarization_jobs (
  recording_id     uuid primary key references recordings(id),
  status           text not null check (status in ('pending','running','done','failed')),
  provider         text not null,             -- e.g. elevenlabs/scribe_v2
  audio_key        text not null,             -- the object that was (or will be) processed
  audio_sha256     text,                      -- recording.audio_sha256 at request time (re-run if it changes)
  attempts         int  not null default 0,
  error            text,
  requested_at     timestamptz not null default now(),
  started_at       timestamptz,               -- last claim; a 'running' row older than 16 min is dead and re-claimable
  claim_id         uuid,                      -- fences a superseded worker: results are written only if claim_id still matches
  updated_at       timestamptz not null default now(),
  finished_at      timestamptz,
  audio_duration_s double precision,
  provider_transcription_id text,
  result           jsonb                      -- {engine, locale, segments, full_text, speakers} (kept even if the iPad later overwrites transcripts)
);
create index if not exists diarization_jobs_active_idx on diarization_jobs (status) where status in ('pending','running');

-- ---------------------------------------------------------------------------
-- Agent handoff (PRD §10 Phase 3). Additive. See README § Agent handoff.
-- ---------------------------------------------------------------------------
-- One row per "Hand off to agent" tap. The public link is /h/<token>; only the token's SHA-256 is stored,
-- so a database leak doesn't leak working links. payload = {pdf_key, pages[], moments[], time_zone} as sent by the iPad.
create table if not exists handoffs (
  token_hash  text primary key,              -- hex SHA-256 of the base64url token
  note_id     uuid not null references notes(id),
  payload     jsonb not null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  revoked_at  timestamptz
);
create index if not exists handoffs_note_id_idx on handoffs (note_id);
