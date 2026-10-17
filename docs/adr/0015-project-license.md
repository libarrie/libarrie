# ADR 0015: Apache-2.0 project license

Status: accepted

DESIGN.md listed the open-source license as a gate before public code
publication. Libarrie is licensed under the Apache License 2.0.

## Why Apache-2.0

- **Permissive, with a patent grant.** Self-hosters, deployments that
  build their own web extensions (ADR 0009) and external entitlement
  authorities can use the core without copyleft obligations.
- **Compatible with the dependency policy.** It is outside the GPL family
  that section 3 excludes, and it matches most of what we already ship:
  Gleam packages, AndroidX, OkHttp, SeaweedFS and LLVM's libc++.

## What already carries it

The repository was set up with this license before the decision was
recorded:
- `LICENSE` holds the Apache-2.0 text;
- every `gleam.toml` declares `licences = ["Apache-2.0"]`, which the
  release license gate reads for first-party packages (ADR 0010);
- `clients/web/package.json` declares `"license": "Apache-2.0"`;
- release images carry `org.opencontainers.image.licenses=Apache-2.0`
  (ADR 0013);
- the Helm chart sets `artifacthub.io/license: Apache-2.0` (ADR 0014);
- the decoder and launcher are listed as Apache-2.0 in
  `server/native/decoder/LICENSES.md`.

## Not decided here

- **Contribution policy.** Until one is chosen, contributions are taken
  under section 5 of the license (inbound = outbound), with no CLA.
- **NOTICE file.** None yet. Add one if a bundled dependency's license
  requires its notices to be passed on.
