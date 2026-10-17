#!/usr/bin/env python3
"""Assemble the release root filesystem (DESIGN.md section 3).

The image has no shell, so:
- OTP's shell scripts (`erl`, `start`, ...) and Gleam's `entrypoint.sh` are
  dropped; each program starts by exec'ing `erlexec` with an args file
  (`-args_file`) generated here, with the code paths spelled out.
- Name resolution uses OTP's own DNS client (`/etc/inetrc`), because the
  native resolver is started through `/bin/sh -c`.
- Every shared library is copied from the exact files the ELF binaries
  need, so nothing else from the build image comes along.

Usage: stage.py ROOTFS NAME=MAIN...
  for example: stage.py /rootfs api=libarrie_api worker=libarrie_worker
Inputs (from the Dockerfile): /opt/erlang (our OTP build) and, for each
program NAME, its Gleam erlang-shipment at /ship/NAME. Optional: the decoder
sandbox at /ship/decoder, web assets at /ship/static and migrations at
/ship/migrations, each staged only if present.
"""

import os
import re
import shutil
import stat
import subprocess
import sys

ROOT = sys.argv[1]
OTP = "/opt/erlang/lib/erlang"

# Programs in the image: the args file each one starts from, and its main.
PROGRAMS = dict(spec.split("=", 1) for spec in sys.argv[2:])
if not PROGRAMS:
    sys.exit("usage: stage.py ROOTFS NAME=MAIN...")

# OTP applications always needed, besides those the shipments' .app files
# name: the boot applications, and those reached through function calls
# rather than .app dependencies.
BASE_APPS = {"kernel", "stdlib", "compiler", "crypto", "public_key", "asn1", "ssl", "inets", "sasl"}


