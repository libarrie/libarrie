#!/usr/bin/env python3
"""Release SBOM and license gate (DESIGN.md section 3).

Attributes every file in the release root filesystem to a component,
writes a CycloneDX 1.5 SBOM, and fails on:
- a file no component accounts for;
- a component with an unknown license;
- any GPL-family license (GPL, LGPL, AGPL, including "WITH" exceptions),
  unless the component is dual-licensed and its non-GPL alternative is
  recorded in license-elections.tsv;
- a shared library from a GCC runtime.

Usage: sbom.py ROOTFS OUTPUT.json [NAME]
Inputs: /otp-vendor (OTP's vendor.info files), /ship/licenses (one file
per Gleam/Hex package holding its license), server/native/decoder/LICENSES.md
at /ship/decoder-licenses.md, and the elections at /ship/license-elections.tsv.
"""

import json
import os
import re
import subprocess
import sys

ROOT, OUTPUT = sys.argv[1], sys.argv[2]
IMAGE = sys.argv[3] if len(sys.argv) > 3 else "libarrie-server"
OTP_VERSION = open("/otp-version").read().strip()
FIRST_PARTY = "Apache-2.0"

components = {}   # key -> dict(name, version, license, kind)
owner = {}        # file -> component key


def component(key, name, version, license, kind="library", purl=None):
    if key not in components:
        components[key] = {"name": name, "version": version, "license": license, "kind": kind, "purl": purl}
    return key


def files_under(prefix):
    base = ROOT + prefix
    for dirpath, _, filenames in os.walk(base):
        for name in filenames:
            yield os.path.join(dirpath, name)[len(ROOT):]


def attribute(prefix, key):
    for f in files_under(prefix):
        owner.setdefault(f, key)


# Erlang/OTP and the third-party code it vendors into the runtime.
otp = component("erlang-otp", "erlang-otp", OTP_VERSION, "Apache-2.0", purl="pkg:github/erlang/otp@OTP-" + OTP_VERSION)
attribute("/opt/erlang", otp)
included_apps = {d.rsplit("-", 1)[0] for d in os.listdir(ROOT + "/opt/erlang/lib/erlang/lib")}
for name in sorted(os.listdir("/otp-vendor")):
    text = open(os.path.join("/otp-vendor", name)).read()
    entries = json.loads("\n".join(l for l in text.splitlines() if not l.lstrip().startswith("//")))
    for e in entries:
        paths = e.get("path", "")
        paths = paths if isinstance(paths, list) else [paths]

        def shipped(path):
            # Runtime code only: not build scripts (autoconf) or test data.
            parts = path[2:].split("/") if path.startswith("./") else path.split("/")
            if any(p in ("autoconf", "test", "test_server") for p in parts):
                return False
            return parts[0] == "erts" or (parts[0] == "lib" and len(parts) > 1 and parts[1] in included_apps)

        if any(shipped(p) for p in paths):
            component("otp-vendor:" + e["ID"], e.get("name", e["ID"]), e.get("versionInfo", ""),
                      e.get("licenseDeclared", ""), purl=None)

# Alpine packages for every file not produced by our builds.
def apk_owner(path):
    out = subprocess.run(["apk", "info", "--who-owns", path], capture_output=True, text=True).stdout
    m = re.search(r"is owned by (\S+)", out)
    return m.group(1) if m else None


