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
-- the next run boundary. That is why there is no mid-run abort to recover
-- from and no auto-continue nudge, unlike pi-auto-compact: the run that
-- crossed the threshold finishes normally, and the compaction happens before
-- the next prompt.
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
  debug = false,
}

local PENDING_TIMEOUT_SECS = 600

local cfg = {}
local configured = {}
for key, value in pairs(DEFAULTS) do
  cfg[key] = value
  configured[key] = value
end

-- session id -> { pending, pending_at, after }
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
  debug(string.format("compacting %s at %s / %s (%s)", session_id, human(size), human(window), source))
  local ok, err = maki.api.run_command(compact_command())
  if not ok then
    state.pending = false
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
    -- The user cancelled: do not start a multi-minute summary right after Esc.
    if data.reason == "cancelled" or data.reason == "dropped" then
      return
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

maki.api.create_autocmd("CompactionDone", {
  callback = function(event)
    local data = event.data or {}
    if not data.session_id then
      return
    end
    local state = state_for(data.session_id)
    state.pending = false
    state.pending_at = nil
    state.after = data.context_size_after or 0
    debug(string.format(
      "compaction done for %s: %s -> %s",
      data.session_id,
      human(data.context_size_before or 0),
      human(data.context_size_after or 0)
    ))
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
    end
  else
    lines[#lines + 1] = "Context: unavailable"
  end
  lines[#lines + 1] = "Guidance: " .. ((cfg.instructions and cfg.instructions ~= "") and cfg.instructions or "(none)")
  lines[#lines + 1] = "Usage: /auto-compact [status|<percent>|tokens <n>|instructions <text>|on|off|reset]"
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

    local percent = tonumber(head)
    if percent and percent > 0 and percent < 100 then
      cfg.percent = math.floor(percent)
      cfg.tokens = 0
      forget_after()
      maki.notify(string.format("Auto-compaction at %d%% of the context window", cfg.percent))
      return
    end

    maki.notify("usage: /auto-compact [status|<percent>|tokens <n>|instructions <text>|on|off|reset]", "warn")
  end,
})

local M = {}

function M.setup(opts)
  opts = opts or {}
  for key in pairs(DEFAULTS) do
    if opts[key] ~= nil then
      local value = opts[key]
      if key == "percent" or key == "tokens" or key == "min_regrow_percent" then
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
