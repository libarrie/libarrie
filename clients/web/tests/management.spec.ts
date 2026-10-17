import { test, expect, Page } from "@playwright/test";
import { pagePng } from "./png";
import { watch, cspViolations, signIn } from "./helpers";

async function createNotebook(page: Page, name: string) {
  await page.getByLabel("New notebook").fill(name);
  await page.getByText("Description and color").click();
  await page.getByLabel("Description (optional)").fill("Green cover");
  await page.getByLabel("Green").check();
  await page.getByRole("button", { name: "Create" }).click();
  await page.getByRole("link", { name }).click();
}

async function uploadFirstPage(page: Page, text: string) {
  await page.getByRole("link", { name: "Add pages" }).click();
  await page.locator("#files").setInputFiles({ name: "p1.png", mimeType: "image/png", buffer: pagePng(text) });
  await page.getByRole("button", { name: "Upload" }).click();
  await expect(page.locator("#upload-queue")).toContainText("Uploaded; processing", { timeout: 30_000 });
  await page.getByRole("link", { name: "Back to the notebook" }).click();
  await expect(async () => {
    await page.reload();
    await expect(page.locator(".page-tile")).toContainText("Searchable", { timeout: 1_000 });
  }).toPass({ timeout: 60_000 });
}

test("notebook settings, renumbering, replacement scan and export", async ({ page }) => {
  const problems = await watch(page);
  await signIn(page, `manage-${Date.now()}`);
  await createNotebook(page, "Lab book");
  await expect(page.locator(".notebook-title .swatch")).toBeVisible();

  await uploadFirstPage(page, "Calibrated the spectrometer");

  // Renumber: shift page 1 to page 2.
  await page.getByText("Notebook settings").click();
  await page.getByRole("link", { name: "Renumber pages" }).click();
  await page.getByLabel("First page").fill("1");
  await page.getByLabel("Last page").fill("1");
  await page.getByLabel("Move by").fill("1");
  await page.getByRole("button", { name: "Renumber" }).click();
  await expect(page.getByText("Pages renumbered.")).toBeVisible();
  await expect(page.locator(".page-tile")).toContainText("Page 2");

  // Replace the scan from the page detail screen.
  await page.locator(".page-tile a").first().click();
  await page.getByLabel("Replace with a new photo").setInputFiles({
    name: "better.png",
    mimeType: "image/png",
    buffer: pagePng("Calibrated the spectrometer twice"),
  });
  await page.getByRole("button", { name: "Upload replacement" }).click();
  await expect(page.locator("#replace-queue")).toContainText("Uploaded; processing", { timeout: 30_000 });
  // The page reloads by itself and eventually shows the new text.
  await expect(async () => {
    await page.reload();
    await expect(page.locator("#transcript-text")).toHaveValue("Calibrated the spectrometer twice", { timeout: 1_000 });
  }).toPass({ timeout: 60_000 });
  expect(await cspViolations(page)).toEqual([]);

  // Export everything; the list polls until the files are ready.
  await page.getByRole("link", { name: "Exports" }).click();
  await page.getByRole("button", { name: "Start export" }).click();
  await expect(page.getByText("Export started.")).toBeVisible();
  await expect(page.getByRole("link", { name: "Download part 1" })).toBeVisible({ timeout: 60_000 });
  const download = page.waitForEvent("download");
  await page.getByRole("link", { name: "Download part 1" }).click();
  expect((await download).suggestedFilename()).toMatch(/^libarrie-export-.*-part-0001\.zip$/);

  expect(await cspViolations(page)).toEqual([]);
  expect(problems.filter((p) => !p.includes("favicon"))).toEqual([]);
});

test("account deletion asks to sign in again, then can be cancelled", async ({ page }) => {
  await watch(page);
  const subject = `closing-${Date.now()}`;
  await signIn(page, subject);
  await page.getByRole("link", { name: "Browser Tester" }).click();
  await page.getByRole("link", { name: "Delete account…" }).click();
  // A fresh sign-in is still recent, so the confirmation form is shown.
  await page.getByLabel("I want to delete my account and all of my notes").check();
  await page.getByRole("button", { name: "Delete account" }).click();
  await expect(page.getByText("Account deletion scheduled.")).toBeVisible();
  await page.getByRole("button", { name: "Keep my account" }).click();
  await expect(page.getByText("Account deletion cancelled.")).toBeVisible();
  expect(await cspViolations(page)).toEqual([]);
});
