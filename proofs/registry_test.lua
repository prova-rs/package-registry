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
