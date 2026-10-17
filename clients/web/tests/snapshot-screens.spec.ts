import { test } from "@playwright/test";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { extname, join, resolve } from "node:path";

// One full-page screenshot per rendered snapshot (scripts/screens.sh).
const snapshots = process.env.LIBARRIE_A11Y_SNAPSHOTS ?? "";
const out = process.env.SCREENS_OUT ?? "test-results/screens";
const staticDir = resolve(__dirname, "../static");
const types: Record<string, string> = {
  ".css": "text/css", ".js": "text/javascript", ".png": "image/png", ".svg": "image/svg+xml",
};
const files = snapshots && existsSync(snapshots) ? readdirSync(snapshots).filter((f) => f.endsWith(".html")) : [];

for (const file of files) {
  test(`screenshot: ${file.replace(".html", "")}`, async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.route("http://snapshot.test/**", async (route) => {
      const path = new URL(route.request().url()).pathname;
      if (path.startsWith("/static/")) {
        const local = join(staticDir, path.slice("/static/".length));
        if (existsSync(local)) {
          return route.fulfill({ body: readFileSync(local), contentType: types[extname(local)] ?? "application/octet-stream" });
        }
      }
      // Page images are not part of the snapshot; show the brand mark.
      if (path.startsWith("/img/") || /^\/pages\/[^/]+\/original$/.test(path)) {
        return route.fulfill({ body: readFileSync(join(staticDir, "img/icon.png")), contentType: "image/png" });
      }
      if (path === "/") return route.fulfill({ body: readFileSync(join(snapshots, file)), contentType: "text/html" });
      return route.fulfill({ status: 404, body: "" });
    });
    await page.goto("http://snapshot.test/");
    await page.screenshot({ path: join(out, file.replace(".html", ".png")), fullPage: true });
  });
}
