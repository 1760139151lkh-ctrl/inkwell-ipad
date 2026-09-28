// HARD-delete a note's rows and bucket objects (admin/dev tool; the API only tombstones).
// Usage: node server/scripts/purge-note.mjs <noteId> [--subject <subjectId>] [--env-file <branch env file>]
//   --env-file: target another branch, e.g. the file written by `neon env pull --branch phase4-staging --file …`
//   (or set DATABASE_URL + AWS_* in the process env). Refuses if the DB and the bucket are on different branches.
// Runs as the branch owner role, which has BYPASSRLS: with FORCE ROW LEVEL SECURITY on every app table, a role
// without it would see no rows and silently delete nothing, so that is checked first. Never prints secrets.
// Deletes the note whoever owns it (or none: legacy rows). Order: bucket objects FIRST (a failure leaves the rows, so a
// re-run finishes the job and no row ever points at an object nobody can find), then the rows, the note's
// object_ledger entries, and a permanent deleted_note_ids tombstone (the id can never be claimed again).
// This is also the core of a future 30-day tombstone purge.
import pg from "pg";
import { S3Client, ListObjectsV2Command, DeleteObjectsCommand } from "@aws-sdk/client-s3";
import { envFileArg, loadEnvLayers, pickDatabaseUrl } from "./env.mjs";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const { args, envFile } = envFileArg();
const [noteId, flag, subjectId] = args;
if (!UUID_RE.test(noteId ?? "") || (flag && (flag !== "--subject" || !UUID_RE.test(subjectId ?? "")))) {
  console.error("usage: node server/scripts/purge-note.mjs <noteId> [--subject <subjectId>] [--env-file <path>]");
  process.exit(2);
}

const layers = loadEnvLayers(process.cwd(), envFile);
const env = Object.assign({}, ...layers.map((l) => l.vars));
const db = pickDatabaseUrl(layers);
if (!db) {
  console.error("DATABASE_URL(_UNPOOLED) not found");
  process.exit(1);
}
const client = new pg.Client({ connectionString: db.url.replace(/sslmode=(require|prefer|verify-ca)/, "sslmode=verify-full") });
await client.connect();
const counts = {};
try {
  await client.query("reset role");
  const who = (await client.query(
    `select r.rolbypassrls, current_setting('neon.branch_id', true) as branch
     from pg_roles r where r.rolname = current_user`)).rows[0];
  if (!who.rolbypassrls) throw new Error("the connecting role lacks BYPASSRLS: connect as the branch owner (neondb_owner)");
  const endpoint = env.AWS_ENDPOINT_URL_S3 ?? "";
  if (who.branch && !new URL(endpoint).hostname.startsWith(`${who.branch}.`)) {
    throw new Error(`DB is branch ${who.branch} but AWS_ENDPOINT_URL_S3 is another branch's bucket; pass a matching --env-file`);
  }
  console.error(`target: branch ${who.branch ?? "?"} (${db.host}, from ${db.source})`);

  // 1. Objects first.
  const s3 = new S3Client({
    forcePathStyle: true,
    region: env.AWS_REGION,
    endpoint: env.AWS_ENDPOINT_URL_S3,
    credentials: { accessKeyId: env.AWS_ACCESS_KEY_ID, secretAccessKey: env.AWS_SECRET_ACCESS_KEY },
  });
  let objects = 0;
  let token;
  do {
    const page = await s3.send(new ListObjectsV2Command({ Bucket: "uploads", Prefix: `notes/${noteId}/`, ContinuationToken: token }));
    const keys = (page.Contents ?? []).map((o) => ({ Key: o.Key }));
    if (keys.length) {
      await s3.send(new DeleteObjectsCommand({ Bucket: "uploads", Delete: { Objects: keys, Quiet: true } }));
      objects += keys.length;
    }
    token = page.IsTruncated ? page.NextContinuationToken : undefined;
  } while (token);
  counts.objects = objects;

  // 2. Rows.
  await client.query("begin");
  counts.transcripts = (await client.query(
    "delete from transcripts where recording_id in (select id from recordings where note_id = $1)", [noteId])).rowCount;
  counts.diarization_jobs = (await client.query(
    "delete from diarization_jobs where recording_id in (select id from recordings where note_id = $1)", [noteId])).rowCount;
  counts.handoffs = (await client.query("delete from handoffs where note_id = $1", [noteId])).rowCount;
  counts.strokes_index = (await client.query("delete from strokes_index where note_id = $1", [noteId])).rowCount;
  counts.elements = (await client.query("delete from elements where note_id = $1", [noteId])).rowCount;
  counts.recordings = (await client.query("delete from recordings where note_id = $1", [noteId])).rowCount;
  counts.notes = (await client.query("delete from notes where id = $1", [noteId])).rowCount;
  counts.note_claims = (await client.query("delete from note_claims where note_id = $1", [noteId])).rowCount;
  counts.object_ledger = (await client.query("delete from object_ledger where key like $1", [`notes/${noteId}/%`])).rowCount;
  await client.query("insert into deleted_note_ids (note_id) values ($1) on conflict do nothing", [noteId]);
  if (subjectId) {
    counts.subjects = (await client.query(
      "delete from subjects s where s.id = $1 and not exists (select 1 from notes n where n.subject_id = s.id)", [subjectId])).rowCount;
  }
  await client.query("commit");
} catch (e) {
  await client.query("rollback").catch(() => {});
  throw e;
} finally {
  await client.end();
}


console.log(JSON.stringify({ purged: noteId, ...counts }));
