# Libarrie web client assets and browser tests

- `static/`: served by the API under `/static`. It contains the stylesheet
  (design tokens for light and dark), pinned htmx, and three small modules:
  `app.js` (announcements and focus), `md5.js` and `upload.js` (the direct
  upload flow).
- `tests/`: Playwright tests that drive your installed Google Chrome against
  the real API and worker, using the development OIDC issuer.

```sh
cd clients/web
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install
npx playwright test                         # needs the dev Postgres and S3 stack
SCREENSHOTS=1 npx playwright test tests/screenshots.spec.ts   # review images
```

Nothing in this directory except `static/` ships to production.

## Accessibility audit

```sh
clients/web/scripts/a11y.sh
```

The server test suite renders every screen, in light and dark themes, to
HTML using the test database. Playwright then loads each one with the real
stylesheet and checks WCAG 2.2 A and AA with axe-core. No server is started.
