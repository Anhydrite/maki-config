-- Auto-compaction at a chosen share of the context window.
--
-- Maki compacts on its own only once the context reaches
-- context_window - agent.compaction_buffer, and that buffer is capped at 50%
-- of the window (MAX_RESERVED_PERCENT in maki-agent/src/agent/compaction.rs).
-- The earliest native trigger is therefore half the window. This plugin
-- lowers it, the way pi-auto-compact does on pi: it watches the context size
-- and asks the built-in /compact command to summarize once the configured
-- share is reached.
--
-- Where it checks:
--   TurnEnd               end of a run, so the next prompt starts lean
--   SessionFocusChanged   first focus at startup, and a resumed session
--   SessionStatusChanged  a tab that just became idle
--
-- A /compact sent while the agent is streaming is queued by maki and runs at
-- the next run boundary, so the run that crossed the threshold finishes
-- normally. Left there the agent parks until the next human prompt, because
-- the compaction lands between two turns: measured 2026-10-25, turn end at
-- 13:50:22, compaction done at 13:50:44, next work at 14:03:11 (a prompt).
-- So after a compaction this plugin started -- or one maki's own trigger
-- started -- it posts a resume note with wake = true and the agent carries on
-- with the work in flight, the way pi-auto-compact does.
--
-- What counts as resumable:
--   ours     set by trigger() right before /compact
--   native   set by the "AutoCompacting" event maki fires on its own trigger
-- A manual /compact sets neither: the user asked for the summary, not for the
-- work to carry on, so it stays silent.
--
-- Only the focused session is compacted: maki.api.run_command always targets
-- the focused tab. Background tabs keep maki's native trigger (50% at most).
--
-- Not ported from pi-auto-compact: keep-recent / keep-bookends /
-- summarize-all. Maki's summarizer owns the transcript layout and exposes no
-- such knob.
--
-- Settings are in-memory: set the defaults from init.lua with
-- require("autocompact").setup({ percent = 30 }), and use /auto-compact while
-- maki runs to tune the current process.

local DEFAULTS = {
  enabled = true,
  percent = 30,
  -- Used only when percent == 0.
  tokens = 0,
  -- After a compaction, wait for the context to grow by this share of the
  -- window before compacting again. Stops a summary that lands just under
  -- the threshold from triggering another one on the next turn.
  min_regrow_percent = 10,
  instructions = "Focus on preserving task context and recent work.",
  -- Wake the session with a resume note once a compaction lands, so the agent
  -- continues instead of parking until the next human prompt.
  resume = true,
  -- A second compaction this soon after a resume is one the waking turn caused
  -- by itself; waking again would compound the cost without new work.
  resume_min_gap_secs = 60,
  -- Appended to the sizes of the compaction. Model-facing, so it says what to
  -- do rather than what happened.
  resume_text = "Reprends le travail en cours là où il s'est arrêté : le résumé "
    .. "de compaction remplace l'historique détaillé. Ne refais pas ce qui est "
    .. "déjà fait, ne redemande pas une confirmation déjà donnée, et si le lot "
    .. "est terminé, donne le rapport de livraison et arrête-toi.",
  debug = false,
}

local PENDING_TIMEOUT_SECS = 600

local cfg = {}
local configured = {}
for key, value in pairs(DEFAULTS) do
  cfg[key] = value
  configured[key] = value
end

-- session id -> { pending, pending_at, after, ours, native, cancelled, last_resume }
local sessions = {}

local function debug(message)
  if cfg.debug then
    maki.log.debug("autocompact: " .. message)
  end
end

local function human(tokens)
  if tokens >= 1000000 then
    return string.format("%.1fM", tokens / 1000000)
  end
  if tokens >= 1000 then
    return string.format("%.1fk", tokens / 1000)
  end
  return tostring(tokens)
end

local function state_for(session_id)
  local state = sessions[session_id]
  if not state then
    state = {}
    sessions[session_id] = state
  end
  return state
end

-- The regrowth floor is measured from the last compaction under the old
-- settings, so a new threshold must not keep waiting on it.
local function forget_after()
  for _, state in pairs(sessions) do
    state.after = nil
  end
end

local function limit_for(window)
  if cfg.percent > 0 then
    return math.floor(window * cfg.percent / 100)
  end
  return cfg.tokens
end

