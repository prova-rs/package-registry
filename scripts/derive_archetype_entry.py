#!/usr/bin/env python3
"""Derive an ARCHETYPE registry entry from an archetype checkout.

Sibling of derive_entry.py, and the same discipline: an entry is a PROJECTION of what the archetype
repo already declares, never hand-maintained metadata that can drift. Re-run registration and the
projection is rebuilt; identical inputs produce identical bytes, so a re-register with nothing new
commits nothing.

Archetypes live in `archetypes/` rather than alongside plugins in `registry/` because they are a
separate namespace with a different projection source (prova's docs/design/registry.md): an archetype
key and a plugin name never collide, and an archetype has no `[plugin]` manifest — its metadata comes
from `archetype.yaml`.

Two fields are DECLARED rather than derived, both under a `prova:` block in `archetype.yaml`:

  prova:
    init_key:   "project"    # the `prova init <key>` key
    in_package: "deny"       # deny | allow

`init_key` cannot be derived because prova resolves init keys THROUGH the registry rather than
inferring a repo name from them — that convention was removed on purpose so an archetype can live at
any host under any name. A repo with no `prova.init_key` is therefore not an archetype this registry
can serve, and registration skips it, exactly as it skips a repo with no `[plugin]` manifest.

`in_package` cannot be derived because only the archetype knows whether it creates a package or
augments an existing one.

Exits 2 (not 1) when the repo is simply not a registrable archetype, so a caller can distinguish
"skip this repo, that is normal" from "the derivation itself failed".
"""

import argparse
import pathlib
import re
import sys

try:
    import yaml  # PyYAML — present on GitHub runners; the reconcile workflow installs it explicitly.
except ModuleNotFoundError:  # pragma: no cover - environment problem, not an entry problem
    sys.exit("error: PyYAML is required to read archetype.yaml (pip install pyyaml)")

NOT_AN_ARCHETYPE = 2

# The key becomes a filename (`archetypes/<key>.toml`) and a CLI argument, so it must survive both.
KEY_RE = re.compile(r"^[a-z0-9][a-z0-9\-_]*$")
IN_PACKAGE_VALUES = ("deny", "allow")


def toml_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--archetype-dir", required=True, help="checkout of the archetype repo at --ref")
    p.add_argument("--repo", required=True, help="canonical https URL of the archetype repo")
    p.add_argument("--ref", required=True, help="released tag being registered; becomes `latest`")
    p.add_argument(
        "--description-fallback",
        default="",
        help="used when archetype.yaml carries no description (e.g. the GitHub repo description)",
    )
    p.add_argument("--out-dir", required=True, help="the archetypes/ directory to write into")
    a = p.parse_args()

    manifest = pathlib.Path(a.archetype_dir) / "archetype.yaml"
    if not manifest.is_file():
        # Not an archetype repo at all. The common case across an org, and not a problem.
        sys.exit(NOT_AN_ARCHETYPE)

    data = yaml.safe_load(manifest.read_text()) or {}
    if not isinstance(data, dict):
        sys.exit(f"error: {manifest} does not parse as a mapping")
    declared = data.get("prova") or {}
    if not isinstance(declared, dict):
        sys.exit(f"error: {manifest}: `prova:` must be a mapping")

    key = declared.get("init_key")
    if not key:
        # An archetype that has not opted in. Silent-skippable, but say why on stderr so a maintainer
        # who EXPECTED registration can find out in one look.
        print(
            f"skip: {manifest} declares no `prova.init_key` — not a registrable archetype",
            file=sys.stderr,
        )
        sys.exit(NOT_AN_ARCHETYPE)

    key = str(key)
    if not KEY_RE.match(key):
        sys.exit(
            f"error: prova.init_key {key!r} must be lowercase alphanumeric with - or _ "
            "(it becomes a filename and a CLI argument)"
        )

    in_package = str(declared.get("in_package", "deny"))
    if in_package not in IN_PACKAGE_VALUES:
        # Refuse rather than default: prova's resolver degrades an unknown value to "deny", so a typo
        # here would silently make an augmenting archetype refuse to render into a package.
        sys.exit(
            f"error: prova.in_package {in_package!r} must be one of {IN_PACKAGE_VALUES}"
        )

    description = str(data.get("description") or a.description_fallback or "")
    if not description:
        sys.exit(
            f"error: no description — neither `description` in {manifest} nor "
            "--description-fallback was given"
        )

    repo = a.repo.removesuffix(".git").rstrip("/")
    ref = a.ref.removeprefix("refs/tags/")

    out = pathlib.Path(a.out_dir) / f"{key}.toml"
    lines = [
        f"# archetypes/{key}.toml — derived from {repo}@{ref}; do not hand-edit (re-register instead)",
        "schema      = 1",
        f"name        = {toml_str(key)}",
        f"repo        = {toml_str(repo)}",
        f"description = {toml_str(description)}",
        f"latest      = {toml_str(ref)}",
        f"in_package  = {toml_str(in_package)}",
    ]
    out.write_text("\n".join(lines) + "\n")
    print(out)


if __name__ == "__main__":
    main()
