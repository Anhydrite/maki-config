-- /relance — auto-relaunch driven by the project's suivi.md.
--
-- The file is the arbiter: a `REQ-YYYYMMDD-NN` row is finished when its state
-- cell starts with "fait" (which covers "fait, publié" and "fait, à publier"),
-- and a checkbox case is finished when it is `[x]`. Everything else is work
-- left on the table, so the plugin wakes the session again after each turn
-- until nothing is left.
--
-- Why the file and not the transcript: the agent cannot quietly decide it is
-- done. The ledger already carries the truth, and the turn that updates it is
-- the same turn that claims the work.
--
-- Guards, in the order they stop the loop:
--   1. no unfinished task left                      -> done
--   2. turn cancelled (Esc), or ended in an error   -> stopped
--   3. two relaunches without the ledger moving     -> stopped, and named
--   4. the iteration cap                            -> stopped
-- The user keeps the floor: a queued prompt, a running turn, or text in the
-- input bar never gets a wake on top of it.

local MAX_STRIKES = 2
local DEFAULT_MAX = 15

-- A state cell that begins with one of these is a finished line. Prefix
-- matching on purpose: "fait, publié", "terminé", "livré", "soldé" all pass,
-- and accents never enter the comparison.
local DONE_STEMS = { "fait", "termin", "livr", "publi", "sold", "done", "ok" }

local CANDIDATES = {
  "suivi.md",
  "SUIVI.md",
  "Suivi.md",
  "docs/design/SUIVI.md",
  "docs/design/suivi.md",
  "docs/SUIVI.md",
  "docs/suivi.md",
}

local log = maki.log

-- session id -> state table
local sessions = {}

local function debug(msg)
  log.debug("relance: " .. msg)
end

