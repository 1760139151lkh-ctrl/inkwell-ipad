// Apply server/db/schema.sql (idempotent) to a branch's Postgres.
// Usage (from repo root):
//   node server/db/apply.mjs                               # the linked branch (.env / .env.local)
//   node server/db/apply.mjs --env-file <staging env file> # another branch (e.g. `neon env pull --branch phase4-staging --file …`)
//   DATABASE_URL=… node server/db/apply.mjs                # explicit override
// Needs Neon Auth enabled on the branch first (owner_id references neon_auth."user"). Never prints the connection string.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { envFileArg, loadEnvLayers, pickDatabaseUrl } from "../scripts/env.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const { envFile } = envFileArg();
const db = pickDatabaseUrl(loadEnvLayers(process.cwd(), envFile));
if (!db) {
  console.error("DATABASE_URL(_UNPOOLED) not found in the process env, --env-file, .env.local or .env");
  process.exit(1);
}
console.log(`target: ${db.host} (from ${db.source})`);

const sql = readFileSync(join(here, "schema.sql"), "utf8");
const client = new pg.Client({ connectionString: db.url.replace(/sslmode=(require|prefer|verify-ca)/, "sslmode=verify-full") });
await client.connect();
try {
  const auth = await client.query(`select to_regclass('neon_auth."user"') is not null as ok`);
  if (!auth.rows[0].ok) {
    console.error('neon_auth."user" does not exist on this branch: enable Neon Auth first (auth: true in neon.ts, then deploy)');
    process.exit(1);
  }
  await client.query(sql);
  const { rows } = await client.query(
    `select c.relname, c.relrowsecurity and c.relforcerowsecurity as rls
     from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
       and c.relname in ('subjects','notes','recordings','transcripts','strokes_index','elements','diarization_jobs',
                         'handoffs','note_claims','legacy_claims','usage_events','object_ledger','deleted_note_ids')
     order by c.relname`,
  );
  console.log("schema applied; tables:", rows.map((r) => `${r.relname}${r.rls ? "" : " (RLS OFF!)"}`).join(", "));
} finally {
  await client.end();
}
