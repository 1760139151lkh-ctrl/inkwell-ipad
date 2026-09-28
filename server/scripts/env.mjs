// Minimal .env reader for local scripts (no `source .env`: DATABASE_URL contains `&`).
// Process env wins over files; .env.local wins over .env. Values are never printed.
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

export function loadEnv(root = process.cwd()) {
  const out = {};
  for (const name of [".env", ".env.local"]) {
    const p = join(root, name);
    if (!existsSync(p)) continue;
    for (const line of readFileSync(p, "utf8").split("\n")) {
      const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
      if (!m) continue;
      let v = m[2];
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
      out[m[1]] = v;
    }
  }
  for (const [k, v] of Object.entries(process.env)) if (v !== undefined) out[k] = v;
  return out;
}
