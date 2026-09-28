// Apply server/db/schema.sql to the linked branch's Postgres.
// Usage (from repo root): node server/db/apply.mjs
// Reads DATABASE_URL_UNPOOLED (or DATABASE_URL) from the environment or ./.env.
// Never prints the connection string.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { loadEnv } from "../scripts/env.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const env = loadEnv();
const url = env.DATABASE_URL_UNPOOLED || env.DATABASE_URL;
if (!url) {
  console.error("DATABASE_URL(_UNPOOLED) not found in env or .env");
  process.exit(1);
}

const sql = readFileSync(join(here, "schema.sql"), "utf8");
const client = new pg.Client({ connectionString: url });
await client.connect();
try {
  await client.query(sql);
  const { rows } = await client.query(
    `select table_name from information_schema.tables
     where table_schema = 'public'
       and table_name in ('subjects','notes','recordings','transcripts','strokes_index','elements','diarization_jobs','handoffs')
     order by table_name`,
  );
  console.log("schema applied; tables:", rows.map((r) => r.table_name).join(", "));
} finally {
  await client.end();
}
