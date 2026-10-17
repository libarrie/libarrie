#!/bin/sh
# Boot checks against the staged root filesystem, run with chroot from the
# build stage (the root itself has no shell).
#   smoke.sh ROOTFS ERTS_DIR NAME=MAIN[+entry]...
# Each program boots, starts its applications and passes the runtime
# checks. Programs marked +entry must also reach their command-line
# handling (a usage message for an unknown command) without a database.
set -eu
ROOTFS="$1"
ERTS="$2"
shift 2
CHROOT=$(command -v chroot)
# A container gets /dev from the runtime; the chroot needs the few device
# nodes the emulator opens. They are removed again before the image is made.
mkdir "$ROOTFS/dev"
trap 'rm -rf "$ROOTFS/dev"' EXIT
mknod -m 666 "$ROOTFS/dev/null" c 1 3
mknod -m 666 "$ROOTFS/dev/zero" c 1 5
mknod -m 444 "$ROOTFS/dev/random" c 1 8
mknod -m 444 "$ROOTFS/dev/urandom" c 1 9
run() {
  env -i ROOTDIR=/opt/erlang/lib/erlang BINDIR="/opt/erlang/lib/erlang/$ERTS/bin" \
    EMU=beam PROGNAME=erl HOME=/tmp ERL_INETRC=/etc/inetrc \
    timeout 60 "$CHROOT" "$ROOTFS" /app/bin/erlexec "$@"
}

# The runtime: JIT, NIFs, TLS trust store, OTP's resolver, and starting the
# decoder with spawn_executable (no shell).
for spec in "$@"; do
  prog=${spec%%=*}
  main=${spec#*=}
  entry=no
  case "$main" in *+entry) main=${main%+entry}; entry=yes ;; esac
  run -args_file "/app/$prog.args" -eval "
    jit = erlang:system_info(emu_flavor),
    {ok, _} = application:ensure_all_started($main),
    {ok, _} = application:ensure_all_started(ssl),
    true = length(public_key:cacerts_get()) > 50,
    [file, dns] = inet_db:res_option(lookup),
    case filelib:is_file(\"/opt/libarrie/bin/decoder\") of
      true ->
        Port = open_port({spawn_executable, \"/opt/libarrie/bin/decoder\"}, [exit_status, {args, []}]),
        receive {Port, {exit_status, _}} -> ok after 5000 -> exit(decoder_timeout) end;
      false -> ok
    end,
    io:format(\"$prog: runtime checks passed~n\"),
    halt(0)."
  if [ "$entry" = yes ]; then
    out=$(run -args_file "/app/$prog.args" -eval "$main@@main:run($main)" -extra no-such-command 2>&1 || true)
    case "$out" in
      *usage:*) echo "$prog: entry point reached argument handling" ;;
      *) echo "$prog did not reach its command line:"; echo "$out"; exit 1 ;;
    esac
  fi
done
