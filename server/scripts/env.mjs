// Minimal .env reader for local scripts (no `source .env`: DATABASE_URL contains `&`). Values are never printed.
// Precedence (highest first): process env > --env-file <path> (or INKWELL_ENV_FILE) > .env.local > .env.
// To target another branch (e.g. phase4-staging), either pass `--env-file <file from neon env pull --branch …>`
// or set DATABASE_URL in the process env: a DATABASE_URL set there is used as-is and a file's
// DATABASE_URL_UNPOOLED can no longer silently win over it.
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

function readEnvFile(p) {
  const out = {};
  for (const line of readFileSync(p, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (!m) continue;
    let v = m[2];
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    out[m[1]] = v;
  }
  return out;
}

/** `--env-file <path>` from argv (removed from the returned args), else INKWELL_ENV_FILE. */
export function envFileArg(argv = process.argv.slice(2)) {
  const args = [...argv];
  let envFile = process.env.INKWELL_ENV_FILE || null;
  const i = args.indexOf("--env-file");
  if (i !== -1) {
    envFile = args[i + 1];
    if (!envFile) throw new Error("--env-file needs a path");
    args.splice(i, 2);
  }
  return { args, envFile };
}

/** Layers, lowest precedence first. */
export function loadEnvLayers(root = process.cwd(), envFile = null) {
  const layers = [];
  for (const name of [".env", ".env.local"]) {
    const p = join(root, name);
    if (existsSync(p)) layers.push({ source: name, vars: readEnvFile(p) });
  }
  if (envFile) {
    const p = resolve(root, envFile);
    if (!existsSync(p)) throw new Error(`env file not found: ${envFile}`);
    layers.push({ source: envFile, vars: readEnvFile(p) });
  }
  const proc = {};
  for (const [k, v] of Object.entries(process.env)) if (v !== undefined) proc[k] = v;
  layers.push({ source: "process env", vars: proc });
  return layers;
}

export function loadEnv(root = process.cwd(), envFile = null) {
  return Object.assign({}, ...loadEnvLayers(root, envFile).map((l) => l.vars));
}

/**
 * The Postgres URL to use: from the highest-precedence layer that defines DATABASE_URL or DATABASE_URL_UNPOOLED
 * (preferring UNPOOLED within that layer). Returns {url, source, host} — print only `source`/`host`, never `url`.
 */
export function pickDatabaseUrl(layers) {
  for (const l of [...layers].reverse()) {
    const url = l.vars.DATABASE_URL_UNPOOLED || l.vars.DATABASE_URL;
    if (url) {
      let host = "?";
      try {
        host = new URL(url).hostname;
      } catch {}
      return { url, source: l.source, host };
    }
  }
  return null;
}
