#!/bin/sh
# Builds the sandboxed decoder, launcher and minijail0 as static musl
# binaries (clang + lld + compiler-rt; no GCC runtime) inside an Alpine
# image, and lays out the artifact under /out/opt/libarrie. Shared by
# native/decoder/Dockerfile and the server image (server/Dockerfile).
#   build.sh SOURCE_DIR    (SOURCE_DIR holds decoder.c, launcher.c, *.policy)
set -eu
SRC="$1"
MINIJAIL_COMMIT=f4882a440f6d6eab7f35190e06bc16257ef3dcae
STATIC="-static -fuse-ld=lld -rtlib=compiler-rt -unwindlib=none"

apk add --no-cache clang lld llvm compiler-rt musl-dev musl-utils linux-headers \
  libjpeg-turbo-dev libjpeg-turbo-static libpng-dev libpng-static \
  zlib-dev zlib-static libcap-dev libcap-static git make bash

# No binutils: LLVM's ar and nm (newer Alpine clang no longer pulls binutils in).
PATH="$(dirname "$(ls -d /usr/lib/llvm*/bin/llvm-ar | head -1)"):$PATH"
export PATH

mkdir -p /build && cd /build
cp "$SRC/decoder.c" "$SRC/launcher.c" "$SRC"/decoder.*.policy .
clang -O2 -Wall -Wextra -fstack-protector-strong -D_FORTIFY_SOURCE=2 $STATIC \
  decoder.c -o decoder -lpng16 -ljpeg -lz -lm
git clone https://github.com/google/minijail.git /build/minijail
(cd /build/minijail && git checkout "$MINIJAIL_COMMIT" \
  && make CC=clang AR=llvm-ar CFLAGS="-O2 -D_GNU_SOURCE" LDFLAGS="$STATIC" \
       "CC_BINARY(minijail0)" "CC_STATIC_LIBRARY(libminijail.pie.a)")
cp /build/minijail/minijail0 /build/minijail0
# The launcher links libminijail statically for its seccomp policy parser.
clang -O2 -Wall -Wextra -fstack-protector-strong -D_GNU_SOURCE $STATIC \
  -I/build/minijail launcher.c -o launcher /build/minijail/libminijail.pie.a -lcap

# Fail the build if any GCC runtime slipped into a binary.
for b in decoder launcher minijail0; do
  if llvm-nm --defined-only "/build/$b" | grep -qiE "__gcc_personality|_Unwind_Resume|__register_frame_info"; then
    echo "GCC runtime symbols found in $b"; exit 1
  fi
  if ldd "/build/$b" 2>&1 | grep -q "=>"; then echo "$b is dynamic"; exit 1; fi
done

mkdir -p /out/opt/libarrie/bin /out/opt/libarrie/sandbox-root/proc /out/opt/libarrie/policy
cp decoder launcher minijail0 /out/opt/libarrie/bin/
cp decoder.*.policy /out/opt/libarrie/policy/
cp "decoder.$(uname -m).policy" /out/opt/libarrie/policy/decoder.policy
