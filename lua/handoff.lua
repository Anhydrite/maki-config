-- /handoff — one feature at a time, validated by the human.
--
-- Maki 0.7.0 only knows the build and plan modes, so this mode is emulated:
-- a prompt hint carries the workflow, a status hint makes it visible, and a
-- bash input layer is the real guard. The layer also lets one blocked command
-- through after `/handoff allow-tests`, then re-arms.
--
-- The rule the whole mode rests on: the agent does the change the user asked
-- for, runs only the test that change touches, and ends by handing the
-- validation back instead of claiming the suite is green.

local log = maki.log

-- Process-wide: the prompt hint callback gets no session context, and the mode
-- is meant to be shared by every tab of this Maki process.
local state = { on = false, allow_next = false }

local STATE_FILE = "handoff.json"

local DENY_REASON = table.concat({
  "Handoff mode: the full test suite is out of scope here. Run only the test you",
  "wrote or adapted (`pytest path/to/test_file.py::test_name`), or ask the human",
  "to unlock a broader run with `/handoff allow-tests`. Then end with the",
  '"À valider" block.',
}, "\n")

local PROMPT_BLOCK = [=[
## Handoff mode (human-validated, one feature at a time)

Handoff mode is ON. Do exactly the change the user asked for, do it well, and
let the human validate it. This block overrides the project's test-first and
full-CI workflow for this session. If plan mode is active, ignore this block:
plan mode wins.

- One feature, one request at a time. Do not batch unrelated changes, do not
  start a second feature in the same turn, and do not refactor beyond what the
  change needs. A small, complete diff beats a broad one.
- Skip the planning phase and extra exploration: read only what the change
  needs, then implement.
- Update the tests the change touches. Run only the specific test(s) you wrote
  or adapted: one file, a `::nodeid`, or a `-k` filter on a named file. Never
  run the full suite, bare `make`, `make test`, `make all`, `make test-cover`,
  `make test-gate`, or any whole-project test command.
- Self-validation is read-only plus lint/format: re-read the diff, check
  imports and every call site, run `make format` / `make lint` (or the project
  formatter and linter). Do not launch builds, full CI, or anything that runs
  the suite.
- Still follow the project's non-test conventions (CHANGELOG, docs, playbooks)
  unless the user says otherwise.
- Never claim the tests pass, the suite is green, or the feature is validated.
  Say exactly what you ran and what you did not run.
- When the feature is done, end with a short "À valider" block: files changed,
  the exact targeted test commands you ran, the commands the human must run
  (full suite / `make`), what to check manually, and the risks or edge cases.
- Do not commit or push unless the human asks. Auto-relaunch is not part of
  this mode: `/relance` is a separate, explicit decision. Stay in handoff
  mode until the human runs `/handoff off`.
]=]

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function state_path()
  local dir = maki.env.state_dir()
  if not dir then
    return nil
  end
  return maki.fs.joinpath(dir, STATE_FILE)
end

local function save()
  local path = state_path()
  if not path then
    log.warn("handoff: cannot resolve the state dir, keeping state in memory")
    return
  end
  local ok, err = maki.fs.atomic_write(path, string.format('{"on":%s}\n', state.on and "true" or "false"))
  if not ok then
    log.warn("handoff: could not write " .. path .. ": " .. tostring(err))
  end
end

local function looks_missing(err)
  local e = (err or ""):lower()
  return e:find("no such file", 1, true) ~= nil or e:find("not found", 1, true) ~= nil
end

local function load()
  local path = state_path()
  if not path then
    log.warn("handoff: cannot resolve the state dir, starting disabled")
    return
  end
  local text, err = maki.fs.read(path)
  if text then
    state.on = text:match('"on"%s*:%s*true') ~= nil
    return
  end
  if err and not looks_missing(err) then
    log.warn("handoff: could not read " .. path .. ": " .. tostring(err))
  end
end

