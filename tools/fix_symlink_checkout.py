#!/usr/bin/env python3
"""Materialise git symlinks that Windows checked out as plain text files.

Why this exists
---------------
Several rexglue-sdk submodules track symlinks. Git on Windows only creates real
symlinks when `core.symlinks=true`, which needs Developer Mode or an elevated
shell; otherwise each symlink lands as a small text file whose contents are the
link target path. The compiler then sees a C file containing one relative path
and fails with "expected identifier or '('".

Two of the three affected submodules matter to the build:

  * thirdparty/libmspack - cabextract/mspack/*, used on EVERY platform for XEX
    LZX decompression. 15 symlinks. Breaks the build outright.
  * thirdparty/moltenvk  - needed for the macOS Vulkan stack. 10 symlinks,
    mostly directories.
  * thirdparty/o1heap    - one doc file. Harmless.

This script replaces each placeholder with a real copy of its target, which
works on every platform and survives being copied between machines by any
means (zip, rsync, cloud sync) - unlike a real symlink.

Idempotent. Entries that are already real symlinks, or already real content,
are left alone. Safe to re-run after a submodule update.

Usage:
    python tools/fix_symlink_checkout.py [--sdk third_party/rexglue-sdk] [--check]

    --check  report what would change and exit non-zero if anything would,
             without writing. Useful in CI.
"""

import argparse
import os
import shutil
import subprocess
import sys


def run(args, cwd):
    return subprocess.run(
        args, cwd=cwd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    ).stdout.decode("utf-8", "replace")


def submodule_paths(sdk):
    """Every submodule working-tree path, recursively, plus the SDK itself."""
    out = run(
        ["git", "submodule", "foreach", "--recursive", "--quiet", "echo $displaypath"],
        cwd=sdk,
    )
    paths = [os.path.join(sdk, p.strip()) for p in out.splitlines() if p.strip()]
    return [sdk] + paths


def symlink_entries(repo):
    """Paths git records as symlinks (mode 120000) in this repo."""
    out = run(["git", "ls-files", "-s"], cwd=repo)
    entries = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and parts[0] == "120000":
            entries.append(parts[3].strip())
    return entries


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sdk", default=os.path.join("third_party", "rexglue-sdk"))
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    sdk = os.path.abspath(args.sdk)
    if not os.path.isdir(os.path.join(sdk, ".git")) and not os.path.isfile(
        os.path.join(sdk, ".git")
    ):
        sys.exit("not a git checkout: %s" % sdk)

    fixed, already, missing, pending = 0, 0, [], []

    for repo in submodule_paths(sdk):
        for rel in symlink_entries(repo):
            path = os.path.join(repo, rel)

            # A real symlink (any platform that supports them): nothing to do.
            if os.path.islink(path):
                already += 1
                continue
            if not os.path.isfile(path):
                continue

            # A placeholder is tiny and holds exactly one path. Anything larger
            # is real content that someone already materialised - leave it.
            try:
                if os.path.getsize(path) > 4096:
                    already += 1
                    continue
                with open(path, "r", encoding="utf-8", errors="strict") as fh:
                    target_rel = fh.read().strip()
            except (OSError, UnicodeDecodeError):
                already += 1
                continue

            if not target_rel or "\n" in target_rel or "\x00" in target_rel:
                already += 1
                continue

            target = os.path.normpath(os.path.join(os.path.dirname(path), target_rel))
            if not os.path.exists(target):
                missing.append((os.path.relpath(path, sdk), target_rel))
                continue

            if args.check:
                pending.append(os.path.relpath(path, sdk))
                continue

            if os.path.isdir(target):
                os.remove(path)
                shutil.copytree(target, path, symlinks=False)
            else:
                shutil.copyfile(target, path)
            fixed += 1

    if args.check:
        for p in pending:
            print("would materialise: %s" % p)
        for p, t in missing:
            print("would skip (target absent): %s -> %s" % (p, t))
        print("\n%d to materialise, %d already fine, %d unresolvable"
              % (len(pending), already, len(missing)))
        return 1 if pending else 0

    print("materialised %d, already fine %d" % (fixed, already))
    if missing:
        print("\nskipped %d placeholder(s) whose target is absent:" % len(missing))
        for p, t in missing:
            print("  %s -> %s" % (p, t))
        print(
            "\nThese point into a nested submodule that is not checked out. They\n"
            "only matter if the build actually consumes them - MoltenVK's Demos\n"
            "and SPIRV tool directories, for instance, are not part of this build."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