local function is_done(state)
  local s = (state or ""):lower()
  s = s:gsub("^%**", ""):gsub("^%s+", "")
  if s == "" then
    return false
  end
  for _, stem in ipairs(DONE_STEMS) do
    if s:sub(1, #stem) == stem then
      return true
    end
  end
  return false
end

-- Split a markdown table row into cells, dropping the outer pipes.
local function cells_of(line)
  local s = line
  if s:sub(1, 1) == "|" then
    s = s:sub(2)
  end
  if s:sub(-1) == "|" then
    s = s:sub(1, -2)
  end
  local out = {}
  for cell in (s .. "|"):gmatch("([^|]*)|") do
    out[#out + 1] = cell
  end
  return out
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Read the ledger: returns total, finished, and the list of unfinished items.
-- Two shapes are understood in the same pass, because a project may carry both:
--   | REQ-20261025-27 | demande | en attente | preuve |
--   - [ ] something
local function parse(text)
  local total, done, unfinished = 0, 0, {}
  local lineno = 0

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    local stripped = trim(line)

    local id = stripped:match("^|%s*(REQ%-%d%d%d%d%d%d%d%d%-%d+)")
    if id then
      local cells = cells_of(stripped)
      local state = trim(cells[3] or "")
      total = total + 1
      if is_done(state) then
        done = done + 1
      else
        unfinished[#unfinished + 1] = {
          id = id,
          state = state,
          line = lineno,
          demand = trim(cells[2] or ""),
        }
      end
    elseif stripped:find("^|") then
      -- any other table row: not a task, do not count it
    else
      local box = stripped:match("^[-*+]%s+%[(.)%]%s*(.+)$")
      if box then
        if box == "x" or box == "X" then
          total = total + 1
          done = done + 1
        elseif box == " " or box == "" then
          total = total + 1
          unfinished[#unfinished + 1] = {
            id = "#" .. lineno,
            state = "à faire",
            line = lineno,
            demand = trim((stripped:gsub("^[-*+]%s+%[.%]%s*", ""))),
          }
        end
      end
    end
  end

  return total, done, unfinished
end

-- Cheap change detector: the counts plus a byte checksum of the whole file.
-- Counts alone would miss a line rewritten in place; the checksum alone would
-- fire on every proof appended. Both together are what "the ledger moved" means.
local function signature(text, total, done)
  local sum = 0
  for i = 1, #text, 97 do
    sum = (sum * 31 + text:byte(i)) % 2147483647
  end
  return string.format("%d/%d/%d/%d", total, done, sum, #text)
end

local function state_for(session_id)
  local st = sessions[session_id]
  if not st then
    st = {
      armed = false,
      runs = 0,
      strikes = 0,
      last_sig = nil,
      path = nil,
      max = DEFAULT_MAX,
    }
    sessions[session_id] = st
  end
  return st
end

local function find_ledger(cwd, wanted)
  if wanted and wanted ~= "" then
    local path = wanted
    if path:sub(1, 1) ~= "/" and cwd then
      path = maki.fs.joinpath(cwd, path)
    end
    local text = maki.fs.read(path)
    if text then
      return path, text
    end
    return nil, nil
  end

  local dir, seen = cwd, {}
  while dir and not seen[dir] do
    seen[dir] = true
    for _, name in ipairs(CANDIDATES) do
      local candidate = maki.fs.joinpath(dir, name)
      local text = maki.fs.read(candidate)
      if text then
        return candidate, text
      end
    end
    local parent = maki.fs.dirname(dir)
    if not parent or parent == dir or parent == "" or parent == "." then
      break
    end
    dir = parent
  end
  return nil, nil
end

local function rel(path)
  local cwd = maki.uv.cwd()
  if cwd and path:sub(1, #cwd + 1) == cwd .. "/" then
    return path:sub(#cwd + 2)
  end
  return path
end

local function stop(session_id, reason, notify)
  local st = sessions[session_id]
  if st then
    st.armed = false
    st.last_sig = nil
  end
  log.info("relance: stopped for " .. session_id .. ": " .. reason)
  if notify then
    maki.ui.flash("Relance : " .. reason)
  end
end

local function resume_note(st, path, total, done, unfinished)
  local ids, extra = {}, #unfinished - 6
  for i = 1, math.min(#unfinished, 6) do
    ids[#ids + 1] = unfinished[i].id
  end
  local list = table.concat(ids, ", ")
  if extra > 0 then
    list = list .. string.format(" (+%d autres)", extra)
  end

  return string.format(
    "[relance %d/%d] %s porte encore %d tâche(s) non finie(s) sur %d : %s. "
      .. "Prends la PREMIÈRE de ces lignes, traite-la entièrement (code, test rouge→vert, doc, preuve), "
      .. "puis mets sa ligne à jour dans le même geste. "
      .. "Une seule tâche par relance. "
      .. "Respecte l'AGENTS.md du projet (boucle T0/T1, pas de suite complète hors commit). "
      .. "Ne commite, ne pousse et ne déploie pas. "
      .. "Si la tâche exige une décision du propriétaire ou une action destructive, laisse-la en attente "
      .. "avec la raison écrite et prends la suivante.",
    st.runs + 1,
    st.max,
    rel(path),
    #unfinished,
    total,
    list
  )
end

-- Decide, then wake. `kick` is true when the user just ran /relance and the
-- session is sitting idle, so the first run does not wait for a human turn.
local function step(session_id, kick, reason_from_turn)
  local st = state_for(session_id)
  if not st.armed then
    return
  end

  if reason_from_turn then
    if reason_from_turn == "cancelled" then
      return stop(session_id, "tour interrompu (Esc)", true)
    end
    if reason_from_turn ~= "finished" and reason_from_turn ~= "max_turns" then
      return stop(session_id, "tour clos par " .. reason_from_turn, true)
    end
  end

  if st.runs >= st.max then
    return stop(session_id, string.format("plafond de %d relances atteint", st.max), true)
  end

  local snapshot, err = maki.session.read({ session = session_id })
  if not snapshot then
    return stop(session_id, "session illisible : " .. tostring(err), true)
  end

  local cwd = snapshot.cwd or maki.uv.cwd()
  local path, text = find_ledger(cwd, st.path)
  if not path then
    return stop(session_id, "aucun suivi.md trouvé depuis " .. rel(cwd or "?"), true)
  end

  local total, done, unfinished = parse(text)
  local sig = signature(text, total, done)

  if #unfinished == 0 then
    return stop(session_id, string.format("terminé, %d/%d lignes finies dans %s", done, total, rel(path)), true)
  end

  -- Progress check, skipped on the very first run: arming is not a relaunch.
  if st.last_sig and not kick then
    if st.last_sig == sig then
      st.strikes = st.strikes + 1
      log.warn(string.format(
        "relance: no progress for %s (%d/%d), strike %d",
        session_id, done, total, st.strikes
      ))
      if st.strikes >= MAX_STRIKES then
        return stop(
          session_id,
          string.format("%d relances sans progrès (%d tâche(s) restante(s))", st.strikes, #unfinished),
          true
        )
      end
    else
      st.strikes = 0
    end
  end

  -- Never take the floor from the user: an in-flight run, a queued prompt, or
  -- text being typed will get to the ledger on its own.
  local queued = (snapshot.queue and snapshot.queue.count) or 0
  local composing = false
  local input = maki.ui.input()
  if input and input.session_id == session_id and (input.text or "") ~= "" then
    composing = true
  end
  if not kick and (snapshot.status == "working" or queued > 0 or composing) then
    debug("left for the next run: status " .. tostring(snapshot.status))
    return
  end

  local text_note = resume_note(st, path, total, done, unfinished)

  st.runs = st.runs + 1
  st.last_sig = sig
  st.path = path

  local sent, send_err = maki.session.prompt(text_note, { session = session_id })
  if not sent then
    st.runs = st.runs - 1
    return stop(session_id, "prompt refusé : " .. tostring(send_err), true)
  end

  log.info(string.format(
    "relance: run %d/%d for %s (%d unfinished, %d/%d done) %s",
    st.runs, st.max, session_id, #unfinished, done, total, sent
  ))
end

local function status_line(session_id)
  local st = sessions[session_id]
  if not st or not st.armed then
    return "Relance : arrêtée."
  end
  local snapshot = maki.session.read({ session = session_id })
  local cwd = (snapshot and snapshot.cwd) or maki.uv.cwd()
  local path, text = find_ledger(cwd, st.path)
  if not path then
    return "Relance : active, mais aucun suivi.md trouvé."
  end
  local total, done, unfinished = parse(text)
  return string.format(
    "Relance : active sur %s — %d non finie(s) / %d, %d/%d relances, %d strike(s).",
    rel(path), #unfinished, total, st.runs, st.max, st.strikes
  )
end

local function current_session()
  local id = maki.session.current()
  if not id then
    maki.ui.flash("Relance : aucune session active")
  end
  return id
end

maki.api.register_command({
  name = "/relance",
  description = "Auto-relance l'agent tant que suivi.md garde des tâches non finies (/relance off, /relance 20, /relance <chemin>)",
  nargs = "*",
  handler = function(opts)
    local id = current_session()
    if not id then
      return
    end
    local st = state_for(id)
    local arg = trim(opts.args or "")
    local lower = arg:lower()

    if lower == "off" or lower == "stop" or lower == "arrêt" or lower == "arret" or lower == "0" then
      if not st.armed then
        maki.ui.flash("Relance : déjà arrêtée")
        return
      end
      stop(id, "arrêt demandé", true)
      return
    end

    if lower == "status" or lower == "etat" or lower == "état" then
      maki.ui.flash(status_line(id))
      return
    end

    -- Bare /relance toggles: a second one is the natural way to say stop.
    if lower == "on" or lower == "start" or lower == "go" then
      st.armed = false
      arg = ""
    end

    if arg == "" and st.armed then
      stop(id, "arrêt demandé", true)
      return
    end

    if arg ~= "" then
      local n = tonumber(arg)
      if n then
        st.max = math.floor(n)
        if st.max < 1 then
          st.max = DEFAULT_MAX
        end
      else
        st.path = arg
      end
    end

    st.armed = true
    st.runs = 0
    st.strikes = 0
    st.last_sig = nil

    local snapshot = maki.session.read({ session = id })
    local cwd = (snapshot and snapshot.cwd) or maki.uv.cwd()
    local path, text = find_ledger(cwd, st.path)
    if not path then
      st.armed = false
      maki.ui.flash("Relance : aucun suivi.md trouvé depuis " .. rel(cwd or "?"))
      return
    end
    local total, done, unfinished = parse(text)
    maki.ui.flash(string.format(
      "Relance armée : %s, %d non finie(s) / %d, plafond %d.",
      rel(path), #unfinished, total, st.max
    ))
    log.info(string.format("relance: armed for %s on %s (%d/%d done)", id, path, done, total))

    if #unfinished == 0 then
      stop(id, "rien à faire, toutes les lignes sont finies", true)
      return
    end

    step(id, true, nil)
  end,
})

maki.api.create_autocmd("TurnEnd", {
  callback = function(ev)
    local id = ev.data and ev.data.session_id
    if not id then
      return
    end
    -- Let the turn finish tearing down before posting the next one: a prompt
    -- sent in the same tick races the history write it just ended.
    local reason = ev.data.reason
    maki.defer_fn(function()
      step(id, false, reason)
    end, 300)
  end,
})

maki.api.create_autocmd("SessionEnd", {
  callback = function(ev)
    local id = ev.data and ev.data.session_id
    if id then
      sessions[id] = nil
    end
  end,
})


-- Kept for the day a spec runner exists: the parser is pure.
return { parse = parse, is_done = is_done }
