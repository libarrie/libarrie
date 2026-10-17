# Release images (DESIGN.md section 3): no GPL-family software, no shell.
# Build context: the repository root.
#   docker build -f server/release/Dockerfile --target api    -t libarrie-api .
#   docker build -f server/release/Dockerfile --target worker -t libarrie-worker .
#   docker build -f server/release/Dockerfile --target sbom --output type=local,dest=out/sbom .
#
# - Erlang/OTP is built from source with clang, lld, libc++, compiler-rt
#   and LLVM libunwind against musl (build-otp.sh), so neither the runtime
#   nor its JIT links libstdc++ or libgcc_s.
# - The images are `scratch` plus exactly the files the programs need
#   (stage.py). Programs start by exec'ing erlexec with a generated args
#   file; Gleam's entrypoint.sh and OTP's shell scripts are not included.
# - sbom.py attributes every file to a component, writes a CycloneDX SBOM
#   (/app/sbom.cdx.json in the image), and fails the build on any
#   GPL-family license without a recorded election, or any unknown license.

ARG ALPINE=alpine:3.24
ARG GLEAM_IMAGE=ghcr.io/gleam-lang/gleam:v1.19.1-erlang-alpine
ARG OTP_VERSION=29.1.1
ARG OTP_SHA256=054e0143e39c780e091107fc9b345792a9c1a55f6bac1eca1c1101510fc06bf6
ARG ERTS_VERSION=17.1

FROM ${ALPINE} AS decoder
COPY server/native/decoder/ /src/decoder/
RUN sh /src/decoder/build.sh /src/decoder

FROM ${ALPINE} AS otp
ARG OTP_VERSION
ARG OTP_SHA256
COPY server/release/build-otp.sh /build-otp.sh
RUN sh /build-otp.sh "$OTP_VERSION" "$OTP_SHA256" \
 && echo "$OTP_VERSION" > /otp-version \
 && mkdir /otp-vendor && cd "/build/otp_src_$OTP_VERSION" \
 && find . -name vendor.info | while read -r f; do \
      cp "$f" "/otp-vendor/$(echo "${f#./}" | tr / _)"; done

FROM ${GLEAM_IMAGE} AS gleam
ARG OTP_VERSION
# gleam_mcp and its httpp fork are git dependencies.
RUN apk add --no-cache git
# Beams compiled here run on the release runtime; the versions must match.
RUN test "$(erl -noshell -eval '{ok, V} = file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])), io:put_chars(string:trim(V)), halt().')" = "$OTP_VERSION"
COPY server/packages /src/server/packages
COPY server/apps /src/server/apps
RUN cd /src/server/apps/api && rm -rf build && gleam export erlang-shipment \
 && cd /src/server/apps/worker && rm -rf build && gleam export erlang-shipment
# Each package's declared license (gleam.toml `licences`, or the Hex
# `licenses` of an Erlang package, from its .app.src or mix.exs). Several are combined with AND.
# First-party packages are path dependencies, so they're read from their
# own directories; a Gleam package is named by its gleam.toml.
RUN mkdir /licenses && for d in /src/server/apps/*/build/packages/*/ \
      /src/server/apps/*/ /src/server/packages/*/; do \
      n=$(basename "$d"); \
      if [ -f "$d/gleam.toml" ]; then \
        n=$(sed -n 's/^name = "\(.*\)"$/\1/p' "$d/gleam.toml"); \
        l=$(grep -E '^licen[cs]es' "$d/gleam.toml" | grep -o '"[^"]*"' | tr -d '"'); \
      else \
        l=$(grep -ho '{licenses, *\[[^]]*\]' "$d"/src/*.app.src 2>/dev/null | grep -o '"[^"]*"' | tr -d '"'); \
      fi; \
      # Some Hex packages declare it in mix.exs only (ssl_verify_fun).
      if [ -z "$l" ] && [ -f "$d/mix.exs" ]; then \
        l=$(grep -o 'licenses: *\[[^]]*\]' "$d/mix.exs" | grep -o '"[^"]*"' | tr -d '"'); \
      fi; \
      echo "$l" | paste -sd'\t' - | sed 's/\t/ AND /g' > "/licenses/$n"; \
      # Erlang packages install under their application name (hpack_erl -> hpack).
      for app in "$d"/src/*.app.src; do \
        a=$(basename "$app" .app.src); \
        if [ -f "$app" ] && [ "$a" != "$n" ]; then cp "/licenses/$n" "/licenses/$a"; fi; \
      done; \
    done

FROM ${ALPINE} AS stage
ARG ERTS_VERSION
RUN apk add --no-cache python3 scanelf musl-utils libc++ llvm-libunwind \
      libcrypto3 libssl3 zlib ca-certificates-bundle
COPY --from=otp /opt/erlang /opt/erlang
COPY --from=otp /otp-vendor /otp-vendor
COPY --from=otp /otp-version /otp-version
COPY --from=gleam /src/server/apps/api/build/erlang-shipment /ship/api
COPY --from=gleam /src/server/apps/worker/build/erlang-shipment /ship/worker
COPY --from=gleam /licenses /ship/licenses
COPY --from=decoder /out/ /ship/decoder/
COPY clients/web/static /ship/static
COPY database/migrations /ship/migrations
COPY server/native/decoder/LICENSES.md /ship/decoder-licenses.md
COPY server/release/license-elections.tsv /ship/license-elections.tsv
COPY server/release/stage.py server/release/sbom.py server/release/smoke.sh /release/
RUN python3 /release/stage.py /rootfs api=libarrie_api worker=libarrie_worker \
 && test "$(cat /staged-erts)" = "erts-$ERTS_VERSION" \
 && python3 /release/sbom.py /rootfs /rootfs/app/sbom.cdx.json
# Boot both programs from the staged root, without a shell inside it.
FROM stage AS checked
ARG ERTS_VERSION
RUN sh /release/smoke.sh /rootfs "erts-$ERTS_VERSION" api=libarrie_api+entry worker=libarrie_worker

FROM scratch AS sbom
COPY --from=checked /rootfs/app/sbom.cdx.json /sbom.cdx.json

FROM scratch AS release
ARG ERTS_VERSION
COPY --from=checked /rootfs/ /
ENV ROOTDIR=/opt/erlang/lib/erlang \
    BINDIR=/opt/erlang/lib/erlang/erts-${ERTS_VERSION}/bin \
    EMU=beam \
    PROGNAME=erl \
    HOME=/tmp \
    ERL_INETRC=/etc/inetrc \
    MIGRATIONS_DIR=/app/migrations \
    WEB_STATIC_DIR=/app/static \
    DECODER_BIN_DIR=/opt/libarrie/bin \
    DECODER_POLICY=/opt/libarrie/policy/decoder.policy \
    DECODER_SCRATCH_DIR=/tmp/libarrie-decoder
USER 10001:10001
WORKDIR /app

FROM release AS worker
ENTRYPOINT ["/app/bin/erlexec", "-args_file", "/app/worker.args", "-eval", "libarrie_worker@@main:run(libarrie_worker)", "-extra"]

# Commands: serve (default), migrate, reindex, reindex-status,
# reindex-rollback ACCOUNT_ID, storage-check, journal-replay.
FROM release AS api
EXPOSE 8080
ENTRYPOINT ["/app/bin/erlexec", "-args_file", "/app/api.args", "-eval", "libarrie_api@@main:run(libarrie_api)", "-extra"]
CMD ["serve"]
