#!/bin/sh
# Builds Erlang/OTP for the release image against musl with clang, lld,
# libc++, compiler-rt and LLVM libunwind, so no GCC runtime (libstdc++,
# libgcc_s) is linked into the runtime or its JIT (DESIGN.md section 3).
# Installs to /opt/erlang. Runs in an Alpine build stage.
#   build-otp.sh OTP_VERSION SHA256
set -eu
VERSION="$1"
SHA256="$2"

apk add --no-cache clang22 lld22 llvm22 compiler-rt libc++-dev llvm-libunwind-dev \
  musl-dev linux-headers openssl-dev zlib-dev perl make curl scanelf

mkdir -p /build && cd /build
curl -fsSL -o otp.tar.gz \
  "https://github.com/erlang/otp/releases/download/OTP-$VERSION/otp_src_$VERSION.tar.gz"
echo "$SHA256  otp.tar.gz" | sha256sum -c -
tar xzf otp.tar.gz
cd "otp_src_$VERSION"

# No binutils: the LLVM tools stand in for ld, ar, ranlib, nm and strings.
export PATH="/usr/lib/llvm22/bin:$PATH"
# The runtime choices live in the compiler commands themselves, because
# configure probes some flags (such as -Wl,-export-dynamic, which NIFs need)
# without our LDFLAGS; a probe that fell back to libgcc would fail and
# silently drop the flag.
TOOLCHAIN="-fuse-ld=lld -rtlib=compiler-rt -unwindlib=libunwind -Wno-unused-command-line-argument"
export CC="clang $TOOLCHAIN"
export CXX="clang++ -stdlib=libc++ $TOOLCHAIN"
export LD="$CC" AR=llvm-ar RANLIB=llvm-ranlib NM=llvm-nm
export CFLAGS="-O2 -g0" CXXFLAGS="-O2 -g0"

# Only what the servers use: no terminal library (ncurses), no GUI, ODBC,
# Java or SSH, and none of the development and monitoring tools.
./configure --prefix=/opt/erlang --enable-jit --without-termcap \
  --without-wx --without-odbc --without-javac --without-jinterface \
  --without-debugger --without-observer --without-et --without-megaco \
  --without-diameter --without-ssh --without-snmp --without-eldap \
  --without-ftp --without-tftp --without-reltool --without-common_test \
  --without-eunit --without-edoc --without-erl_docgen --without-dialyzer \
  --without-typer --without-mnesia --without-os_mon --without-tools
make -j"$(nproc)"
make install

# No binary may depend on a GCC runtime.
ROOT=/opt/erlang/lib/erlang
bad=$(scanelf -RBn "$ROOT" | grep -E "libstdc\+\+|libgcc_s" || true)
if [ -n "$bad" ]; then echo "GCC runtime linked:"; echo "$bad"; exit 1; fi
for f in $(scanelf -RBF '%F' "$ROOT"); do
  if llvm-readelf --version-info "$f" | grep -qE "GLIBCXX_|GCC_[0-9]|CXXABI_1"; then
    echo "GNU runtime symbol versions required by $f"; exit 1
  fi
done
# The runtime must boot with the JIT and load its NIFs (crypto links
# OpenSSL; NIFs resolve enif_* from the exported emulator symbols).
"$ROOT/bin/erl" -noshell -eval '"jit" = atom_to_list(erlang:system_info(emu_flavor)), [{_, _, _}] = crypto:info_lib(), ok = asn1rt_nif:module_info(module) =:= asn1rt_nif andalso ok, io:format("OTP ~s with JIT; crypto and asn1 NIFs load~n", [erlang:system_info(otp_release)]), halt().'