def apk_package(pkgver):
    out = subprocess.run(["apk", "list", "-I"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith(pkgver + " "):
            license = re.search(r"\(([^)]*)\)", line).group(1)
            name = re.sub(r"-[0-9][^-]*-r[0-9]+$", "", pkgver)
            version = pkgver[len(name) + 1:]
            return name, version, license
    return None


for libdir in ("/lib", "/usr/lib", "/etc/ssl"):
    for f in files_under(libdir):
        if os.path.islink(ROOT + f):
            continue
        pkgver = apk_owner(f) if os.path.exists(f) else None
        if pkgver:
            name, version, license = apk_package(pkgver)
            if name in ("libstdc++", "libgcc"):
                sys.exit("GCC runtime library in the image: " + f)
            owner[f] = component("apk:" + name, name, version, license, purl="pkg:apk/alpine/" + name + "@" + version)

# Gleam and Hex packages in each shipment.
for prog in os.listdir(ROOT + "/app"):
    ship = os.path.join(ROOT + "/app", prog)
    if not os.path.isdir(ship) or prog in ("bin", "static", "migrations", "billing-migrations"):
        continue
    for pkg in os.listdir(ship):
        if not os.path.isdir(os.path.join(ship, pkg)):
            continue
        lic_file = os.path.join("/ship/licenses", pkg)
        declared = open(lic_file).read().strip() if os.path.exists(lic_file) else ""
        if pkg.startswith("libarrie_") and declared == FIRST_PARTY:
            key = component("first-party", "libarrie", "", FIRST_PARTY, kind="application")
        elif pkg.startswith("libarrie_"):
            # A first-party package under another license (or none, which
            # the gate refuses): its own component, never assumed.
            key = component("first-party:" + pkg, pkg, "", declared, kind="application")
        elif os.path.exists(lic_file):
            license = open(lic_file).read().strip()
            key = component("hex:" + pkg, pkg, "", license, purl="pkg:hex/" + pkg)
        else:
            key = component("hex:" + pkg, pkg, "", "")
        attribute("/app/" + prog + "/" + pkg, key)

# The decoder sandbox, from its recorded license table.
decoder_rows = []
decoder_table = "/ship/decoder-licenses.md" if os.path.isdir(ROOT + "/opt/libarrie") else os.devnull
for line in open(decoder_table):
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) >= 2 and cells[0] and not cells[0].startswith(("Component", "---")) and line.startswith("|"):
        decoder_rows.append(cells)
for cells in decoder_rows:
    name, license = cells[0], cells[1]
    if cells[2:3] == ["This directory"]:
        continue
    component("decoder:" + name, name, "", license)
first = component("first-party", "libarrie", "", FIRST_PARTY, kind="application")
attribute("/opt/libarrie", first)

# Web assets: htmx is vendored; the rest is ours.
for f in files_under("/app/static"):
    if os.path.basename(f).startswith("htmx-"):
        owner[f] = component("htmx", "htmx", "2.0.11", "0BSD", purl="pkg:npm/htmx.org@2.0.11")
attribute("/app/static", first)
attribute("/app/migrations", first)
for f in files_under("/app"):
    if f.endswith(".args") and f.count("/") == 2:
        owner[f] = first
owner["/etc/inetrc"] = first

# Gate --------------------------------------------------------------------------------------

errors = []
for f in sorted(files_under("/")):
    if f not in owner and not os.path.islink(ROOT + f):
        errors.append("unattributed file: " + f)

elections = {}
for line in open("/ship/license-elections.tsv"):
    if line.strip() and not line.startswith("#"):
        name, elected = line.split("\t")[:2]
        elections[name] = elected.strip()

GPL = re.compile(r"\b(A|L)?GPL", re.IGNORECASE)
for key, c in components.items():
    license = c["license"]
    if not license:
        errors.append("unknown license: " + c["name"])
        continue
    if GPL.search(license):
        alternatives = [a.strip("() ") for a in re.split(r"\s+OR\s+", license)]
        # Decoder rows read like "libcap (static)"; elections name the component.
        elected = elections.get(c["name"]) or elections.get(c["name"].split(" (")[0])
        if not elected or elected not in alternatives or GPL.search(elected):
            errors.append("GPL-family license without a recorded election: %s (%s)" % (c["name"], license))
        else:
            c["license"] = elected
            c["elected_from"] = license

sbom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "version": 1,
    "metadata": {"component": {"type": "container", "name": IMAGE}},
    "components": [
        dict(
            {"type": c["kind"], "name": c["name"], "version": c["version"],
             "licenses": [{"expression": c["license"]}]},
            **({"purl": c["purl"]} if c["purl"] else {}),
            **({"properties": [{"name": "libarrie:license-election",
                                "value": "elected %s from %s" % (c["license"], c["elected_from"])}]}
               if c.get("elected_from") else {}),
        )
        for c in sorted(components.values(), key=lambda c: c["name"].lower())
    ],
}
os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
with open(OUTPUT, "w") as f:
    json.dump(sbom, f, indent=2)

for c in sorted(components.values(), key=lambda c: c["name"].lower()):
    print("%-28s %-12s %s" % (c["name"], c["version"][:12], c["license"]))
if errors:
    print("\nLICENSE GATE FAILED")
    for e in errors:
        print("  " + e)
    sys.exit(1)
print("\nlicense gate passed: %d components, %d files" % (len(components), len(owner)))
