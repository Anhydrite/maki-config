-- Real-time tokens-per-second, ported from pi-token-speed.
--
-- Maki fires TextDelta, ThinkingDelta and ToolCallDelta while the model
-- streams, so the rate is measured from the deltas themselves instead of
-- polling session.read at round boundaries. Tool execution time is paused
-- out, and TurnEnd reconciles the exact provider usage so the final average
-- is not an estimate.

local CONFIG_FILE = "tps.json"
local MIN_WINDOW_MS = 100
local MAX_WINDOW_MS = 30000
local COMPACT_AT = 5000
local ZWSP = "\226\128\139"

local DEFAULTS = {
  display = "tps",
  icon = "⚡",
  slidingWindow = 1000,
  updateInterval = 0,
  countStrategy = "estimate",
  endTpsBehavior = "average",
  formatDuration = false,
  thresholds = { slow = 0, medium = 15, fast = 30, blazing = 45 },
  colors = {
    slow = "error",
    medium = "accent",
    fast = "tool_success",
    blazing = "item",
  },
  displayColors = { count = "", elapsed = "", ttft = "" },
  providerOverrides = {},
}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = copy(v)
  end
  return out
end

local function merge(base, over)
  local out = copy(base)
  for k, v in pairs(over or {}) do
    if type(v) == "table" and type(out[k]) == "table" then
      out[k] = merge(out[k], v)
    else
      out[k] = copy(v)
    end
  end
  return out
end

local function now_ms()
  if maki.uv.hrtime then
    return maki.uv.hrtime() / 1e6
  end
  return os.clock() * 1000
end

local function config_path()
  local dir = maki.env.config_dir()
  if not dir then
    return nil
  end
  return maki.fs.joinpath(dir, CONFIG_FILE)
end

local function clamp(value, lo, hi, fallback)
  if type(value) ~= "number" or value ~= value then
    return fallback
  end
  return math.max(lo, math.min(hi, value))
end

local function validate(cfg)
  if cfg.display ~= "tps" and cfg.display ~= "ttft" and cfg.display ~= "stats" and cfg.display ~= "full" then
    cfg.display = DEFAULTS.display
  end
  if cfg.countStrategy ~= "direct" and cfg.countStrategy ~= "estimate" then
    cfg.countStrategy = DEFAULTS.countStrategy
  end
  if cfg.endTpsBehavior ~= "average" and cfg.endTpsBehavior ~= "last" then
    cfg.endTpsBehavior = DEFAULTS.endTpsBehavior
  end
  cfg.slidingWindow = clamp(cfg.slidingWindow, MIN_WINDOW_MS, MAX_WINDOW_MS, DEFAULTS.slidingWindow)
  cfg.updateInterval = clamp(cfg.updateInterval, 0, 60000, DEFAULTS.updateInterval)
  cfg.icon = type(cfg.icon) == "string" and cfg.icon or DEFAULTS.icon
  cfg.formatDuration = cfg.formatDuration == true

  local t = type(cfg.thresholds) == "table" and cfg.thresholds or {}
  local slow = clamp(t.slow, 0, 100000, DEFAULTS.thresholds.slow)
  local medium = clamp(t.medium, 0, 100000, DEFAULTS.thresholds.medium)
  local fast = clamp(t.fast, 0, 100000, DEFAULTS.thresholds.fast)
  local blazing = clamp(t.blazing, 0, 100000, DEFAULTS.thresholds.blazing)
  if not (slow < medium and medium < fast and fast < blazing) then
    slow, medium, fast, blazing = DEFAULTS.thresholds.slow, DEFAULTS.thresholds.medium, DEFAULTS.thresholds.fast, DEFAULTS.thresholds.blazing
  end
  cfg.thresholds = { slow = slow, medium = medium, fast = fast, blazing = blazing }

  local c = type(cfg.colors) == "table" and cfg.colors or {}
  cfg.colors = {
    slow = type(c.slow) == "string" and c.slow ~= "" and c.slow or DEFAULTS.colors.slow,
    medium = type(c.medium) == "string" and c.medium ~= "" and c.medium or DEFAULTS.colors.medium,
    fast = type(c.fast) == "string" and c.fast ~= "" and c.fast or DEFAULTS.colors.fast,
    blazing = type(c.blazing) == "string" and c.blazing ~= "" and c.blazing or DEFAULTS.colors.blazing,
  }

  local dc = type(cfg.displayColors) == "table" and cfg.displayColors or {}
  cfg.displayColors = {
    count = type(dc.count) == "string" and dc.count or "",
    elapsed = type(dc.elapsed) == "string" and dc.elapsed or "",
    ttft = type(dc.ttft) == "string" and dc.ttft or "",
  }

  if type(cfg.providerOverrides) ~= "table" then
    cfg.providerOverrides = {}
  end
  return cfg
