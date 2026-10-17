# Build context: the repository root, e.g.
#   docker build -f server/Dockerfile -t libarrie-server .
#
# One image holding the API (with the web UI), the worker and the sandboxed
# image decoder. This is a development/test image: its runtime layer is the
# upstream Gleam/Erlang Alpine image, not the GPL-free release image.

ARG ALPINE=alpine:3.20
ARG GLEAM_IMAGE=ghcr.io/gleam-lang/gleam:v1.19.1-erlang-alpine

# Static decoder, launcher and minijail0 (see native/decoder/build.sh).
FROM ${ALPINE} AS decoder
COPY server/native/decoder/ /src/decoder/
RUN sh /src/decoder/build.sh /src/decoder

FROM ${GLEAM_IMAGE} AS build
# gleam_mcp and its httpp fork are git dependencies.
RUN apk add --no-cache git
COPY server/packages /src/server/packages
COPY server/apps /src/server/apps
RUN cd /src/server/apps/api && rm -rf build && gleam export erlang-shipment \
 && cd /src/server/apps/worker && rm -rf build && gleam export erlang-shipment

FROM ${GLEAM_IMAGE}
RUN addgroup -S -g 10001 libarrie && adduser -S -u 10001 -G libarrie -H libarrie
COPY --from=decoder /out/ /
COPY --from=build /src/server/apps/api/build/erlang-shipment /app/api
COPY --from=build /src/server/apps/worker/build/erlang-shipment /app/worker
COPY database/migrations /app/migrations
COPY clients/web/static /app/static
ENV MIGRATIONS_DIR=/app/migrations \
    WEB_STATIC_DIR=/app/static \
    DECODER_BIN_DIR=/opt/libarrie/bin \
    DECODER_POLICY=/opt/libarrie/policy/decoder.policy \
    DECODER_SCRATCH_DIR=/tmp/libarrie-decoder
USER libarrie
WORKDIR /app
EXPOSE 8080
CMD ["/app/api/entrypoint.sh", "run", "serve"]
