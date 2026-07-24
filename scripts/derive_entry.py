#!/usr/bin/env python3
"""Derive a registry entry from a plugin checkout — the single source of derivation logic.

A registry entry is a PROJECTION of the plugin's own manifest (prova's docs/design/registry.md):
name, description, capabilities, and topologies come from the plugin's `[plugin]` section; the
recommended pin (`latest`) is the released ref being registered. Entries are never hand-edited —
re-run registration and the projection is rebuilt. Idempotent by construction: the same inputs
produce the same bytes, so a re-register with nothing new commits nothing.
"""

import argparse
import pathlib
import sys
import tomllib


def toml_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def toml_list(xs) -> str:
    return "[" + ", ".join(toml_str(str(x)) for x in xs) + "]"


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--plugin-dir", required=True, help="checkout of the plugin repo at --ref")
    p.add_argument("--repo", required=True, help="canonical https URL of the plugin repo")
    p.add_argument("--ref", required=True, help="released tag being registered; becomes `latest`")
    p.add_argument(
        "--description-fallback",
        default="",
        help="used when the manifest carries no [plugin] description (e.g. the GitHub repo description)",
    )
    p.add_argument("--out-dir", required=True, help="the registry/ directory to write into")
    a = p.parse_args()

    manifest = pathlib.Path(a.plugin_dir) / "prova.toml"
    data = tomllib.loads(manifest.read_text()) if manifest.is_file() else {}
    plugin = data.get("plugin", {})

    repo = a.repo.removesuffix(".git").rstrip("/")
    name = plugin.get("name") or repo.rsplit("/", 1)[-1].removeprefix("prova-")
    description = plugin.get("description") or a.description_fallback
    if not description:
        sys.exit(
            f"error: no description — neither [plugin] description in {manifest} "
            "nor --description-fallback was given"
        )

    ref = a.ref.removeprefix("refs/tags/")
    topologies = [t["name"] for t in plugin.get("topologies", [])]
    # Capability gates the plugin declares: an explicit `[plugin] requires` list if present,
    # unioned with what its advertised topologies require.
    requires = sorted(
        set(plugin.get("requires", []))
        | {r for t in plugin.get("topologies", []) for r in t.get("requires", [])}
    )
    # The search surface: an explicit `[plugin] capabilities` list, else the name itself.
    capabilities = plugin.get("capabilities") or [name]

    out = pathlib.Path(a.out_dir) / f"{name}.toml"
    lines = [
        f"# registry/{name}.toml — derived from {repo}@{ref}; do not hand-edit (re-register instead)",
        "schema       = 1",
        f"name         = {toml_str(name)}",
        f"repo         = {toml_str(repo)}",
        f"description  = {toml_str(description)}",
        f"capabilities = {toml_list(capabilities)}",
        f"latest       = {toml_str(ref)}",
        "",
        f"namespaces = {toml_list([name])}",
        f"topologies = {toml_list(topologies)}",
        f"requires   = {toml_list(requires)}",
    ]
    out.write_text("\n".join(lines) + "\n")
    print(out)


if __name__ == "__main__":
    main()