end

local function load_config()
  local path = config_path()
  if not path then
    return copy(DEFAULTS)
  end
  local text = maki.fs.read(path)
  if not text then
    return copy(DEFAULTS)
  end
  local decoded = maki.json.decode(text)
  if type(decoded) ~= "table" then
    return copy(DEFAULTS)
  end
  return validate(merge(DEFAULTS, decoded))
end

local function save_config(cfg)
  local path = config_path()
  if not path then
    return false, "no config directory"
  end
  local text, err = maki.json.encode(cfg)
  if not text then
    return false, err
  end
  return maki.fs.write(path, text)
end

local function resolve_config(cfg, provider)
  if not provider then
    return cfg
  end
  local over = cfg.providerOverrides and cfg.providerOverrides[provider]
  if type(over) ~= "table" then
    return cfg
  end
  return validate(merge(cfg, over))
end

local function estimate_tokens(text)
  if not text or text == "" then
    return 0
  end
  local n = 0
  for _ in text:gmatch("%w+") do
    n = n + 1
  end
  for _ in text:gmatch("[^%s%w]") do
    n = n + 1
  end
  return n
end

local Window = {}
Window.__index = Window

function Window.new(ms)
  return setmetatable({ ms = ms, events = {}, start = 1 }, Window)
end

function Window:reset()
  self.events = {}
  self.start = 1
end

