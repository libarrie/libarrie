import { expect, Page } from "@playwright/test";

// Records CSP violations and console errors on every page.
export async function watch(page: Page) {
  const problems: string[] = [];
  await page.addInitScript(() => {
    (window as any).__csp = [];
    document.addEventListener("securitypolicyviolation", (e) => {
      (window as any).__csp.push(`${e.violatedDirective} ${e.blockedURI}`);
    });
  });
  page.on("console", (message) => {
    if (message.type() === "error") problems.push(message.text());
  });
  page.on("pageerror", (error) => problems.push(String(error)));
  return problems;
}

export async function cspViolations(page: Page): Promise<string[]> {
  return page.evaluate(() => (window as any).__csp ?? []);
}

export async function signIn(page: Page, subject: string) {
  await page.goto("/");
  await page.getByRole("link", { name: "Sign in" }).click();
  await expect(page.getByRole("heading", { name: "Development sign-in" })).toBeVisible();
  await page.getByLabel("Subject").fill(subject);
  await page.getByLabel("Display name").fill("Browser Tester");
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page).toHaveURL(/\/notebooks$/);
}
