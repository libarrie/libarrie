#!/bin/bash
# Foundation spike checks for the decoder sandbox (DESIGN.md sections 7, 15
# and 17 scenario 35). Run in a privileged container:
#   docker build --target test -t libarrie-decoder-test . &&
#   docker run --rm --privileged libarrie-decoder-test
set -u
ROOT=/out/opt/libarrie
BIN=$ROOT/bin
ARCH=$(uname -m)
POLICY=$ROOT/policy/decoder.$ARCH.policy
PASS=0
FAIL=0
WORK=$(mktemp -d)
chmod 0777 "$WORK"

magick -size 1200x900 gradient:navy-white -quality 90 "$WORK/photo.jpg"
magick -size 640x480 xc:white "$WORK/page.png"
magick -size 9000x9000 xc:white -quality 50 "$WORK/huge.jpg"
head -c 4096 "$WORK/photo.jpg" > "$WORK/truncated.jpg"
printf 'not an image at all' > "$WORK/text.jpg"
# Rotated photo: a 300x200 JPEG with a hand-built EXIF APP1 segment whose
# Orientation tag is 6 (display rotated 90 degrees clockwise).
magick -size 300x200 xc:red -quality 90 "$WORK/plain.jpg"
{
  printf '\xff\xd8'
  printf '\xff\xe1\x00\x22Exif\x00\x00MM\x00\x2a\x00\x00\x00\x08'
  printf '\x00\x01\x01\x12\x00\x03\x00\x00\x00\x01\x00\x06\x00\x00\x00\x00\x00\x00'
  tail -c +3 "$WORK/plain.jpg"
} > "$WORK/rot.jpg"

# sandbox PROGRAM ARGS... runs the full production chain:
# minijail (namespaces, no_new_privs, nobody, no capabilities, seccomp,
# pivot_root into an empty root with read-only /bin and a writable /work)
# -> launcher (rlimits + wall-clock alarm) -> program.
sandbox() {
  local cpu=$1 mem=$2 wall=$3; shift 3
  # -p: new pid namespace (minijail stays init, so the decoder keeps
  # default signal actions such as SIGALRM). A fresh read-only procfs is
  # mounted because -p remounts /proc.
  "$BIN/minijail0" -T static -n -e -l -p --uts -N \
    -u 65534 -g 65534 -c 0 --ambient \
    -P "$ROOT/sandbox-root" -k proc,/proc,proc,0x1 \
    -b "$BIN,/bin,0" -b "$EXTRA_BIN,/xbin,0" -b "$WORK,/work,1" \
    -S "$POLICY" --env-reset \
    -- /bin/launcher "$cpu" "$mem" "$wall" 33554432 -- "$@" < <(sleep 30)
}
EXTRA_BIN=/test/bin

check() {
  local name=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    echo "PASS  $name (exit $actual)"; PASS=$((PASS + 1))
  else
    echo "FAIL  $name: expected $expected, got $actual"; FAIL=$((FAIL + 1))
  fi
}

check "fixture carries EXIF orientation 6" 6 "$(magick identify -format '%[EXIF:Orientation]' "$WORK/rot.jpg" 2>/dev/null)"

