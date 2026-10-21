-- Opencode Go, with the DeepSeek V4 thinking-mode fix.
--
-- DeepSeek answers 400 ("The `reasoning_content` in the thinking mode must be
-- passed back to the API") to a request that carries tools and an assistant
-- turn without `reasoning_content`. The built-in `opencode-go` provider is
-- generic: it sends the turns that have thinking and leaves the others bare,
-- and a tool-only turn with no reasoning poisons the session. This provider
-- back-fills the missing field, the way the bundled `deepseek` plugin does.
local REASONER = "deepseek-reasoner"
local PAD = ""

local function uses_v4_thinking_protocol(model)
  return model:find("deepseek", 1, true) ~= nil and model:sub(1, #REASONER) ~= REASONER
end

local function pad_reasoning_content(body, model)
  if not body.tools or not uses_v4_thinking_protocol(model) then
    return
  end
  for _, message in ipairs(body.messages or {}) do
    if message.role == "assistant" and type(message.reasoning_content) ~= "string" then
      message.reasoning_content = PAD
    end
  end
end

-- Reuse the key already stored for the built-in `opencode-go` provider: a
-- plugin cannot read another provider's auth store, but the file is local.
local function stored_key()
  local state = maki.env.state_dir()
  if not state then
    return nil
  end
  local text = maki.fs.read(state .. "/auth/opencode-go.json")
  if not text then
    return nil
  end
  local saved = maki.json.decode(text)
  return saved and saved.api_key
end

maki.provider.register({
  slug = "ocgo",
  display_name = "Opencode Go (DeepSeek thinking fix)",
  codec = "openai",
  base_url = "https://opencode.ai/zen/go/v1",
  family = "generic",
  accepts_arbitrary_models = true,
  default_model = "deepseek-v4.1-flash",
  context_window = 1000000,
  max_output_tokens = 384000,

  openai = {
    -- Zen requires a stable per-conversation id, like the built-in provider.
    session_id = { header = "x-opencode-session" },
    -- Adaptive thinking goes out as `reasoning_effort`.
    thinking = { dialect = "standard" },
  },

  auth = function()
    local key = stored_key()
    if not key or key == "" then
      return nil, "no OpenCode key: log in once with Opencode Go in maki"
    end
    return { headers = { authorization = "Bearer " .. key } }
  end,

  -- Only the DeepSeek models, since this provider exists for the padding.
  list_models = function()
    return {}
  end,

  models = {
    {
      prefixes = { "deepseek-v4.1-flash" },
      tier = "medium",
      default = true,
      supports_thinking = true,
      supports_vision = true,
      context_window = 1000000,
      max_output_tokens = 384000,
      pricing = { input = 0.15, output = 0.6, cache_write = 0.0, cache_read = 0.003 },
    },
    {
      prefixes = { "deepseek-v4-pro" },
      tier = "strong",
      default = true,
      supports_thinking = true,
      supports_vision = false,
      context_window = 1000000,
      max_output_tokens = 384000,
      pricing = { input = 0.66, output = 1.98, cache_write = 0.0, cache_read = 0.022 },
    },
  },

  build_body = function(_, body, model, _)
    pad_reasoning_content(body, model)
    return body
  end,

  -- GET /usage answers { rolling, weekly, monthly } windows, each with a
  -- percentage and an RFC 3339 reset time. Maki's usage modal (/usage) shows
  -- them as the 5-hour, weekly and monthly subscription quotas.
  fetch_usage = function(ctx)
    local body, err = ctx.get_json("/usage")
    if err then
      return nil, err
    end
    local usage = body and body.usage
    if not usage then
      return nil
    end
    local windows = {
      { key = "rolling", label = "5-hour" },
      { key = "weekly", label = "Weekly" },
      { key = "monthly", label = "Monthly" },
    }
    local limits = {}
    for _, window in ipairs(windows) do
      local w = usage[window.key]
      if w then
        table.insert(limits, {
          label = window.label,
          percentage = w.percent,
          reset_at = w.resetsAt,
          detail = w.status and w.status ~= "ok" and ("status: " .. w.status) or nil,
        })
      end
    end
    return { plan = "OpenCode Go", limits = limits }
  end,
})
