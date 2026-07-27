--- The registry proves itself (prova docs/design/registry.md, Automation): every entry parses,
--- required fields are present, names match filenames, repos are well-formed git sources, and
--- schemas are known. The serving check runs through the REAL consumer — `prova plugins`
--- pointed at this checkout as the sole configured registry — so the bar is exactly what the
--- binary serves, not a re-implementation of its parser.

local function entries(t)
  local out = shell.run("ls registry/*.toml", { check = true }).stdout
  local files = {}
  for f in out:gmatch("[^\n]+") do files[#files + 1] = f end
  t:expect(#files > 0, "registry/ has entries"):is_true()
  return files
end

prova.test("the real consumer serves every entry, warning-free", function(t)
  local root = shell.run("pwd", { check = true }).stdout:gsub("%s+$", "")
  -- A config home whose [[registries]] entry REPLACES the built-in by name, so the only
  -- registry in play is this very checkout — offline, no cache, no network.
  local home = fs.tempdir()
  fs.write(home .. "/prova/config.toml",
    '[[registries]]\nname = "prova-rs"\nsource = "' .. root .. '"\n')
  local run = shell.run("prova plugins --offline", { env = { XDG_CONFIG_HOME = home } })
  t:expect(run.code):equals(0)
  -- Tolerance skips would keep siblings serving — but an entry WE ship must never need it.
  t:expect(run.stderr):never():contains("skipping entry")
  for _, f in ipairs(entries(t)) do
    local name = f:match("registry/(.+)%.toml")
    t:expect(run.stdout, f):contains(name)
  end
end)

prova.test("entries are self-consistent: filename = name, schema known, repo well-formed",
  function(t)
  for _, f in ipairs(entries(t)) do
    local stem = f:match("registry/(.+)%.toml")
    local text = fs.read(f)
    t:expect(text, f .. ": name matches filename"):contains('name         = "' .. stem .. '"')
    t:expect(text, f .. ": schema"):contains("schema       = 1")
    local repo = text:match('repo%s*=%s*"([^"]+)"')
    t:expect(repo ~= nil, f .. ": has repo"):is_true()
    t:expect(repo:match("^https://") ~= nil or repo:match("^git@") ~= nil,
      f .. ": repo is a git source"):is_true()
    local description = text:match('description%s*=%s*"([^"]+)"')
    t:expect(description ~= nil and #description > 0, f .. ": has description"):is_true()
    local latest = text:match('latest%s*=%s*"([^"]+)"')
    t:expect(latest ~= nil, f .. ": has a recommended pin"):is_true()
  end
end)

-- ── archetypes/ — the `prova init` half of this registry ─────────────────────────────────────
--
-- Same bar as the plugin entries above, and the same reason: an entry this registry ships must never
-- need the consumer's tolerance path. A skipped entry keeps its siblings serving, which is correct
-- behaviour for someone ELSE's registry and a red proof for ours.
--
-- Entries here are derived by scripts/derive_archetype_entry.py from each archetype's `archetype.yaml`
-- (`prova:` block for the key and in_package; description and repo from the repo itself). Never
-- hand-edited — re-register instead.

-- Deliberately tolerant of an empty/absent `archetypes/`: the two validation proofs below gate
-- whatever is present (a third-party PR adding an entry is checked the moment it lands), while the
-- fact that OUR archetypes are not registered yet is tracked as the open spec at the end of this
-- section rather than hidden inside a loop that silently runs zero times.
local function archetype_entries()
  local files = fs.glob(".", "archetypes/*.toml")
  table.sort(files)
  return files
end

prova.test("archetype entries are self-consistent: filename = name, schema known, repo well-formed",
  function(t)
  for _, f in ipairs(archetype_entries()) do
    local stem = f:match("archetypes/(.+)%.toml") or f:match("([^/]+)%.toml")
    local doc = toml.decode(fs.read(f))

    t:expect(doc.name, f .. ": name must match the filename"):equals(stem)
    t:expect(doc.schema, f .. ": schema"):equals(1)

    -- The key is a filename AND a `prova init <key>` argument — it has to survive both.
    t:expect(stem:match("^[a-z0-9][a-z0-9%-_]*$") ~= nil,
      f .. ": key must be lowercase alphanumeric with - or _"):is_true()

    local repo = tostring(doc.repo or "")
    t:expect(repo:match("^https://") ~= nil or repo:match("^git@") ~= nil,
      f .. ": repo must be a git source, got " .. repo):is_true()

    t:expect(#tostring(doc.description or "") > 0, f .. ": needs a description"):is_true()

    -- `latest` is the ref `prova init` renders. Absent means the default branch, which makes
    -- scaffolding drift when that branch moves — not something this registry should ever ship.
    t:expect(doc.latest ~= nil, f .. ": needs a recommended pin"):is_true()

    -- in_package is optional (absent means deny), but a typo must not silently become deny: prova's
    -- resolver degrades an unknown value, so the check has to live here.
    if doc.in_package ~= nil then
      local ok = doc.in_package == "deny" or doc.in_package == "allow"
      t:expect(ok, f .. ": in_package must be \"deny\" or \"allow\", got "
        .. tostring(doc.in_package)):is_true()
    end
  end
end)

prova.test("the real consumer resolves and would render every archetype entry", function(t)
  -- Through the REAL consumer, like the plugin check above: point prova at this checkout as its sole
  -- registry and ask it to resolve each key. `--list` deliberately shows only the catalog, so the
  -- lookup is exercised by naming the key — which is also the code path a user takes.
  local root = shell.run("pwd", { check = true }).stdout:gsub("%s+$", "")
  local home = fs.tempdir()
  fs.write(home .. "/prova/config.toml",
    '[[registries]]\nname = "prova-rs"\nsource = "' .. root .. '"\n')

  for _, f in ipairs(archetype_entries()) do
    local key = f:match("archetypes/(.+)%.toml") or f:match("([^/]+)%.toml")
    -- `--list` after the key would be ambiguous; instead ask for a render into a throwaway dir with a
    -- source we know cannot be fetched offline. What is under proof is that prova RESOLVES the key —
    -- it must never fail with "unknown init key", which is what a malformed entry would produce.
    local dest = fs.tempdir()
    local r = shell.run("prova init " .. key .. " --headless 2>&1",
      { cwd = dest, env = { XDG_CONFIG_HOME = home } })
    t:expect(r.stdout, f .. ": prova must not reject the key"):never():contains("unknown init key")
    t:expect(r.stdout, f .. ": entry must not be skipped by tolerance")
      :never():contains("skipping archetype")
  end
end)

-- `prova init project` / `prova init plugin` work from prova's built-in catalog, which carries
-- explicit pinned URLs — but that alone does not make them *discoverable*: a user browsing this
-- registry has to find them here. Registration is automated and derives from the archetype's
-- `archetype.yaml` at the RELEASED tag, so an entry exists exactly when a release carrying a
-- `prova:` block does.
--
-- This graduated from a spec at the archetypes' v1.1 release, the first to ship that block. It is
-- now a standing guardrail: if either entry disappears — a botched reconcile, a dropped `prova:`
-- block, a repo rename — the org's own archetypes have silently stopped being discoverable, and
-- this goes red instead of nobody noticing.
prova.test("this registry serves the org's own archetypes",
  { proves = "the org's archetypes stay registered — discoverability is not a manual step" },
  function(t)
  local files = archetype_entries()
  t:expect(#files > 0, "archetypes/ must serve at least one entry"):is_true()

  -- The two prova ships built-in are the ones whose absence is a discoverability gap.
  local keys = {}
  for _, f in ipairs(files) do
    keys[(f:match("archetypes/(.+)%.toml") or f:match("([^/]+)%.toml"))] = true
  end
  t:expect(keys["project"] == true, "project must be discoverable here"):is_true()
  t:expect(keys["plugin"] == true, "plugin must be discoverable here"):is_true()
end)

prova.test("info serves full detail for a spot-checked entry", function(t)
  local root = shell.run("pwd", { check = true }).stdout:gsub("%s+$", "")
  local home = fs.tempdir()
  fs.write(home .. "/prova/config.toml",
    '[[registries]]\nname = "prova-rs"\nsource = "' .. root .. '"\n')
  local first = entries(t)[1]:match("registry/(.+)%.toml")
  local r = shell.run("prova plugins info " .. first, { env = { XDG_CONFIG_HOME = home } })
  t:expect(r.code):equals(0)
  t:expect(r.stdout):contains("repo:")
  t:expect(r.stdout):contains("latest:")
end)