if [ "$(id -u)" != 0 ]; then
  # ---- Unprivileged tier: Landlock + seccomp + rlimits, no namespaces ----
  # Runs as a non-root user under the container runtime's default profile.
  confined() {
    local cpu=$1 mem=$2 wall=$3 prog=$4; shift 4
    "$BIN/launcher" --require-landlock --seccomp "$POLICY" \
      --landlock-ro "$prog" --landlock-rw "$WORK" \
      "$cpu" "$mem" "$wall" 33554432 -- "$prog" "$@" < <(sleep 30)
  }
  echo "unprivileged tier as uid $(id -u)"
  confined 10 1073741824 10 "$BIN/decoder" resize "$WORK/photo.jpg" "$WORK/thumb.jpg" 80000000 256 80
  check "unprivileged: resize to thumbnail" 0 $?
  check "unprivileged: thumbnail dimensions" "256x192" "$(magick identify -format %wx%h "$WORK/thumb.jpg")"
  confined 10 1073741824 10 "$BIN/decoder" validate "$WORK/truncated.jpg" "$WORK/x.json" 80000000
  check "unprivileged: corrupt image is unsupported" 2 $?
  confined 10 1073741824 10 /test/bin/probe read /etc/passwd
  check "unprivileged: Landlock denies reads outside the scratch dir" 7 $?
  confined 10 1073741824 10 /test/bin/probe write /tmp/evil
  check "unprivileged: Landlock denies writes outside the scratch dir" 7 $?
  confined 10 1073741824 10 /test/bin/probe write "$WORK/ok"
  check "unprivileged: scratch dir is writable" 0 $?
  confined 10 1073741824 10 /test/bin/probe segv
  check "unprivileged: crash contained (SIGSEGV)" $((128 + 11)) $?
  confined 1 1073741824 30 /test/bin/probe spin
  check "unprivileged: CPU limit (SIGKILL)" $((128 + 9)) $?
  confined 30 1073741824 2 /test/bin/probe block
  check "unprivileged: wall clock (SIGALRM)" $((128 + 14)) $?
  confined 10 1073741824 10 /test/bin/probe socket
  check "unprivileged: seccomp blocks sockets (SIGSYS)" $((128 + 31)) $?
  confined 10 1073741824 10 /test/bin/probe fork
  check "unprivileged: no process creation" 7 $?
  echo
  echo "$PASS passed, $FAIL failed"
  [ "$FAIL" = 0 ]
  exit
fi

sandbox 10 1073741824 10 /bin/decoder validate /work/photo.jpg /work/photo.json 80000000
check "validate jpeg" 0 $?
grep -q '"width":1200,"height":900' "$WORK/photo.json" && echo "      $(cat "$WORK/photo.json")"

sandbox 10 1073741824 10 /bin/decoder resize /work/photo.jpg /work/thumb.jpg 80000000 256 80
check "resize to thumbnail" 0 $?
check "thumbnail dimensions" "256x192" "$(magick identify -format %wx%h "$WORK/thumb.jpg")"

sandbox 10 1073741824 10 /bin/decoder resize /work/page.png /work/preview.jpg 80000000 1600 85
check "png preview (no upscale)" "640x480" "$(magick identify -format %wx%h "$WORK/preview.jpg")"

sandbox 10 1073741824 10 /bin/decoder resize /work/rot.jpg /work/rot-out.jpg 80000000 1000 85
check "EXIF orientation applied" "200x300" "$(magick identify -format %wx%h "$WORK/rot-out.jpg")"
check "derived image has no EXIF" "present:" "$( [ -s "$WORK/rot-out.jpg" ] && echo present):$(magick identify -format '%[EXIF:*]' "$WORK/rot-out.jpg" 2>/dev/null)"

sandbox 10 1073741824 10 /bin/decoder validate /work/truncated.jpg /work/x.json 80000000
check "truncated jpeg is unsupported" 2 $?
sandbox 10 1073741824 10 /bin/decoder validate /work/text.jpg /work/x.json 80000000
check "non-image is unsupported" 2 $?
sandbox 10 1073741824 10 /bin/decoder validate /work/huge.jpg /work/x.json 50000000
check "pixel limit enforced" 3 $?
sandbox 10 134217728 10 /bin/decoder validate /work/huge.jpg /work/x.json 81000000
check "address-space limit stops a large decode" 3 $?

sandbox 10 1073741824 10 /xbin/probe segv
check "crashing decoder: only the subprocess dies (SIGSEGV)" $((128 + 11)) $?
sandbox 1 1073741824 30 /xbin/probe spin
check "CPU limit kills a spinning decoder (SIGKILL after SIGXCPU)" $((128 + 9)) $?
start=$SECONDS
sandbox 30 1073741824 2 /xbin/probe block
check "wall-clock alarm kills a stalled decoder (SIGALRM)" $((128 + 14)) $?
check "stalled decoder stopped within the wall clock" yes "$( [ $((SECONDS - start)) -le 4 ] && echo yes)"
# minijail reports a seccomp violation as exit 253.
sandbox 10 1073741824 10 /xbin/probe socket
check "seccomp blocks sockets (SIGSYS)" $((128 + 31)) $?
sandbox 10 1073741824 10 /xbin/probe fork
check "decoder cannot create processes (RLIMIT_NPROC=0)" 7 $?
sandbox 10 1073741824 10 /xbin/probe write-bin
check "binaries are mounted read-only" 7 $?
sandbox 10 1073741824 10 /xbin/probe write-work
check "scratch directory is writable" 0 $?

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
