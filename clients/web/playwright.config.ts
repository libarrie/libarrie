import { defineConfig } from "@playwright/test";

// Browser tests drive the installed Google Chrome (no browser download) against
// the real API and worker started by tests/serve.sh.
export default defineConfig({
  testDir: "tests",
  timeout: 120_000,
  expect: { timeout: 15_000 },
  workers: 1,
  reporter: [["list"]],
  use: {
    baseURL: "http://localhost:8080",
    channel: "chrome",
    headless: true,
    trace: "retain-on-failure",
  },
  webServer: {
    command: "bash tests/serve.sh",
    url: "http://localhost:8080/healthz",
    timeout: 300_000,
    reuseExistingServer: false,
    stdout: "pipe",
    stderr: "pipe",
  },
});