def run(*cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def ensure_dir(path, mode=0o755):
    os.makedirs(path, exist_ok=True)
    os.chmod(path, mode)


def is_script(path):
    with open(path, "rb") as f:
        return f.read(2) == b"#!"


def app_dependencies(app_file):
    """Applications named in a .app file (applications, included and optional)."""
    text = open(app_file, encoding="utf-8", errors="replace").read()
    names = set()
    for key in ("applications", "included_applications", "optional_applications"):
        m = re.search(r"\{\s*" + key + r"\s*,\s*\[([^\]]*)\]", text)
        if m:
            names.update(n.strip().strip("'") for n in m.group(1).split(",") if n.strip())
    return names


def otp_app_dirs():
    lib = os.path.join(OTP, "lib")
    return {d.rsplit("-", 1)[0]: os.path.join(lib, d) for d in os.listdir(lib)}


def needed_otp_apps(shipments):
    otp = otp_app_dirs()
    wanted = set(BASE_APPS)
    for ship in shipments:
        for pkg in os.listdir(ship):
            ebin = os.path.join(ship, pkg, "ebin")
            if os.path.isdir(ebin):
                for f in os.listdir(ebin):
                    if f.endswith(".app"):
                        wanted |= app_dependencies(os.path.join(ebin, f))
    # Close over OTP's own dependencies.
    pending = [a for a in wanted if a in otp]
    seen = set()
    while pending:
        app = pending.pop()
        if app in seen:
            continue
        seen.add(app)
        app_file = os.path.join(otp[app], "ebin", app + ".app")
        for dep in app_dependencies(app_file):
            if dep in otp and dep not in seen:
                pending.append(dep)
    missing = sorted(a for a in wanted if a not in otp and not any(
        os.path.isdir(os.path.join(s, a)) for s in shipments))
    if missing:
        sys.exit("applications not found in OTP or the shipments: " + ", ".join(missing))
    return sorted(seen)


def copy_tree(src, dst, keep=lambda rel: True):
    for dirpath, dirnames, filenames in os.walk(src):
        rel_dir = os.path.relpath(dirpath, src)
        for name in filenames:
            rel = os.path.normpath(os.path.join(rel_dir, name))
            if not keep(rel):
                continue
            s = os.path.join(dirpath, name)
            d = os.path.join(dst, rel)
            if os.path.islink(s) or is_script(s):
                continue
            os.makedirs(os.path.dirname(d), exist_ok=True)
            shutil.copy2(s, d)


def stage_otp(apps):
    dst = ROOT + OTP
    erts = next(d for d in os.listdir(OTP) if d.startswith("erts-"))
    # The emulator and the helpers it starts itself; no epmd (no
    # distribution), heart, inet_gethost (DNS goes through OTP's resolver),
    # or development tools.
    for prog in ("erlexec", "beam.smp", "erl_child_setup"):
        src = os.path.join(OTP, erts, "bin", prog)
        os.makedirs(os.path.join(dst, erts, "bin"), exist_ok=True)
        shutil.copy2(src, os.path.join(dst, erts, "bin", prog))
    # Boot files and release metadata.
    for name in os.listdir(os.path.join(OTP, "bin")):
        if name.endswith(".boot"):
            os.makedirs(os.path.join(dst, "bin"), exist_ok=True)
            shutil.copy2(os.path.join(OTP, "bin", name), os.path.join(dst, "bin", name))
    copy_tree(os.path.join(OTP, "releases"), os.path.join(dst, "releases"),
              keep=lambda rel: not rel.endswith((".script", ".rel")) or "start" in rel)
    # Applications: compiled code and private files only.
    otp = otp_app_dirs()
    for app in apps:
        name = os.path.basename(otp[app])
        copy_tree(otp[app], os.path.join(dst, "lib", name),
                  keep=lambda rel: rel.split(os.sep)[0] in ("ebin", "priv")
                  and not rel.startswith(os.path.join("priv", "obj")))
    return erts


def stage_shipment(name, src):
    # Package directories only: not Gleam's entrypoint.sh or entrypoint.ps1.
    dst = os.path.join(ROOT, "app", name)
    for pkg in os.listdir(src):
        if os.path.isdir(os.path.join(src, pkg)):
            copy_tree(os.path.join(src, pkg), os.path.join(dst, pkg))
    return dst


def args_file(name, main, ship_dir):
    ebins = sorted(
        os.path.join("/app", name, pkg, "ebin")
        for pkg in os.listdir(ship_dir)
        if os.path.isdir(os.path.join(ship_dir, pkg, "ebin"))
    )
    # The image entrypoint adds `-eval <main>@@main:run(<main>)`, so checks
    # can boot the same code path with their own -eval.
    lines = ["# Generated by server/release/stage.py: the code path for erlexec."]
    lines += ["-pa " + e for e in ebins]
    lines += ["-noshell"]
    with open(os.path.join(ROOT, "app", name + ".args"), "w") as f:
        f.write("\n".join(lines) + "\n")


def elf_files():
    out = run("scanelf", "-RBF", "%F", ROOT)
    return [p for p in out.split() if p]


def stage_libraries():
    """Copy every shared library the binaries need (transitively), by soname."""
    copied = set()
    by_real = {}
    pending = elf_files()
    while pending:
        f = pending.pop()
        out = subprocess.run(["ldd", f], capture_output=True, text=True).stdout
        for line in out.splitlines():
            m = re.match(r"\s*(\S+)\s+=>\s+(\S+)", line)
            if not m:
                m2 = re.match(r"\s*(/\S+)\s+\(", line)
                if not m2:
                    continue
                soname, path = os.path.basename(m2.group(1)), m2.group(1)
            else:
                soname, path = m.group(1), m.group(2)
            target = os.path.join(os.path.dirname(path), soname) if "/" not in soname else soname
            if target in copied:
                continue
            copied.add(target)
            real = os.path.realpath(path)
            dst = ROOT + target
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if real in by_real:
                # One file under two names (musl's loader is also its libc).
                os.symlink(by_real[real], dst)
                continue
            shutil.copy2(real, dst)
            by_real[real] = target
            pending.append(dst)
    return sorted(copied)


def write(path, text, mode=0o644):
    full = ROOT + path
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(text)
    os.chmod(full, mode)


def main():
    ensure_dir(ROOT)
    shipments = {name: "/ship/" + name for name in PROGRAMS}
    apps = needed_otp_apps(shipments.values())
    erts = stage_otp(apps)
    for name, main in PROGRAMS.items():
        args_file(name, main, stage_shipment(name, shipments[name]))
    for src, dst in (("/ship/decoder", ROOT), ("/ship/static", ROOT + "/app/static"),
                     ("/ship/migrations", ROOT + "/app/migrations")):
        if os.path.isdir(src):
            copy_tree(src, dst)
    libs = stage_libraries()
    # CA certificates for outbound TLS (public_key:cacerts_get/0).
    ensure_dir(ROOT + "/etc/ssl/certs")
    shutil.copy2("/etc/ssl/certs/ca-certificates.crt", ROOT + "/etc/ssl/certs/ca-certificates.crt")
    # OTP's own resolver; Docker provides /etc/hosts and /etc/resolv.conf.
    write("/etc/inetrc", "{lookup, [file, dns]}.\n{resolv_conf, \"/etc/resolv.conf\"}.\n{hosts_file, \"/etc/hosts\"}.\n")
    # erlexec at a stable path, so entrypoints don't name the erts version.
    ensure_dir(ROOT + "/app/bin")
    os.symlink(os.path.join(OTP, erts, "bin", "erlexec"), ROOT + "/app/bin/erlexec")
    ensure_dir(ROOT + "/tmp", 0o1777)
    os.chmod(ROOT + "/tmp", stat.S_IRWXU | stat.S_IRWXG | stat.S_IRWXO | stat.S_ISVTX)
    # Nothing in the image may be a script (there is no interpreter).
    for dirpath, _, filenames in os.walk(ROOT):
        for name in filenames:
            p = os.path.join(dirpath, name)
            if not os.path.islink(p) and is_script(p):
                sys.exit("script in the release image: " + p)
    with open("/staged-erts", "w") as f:
        f.write(erts)
    print("staged OTP applications:", ", ".join(apps))
    print("staged libraries:", ", ".join(libs))


main()
