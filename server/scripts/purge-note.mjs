// HARD-delete a note's rows and bucket objects (admin/dev tool; the API only tombstones).
// Usage: node server/scripts/purge-note.mjs <noteId> [--subject <subjectId>]
// Uses DATABASE_URL + AWS_* from the environment / .env. Never prints secrets.
// This is also the core of a future 30-day tombstone purge (PRD §8.3).
import pg from "pg";
import { S3Client, ListObjectsV2Command, DeleteObjectsCommand } from "@aws-sdk/client-s3";
import { loadEnv } from "./env.mjs";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const [noteId, flag, subjectId] = process.argv.slice(2);
if (!UUID_RE.test(noteId ?? "") || (flag && (flag !== "--subject" || !UUID_RE.test(subjectId ?? "")))) {
  console.error("usage: node server/scripts/purge-note.mjs <noteId> [--subject <subjectId>]");
  process.exit(2);
}

const env = loadEnv();
const client = new pg.Client({
  connectionString: (env.DATABASE_URL_UNPOOLED || env.DATABASE_URL).replace(/sslmode=(require|prefer|verify-ca)/, "sslmode=verify-full"),
});
await client.connect();
const counts = {};
try {
  await client.query("begin");
  counts.transcripts = (await client.query(
    "delete from transcripts where recording_id in (select id from recordings where note_id = $1)", [noteId])).rowCount;
  counts.diarization_jobs = (await client.query(
    "delete from diarization_jobs where recording_id in (select id from recordings where note_id = $1)", [noteId])).rowCount;
  counts.handoffs = (await client.query("delete from handoffs where note_id = $1", [noteId])).rowCount;
  counts.strokes_index =(await client.query("delete from strokes_index where note_id = $1", [noteId])).rowCount;
  counts.elements = (await client.query("delete from elements where note_id = $1", [noteId])).rowCount;
  counts.recordings = (await client.query("delete from recordings where note_id = $1", [noteId])).rowCount;
  counts.notes = (await client.query("delete from notes where id = $1", [noteId])).rowCount;
  if (subjectId) {
    counts.subjects = (await client.query(
      "delete from subjects s where s.id = $1 and not exists (select 1 from notes n where n.subject_id = s.id)", [subjectId])).rowCount;
  }
  await client.query("commit");
} catch (e) {
  await client.query("rollback");
  throw e;
} finally {
  await client.end();
}

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
console.log(JSON.stringify({ purged: noteId, ...counts }));
