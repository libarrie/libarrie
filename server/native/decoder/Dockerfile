# Build context: the `server/` directory, e.g.
#   docker build -f native/decoder/Dockerfile --target artifact server/
#
# Builds the sandboxed image decoder, its launcher and minijail0 as static
# musl binaries with clang + compiler-rt (no libgcc, no libstdc++), and
# packages them in a scratch image layer for the worker image.
#
# Licenses of what ends up in the artifact (recorded in LICENSES.md):
#   decoder, launcher: Libarrie (project license)
#   musl libc: MIT
#   libjpeg-turbo: IJG + BSD-3-Clause + zlib
#   libpng: libpng license (PNG Reference Library License v2)
#   zlib: zlib license
#   minijail: BSD-3-Clause
#   libcap: dual BSD-3-Clause / GPL-2.0-only -- BSD-3-Clause ELECTED
#   compiler-rt builtins: Apache-2.0 WITH LLVM-exception
# The Alpine build stage (busybox, gcc-free clang toolchain) is
# development-only tooling and never enters the artifact.

ARG ALPINE=alpine:3.20
FROM ${ALPINE} AS build
ENV STATIC="-static -fuse-ld=lld -rtlib=compiler-rt -unwindlib=none"
COPY native/decoder/ /src/decoder/
RUN sh /src/decoder/build.sh /src/decoder
WORKDIR /build

# Test-only stage: adds sample images and a crashing helper.
FROM build AS test
RUN apk add --no-cache imagemagick
COPY native/decoder/probe.c native/decoder/sandbox-test.sh ./
RUN mkdir -p /test/bin /test/crashbin /test/spinbin \
 && clang -O0 $STATIC probe.c -o /test/bin/probe \
 && clang -O0 $STATIC -DFORCE_MODE='"segv"' probe.c -o /test/crashbin/decoder \
 && clang -O0 $STATIC -DFORCE_MODE='"spin"' probe.c -o /test/spinbin/decoder \
 && cp /build/launcher /test/crashbin/ && cp /build/launcher /test/spinbin/ \
 && mkdir -p /test/fixtures \
 && magick -size 1200x900 gradient:navy-white -quality 90 /test/fixtures/photo.jpg \
 && head -c 4096 /test/fixtures/photo.jpg > /test/fixtures/truncated.jpg
ENTRYPOINT ["/bin/bash", "/build/sandbox-test.sh"]

# Runs the Gleam decoder adapter's tests against the real binaries:
#   docker build -f native/decoder/Dockerfile --target adapter-test -t t server/
#   docker run --rm --privileged t                         (minijail tier)
#   docker run --rm --user 1000 -e TIER=unprivileged t     (unprivileged tier)
FROM ghcr.io/gleam-lang/gleam:v1.19.1-erlang-alpine AS adapter-test
COPY --from=test /out/ /
COPY --from=test /test/ /test/
COPY packages/integrations /src/integrations
RUN cd /src/integrations && rm -rf build && gleam deps download && gleam build \
 && chmod -R a+rwX /src/integrations && mkdir -m 1777 /scratch
ENV LIBARRIE_DECODER_BIN=/opt/libarrie/bin LIBARRIE_DECODER_FIXTURES=/test/fixtures
WORKDIR /src/integrations
ENTRYPOINT ["sh", "-c", "LIBARRIE_DECODER_TIER=${TIER:-minijail} gleam test"]

# The artifact: copied into the worker runtime image.
FROM scratch AS artifact
COPY --from=build /out/ /