local function snapshot_for(session_id)
  local opts = nil
  if session_id then
    opts = { session = session_id }
  end
  local snapshot, err = maki.session.read(opts)
  if not snapshot then
    debug("session.read failed: " .. tostring(err))
  end
  return snapshot
end

local function compact_command()
  local instructions = (cfg.instructions or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if instructions == "" then
    return "/compact"
  end
  return "/compact " .. instructions
end

local function trigger(session_id, state, size, window, source)
  state.pending = true
  state.pending_at = os.time()
  -- From here the next CompactionDone is ours, which is what decides whether
  -- the agent gets a resume note afterwards.
  state.ours = true
  debug(string.format("compacting %s at %s / %s (%s)", session_id, human(size), human(window), source))
  local ok, err = maki.api.run_command(compact_command())
  if not ok then
    state.pending = false
    state.ours = nil
    maki.log.warn("autocompact: /compact refused: " .. tostring(err))
    return
  end
  maki.log.info(string.format(
    "autocompact: compacting %s at %s / %s (%s)",
    session_id,
    human(size),
    human(window),
    source
  ))
end

-- The note a woken agent reads. It names the compaction that just happened so
-- the model does not mistake the summary for a user request, then says what to
-- do with it.
local function resume_note(before, after)
  local lead = "Auto-compaction terminée."
  if before and after then
    lead = string.format("Auto-compaction terminée (%s -> %s de contexte).", human(before), human(after))
  end
  return lead .. " " .. cfg.resume_text
end

local function deliver_resume(session_id, note)
  local snapshot = snapshot_for(session_id)
  if not snapshot then
    return
  end
  local queued = (snapshot.queue and snapshot.queue.count) or 0
  -- A run already in flight, or a prompt the user queued, will read the note
  -- on its own: waking on top of it would buy a second turn nobody asked for.
  -- Neither is a half-written prompt in the input: taking the floor while
  -- somebody is typing is the one wake that feels like a bug.
  local composing = false
  local input = maki.ui.input()
  if input and input.session_id == session_id and (input.text or "") ~= "" then
    composing = true
  end
  local wake = snapshot.status == "idle" and queued == 0 and not composing
  local ok, err = maki.session.notify(note, { session = session_id, wake = wake })
  if not ok then
    maki.log.warn("autocompact: resume refused: " .. tostring(err))
    return
  end
  maki.log.info(string.format(
    "autocompact: resume %s for %s (status %s%s)",
    wake and "woke" or "left for the next run",
    session_id,
    tostring(snapshot.status),
    queued > 0 and (", " .. queued .. " queued") or ""
  ))
  debug("resume note: " .. note)
end

local function resume(session_id, state, data)
  if not cfg.resume then
    debug("no resume: off")
    return
  end
  -- Esc means the user stopped the work, not that it should carry on.
  if state.cancelled then
    debug("no resume: last turn was cancelled")
    return
  end
  local now = os.time()
  if state.last_resume and now - state.last_resume < cfg.resume_min_gap_secs then
    debug("no resume: last one " .. (now - state.last_resume) .. "s ago")
    return
  end
  state.last_resume = now
  local note = resume_note(data.context_size_before, data.context_size_after)
  -- Give the compaction a moment to land: a turn posted in the same tick would
  -- race the history rewrite.
  maki.defer_fn(function()
    deliver_resume(session_id, note)
  end, 1000)
end

local function check(session_id, snapshot, source)
  if not cfg.enabled or not session_id or not snapshot or not snapshot.focused then
    return
  end
  -- A permission prompt is waiting on the user. Compacting now would flip the
  -- tab out of needs_input while the run is parked.
  if snapshot.status == "needs_input" then
    return
  end

  local window = snapshot.context_window
  local size = snapshot.context_size
  if not window or window <= 0 or not size then
    return
  end

  local limit = limit_for(window)
  if limit <= 0 or size < limit then
    return
  end

  local state = state_for(session_id)
  if state.pending then
    if os.time() - (state.pending_at or 0) < PENDING_TIMEOUT_SECS then
      return
    end
    -- The compaction never reported back, so let a new one through instead of
    -- staying stuck for the rest of the process.
    state.pending = false
  end

  if state.after then
    local floor = state.after + math.floor(window * cfg.min_regrow_percent / 100)
    if size < floor then
      debug(string.format("holding %s at %s, last compaction left %s", session_id, human(size), human(state.after)))
      return
    end
  end

  trigger(session_id, state, size, window, source)
end

local function check_session(session_id, source)
  local snapshot = snapshot_for(session_id)
  if not snapshot then
    return
  end
  check(snapshot.id or session_id, snapshot, source)
end

maki.api.create_autocmd("TurnEnd", {
  callback = function(event)
    local data = event.data or {}
    -- The user cancelled: do not start a multi-minute summary right after Esc,
    -- and do not resume the work they just stopped.
    if data.reason == "cancelled" or data.reason == "dropped" then
      if data.session_id then
        state_for(data.session_id).cancelled = true
      end
      return
    end
    if data.session_id then
      state_for(data.session_id).cancelled = nil
    end
    local snapshot = snapshot_for(data.session_id)
    if not snapshot then
      return
    end
    snapshot.context_size = data.context_size or snapshot.context_size
    snapshot.context_window = data.context_window or snapshot.context_window
    check(data.session_id or snapshot.id, snapshot, "turn-end")
  end,
})

maki.api.create_autocmd("SessionFocusChanged", {
  callback = function(event)
    check_session((event.data or {}).session_id, "focus")
  end,
})

maki.api.create_autocmd("SessionStatusChanged", {
  callback = function(event)
    local data = event.data or {}
    if data.status ~= "idle" then
      return
    end
    local state = data.session_id and sessions[data.session_id]
    if state and state.pending then
      -- A queued /compact keeps the tab working until it finishes, so idle
      -- this soon means it is still on its way: do not queue a second one.
      if os.time() - (state.pending_at or 0) < 5 then
        return
      end
      -- Older than that and no CompactionDone arrived: the compaction was
      -- skipped, refused, or cancelled. Let a later run try again.
      state.pending = false
      state.pending_at = nil
      debug("pending compaction never reported back, cleared")
      return
    end
    check_session(data.session_id, "idle")
  end,
})

maki.api.create_autocmd("TurnStart", {
  callback = function(event)
    local data = event.data or {}
    local state = data.session_id and sessions[data.session_id]
    if state then
      state.cancelled = nil
    end
  end,
})

maki.api.create_autocmd("CompactionDone", {
  callback = function(event)
    local data = event.data or {}
    if not data.session_id then
      return
    end
    local state = state_for(data.session_id)
    -- Ours or maki's own trigger: the agent was working and should carry on.
    -- A manual /compact sets neither flag, so it stays silent.
    local resumable = state.ours or state.native
    state.pending = false
    state.pending_at = nil
    state.ours = nil
    state.native = nil
    state.after = data.context_size_after or 0
    debug(string.format(
      "compaction done for %s: %s -> %s",
      data.session_id,
      human(data.context_size_before or 0),
      human(data.context_size_after or 0)
    ))
    if resumable then
      resume(data.session_id, state, data)
    end
  end,
})

maki.api.create_autocmd("AutoCompacting", {
  callback = function(event)
    local data = event.data or {}
    if not data.session_id then
      return
    end
    local state = state_for(data.session_id)
    state.pending = true
    state.pending_at = os.time()
    state.native = true
  end,
})

maki.api.create_autocmd({ "SessionEnd", "SessionReset" }, {
  callback = function(event)
    local data = event.data or {}
    if data.session_id then
      sessions[data.session_id] = nil
    end
  end,
})

-- SessionFocusChanged covers the first focus, but give the UI a moment to
-- finish loading a resumed session before reading its context size.
maki.defer_fn(function()
  check_session(nil, "startup")
end, 2000)

local function human_age(secs)
  if secs < 60 then
    return secs .. "s"
  end
  if secs < 3600 then
    return math.floor(secs / 60) .. "m"
  end
  return math.floor(secs / 3600) .. "h"
end

local function status_text()
  local limit
  local lines = {
    string.format("Auto-compact: %s", cfg.enabled and "on" or "off"),
  }
  local snapshot = snapshot_for(nil)
  if snapshot then
    local window = snapshot.context_window or 0
    local size = snapshot.context_size or 0
    limit = limit_for(window)
    local percent = window > 0 and (size / window * 100) or 0
    lines[#lines + 1] = string.format("Context: %s / %s (%.1f%%)", human(size), human(window), percent)
    if cfg.percent > 0 then
      lines[#lines + 1] = string.format("Compact at: %s (%d%%)", human(limit), cfg.percent)
    else
      lines[#lines + 1] = string.format("Compact at: %s tokens", human(limit))
    end
    local state = snapshot.id and sessions[snapshot.id]
    if state then
      if state.after then
        lines[#lines + 1] = string.format("Last compaction left: %s", human(state.after))
      end
      if state.pending then
        lines[#lines + 1] = "Compaction pending"
      end
      if state.last_resume then
        lines[#lines + 1] = string.format("Last resume: %s ago", human_age(os.time() - state.last_resume))
      end
    end
  else
    lines[#lines + 1] = "Context: unavailable"
  end
  lines[#lines + 1] = "Resume: " .. (cfg.resume and "on" or "off")
  lines[#lines + 1] = "Guidance: " .. ((cfg.instructions and cfg.instructions ~= "") and cfg.instructions or "(none)")
  lines[#lines + 1] = "Usage: /auto-compact [status|<percent>|tokens <n>|instructions <text>|resume on|off|simulate|on|off|reset]"
  return table.concat(lines, "\n")
end

maki.api.register_command({
  name = "/auto-compact",
  description = "Auto-compaction threshold and status (default 30% of the context window)",
  nargs = "*",
  handler = function(opts)
    local args = opts.fargs or {}
    local head = (args[1] or "status"):lower()

    if head == "status" then
      local text = status_text()
      maki.log.info(text)
      maki.notify(text)
      return
    end

    if head == "on" or head == "off" then
      cfg.enabled = head == "on"
      maki.notify("Auto-compaction " .. (cfg.enabled and "on" or "off"))
      return
    end

    if head == "reset" then
      for key, value in pairs(configured) do
        cfg[key] = value
      end
      forget_after()
      maki.notify(string.format("Auto-compaction reset to %d%%", configured.percent))
      return
    end

    if head == "tokens" then
      local count = tonumber(args[2] or "")
      if not count or count <= 0 then
        maki.notify("usage: /auto-compact tokens <count>", "warn")
        return
      end
      cfg.tokens = math.floor(count)
      cfg.percent = 0
      forget_after()
      maki.notify(string.format("Auto-compaction at %s tokens", human(cfg.tokens)))
      return
    end

    if head == "instructions" then
      local text = opts.args:gsub("^%s*%S+%s*", "")
      cfg.instructions = text
      maki.notify("Auto-compaction guidance: " .. (text ~= "" and text or "(none)"))
      return
    end

    if head == "resume" then
      local mode = (args[2] or ""):lower()
      if mode == "on" or mode == "off" then
        cfg.resume = mode == "on"
        maki.notify("Resume after auto-compaction " .. (cfg.resume and "on" or "off"))
        return
      end
      maki.notify("usage: /auto-compact resume on|off", "warn")
      return
    end

    -- Self-test of the resume path: fires the event a real compaction fires,
    -- with the context sizes left untouched. Nothing is summarized.
    if head == "simulate" then
      local snapshot = snapshot_for(nil)
      if not snapshot or not snapshot.id then
        maki.notify("simulate: no focused session", "warn")
        return
      end
      state_for(snapshot.id).ours = true
      maki.api.exec_autocmds("CompactionDone", {
        data = {
          session_id = snapshot.id,
          context_size_before = snapshot.context_size,
          context_size_after = snapshot.context_size,
          context_window = snapshot.context_window,
        },
      })
      maki.notify("simulate: CompactionDone fired, resume note on its way")
      return
    end

    local percent = tonumber(head)
    if percent and percent > 0 and percent < 100 then
      cfg.percent = math.floor(percent)
      cfg.tokens = 0
      forget_after()
      maki.notify(string.format("Auto-compaction at %d%% of the context window", cfg.percent))
      return
    end

    maki.notify("usage: /auto-compact [status|<percent>|tokens <n>|instructions <text>|resume on|off|simulate|on|off|reset]", "warn")
  end,
})

local M = {}

function M.setup(opts)
  opts = opts or {}
  for key in pairs(DEFAULTS) do
    if opts[key] ~= nil then
      local value = opts[key]
      if key == "percent" or key == "tokens" or key == "min_regrow_percent" or key == "resume_min_gap_secs" then
        value = math.floor(tonumber(value) or 0)
      end
      cfg[key] = value
      configured[key] = value
    end
  end
  forget_after()
  return M
end

return M
