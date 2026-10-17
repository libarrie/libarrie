import { test, expect } from "@playwright/test";
import { pagePng } from "./png";

// Visual snapshots for review (run with SCREENSHOTS=1); not assertions.
test.skip(!process.env.SCREENSHOTS, "set SCREENSHOTS=1 to capture");

test("capture key screens in light and dark", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 860 });
  await page.goto("/");
  await page.screenshot({ path: "test-results/screens/01-landing.png" });
  await page.getByRole("link", { name: "Sign in" }).click();
  await page.getByLabel("Subject").fill(`shots-${Date.now()}`);
  await page.getByLabel("Display name").fill("Ada");
  await page.getByRole("button", { name: "Sign in" }).click();
  for (const name of ["Blue work notebook"]) {
    await page.getByLabel("New notebook").fill(name);
    await page.getByRole("button", { name: "Create" }).click();
    await expect(page.getByRole("link", { name })).toBeVisible();
  }
  await page.getByRole("link", { name: "Blue work notebook" }).click();
  await page.getByRole("link", { name: "Add pages" }).click();
  await page.locator("#files").setInputFiles([
    { name: "p1.png", mimeType: "image/png", buffer: pagePng("Try giving new customers a sample project before quoting. Call Ada about invoice INV-2024-07.") },
    { name: "p2.png", mimeType: "image/png", buffer: pagePng("Quarterly budget review with Lin; follow up on the compiler licenses.") },
  ]);
  await page.getByRole("button", { name: "Upload" }).click();
  await expect(page.locator("#upload-queue li").nth(1)).toContainText("Uploaded", { timeout: 30_000 });
  await page.screenshot({ path: "test-results/screens/02-upload.png" });
  await page.getByRole("link", { name: "Back to the notebook" }).click();
  await expect(async () => {
    await page.reload();
    await expect(page.locator(".page-tile").nth(1)).toContainText("Searchable", { timeout: 1_000 });
  }).toPass({ timeout: 60_000 });
  await page.screenshot({ path: "test-results/screens/03-notebook.png" });
  await page.locator(".page-tile a").first().click();
  await page.screenshot({ path: "test-results/screens/04-page.png" });
  await page.getByRole("link", { name: "Search" }).click();
  await page.getByLabel("Search your notes").fill("sample project invoice");
  await page.getByRole("button", { name: "Search" }).click();
  await expect(page.locator("#results mark").first()).toBeVisible();
  await page.screenshot({ path: "test-results/screens/05-search-light.png" });
  await page.getByRole("link", { name: "Settings" }).click();
  await page.getByLabel("Dark").check();
  await page.getByRole("button", { name: "Save" }).click();
  await page.getByRole("link", { name: "Search" }).click();
  await page.getByLabel("Search your notes").fill("sample project invoice");
  await page.getByRole("button", { name: "Search" }).click();
  await expect(page.locator("#results mark").first()).toBeVisible();
  await page.screenshot({ path: "test-results/screens/06-search-dark.png" });
  await page.getByRole("link", { name: "Notebooks" }).click();
  await page.screenshot({ path: "test-results/screens/07-notebooks-dark.png" });
});