-- ---------------------------------------------------------------------------
-- Status indicator
-- ---------------------------------------------------------------------------

local function render_status()
  if not state.on then
    -- Only this plugin's hints are removed: other plugins keep theirs.
    maki.ui.set_status_hint(nil)
  elseif state.allow_next then
    maki.ui.set_status_hint({ { "handoff", "tests débloqués (1)" } })
  else
    maki.ui.set_status_hint({ { "handoff", "actif" } })
  end
end

-- ---------------------------------------------------------------------------
-- Command classifier (pure, no I/O)
--
-- One `allow`/`deny` per shell segment. The deny cases are the whole-project
-- runs; everything else, including unknown tools, is allowed, so a missed
-- command costs nothing but a human unlock costs one command.
-- ---------------------------------------------------------------------------

local function basename(token)
  local base = token:match("([^/\\]+)$")
  return base or token
end

local function is_assignment(token)
  return token:match("^[A-Za-z_][A-Za-z0-9_]*=") ~= nil
end

-- Split on shell separators outside quotes: `;`, `&&`, `||`, `|`, newlines.
local function split_top(text)
  local parts, buf = {}, {}
  local i, n = 1, #text
  local quote

  local function flush()
    parts[#parts + 1] = table.concat(buf)
    buf = {}
  end

  while i <= n do
    local c = text:sub(i, i)
    if quote then
      buf[#buf + 1] = c
      if c == quote then
        quote = nil
        i = i + 1
      elseif c == "\\" and quote == '"' and i < n then
        buf[#buf + 1] = text:sub(i + 1, i + 1)
        i = i + 2
      else
        i = i + 1
      end
    elseif c == '"' or c == "'" then
      quote = c
      buf[#buf + 1] = c
      i = i + 1
    else
      local two = text:sub(i, i + 1)
      if two == "&&" or two == "||" then
        flush()
        i = i + 2
      elseif c == ";" or c == "|" or c == "&" or c == "\n" then
        flush()
        i = i + 1
      else
        buf[#buf + 1] = c
        i = i + 1
      end
    end
  end
  flush()
  return parts
end

-- Split on parentheses outside quotes, so `$(pytest ...)` is seen as a run.
local function split_parens(text)
  local parts, buf = {}, {}
  local i, n = 1, #text
  local quote

  local function flush()
    parts[#parts + 1] = table.concat(buf)
    buf = {}
  end

  while i <= n do
    local c = text:sub(i, i)
    if quote then
      buf[#buf + 1] = c
      if c == quote then
        quote = nil
        i = i + 1
      elseif c == "\\" and quote == '"' and i < n then
        buf[#buf + 1] = text:sub(i + 1, i + 1)
        i = i + 2
      else
        i = i + 1
      end
    elseif c == '"' or c == "'" then
      quote = c
      buf[#buf + 1] = c
      i = i + 1
    elseif c == "(" or c == ")" then
      flush()
      i = i + 1
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  flush()
  return parts
end

-- Quote-aware whitespace split. Quotes are removed from the token, which is
-- what the classifier wants: `bash -c "pytest ..."` yields the payload text.
local function tokenize(text)
  local tokens, cur = {}, {}
  local i, n = 1, #text
  local quote

  local function flush()
    if #cur > 0 then
      tokens[#tokens + 1] = table.concat(cur)
      cur = {}
    end
  end

  while i <= n do
    local c = text:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
        i = i + 1
      elseif c == "\\" and quote == '"' and i < n then
        cur[#cur + 1] = text:sub(i + 1, i + 1)
        i = i + 2
      else
        cur[#cur + 1] = c
        i = i + 1
      end
    elseif c == '"' or c == "'" then
      quote = c
      i = i + 1
    elseif c:match("%s") then
      flush()
      i = i + 1
    else
      cur[#cur + 1] = c
      i = i + 1
    end
  end
  flush()
  return tokens
end

-- Wrappers that precede the real command, and the options that take a value.
local WRAPPERS = {
  sudo = {
    values = {
      ["-u"] = true,
      ["-g"] = true,
      ["-p"] = true,
      ["-C"] = true,
      ["-h"] = true,
      ["-r"] = true,
      ["-t"] = true,
      ["-U"] = true,
      ["-T"] = true,
    },
  },
  env = { values = { ["-u"] = true, ["-C"] = true, ["-S"] = true, ["-P"] = true } },
  time = { values = { ["-f"] = true, ["-o"] = true, ["--format"] = true, ["--output"] = true } },
  command = { values = {} },
  exec = { values = { ["-a"] = true } },
  nohup = { values = {} },
  busybox = { values = {} },
  -- R2 (audit du 2026-11-11) : ces enveloppes étaient INCONNUES, donc le mot de
  -- commande restait `timeout`/`nice`/… et la vraie commande n'était jamais
  -- jugée. Mesure : `timeout 300 bash tests/run-impacted.sh` passait, et
  -- `nice -n 5 tox` aussi.
  timeout = {
    values = { ["-s"] = true, ["-k"] = true, ["--signal"] = true, ["--kill-after"] = true },
    positionals = 1, -- la DURÉE précède la commande
  },
  nice = { values = { ["-n"] = true, ["--adjustment"] = true } },
  stdbuf = { values = { ["-i"] = true, ["-o"] = true, ["-e"] = true } },
  flock = { values = { ["-w"] = true, ["-E"] = true, ["-o"] = true }, positionals = 1 },
  setsid = { values = {} },
  watch = { values = { ["-n"] = true, ["--interval"] = true, ["-d"] = true } },
  xargs = {
    values = {
      ["-I"] = true, ["-n"] = true, ["-P"] = true, ["-d"] = true,
      ["-L"] = true, ["-s"] = true, ["-E"] = true, ["-a"] = true,
    },
  },
}

local function strip_prefixes(tokens)
  local i = 1
  while i <= #tokens do
    local token = tokens[i]
    if is_assignment(token) or token == "!" then
      i = i + 1
    else
      local name = basename(token)
      local wrapper = WRAPPERS[name]
      if not wrapper then
        break
      end
      i = i + 1
      while i <= #tokens do
        local option = tokens[i]
        if option == "--" then
          i = i + 1
          break
        end
        if option:sub(1, 1) ~= "-" then
          break
        end
        if wrapper.values[option] then
          i = i + 2
        else
          i = i + 1
        end
      end
      -- R2 : `timeout 300 cmd` et `flock /tmp/l cmd` portent un argument de
      -- POSITION avant la commande. Sans ce saut, le mot de commande devenait
      -- `300` (inconnu, donc autorisé) et la vraie commande n'était jamais vue.
      for _ = 1, (wrapper.positionals or 0) do
        if i <= #tokens and tokens[i]:sub(1, 1) ~= "-" then
          i = i + 1
        end
      end
    end
  end

  local out = {}
  for j = i, #tokens do
    out[#out + 1] = tokens[j]
  end
  return out
end

local function tail(tokens, from)
  local out = {}
  for i = from, #tokens do
    out[#out + 1] = tokens[i]
  end
  return out
end

local function mentions_test_runner(text)
  local lower = (text or ""):lower()
  return lower:find("pytest", 1, true) ~= nil
    or lower:find("unittest", 1, true) ~= nil
    or lower:find("tox", 1, true) ~= nil
    or lower:find("nose", 1, true) ~= nil
end

-- pytest: a file or a node id names a test; nothing else does.
local function pytest_verdict(args)
  for _, arg in ipairs(args) do
    if arg == "--version" or arg == "-V" or arg == "--help" or arg == "-h" then
      return "allow"
    end
  end
  for _, arg in ipairs(args) do
    if arg:sub(1, 1) ~= "-" and (arg:match("%.py$") or arg:find("::", 1, true)) then
      return "allow"
    end
  end
  return "deny", "pytest without a specific test file or node id"
end

local function python_verdict(args)
  for i = 1, #args do
    local arg = args[i]
    if arg == "-c" then
      if mentions_test_runner(args[i + 1]) then
        return "deny", "inline Python code runs the test suite"
      end
      return "allow"
    elseif arg == "-m" then
      local module = args[i + 1] or ""
      if module == "pytest" then
        return pytest_verdict(tail(args, i + 2))
      elseif module == "unittest" or module == "tox" or module == "nox" or module == "nose" then
        return "deny", "python -m " .. module .. " runs the test suite"
      end
      return "allow"
    elseif arg == "--" then
      return "allow"
    end
  end
  return "allow"
end

local MAKE_ALLOWED = { format = true, lint = true, _setup = true }
local MAKE_VALUE_OPTIONS = {
  ["-C"] = true,
  ["-f"] = true,
  ["-j"] = true,
  ["-l"] = true,
  ["-o"] = true,
  ["-W"] = true,
  ["-I"] = true,
  ["--file"] = true,
  ["--directory"] = true,
  ["--include-dir"] = true,
  ["--old-file"] = true,
  ["--what-if"] = true,
  ["--eval"] = true,
}

local function make_verdict(args)
  local targets, dry_run = {}, false
  local i = 1
  while i <= #args do
    local arg = args[i]
    if arg == "-n" or arg == "--dry-run" then
      dry_run = true
      i = i + 1
    elseif arg == "--version" or arg == "-v" or arg == "--help" or arg == "-h" then
      return "allow"
    elseif arg:sub(1, 1) == "-" then
      if MAKE_VALUE_OPTIONS[arg] then
        i = i + 2
      elseif arg:match("^%-%-[%w%-]+=") then
        i = i + 1
      else
        i = i + 1
      end
    else
      targets[#targets + 1] = arg
      i = i + 1
    end
  end

  if #targets == 0 then
    if dry_run then
      return "allow"
    end
    return "deny", "bare make runs the whole project"
  end
  for _, target in ipairs(targets) do
    if not MAKE_ALLOWED[target] then
      return "deny", "make target '" .. target .. "' is out of scope"
    end
  end
  return "allow"
end

local function looks_like_path(arg)
  if arg:find("/", 1, true) or arg:find("\\", 1, true) then
    return true
  end
  return arg:match("%.([Pp][Yy]|[Rr][Bb]|[Pp][Hh][Pp]|js|jsx|ts|tsx|mjs|cjs)$") ~= nil
end

local NODE_RUNNERS = { npm = true, yarn = true, pnpm = true, bun = true }

local function node_verdict(name, args)
  local first = (args[1] or ""):lower()
  if first == "test" or first == "t" then
    -- R8 (audit du 2026-11-11) : `bun test src/f.test.jsx` est le T0
    -- d'AGENTS.md. Le refuser poussait à contourner le garde ; `bun test` nu et
    -- `bun test src/` (un dossier) restent refusés.
    if name == "bun" then
      for i = 2, #args do
        local arg = args[i]
        if arg:sub(1, 1) ~= "-" and arg:sub(-1) ~= "/" and looks_like_path(arg) then
          return "allow"
        end
      end
    end
    return "deny", name .. " test runs the whole suite"
  end
  if first == "run" or first == "run-script" then
    for i = 2, #args do
      local arg = args[i]
      if arg:sub(1, 1) ~= "-" then
        if arg:lower():match("^test") then
          return "deny", name .. " run " .. arg .. " is a test script"
        end
        break
      end
    end
  end
  return "allow"
end

local TEST_SUBCOMMANDS = {
  cargo = true,
  go = true,
  dotnet = true,
  mvn = true,
  mvnw = true,
  gradle = true,
  gradlew = true,
}

local ALWAYS_DENY = { tox = true, nox = true, nose = true, ctest = true }

local PATH_RUNNERS = { jest = true, vitest = true, mocha = true, rspec = true, phpunit = true }


local classify

-- R5 (audit du 2026-11-11, RÉVISÉ LE MÊME JOUR APRÈS MESURE) : `bash <script>`
-- exécute un FICHIER. Mesure d'origine : `timeout 300 bash` suivi du script de
-- suite impactée lançait la suite sans un mot.
--
-- POURQUOI LA RÈGLE N'EST PAS « ON LIT LE FICHIER ». Deux versions ont été
-- mesurées, toutes deux fausses :
--   1. `classify(contenu)` : `bash deploy-all.sh --sans-recu` — le chemin de
--      publication d'AGENTS.md, qui ne lance AUCUN test — rendait « the command
--      is built at run time and cannot be inspected », à cause des `$` de ses
--      commentaires et de ses affectations.
--   2. une recherche d'invocations hors commentaires : `deploy-all.sh` porte
--      `make verify-complet` dans SA BRANCHE `--check`, et `web/deploy.sh` porte
--      `make verify` derrière `ANHYWHERE_SKIP_VERIFY` — un fichier ne dit pas
--      quel chemin sera pris.
-- Un garde qui refuse la publication documentée pousse au contournement (c'est
-- la conclusion de l'audit). La règle retenue est donc celle qu'on peut mesurer :
--   - un script sous `tests/` ou `test/` est refusé : c'est là que vivent les suites ;
--   - `deploy-all.sh --check` est refusé : c'est la seule branche qui lance la
--     porte complète (`make verify-complet`) ;
--   - le reste est autorisé, et le journal dit que le script n'a pas été jugé.
local function classer_script(chemin, args, position)
  local normalise = "/" .. tostring(chemin or ""):gsub("\\", "/")
  if normalise:find("/tests/", 1, true) or normalise:find("/test/", 1, true) then
    return "deny", "the script " .. tostring(chemin) .. " lives under tests/ : that is where the suites are"
  end
  local base = normalise:match("([^/]+)$") or ""
  if base == "deploy-all.sh" then
    for i = (position or 1) + 1, #(args or {}) do
      if args[i] == "--check" then
        return "deny", "deploy-all.sh --check runs the full gate (make verify-complet)"
      end
    end
  end
  log.info("handoff: script not judged, allowed: " .. tostring(chemin))
  return "allow"
end

-- R7 : un `-run` qui CIBLE (motif non vide, ni `.` ni `.*`) est le T0
-- d'AGENTS.md. Tout le reste lance la suite et reste refusé.
local function cible_go(args)
  for i, arg in ipairs(args) do
    local motif = arg:match("^%-%-run=(.*)$") or arg:match("^%-run=(.*)$")
    if motif == nil and (arg == "-run" or arg == "--run") then
      motif = args[i + 1]
    end
    if motif ~= nil then
      if motif == "" or motif == "." or motif == ".*" then
        return false
      end
      return true
    end
  end
  return false
end

local function classify_segment(segment)
  segment = trim(segment)
  if segment == "" then
    return "allow"
  end

  -- Parentheses and command substitutions run their content: split them out
  -- before anything else, so `echo $(pytest ...)` cannot hide behind `echo`.
  local pieces = split_parens(segment)
  if #pieces > 1 then
    for _, piece in ipairs(pieces) do
      if trim(piece) ~= "" then
        local verdict, reason = classify_segment(piece)
        if verdict == "deny" then
          return verdict, reason
        end
      end
    end
    return "allow"
  end

  local tokens = tokenize(segment)
  if #tokens == 0 then
    return "allow"
  end

  local name = basename(tokens[1])
  if name == "command" and (tokens[2] == "-v" or tokens[2] == "-V") then
    return "allow"
  end

  tokens = strip_prefixes(tokens)
  if #tokens == 0 then
    return "allow"
  end

  name = basename(tokens[1])
  local args = tail(tokens, 2)

  -- R4 (audit du 2026-11-11) : une commande qui n'est pas NOMMÉE ne peut pas
  -- être jugée. Mesuré : `eval "tox --version"` et `CMD="tox --version"; $CMD`
  -- passaient tous les deux.
  if name == "eval" or name == "source" or name == "." then
    return classify(table.concat(args, " "))
  end
  if name:sub(1, 1) == "$" or name:sub(1, 1) == "`" then
    return "deny", "the command is built at run time and cannot be inspected"
  end

  -- R2 : `script -c "…"` porte une commande COMPLÈTE, comme `bash -c`.
  if name == "script" then
    for i, arg in ipairs(args) do
      if arg:sub(1, 1) == "-" and arg:find("c", 1, true) then
        local payload = args[i + 1]
        if payload then
          return classify(payload)
        end
      end
    end
    return "allow"
  end

  if name == "bash" or name == "sh" or name == "zsh" then
    for i, arg in ipairs(args) do
      if arg == "--" then
        break
      elseif arg:sub(1, 1) == "-" and arg:sub(1, 2) ~= "--" and arg:find("c", 1, true) then
        local payload = args[i + 1]
        if payload then
          return classify(payload)
        end
      elseif arg:sub(1, 1) ~= "-" then
        return classer_script(arg, args, i)
      end
    end
    return "allow"
  end

  if name:match("^python[%d%.]*$") or name == "py" then
    return python_verdict(args)
  end
  if name == "pytest" then
    return pytest_verdict(args)
  end
  if name == "make" then
    return make_verdict(args)
  end
  if NODE_RUNNERS[name] then
    return node_verdict(name, args)
  end
  if TEST_SUBCOMMANDS[name] then
    for _, arg in ipairs(args) do
      if arg:sub(1, 1) ~= "-" and arg:lower():match("^test") then
        -- R7 (audit du 2026-11-11) : `go test -run <motif>` EST le test ciblé
        -- que le mode demande. Un motif vide, `.` ou `.*` ne cible rien.
        if name == "go" and cible_go(args) then
          return "allow"
        end
        return "deny", name .. " " .. arg .. " runs the test suite"
      end
    end
    return "allow"
  end
  if ALWAYS_DENY[name] then
    return "deny", name .. " runs a whole-project test suite"
  end
  if PATH_RUNNERS[name] then
    for _, arg in ipairs(args) do
      if arg:sub(1, 1) ~= "-" and looks_like_path(arg) then
        return "allow"
      end
    end
    return "deny", name .. " needs an explicit test file or path"
  end

  return "allow"
end

classify = function(command)
  if type(command) ~= "string" or trim(command) == "" then
    return "allow"
  end
  for _, segment in ipairs(split_top(command)) do
    local verdict, reason = classify_segment(segment)
    if verdict == "deny" then
      return "deny", reason
    end
  end
  return "allow"
end

-- ---------------------------------------------------------------------------
-- Prompt hint
-- ---------------------------------------------------------------------------

maki.api.register_prompt_hint({
  slot = "after_instructions",
  prompt = "system",
  content = function()
    if not state.on then
      return ""
    end
    return "\n\n" .. PROMPT_BLOCK .. "\n"
  end,
})

-- ---------------------------------------------------------------------------
-- Guard: bash input layer
-- ---------------------------------------------------------------------------

-- R1 (audit du 2026-11-11) — LE MÊME GARDE POUR LES COMMANDES DE FOND.
--
-- `bg_run` est un OUTIL distinct (jobs.lua), donc le slot `tool.bash.input` ne
-- le voyait pas : `bg_run("bash tests/run-impacted.sh")` lançait la suite
-- complète sans un mot, et c'était le SEUL contournement mesuré en exécution.
-- `jobs.lua` appelle `gate()` avant de démarrer le travail.
local function gate(command)
  if not state.on then
    return nil
  end
  local verdict, reason = classify(command)
  if verdict ~= "deny" then
    return nil
  end
  if state.allow_next then
    state.allow_next = false
    render_status()
    log.info("handoff: unlocked one blocked background command: " .. tostring(command))
    return nil
  end
  log.warn("handoff: blocked (background): " .. tostring(command) .. " (" .. tostring(reason) .. ")")
  return DENY_REASON
end

maki.api.set_slot("tool.bash.input", function(prev, input, ctx)
  if not state.on then
    return prev(input, ctx)
  end
  local verdict, reason = classify(input and input.command)
  if verdict ~= "deny" then
    return prev(input, ctx)
  end
  if state.allow_next then
    state.allow_next = false
    render_status()
    log.info("handoff: unlocked one blocked command: " .. tostring(input.command))
    return prev(input, ctx)
  end
  log.warn("handoff: blocked: " .. tostring(input.command) .. " (" .. tostring(reason) .. ")")
  return nil, DENY_REASON
end)

-- ---------------------------------------------------------------------------
-- /handoff
-- ---------------------------------------------------------------------------

local function set_on(on)
  state.on = on
  if not on then
    state.allow_next = false
  end
  save()
  render_status()
end

local function status_line()
  if not state.on then
    return "Handoff : inactif."
  end
  local unlock = state.allow_next and "un déblocage de tests en attente (1 commande)"
    or "aucun déblocage en attente"
  return "Handoff : actif — implémentation rapide, tests ciblés seulement, validation humaine ; "
    .. unlock
    .. "."
end

local function flash_on()
  maki.ui.flash("Handoff activé : implémentation rapide, tests ciblés seulement, validation humaine.")
end

local function flash_off()
  maki.ui.flash("Handoff désactivé : validation et suite complète rendues à l'humain.")
end

local USAGE = "Handoff : /handoff [on|off|status|allow-tests|check <commande>]"

maki.api.register_command({
  name = "/handoff",
  description = "Mode handoff : une feature à la fois, tests ciblés seulement, validation humaine (/handoff on, off, status, allow-tests, check <cmd>)",
  nargs = "*",
  handler = function(opts)
    local arg = trim(opts.args or "")
    if arg == "" then
      if state.on then
        set_on(false)
        flash_off()
      else
        set_on(true)
        flash_on()
      end
      return
    end

    local word, rest = arg:match("^(%S+)%s*(.*)$")
    local lower = (word or ""):lower()

    if lower == "on" or lower == "start" or lower == "activer" then
      set_on(true)
      flash_on()
    elseif lower == "off" or lower == "stop" or lower == "arreter" or lower == "arrêter" or lower == "désactiver" or lower == "desactiver" then
      set_on(false)
      flash_off()
    elseif lower == "status" or lower == "etat" or lower == "état" then
      maki.ui.flash(status_line())
    elseif lower == "allow-tests" or lower == "allow" then
      if not state.on then
        maki.ui.flash("Handoff inactif : rien à débloquer (/handoff on pour activer).")
        return
      end
      state.allow_next = true
      render_status()
      maki.ui.flash("Handoff : prochaine commande de test autorisée.")
    elseif lower == "check" then
      if rest == "" then
        maki.ui.flash("Handoff check : donne une commande, ex. /handoff check make test")
        return
      end
      local verdict, reason = classify(rest)
      if verdict == "allow" then
        maki.ui.flash("Handoff check : AUTORISÉ — " .. rest)
      else
        maki.ui.flash("Handoff check : REFUSÉ (" .. tostring(reason) .. ") — " .. rest)
      end
    else
      maki.ui.flash(USAGE)
    end
  end,
})

-- UI calls fail while the plugin is loading, and `fs.read` may park, so the
-- load is deferred until the host is ready.
maki.defer_fn(function()
  load()
  render_status()
end, 0)

-- Kept for the day a spec runner exists: the classifier is pure.
return { classify = classify, gate = gate }
