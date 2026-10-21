-- Last-turn output speed, shown under the chat input.
--
-- There is no per-stream event for plugins, so this measures the turn:
-- wall time from TurnStart to TurnEnd minus the time tools ran (ToolDone
-- carries duration_ms). That is generation plus network/queueing, close to
-- the model's throughput. os.time() has one-second resolution, so very short
-- turns read as a rough number.

local started_at = nil
local tool_ms = 0
local session_id = nil

local function show(rate)
  maki.ui.set_status_hint({
    { string.format(" %.1f tok/s ", rate), "accent" },
  })
end

maki.api.create_autocmd("TurnStart", {
  callback = function(ev)
    session_id = ev.data and ev.data.session_id
    started_at = os.time()
    tool_ms = 0
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
    local started = started_at
    started_at = nil
    if not started then
      return
    end
    local data = ev.data or {}
    if data.session_id ~= session_id then
      return
    end
    local output_tokens = data.usage and data.usage.output_tokens or 0
    if output_tokens <= 0 then
      return
    end
    local elapsed = math.max(os.time() - started, 1)
    local model_secs = math.max(elapsed - tool_ms / 1000, 0.5)
    show(output_tokens / model_secs)
  end,
})

maki.api.create_autocmd({ "TurnError", "SessionReset" }, {
  callback = function()
    started_at = nil
    maki.ui.set_status_hint(nil)
  end,
})
