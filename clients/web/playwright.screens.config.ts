import { defineConfig } from "@playwright/test";

// Screenshots of server-rendered snapshots for design review
// (scripts/screens.sh). Like the accessibility audit, no server runs.
export default defineConfig({
  testDir: "tests",
  testMatch: "snapshot-screens.spec.ts",
  reporter: [["list"]],
  use: { channel: "chrome", headless: true },
});
