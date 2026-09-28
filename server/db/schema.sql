-- Inkwell cloud backup schema (PRD §8.3). Idempotent: safe to re-run.
-- Apply: node server/db/apply.mjs [--env-file <branch env file>]   (it prints the target host: check it)
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

-- ---------------------------------------------------------------------------
-- Accounts (Neon Auth / Managed Better Auth) + per-user ownership. Additive. See README § Accounts.
-- Requires Neon Auth enabled on the branch (the neon_auth schema), i.e. `auth: true` in neon.ts + deploy.
-- ---------------------------------------------------------------------------
-- owner_id NULL = a legacy pre-accounts row: invisible to every user until POST /api/account/claim-legacy.
-- Deleting the neon_auth user cascades to every app row it owns.
alter table subjects         add column if not exists owner_id uuid references neon_auth."user"(id) on delete cascade;
alter table notes            add column if not exists owner_id uuid references neon_auth."user"(id) on delete cascade;
alter table recordings       add column if not exists owner_id uuid references neon_auth."user"(id) on delete cascade;
alter table transcripts      add column if not exists owner_id uuid references neon_auth."user"(id) on delete cascade;
alter table elements         add column if not exists owner_id uuid references neon_auth."user"(id) on delete cascade;
alter table strokes_index    add column if not exists owner_id uuid references neon_auth."user"(id) on delete cascade;
alter table diarization_jobs add column if not exists owner_id uuid references neon_auth."user"(id) on delete cascade;
alter table handoffs         add column if not exists owner_id uuid references neon_auth."user"(id) on delete cascade;

create index if not exists subjects_owner_idx         on subjects (owner_id, sort_index);
create index if not exists notes_owner_modified_idx   on notes (owner_id, modified_at);
create index if not exists recordings_owner_idx       on recordings (owner_id);
create index if not exists transcripts_owner_idx      on transcripts (owner_id);
create index if not exists elements_owner_idx         on elements (owner_id);
create index if not exists strokes_index_owner_idx    on strokes_index (owner_id);
create index if not exists diarization_jobs_owner_idx on diarization_jobs (owner_id);
create index if not exists handoffs_owner_created_idx on handoffs (owner_id, created_at);

-- The iPad presigns uploads BEFORE its first PUT /api/notes/:id, so a client-generated note id is bound to the
-- first account that touches it (upload or PUT). Another account can then never presign into, or create, that note.
create table if not exists note_claims (
  note_id    uuid primary key,
  owner_id   uuid not null references neon_auth."user"(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists note_claims_owner_idx on note_claims (owner_id);

-- One row, ever: who claimed the pre-accounts (owner_id IS NULL) data, and how much.
create table if not exists legacy_claims (
  id         int primary key default 1 check (id = 1),
  claimed_by uuid,
  claimed_at timestamptz,
  counts     jsonb
);

-- Quota ledger (diarization minutes per calendar month, handoffs per day; UTC). Append-only.
create table if not exists usage_events (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references neon_auth."user"(id) on delete cascade,
  kind       text not null check (kind in ('diarize_minutes', 'handoff')),
  amount     double precision not null,
  created_at timestamptz not null default now()
);
create index if not exists usage_events_owner_idx on usage_events (owner_id, kind, created_at);
-- A diarization job's up-front charge (estimated from the audio object's size), settled to the provider's measured
-- duration when the job finishes.
alter table diarization_jobs add column if not exists usage_event_id uuid;

-- Storage quota ledger: one row per bucket key, upserted when an upload is presigned (the presigned PUT is signed for
-- exactly `bytes`). Deleted with the account (FK cascade) or by purge-note.
create table if not exists object_ledger (
  key        text primary key,               -- notes/<noteId>/<path>
  owner_id   uuid not null references neon_auth."user"(id) on delete cascade,
  bytes      bigint not null check (bytes > 0),
  updated_at timestamptz not null default now()
);
create index if not exists object_ledger_owner_idx on object_ledger (owner_id);

-- Permanent tombstones: note ids whose rows + objects were hard-deleted (account deletion, purge-note). Such an id is
-- treated as someone else's forever (404), so nobody can re-claim it and inherit stale objects or links.
create table if not exists deleted_note_ids (
  note_id    uuid primary key,
  deleted_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Row-level security (defense in depth). The Function connects as the branch owner role (BYPASSRLS) and runs every
-- user request inside: begin; set local role inkwell_app; select set_config('app.user_id', <uid>, true); …; commit.
-- inkwell_app has no BYPASSRLS, so it sees only rows with owner_id = app_uid(); legacy (NULL) rows never match.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select from pg_roles where rolname = 'inkwell_app') then
    create role inkwell_app nologin;
  end if;
end $$;
-- The connecting role must be able to SET ROLE inkwell_app (PG16+ membership options).
grant inkwell_app to current_user with set true, inherit false;

create or replace function app_uid() returns uuid
  language sql stable
  as $$ select nullif(current_setting('app.user_id', true), '')::uuid $$;

grant usage on schema public to inkwell_app;
grant select, insert, update, delete on subjects, notes, recordings, transcripts, elements, strokes_index,
  diarization_jobs, handoffs, note_claims to inkwell_app;
grant select, insert, update on usage_events to inkwell_app;
grant select, insert, update, delete on object_ledger to inkwell_app;
revoke all on legacy_claims from inkwell_app;
revoke all on deleted_note_ids from inkwell_app;

do $$
declare t text;
begin
  foreach t in array array['subjects','notes','recordings','transcripts','elements','strokes_index',
                           'diarization_jobs','handoffs','note_claims','usage_events','object_ledger',
                           'legacy_claims','deleted_note_ids'] loop
    execute format('alter table %I enable row level security', t);
    execute format('alter table %I force row level security', t);
    if t not in ('legacy_claims', 'deleted_note_ids') then  -- no policy = no rows for inkwell_app (owner-only tables)
      execute format('drop policy if exists owner_only on %I', t);
      execute format('create policy owner_only on %I for all to inkwell_app
                        using (owner_id = app_uid()) with check (owner_id = app_uid())', t);
    end if;
  end loop;
end $$;

-- "Is any of these ids taken by someone else (another account, or legacy)?" Runs as the table owner (BYPASSRLS) so
-- a request under inkwell_app can refuse (404) instead of hitting an opaque RLS error or silently skipping a row.
create or replace function app_foreign_ids(tbl text, ids uuid[]) returns setof uuid
  language plpgsql stable security definer set search_path = public, pg_temp
  as $$
begin
  if tbl = 'notes' then
    return query select n.id from notes n where n.id = any(ids) and n.owner_id is distinct from app_uid()
      union select c.note_id from note_claims c where c.note_id = any(ids) and c.owner_id is distinct from app_uid()
      union select d.note_id from deleted_note_ids d where d.note_id = any(ids);
  elsif tbl = 'subjects' then
    return query select s.id from subjects s where s.id = any(ids) and s.owner_id is distinct from app_uid();
  elsif tbl = 'recordings' then
    return query select r.id from recordings r where r.id = any(ids) and r.owner_id is distinct from app_uid();
  elsif tbl = 'elements' then
    return query select e.id from elements e where e.id = any(ids) and e.owner_id is distinct from app_uid();
  else
    raise exception 'app_foreign_ids: unknown table %', tbl;
  end if;
end $$;
revoke all on function app_foreign_ids(text, uuid[]) from public;
grant execute on function app_foreign_ids(text, uuid[]) to inkwell_app;
