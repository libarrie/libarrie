import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { extname, join, resolve } from "node:path";

// WCAG 2.2 A and AA on every rendered screen, in light and dark themes.
const snapshots = process.env.LIBARRIE_A11Y_SNAPSHOTS ?? "";
const staticDir = resolve(__dirname, "../static");
const types: Record<string, string> = {
  ".css": "text/css", ".js": "text/javascript", ".png": "image/png", ".svg": "image/svg+xml",
};

const files = snapshots && existsSync(snapshots) ? readdirSync(snapshots).filter((f) => f.endsWith(".html")) : [];

test("snapshots were rendered", () => {
  expect(files.length, "run scripts/a11y.sh, which renders the snapshots first").toBeGreaterThan(0);
});

// The audit itself works: a known violation is reported.
test("axe reports a known violation", async ({ page }) => {
  await page.setContent('<!doctype html><html lang="en"><title>t</title><main><img src="x.png"></main></html>');
  const results = await new AxeBuilder({ page }).withTags(["wcag2a"]).analyze();
  expect(results.violations.map((v) => v.id)).toContain("image-alt");
});

for (const file of files) {
  test(`accessible: ${file.replace(".html", "")}`, async ({ page }) => {
    await page.route("http://snapshot.test/**", async (route) => {
      const path = new URL(route.request().url()).pathname;
      if (path.startsWith("/static/")) {
        const local = join(staticDir, path.slice("/static/".length));
        if (existsSync(local)) {
          return route.fulfill({ body: readFileSync(local), contentType: types[extname(local)] ?? "application/octet-stream" });
        }
      }
      if (path === "/") return route.fulfill({ body: readFileSync(join(snapshots, file)), contentType: "text/html" });
      return route.fulfill({ status: 404, body: "" });
    });
    await page.goto("http://snapshot.test/");
    // The real stylesheet is applied, so contrast is checked against the
    // brand colors, not browser defaults.
    const background = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
    expect(background).toBe(file.endsWith("-dark.html") ? "rgb(14, 36, 68)" : "rgb(254, 248, 234)");
    const results = await new AxeBuilder({ page })
      .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"])
      .analyze();
    const summary = results.violations.map((v) => `${v.id} (${v.impact}): ${v.help} — ${v.nodes.map((n) => n.target.join(" ")).slice(0, 3).join(", ")}`);
    expect(summary).toEqual([]);
  });
}