function Window:record(tokens, t)
  if tokens <= 0 then
    return
  end
  self.events[#self.events + 1] = { t = t or now_ms(), n = tokens }
  if self.start >= COMPACT_AT then
    local kept = {}
    for i = self.start, #self.events do
      kept[#kept + 1] = self.events[i]
    end
    self.events = kept
    self.start = 1
  end
end

function Window:tps(t)
  local n = #self.events
  if n == 0 then
    return 0
  end
  local cutoff = t - self.ms
  while self.start <= n and self.events[self.start].t < cutoff do
    self.start = self.start + 1
  end
  if self.start > n then
    return 0
  end
  local tokens = 0
  for i = self.start, n do
    tokens = tokens + self.events[i].n
  end
  if tokens <= 0 then
    return 0
  end
  local span_start = self.events[self.start].t
  local first = self.events[self.start].t
  local last = self.events[n].t
  if first == last and self.start > 1 then
    span_start = self.events[self.start - 1].t
  end
  local span = math.max(t - span_start, MIN_WINDOW_MS)
  return (1000 * tokens) / span
end

local Engine = {}
Engine.__index = Engine

function Engine.new()
  return setmetatable({
    streaming = false,
    paused = false,
    tokens = 0,
    turn_start = 0,
    start_time = 0,
    end_time = 0,
    ttft_start = 0,
    ttft_end = 0,
    pause_start = 0,
    paused_ms = 0,
    tps = 0,
    window = Window.new(DEFAULTS.slidingWindow),
    cfg = copy(DEFAULTS),
    provider = nil,
  }, Engine)
end

function Engine:reset(cfg, provider)
  self.streaming = false
  self.paused = false
  self.tokens = 0
  self.turn_start = now_ms()
  self.start_time = 0
  self.end_time = 0
  self.ttft_start = now_ms()
  self.ttft_end = 0
  self.pause_start = 0
  self.paused_ms = 0
  self.tps = 0
  self.window = Window.new(cfg.slidingWindow)
  self.cfg = cfg
  self.provider = provider
end

function Engine:start()
  if self.streaming then
    return
  end
  self.streaming = true
  self.start_time = now_ms()
  self.end_time = self.start_time
  self.window:reset()
end

function Engine:stop_ttft()
  if self.ttft_end == 0 then
    self.ttft_end = now_ms()
  end
end

function Engine:record(delta)
  if not self.streaming then
    self:stop_ttft()
    self:start()
  end
  if self.paused then
    self:resume()
  end
  local n = self.cfg.countStrategy == "direct" and 1 or estimate_tokens(delta)
  if n <= 0 then
    return
  end
  self.tokens = self.tokens + n
  local t = now_ms()
  self.window:record(n, t)
  self.tps = self.window:tps(t)
end

function Engine:pause()
  if self.paused then
    return
  end
  self.paused = true
  self.pause_start = now_ms()
end

function Engine:resume()
  if not self.paused then
    return
  end
  self.paused = false
  self.paused_ms = self.paused_ms + (now_ms() - self.pause_start)
end

function Engine:stop()
  if not self.streaming then
    return
  end
  self:resume()
  self.streaming = false
  self.end_time = now_ms()
  self.window:reset()
end

function Engine:elapsed_ms()
  if self.start_time == 0 then
    return 0
  end
  local end_time = self.streaming and now_ms() or self.end_time
  return math.max(end_time - self.start_time - self.paused_ms, 0)
end

function Engine:ttft_ms()
  if self.ttft_start == 0 or self.ttft_end == 0 then
    return 0
  end
  return math.max(self.ttft_end - self.ttft_start, 0)
end

function Engine:turn_elapsed_ms()
  if self.turn_start == 0 then
    return 0
  end
  local end_time = self.streaming and now_ms() or self.end_time
  return math.max(end_time - self.turn_start - self.paused_ms, 0)
end

function Engine:avg_tps()
  -- A one-chunk answer can finish in under a millisecond; the 0.5s floor
  -- keeps a two-token reply from reading thousands of tok/s.
  local secs = math.max(self:turn_elapsed_ms() / 1000, 0.5)
  return self.tokens / secs
end

function Engine:value()
  if self.streaming then
    return self.tps
  end
  if self.cfg.endTpsBehavior == "last" then
    return self.tps
  end
  return self:avg_tps()
end

function Engine:reconcile(tokens)
  if tokens and tokens > 0 then
    self.tokens = tokens
  end
end

local function format_duration(seconds)
  if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 then
    seconds = 0
  end
  local tenths = math.floor(seconds * 10 + 0.5)
  if tenths == 0 then
    return "0.0s"
  end
  local days = math.floor(tenths / 864000)
  local rem = tenths % 864000
  local hours = math.floor(rem / 36000)
  rem = rem % 36000
  local minutes = math.floor(rem / 600)
  local secs = (rem % 600) / 10
  if tenths >= 864000 then
    return string.format("%dd %dh", days, hours)
  end
  if tenths >= 36000 then
    return string.format("%dh %dm", hours, minutes)
  end
  if tenths >= 600 then
    return string.format("%dm %.1fs", minutes, secs)
  end
  return string.format("%.1fs", secs)
end

local function tier(cfg, tps)
  if tps >= cfg.thresholds.blazing then
    return "blazing"
  end
  if tps >= cfg.thresholds.fast then
    return "fast"
  end
  if tps >= cfg.thresholds.medium then
    return "medium"
  end
  return "slow"
end

local function style_or(style, fallback)
  if type(style) == "string" and style ~= "" then
    return style
  end
  return fallback
end

local function elapsed_text(cfg, engine)
  local secs = engine:turn_elapsed_ms() / 1000
  if cfg.formatDuration then
    return format_duration(secs)
  end
  return string.format("%.1fs", secs)
end

local last_render = 0

local function render(engine, force)
  local cfg = engine.cfg
  local now = now_ms()
  if not force and cfg.updateInterval > 0 and now - last_render < cfg.updateInterval then
    return
  end
  last_render = now

  local tps = engine:value()
  local spans = {
    { string.format(" %.1f tok/s", tps), "dim" },
  }

  local dc = cfg.displayColors
  local function part(text, style)
    if text ~= "" then
      spans[#spans + 1] = { text, style_or(style, "dim") }
    end
  end

  if cfg.display == "ttft" then
    part(" (TTFT: ", "dim")
    part(string.format("%d ms", engine:ttft_ms()), dc.ttft)
    part(")", "dim")
  elseif cfg.display == "stats" then
    part(" (", "dim")
    part(string.format("%d tok", engine.tokens), dc.count)
    part(" in ", "dim")
    part(elapsed_text(cfg, engine), dc.elapsed)
    part(")", "dim")
  elseif cfg.display == "full" then
    part(" (", "dim")
    part(string.format("%d tok", engine.tokens), dc.count)
    part(" in ", "dim")
    part(elapsed_text(cfg, engine), dc.elapsed)
    part(" · TTFT: ", "dim")
    part(string.format("%d ms", engine:ttft_ms()), dc.ttft)
    part(")", "dim")
  end

  spans[#spans + 1] = { ZWSP, "dim" }
  maki.ui.set_status_hint(spans)
end

local engine = Engine.new()
-- Loading the config touches the filesystem, which yields. Do it from an
-- event or a command, never at module load time.
local cfg = copy(DEFAULTS)
local session_id = nil

local function current_provider()
  local m = maki.model.get()
  return m and m.provider or nil
end

local function refresh_config()
  cfg = load_config()
  local provider = current_provider()
  engine.cfg = resolve_config(cfg, provider)
  engine.provider = provider
end

local function on_delta(ev)
  local data = ev.data
  if not data or data.session_id ~= session_id then
    return
  end
  engine:record(data.text or "")
  render(engine, false)
end

maki.api.create_autocmd("TurnStart", {
  callback = function(ev)
    session_id = ev.data and ev.data.session_id
    refresh_config()
    engine:reset(engine.cfg, engine.provider)
    render(engine, true)
  end,
})

maki.api.create_autocmd("TextDelta", { callback = on_delta })
maki.api.create_autocmd("ThinkingDelta", { callback = on_delta })
maki.api.create_autocmd("ToolCallDelta", { callback = on_delta })

maki.api.create_autocmd("ToolStart", {
  callback = function(ev)
    local data = ev.data
    if not data or data.session_id ~= session_id then
      return
    end
    if not engine.streaming then
      engine:stop_ttft()
      engine:start()
    end
    engine:pause()
    render(engine, true)
  end,
})

maki.api.create_autocmd("TurnEnd", {
  callback = function(ev)
    local data = ev.data or {}
    if data.session_id ~= session_id then
      return
    end
    engine:stop()
    engine:reconcile(data.usage and data.usage.output_tokens or 0)
    render(engine, true)
  end,
})

maki.api.create_autocmd({ "TurnError", "SessionReset" }, {
  callback = function()
    engine:stop()
    maki.ui.set_status_hint(nil)
  end,
})

maki.api.create_autocmd("ModelChanged", {
  callback = function()
    refresh_config()
    render(engine, true)
  end,
})

local function show_config()
  refresh_config()
  local provider = current_provider() or "?"
  local lines = {
    "tps (provider: " .. provider .. ")",
    "display=" .. cfg.display,
    "icon=" .. cfg.icon,
    "window=" .. cfg.slidingWindow .. "ms",
    "interval=" .. cfg.updateInterval .. "ms",
    "count=" .. cfg.countStrategy,
    "end=" .. cfg.endTpsBehavior,
    "format=" .. tostring(cfg.formatDuration),
    "thresholds=" .. cfg.thresholds.slow .. "/" .. cfg.thresholds.medium .. "/" .. cfg.thresholds.fast .. "/" .. cfg.thresholds.blazing,
    "colors=" .. cfg.colors.slow .. "/" .. cfg.colors.medium .. "/" .. cfg.colors.fast .. "/" .. cfg.colors.blazing,
  }
  maki.notify(table.concat(lines, "\n"), "info")
end

local function set_and_save(key, value)
  cfg[key] = value
  validate(cfg)
  local ok, err = save_config(cfg)
  if not ok then
    maki.notify("tps: " .. (err or "save failed"), "warn")
    return
  end
  refresh_config()
  render(engine, true)
end

maki.api.register_command({
  name = "tps",
  description = "Show or change token-speed settings",
  nargs = "*",
  handler = function(opts)
    local args = opts.fargs or {}
    local key = args[1]
    if not key then
      show_config()
      return
    end
    if key == "reset" then
      cfg = copy(DEFAULTS)
      save_config(cfg)
      refresh_config()
      render(engine, true)
      maki.notify("tps: reset", "info")
      return
    end
    if key == "path" then
      maki.notify(config_path() or "no config directory", "info")
      return
    end
    if key == "display" and args[2] then
      set_and_save("display", args[2])
      return
    end
    if key == "icon" then
      set_and_save("icon", args[2] or "")
      return
    end
    if key == "window" and args[2] then
      set_and_save("slidingWindow", tonumber(args[2]) or cfg.slidingWindow)
      return
    end
    if key == "interval" and args[2] then
      set_and_save("updateInterval", tonumber(args[2]) or cfg.updateInterval)
      return
    end
    if key == "count" and args[2] then
      set_and_save("countStrategy", args[2])
      return
    end
    if key == "end" and args[2] then
      set_and_save("endTpsBehavior", args[2])
      return
    end
    if key == "format" and args[2] then
      set_and_save("formatDuration", args[2] == "on" or args[2] == "true")
      return
    end
    if key == "threshold" and args[2] and args[3] then
      local tier_name = args[2]
      local value = tonumber(args[3])
      if value and cfg.thresholds[tier_name] ~= nil then
        cfg.thresholds[tier_name] = value
        validate(cfg)
        local ok, err = save_config(cfg)
        if not ok then
          maki.notify("tps: " .. (err or "save failed"), "warn")
        else
          refresh_config()
          render(engine, true)
        end
      else
        maki.notify("tps: threshold <slow|medium|fast|blazing> <number>", "warn")
      end
      return
    end
    if key == "color" and args[2] and args[3] then
      local tier_name = args[2]
      if cfg.colors[tier_name] ~= nil then
        cfg.colors[tier_name] = args[3]
        validate(cfg)
        local ok, err = save_config(cfg)
        if not ok then
          maki.notify("tps: " .. (err or "save failed"), "warn")
        else
          refresh_config()
          render(engine, true)
        end
      else
        maki.notify("tps: color <slow|medium|fast|blazing> <style>", "warn")
      end
      return
    end
    maki.notify(
      "tps: /tps [reset|path|display tps|ttft|stats|full|icon X|window ms|interval ms|count direct|estimate|end average|last|format on|off|threshold tier n|color tier style]",
      "info"
    )
  end,
})
