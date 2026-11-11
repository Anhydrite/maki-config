-- Output speed, shown under the chat input.
--
-- The plugin API exposes nothing that moves while the model streams
-- (verified by sampling: transcript, usage, context, updated_at all frozen
-- until round end). Tokens only become visible at round boundaries, where
-- usage.output_tokens jumps by the exact count of the finished round. So
-- the display combines:
--   - a rate: tokens of the retained jumps divided by the time since the
--     anchor (the sample before the window, or turn start), so the figure
--     keeps moving on every 100ms tick instead of freezing during thinking;
--     the anchor slides forward as old samples are pruned, and the EMA
--     smooths the snaps when a jump lands;
--   - at TurnEnd: the exact whole-turn figure, minus tool time.
-- One in-memory session.read per tick, only while a turn runs.

local POLL_MS = 100
local WINDOW_MS = 1000
local MIN_STEP_S = 1
local ALPHA = 0.3
local SEED_RATE = 60

local session_id = nil
local working = false
local started_at = nil
local ticks = 0
local tool_ms = 0
local model_key = "?"
local rates = {}
local window = {}
local prev_tick = 0
local shown = nil
local usage_start = nil
local usage_now = nil
local jump_tick = 0
local jump_tool_ms = 0

local function show(text)
  maki.ui.set_status_hint({ { " " .. text .. " ", "accent" } })
end

local function ema_rate()
  return rates[model_key] or SEED_RATE
end

local function model_secs(tick, tool)
  return math.max(tick * POLL_MS / 1000 - tool / 1000, 0)
end

local function push(tick, tokens)
  window[#window + 1] = { tick = tick, tokens = tokens }
  local keep = math.ceil(WINDOW_MS / POLL_MS) + 4
  while #window > keep do
    -- l'echantillon prune devient l'ancre: l'intervalle de mesure doit
    -- repartir de lui, pas s'effondrer sur le saut lui-meme
    prev_tick = window[1].tick
    table.remove(window, 1)
  end
end

local function window_rate(now_tick)
  if #window == 0 then
    return nil
  end
  local toks = 0
  for j = 1, #window do
    toks = toks + window[j].tokens
  end
  if toks <= 0 then
    return nil
  end
  -- les tokens des sauts ont ete generes depuis l'ancre (echantillon
  -- precedent, ou debut du tour), pas pendant le tick ou ils apparaissent:
  -- amortir sur cet intervalle, qui grandit a chaque tick -> le chiffre
  -- bouge toutes les 100 ms, y compris pendant le thinking (pas de gel)
  local dt = math.max((now_tick - prev_tick) * POLL_MS / 1000, MIN_STEP_S)
  return toks / dt
end

local function sample()
  local r = window_rate(ticks)
  if r then
    shown = shown and shown + ALPHA * (r - shown) or r
  end
  show(string.format("%.1f tok/s", shown or ema_rate()))
end

maki.api.create_autocmd("TurnStart", {
  callback = function(ev)
    session_id = ev.data and ev.data.session_id
    working = true
    started_at = os.time()
    ticks = 0
    tool_ms = 0
    window = {}
    prev_tick = 0
    shown = nil
    usage_start = nil
    usage_now = nil
    jump_tick = 0
    jump_tool_ms = 0
    local m = maki.model.get()
    model_key = m and m.spec or "?"
  end,
})

maki.api.create_autocmd("ToolDone", {
  callback = function(ev)
    local data = ev.data
    if not data or data.session_id ~= session_id then
      return
    end
    if data.duration_ms then
      tool_ms = tool_ms + data.duration_ms
    end
  end,
})

maki.api.create_autocmd("TurnEnd", {
  callback = function(ev)
    local data = ev.data or {}
    if data.session_id ~= session_id then
      return
    end
    working = false
    local output_tokens = data.usage and data.usage.output_tokens or 0
    if output_tokens <= 0 then
      return
    end
    local secs = model_secs(ticks, tool_ms)
    if secs <= 0 then
      secs = math.max(os.time() - (started_at or os.time()), 1)
    end
    local r = output_tokens / math.max(secs, 0.5)
    rates[model_key] = rates[model_key]
      and rates[model_key] + ALPHA * (r - rates[model_key]) or r
    show(string.format("%.1f tok/s", r))
  end,
})

maki.api.create_autocmd({ "TurnError", "SessionReset" }, {
  callback = function()
    working = false
    window = {}
    prev_tick = 0
    maki.ui.set_status_hint(nil)
  end,
})

maki.async.spawn(function()
  while true do
    maki.async.sleep(POLL_MS)
    if working then
      ticks = ticks + 1
      local s = maki.session.read({ session = session_id })
      if not s then
        s = maki.session.read()
      end
      local out = s and s.usage and s.usage.output_tokens or nil
      if out then
        if usage_start == nil then
          usage_start = out
          usage_now = out
        elseif out > usage_now then
          push(ticks, out - usage_now)
          usage_now = out
          jump_tick = ticks
          jump_tool_ms = tool_ms
        end
      end
      sample()
    end
  end
end)
