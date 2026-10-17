# API conformance fixtures

`api/*.json` are real responses recorded from the server by
`server/apps/api/test/contract_fixtures_test.gleam`. Each file holds the HTTP
`status` and the response `body` (as a string).

- **Clients** decode these in their unit tests (`clients/ios/Tests`), so a
  model that no longer matches the server fails before release.
- **The server suite** checks every run that responses still have the
  recorded shape: the same keys and value types, with null matching anything.
  IDs and timestamps differ between runs and are not compared.

Regenerate them after an intended API change:

```sh
cd server && LIBARRIE_WRITE_FIXTURES=1 scripts/test.sh
```

Changes must stay additive for older installed apps (section 11): add
fields, don't rename or remove them.
