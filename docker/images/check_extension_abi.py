#!/usr/bin/env python3
"""Fail the build if a compiled PG extension will not load in the image that ships it.

Why this exists
---------------
The CNPG extension layers compile TimescaleDB and AGE on the RBE executor
(Ubuntu 24.04, glibc 2.39) but ship them on the CNPG base (Debian bookworm,
glibc 2.36). When build and runtime libc disagree, the resulting .so is present,
correctly named, and kills the database on startup. Both affected libraries are
in shared_preload_libraries, so this is never a degraded image -- Postgres exits.

That shipped once. The broken image was published over an existing tag, Harbor
garbage-collected the manifests two live clusters were pinned to, the fixture
cluster went to ImagePullBackOff, and demo survived only on node-cached layers.

Two distinct failures come out of that mismatch, and catching one does not catch
the other:

  1. VERSIONED reference the runtime cannot satisfy. glibc gained `strlcpy` in
     2.38, so the linker records `strlcpy@GLIBC_2.38`:

         FATAL: could not load library ".../timescaledb.so":
                /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found

  2. UNRESOLVED symbol with no version at all. The executor's headers redirect
     `strtoul` to `__isoc23_strtoul` (glibc 2.38+). Link against the older libc
     and the symbol is simply absent, so it stays undefined and UNVERSIONED --
     it sails through a version-floor check and then:

         FATAL: could not load library ".../age.so":
                undefined symbol: __isoc23_strtoul

So this checks both, against the sysroot that becomes the image rather than
against a version passed in by hand -- the two cannot drift that way.

What it does not check: an extension can still misbehave for reasons no ELF
inspection reveals. This narrowly answers "will the dynamic linker resolve it",
which is the failure that has actually bitten this image twice.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys

# A glibc version tag as it appears in ELF version records, e.g. GLIBC_2.38.
# GLIBC_PRIVATE also appears; it is deliberately ignored, being neither a floor nor
# something that sorts usefully.
_GLIBC_TAG = re.compile(r"\bGLIBC_(\d+)\.(\d+)(?:\.(\d+))?\b")


def _run(tool: str, args: list[str], path: str, *, allow_failure: bool = False) -> str:
    result = subprocess.run(
        [tool, *args, path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        if allow_failure:
            return ""
        raise SystemExit(
            f"{tool} {' '.join(args)} {path} failed with {result.returncode}:\n"
            f"{result.stderr.strip()}"
        )
    return result.stdout


def _find_tool() -> str:
    # Deliberately no silent fallback. A skipped assert is how the broken image
    # reached a cluster in the first place; a failed build is the honest outcome.
    for candidate in ("objdump", "llvm-objdump", "eu-objdump"):
        found = shutil.which(candidate)
        if found:
            return found
    raise SystemExit(
        "no objdump found on PATH (tried objdump, llvm-objdump, eu-objdump).\n"
        "This check cannot be skipped -- it is the only thing between a mis-linked "
        "extension and a database that will not start."
    )


def _parse_dynamic_symbols(text: str) -> tuple[set[str], set[str]]:
    """Return (defined, undefined_strong) symbol names from `objdump -T` output.

    Undefined WEAK symbols are excluded: they legitimately resolve to zero at load
    time and are how optional dependencies are expressed, so flagging them would
    produce noise that trains people to ignore this check.
    """
    defined: set[str] = set()
    undefined: set[str] = set()
    for line in text.splitlines():
        # objdump -T emits a tab between the section and the size:
        #   '0000000000000000  w   D  *UND*\t0000000000000000       __gmon_start__'
        #   '0000000000000000      D  *UND*\t0000000000000000       __isoc23_strtoul'
        # Parse by token, not byte offset: the address width differs between 32- and
        # 64-bit objects, and a fixed slice silently mis-reads the flag column --
        # which made every weak symbol look strong and reported the three that gcc
        # always leaves undefined as if they were real failures.
        head, _, _ = line.partition("\t")
        if not _:
            continue
        tokens = head.split()
        if len(tokens) < 2:
            continue
        section = tokens[-1]
        flags = tokens[1:-1]
        name = line.split()[-1]
        if section == "*UND*":
            # Undefined WEAK symbols resolve to zero at load time by design -- that is
            # how optional dependencies are expressed -- so they are not failures.
            if "w" not in flags:
                undefined.add(name)
        else:
            defined.add(name)
    return defined, undefined


def _libc_in(sysroot: str) -> str:
    candidates = (
        "lib/x86_64-linux-gnu/libc.so.6",
        "usr/lib/x86_64-linux-gnu/libc.so.6",
        "lib64/libc.so.6",
    )
    for rel in candidates:
        path = os.path.join(sysroot, rel)
        if os.path.isfile(path):
            return path
    raise SystemExit(
        f"no libc.so.6 under sysroot {sysroot} (looked for {', '.join(candidates)}).\n"
        "Without it there is no version floor to compare against."
    )


def _provider_paths(sysroot: str) -> list[str]:
    """Everything that can satisfy an extension's undefined symbols at load time.

    The postgres backend matters as much as the shared libraries: extensions are
    dlopened into it and resolve against its exported symbols, which is exactly how
    a call to `strlcpy` is meant to be satisfied on a platform whose libc lacks it.
    """
    providers: list[str] = []
    backend = os.path.join(sysroot, "usr/lib/postgresql/18/bin/postgres")
    if os.path.isfile(backend):
        providers.append(backend)
    lib_dirs = (
        "lib/x86_64-linux-gnu",
        "usr/lib/x86_64-linux-gnu",
        "usr/lib/postgresql/18/lib",
    )
    for rel in lib_dirs:
        directory = os.path.join(sysroot, rel)
        if not os.path.isdir(directory):
            continue
        for name in os.listdir(directory):
            path = os.path.join(directory, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            if name.endswith(".so") or ".so." in name:
                providers.append(path)
    if not providers:
        raise SystemExit(
            f"found no libraries or postgres backend under sysroot {sysroot}; every "
            "undefined symbol would be reported, so this is a broken invocation "
            "rather than a finding."
        )
    return providers


def _shared_objects(roots: list[str]) -> list[str]:
    found: list[str] = []
    for root in roots:
        if os.path.isfile(root):
            found.append(root)
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                if name.endswith(".so") or ".so." in name:
                    path = os.path.join(dirpath, name)
                    # Skip symlinks so each library is reported once, under its real name.
                    if not os.path.islink(path):
                        found.append(path)
    return sorted(found)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sysroot",
        required=True,
        help="Extracted base rootfs: supplies both the glibc version ceiling and "
        "the set of symbols available at load time.",
    )
    parser.add_argument(
        "paths",
        nargs="+",
        help="Shared objects to check, or directories to search for them.",
    )
    args = parser.parse_args()

    tool = _find_tool()
    libc = _libc_in(args.sysroot)

    defined_versions = {
        tuple(int(p) for p in m.groups() if p is not None)
        for m in _GLIBC_TAG.finditer(_run(tool, ["-p"], libc))
    }
    if not defined_versions:
        raise SystemExit(
            f"{libc} declares no GLIBC_* version definitions -- refusing to treat that "
            "as 'nothing to check', since it would pass everything."
        )
    ceiling = max(defined_versions)
    ceiling_str = ".".join(map(str, ceiling))

    available: set[str] = set()
    for provider in _provider_paths(args.sysroot):
        provided, _ = _parse_dynamic_symbols(
            _run(tool, ["-T"], provider, allow_failure=True)
        )
        available |= provided

    objects = _shared_objects(args.paths)
    if not objects:
        raise SystemExit(
            f"found no shared objects under {args.paths}. A vacuous pass here would "
            "report success for an image with no extensions in it."
        )

    # The libraries being installed together also satisfy each other. TimescaleDB is
    # split across modules -- the TSL and invalidations modules call ~320 ts_* functions
    # defined in timescaledb-<version>.so -- and Postgres loads them into one process,
    # so those references resolve at load time exactly as intended. They are not in the
    # sysroot yet because they are what this build just produced.
    for path in _shared_objects(args.paths):
        provided, _ = _parse_dynamic_symbols(_run(tool, ["-T"], path, allow_failure=True))
        available |= provided

    version_failures: list[tuple[str, str]] = []
    symbol_failures: list[tuple[str, list[str]]] = []

    for path in objects:
        name = os.path.basename(path)

        required = {
            tuple(int(p) for p in m.groups() if p is not None)
            for m in _GLIBC_TAG.finditer(_run(tool, ["-p"], path))
        }
        needed_str = ".".join(map(str, max(required))) if required else "-"
        version_bad = bool(required) and max(required) > ceiling
        if version_bad:
            version_failures.append((path, needed_str))

        _, undefined = _parse_dynamic_symbols(_run(tool, ["-T"], path))
        missing = sorted(undefined - available)
        if missing:
            symbol_failures.append((path, missing))

        status = "ok"
        if version_bad and missing:
            status = f"TOO NEW + {len(missing)} UNRESOLVED"
        elif version_bad:
            status = "TOO NEW"
        elif missing:
            status = f"{len(missing)} UNRESOLVED"
        print(f"  {name:<36} glibc<={needed_str:<8} {status}")

    if not version_failures and not symbol_failures:
        print(f"  all {len(objects)} shared object(s) load-clean against GLIBC_{ceiling_str}")
        return 0

    if version_failures:
        print(
            f"\n{len(version_failures)} object(s) require a newer glibc than the image "
            f"ships (GLIBC_{ceiling_str}):",
            file=sys.stderr,
        )
        for path, needed in version_failures:
            print(f"  {path} needs GLIBC_{needed}", file=sys.stderr)

    if symbol_failures:
        print(
            f"\n{len(symbol_failures)} object(s) reference symbols nothing in the image "
            "defines:",
            file=sys.stderr,
        )
        for path, missing in symbol_failures:
            shown = ", ".join(missing[:8])
            more = f" (+{len(missing) - 8} more)" if len(missing) > 8 else ""
            print(f"  {path}: {shown}{more}", file=sys.stderr)

    print(
        "\nPostgres will fail to load these at startup. They were built against a "
        "different libc than the one they run on -- compile AND link them with "
        "--sysroot pointing at the extracted base rootfs.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
