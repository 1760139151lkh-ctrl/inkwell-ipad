import { defineConfig } from "@neon/config/v1";

export default defineConfig({
  auth: true,
  // Upgrade to a paid plan to enable AI Gateway for your project.
  // aiGateway: true,
  buckets: {
    uploads: { access: "private" },
  },
  functions: {
    api: {
      name: "api",
      source: "./server/api.ts",
      // Bearer token for the iPad (PRD §8.3). Lives only in gitignored .env.local.
      // Always deploy with: neon deploy --env .env.local
      // ELEVENLABS_API_KEY: speaker detection (Scribe v2 diarization), server/diarize.ts. Also only in .env.local.
      env: {
        INKWELL_API_TOKEN: process.env.INKWELL_API_TOKEN!,
        ELEVENLABS_API_KEY: process.env.ELEVENLABS_API_KEY!,
      },
    },
  },
  // Branch policy: per-branch tuning
  branch: (branch) => {
    if (branch.isDefault) {
      // Default branch: no overrides, uses project defaults
      return {};
    }
    if (!branch.exists) {
      // New non-default branches: auto-expire
      // Run `neon checkout <name>` to create a new branch with these settings
      return { ttl: "7d" };
    }
    // Existing branch: no changes
    return {};
  },
});
