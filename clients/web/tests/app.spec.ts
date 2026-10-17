import { test, expect } from "@playwright/test";
import { pagePng } from "./png";
import { watch, cspViolations, signIn } from "./helpers";

test("sign in, upload, process, correct, search and theme", async ({ page }) => {
  const problems = await watch(page);
  const subject = `browser-${Date.now()}`;
  await signIn(page, subject);
  await expect(page.getByRole("heading", { name: "Notebooks" })).toBeVisible();
  expect(await cspViolations(page)).toEqual([]);

  // Create a notebook through the htmx form.
  await page.getByLabel("New notebook").fill("Field notes <b>2026</b>");
  await page.getByRole("button", { name: "Create" }).click();
  const link = page.getByRole("link", { name: "Field notes <b>2026</b>" });
  await expect(link).toBeVisible();
  await link.click();

  // Upload a page through the browser upload module.
  await page.getByRole("link", { name: "Add pages" }).click();
  await expect(page.getByRole("heading", { name: "Add pages" })).toBeVisible();
  await page.locator("#files").setInputFiles({
    name: "page-one.png",
    mimeType: "image/png",
    buffer: pagePng("Met Grace Hopper about the COBOL compiler budget"),
  });
  await page.getByRole("button", { name: "Upload" }).click();
  await expect(page.locator("#upload-queue")).toContainText("Uploaded; processing", { timeout: 30_000 });
  expect(await cspViolations(page)).toEqual([]);

  // Wait for the worker to make it searchable.
  await page.getByRole("link", { name: "Back to the notebook" }).click();
  await expect(async () => {
    await page.reload();
    await expect(page.locator(".page-tile")).toContainText("Searchable", { timeout: 1_000 });
  }).toPass({ timeout: 60_000 });

  // Page detail shows the recognized transcript; correct it.
  await page.locator(".page-tile a").first().click();
  const transcript = page.locator("#transcript-text");
  await expect(transcript).toHaveValue("Met Grace Hopper about the COBOL compiler budget");
  await transcript.fill("Met Grace Hopper about the COBOL compiler budget and nanoseconds");
  await page.getByRole("button", { name: "Save transcript" }).click();
  await expect(page.getByText("Edited by you.")).toBeVisible();
  expect(await cspViolations(page)).toEqual([]);

  // Search highlights the match and links back to the page.
  await page.getByRole("link", { name: "Search" }).click();
  await page.getByLabel("Search your notes").fill("Hopper");
  await page.getByRole("button", { name: "Search" }).click();
  await expect(page.locator("#results mark").first()).toHaveText("Hopper");
  await expect(page.locator("#results")).toContainText("Page 1");

  // Theme preference is rendered before paint and persists.
  await page.getByRole("link", { name: "Settings" }).click();
  await page.getByLabel("Dark").check();
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await page.reload();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  const background = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  expect(background).toBe("rgb(14, 36, 68)");

  expect(await cspViolations(page)).toEqual([]);
  expect(problems.filter((p) => !p.includes("favicon"))).toEqual([]);
});

test("an expired session sends htmx requests to sign-in", async ({ page, context }) => {
  await watch(page);
  await signIn(page, `expiry-${Date.now()}`);
  await page.getByRole("link", { name: "Search" }).click();
  await context.clearCookies();
  await page.getByLabel("Search your notes").fill("anything");
  await page.getByRole("button", { name: "Search" }).click();
  // HX-Redirect performs a full navigation to sign-in; nothing is swapped
  // into the results region.
  await expect(page.getByRole("heading", { name: "Development sign-in" })).toBeVisible();
  await expect(page).toHaveURL(/\/dev-issuer\/authorize/);
});

test("keyboard users can skip to content", async ({ page }) => {
  await watch(page);
  await signIn(page, `keyboard-${Date.now()}`);
  await page.keyboard.press("Tab");
  const skip = page.getByRole("link", { name: "Skip to content" });
  await expect(skip).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(page.locator("main")).toBeFocused();
});
