import { defineConfig } from "@playwright/test";

// Accessibility audit of server-rendered snapshots (scripts/a11y.sh): no
// API, worker or web server runs; pages and static assets are served from
// files through request interception.
export default defineConfig({
  testDir: "tests",
  testMatch: "accessibility.spec.ts",
  reporter: [["list"]],
  use: { channel: "chrome", headless: true },
});
