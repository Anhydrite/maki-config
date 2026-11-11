-- Managed background jobs for maki.
--
-- Tools: bg_run, bg_status, bg_logs, bg_wait, bg_kill
-- Command: /jobs [id|clear]
--
-- Jobs are shell processes started by maki.fn.jobstart. Their stdout and
-- stderr are appended to a durable log under <state_dir>/jobs, and their
-- metadata is kept in <state_dir>/jobs/index.json so a /reload can adopt
-- the jobs that are still running.
--
-- Lifetime: a job is owned by the session it was started from (scope
-- { session = <id> }), so it survives /reload and dies when that session
-- ends. Without an interactive session the job is plugin-scoped instead.

local MAX_RECORDS = 50
local DEFAULT_LOG_LINES = 80
local MAX_LOG_LINES = 1000
local MAX_OUTPUT_BYTES = 40 * 1024

local state_dir = maki.env.state_dir()
if not state_dir then
  maki.log.warn("jobs: no state dir; plugin disabled")
  return
end

local jobs_dir = maki.fs.joinpath(state_dir, "jobs")
local index_path = maki.fs.joinpath(jobs_dir, "index.json")

local records = {}
local timers = {}
local seq = 0

local function now()
  return os.time()
end

local function fmt_time(t)
  if not t then
    return "?"
  end
  if os.date then
    return os.date("%Y-%m-%d %H:%M:%S", t)
  end
  return tostring(t)
end

local function one_line(s, max)
  s = tostring(s or ""):gsub("%s+", " ")
  if #s > max then
    return s:sub(1, max - 3) .. "..."
  end
  return s
end

local function duration(secs)
  secs = math.max(0, math.floor(tonumber(secs) or 0))
  if secs < 60 then
    return secs .. "s"
  end
  if secs < 3600 then
    return string.format("%dm%02ds", math.floor(secs / 60), secs % 60)
  end
  return string.format("%dh%02dm", math.floor(secs / 3600), math.floor((secs % 3600) / 60))
end

local function ensure_dir()
  local st = maki.fs.metadata(jobs_dir)
  if st and st.is_dir then
    return true
  end
  local ok, err = maki.fs.mkdir(jobs_dir, { parents = true })
  if not ok then
    maki.log.warn("jobs: mkdir " .. jobs_dir .. " failed: " .. tostring(err))
  end
  return ok
end

local function save()
  if not ensure_dir() then
    return
  end
  local encoded, err = maki.json.encode({ version = 1, jobs = records })
  if not encoded then
    maki.log.warn("jobs: encode failed: " .. tostring(err))
    return
  end
  local ok, werr = maki.fs.atomic_write(index_path, encoded)
  if not ok then
    maki.log.warn("jobs: write " .. index_path .. " failed: " .. tostring(werr))
  end
end

local function load()
  local text = maki.fs.read(index_path)
  if not text or text == "" then
    return
  end
  local data, err = maki.json.decode(text)
  if not data or type(data) ~= "table" or type(data.jobs) ~= "table" then
    maki.log.warn("jobs: ignoring unreadable index: " .. tostring(err))
    return
  end
  for _, rec in ipairs(data.jobs) do
    if type(rec) == "table" and type(rec.id) == "string" and type(rec.command) == "string" then
      records[#records + 1] = rec
    end
  end
end

local function find(id)
  if type(id) ~= "string" then
    return nil
  end
  for _, rec in ipairs(records) do
    if rec.id == id then
      return rec
    end
  end
  return nil
end

local function current_session()
  local ok, sid = pcall(maki.session.current)
  if ok and type(sid) == "string" and sid ~= "" then
    return sid
  end
  return nil
end

local function stop_timer(id)
  local timer = timers[id]
  if timer then
    timer:stop()
    timers[id] = nil
  end
end

local function notify_completion(rec)
  local code = rec.exit_code and ("exit " .. tostring(rec.exit_code)) or "no exit code"
  local label = "finished"
  if rec.status == "killed" then
    label = "killed"
  elseif rec.exit_code and rec.exit_code ~= 0 then
    label = "failed"
  end
  local elapsed = duration((rec.ended_at or now()) - (rec.started_at or now()))
  local msg = string.format(
    "[bg] %s %s (%s) in %s - %s",
    one_line(rec.description or rec.command, 60),
    label,
    code,
    elapsed,
    rec.id
  )

  local level = (rec.status == "exited" and rec.exit_code == 0) and "info" or "warn"
  maki.notify(msg, level, { title = "jobs" })

  if rec.session and rec.session ~= "" then
    local ok, err = maki.session.notify(msg, { session = rec.session, wake = rec.wake == true })
    if not ok then
      maki.log.debug("jobs: session notify failed: " .. tostring(err))
    end
  end
end

local function finalize(rec, code, status)
  stop_timer(rec.id)
  if code ~= nil then
    rec.exit_code = code
  end
  local was_running = rec.status == "running"
  if was_running then
    rec.status = status or "exited"
    rec.ended_at = now()
  elseif status == "killed" and rec.status ~= "killed" then
    rec.status = "killed"
    rec.ended_at = rec.ended_at or now()
  end
  local should_notify = was_running and not rec.notified
  if should_notify then
    rec.notified = true
  end
  save()
  if should_notify then
    notify_completion(rec)
  end
end

local function arm_timeout(rec)
  stop_timer(rec.id)
  if rec.status ~= "running" or not rec.deadline then
    return
  end
  local ms = math.max(0, ((rec.deadline or 0) - now()) * 1000)
  timers[rec.id] = maki.defer_fn(function()
    timers[rec.id] = nil
    -- Timer callbacks must not yield; do the file I/O in a plugin task.
    maki.async.spawn(function()
      if rec.status ~= "running" then
        return
      end
      rec.timed_out = true
      maki.fn.jobstop(rec.job_id)
      finalize(rec, nil, "killed")
    end)
  end, ms)
end

local function read_tail(path, n)
  n = math.max(1, math.min(math.floor(tonumber(n) or DEFAULT_LOG_LINES), MAX_LOG_LINES))

  local tail_id = maki.fn.jobstart({ "tail", "-n", tostring(n), path }, { scope = "task" })
  if tail_id then
    local res = maki.fn.jobwait(tail_id, 5000)
    if res and res.exit_code == 0 and type(res.stdout) == "string" then
      return res.stdout
    end
  end

  local st = maki.fs.metadata(path)
  if st and st.size and st.size > 32 * 1024 * 1024 then
    return nil, "log is larger than 32 MiB and tail is unavailable"
  end

  local text, err = maki.fs.read(path)
  if not text then
    return nil, err
  end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  local out = {}
  for i = math.max(1, #lines - n + 1), #lines do
    out[#out + 1] = lines[i]
  end
  return table.concat(out, "\n")
end

local function clip(text, ctx, max_lines, max_bytes)
  text = text or ""
  if ctx and ctx:output_mode() == "full" then
    return text
  end
  max_lines = max_lines or DEFAULT_LOG_LINES
  max_bytes = max_bytes or MAX_OUTPUT_BYTES

  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end

  local truncated = false
  if #lines > max_lines then
    local out = {}
    for i = #lines - max_lines + 1, #lines do
      out[#out + 1] = lines[i]
    end
    lines = out
    truncated = true
  end

  local out = table.concat(lines, "\n")
  if #out > max_bytes then
    out = out:sub(#out - max_bytes + 1)
    truncated = true
  end
  if truncated then
    out = "... (truncated; use bg_logs with a larger lines value, or read the log path)\n" .. out
  end
  return out
end

local function status_text(rec)
  if rec.status == "running" then
    local secs = now() - (rec.started_at or now())
    if rec.job_id then
      local info = maki.fn.jobinfo(rec.job_id)
      if info and info.status == "running" and info.elapsed_secs then
        secs = info.elapsed_secs
      end
    end
    return "running " .. duration(secs)
  end
  if rec.status == "exited" then
    return "exited " .. tostring(rec.exit_code or "?")
  end
  if rec.status == "killed" then
    return "killed" .. (rec.exit_code and (" (exit " .. tostring(rec.exit_code) .. ")") or "")
  end
  return tostring(rec.status or "unknown")
end

local function new_id()
  while true do
    seq = seq + 1
    local id = string.format("bg-%d-%d", now(), seq)
    if not find(id) then
      return id
    end
  end
end

local function prune()
  local kept = {}
  local removed = 0
  for _, rec in ipairs(records) do
    if #kept < MAX_RECORDS or rec.status == "running" then
      kept[#kept + 1] = rec
    else
      removed = removed + 1
      maki.fs.rm(rec.log, { force = true })
    end
  end
  if removed > 0 then
    records = kept
    save()
  end
end

local function start_job(input)
  local command = input.command
  if type(command) ~= "string" or command:match("^%s*$") then
    return nil, "command is required"
  end
  if not ensure_dir() then
    return nil, "cannot create " .. jobs_dir
  end

  local id = new_id()
  local log = maki.fs.joinpath(jobs_dir, id .. ".log")
  local cwd = input.workdir or maki.uv.cwd()
  local header = string.format(
    "# job: %s\n# description: %s\n# cwd: %s\n# started: %s\n# command: %s\n\n",
    id,
    one_line(input.description or command, 120),
    tostring(cwd),
    fmt_time(now()),
    command
  )
  local ok, werr = maki.fs.write(log, header)
  if not ok then
    return nil, "cannot write log: " .. tostring(werr)
  end

  local sid = current_session()
  local timeout = tonumber(input.timeout_secs)
  local rec = {
    id = id,
    command = command,
    cwd = cwd,
    description = input.description or one_line(command, 80),
    log = log,
    session = sid,
    wake = input.wake == true,
    started_at = now(),
    status = "running",
  }
  if timeout and timeout > 0 then
    rec.timeout_secs = math.min(math.floor(timeout), 86400)
    rec.deadline = rec.started_at + rec.timeout_secs
  end

  local job_id, err = maki.fn.jobstart(command, {
    cwd = input.workdir,
    stdout = log,
    stderr = log,
    scope = sid and { session = sid } or "plugin",
    name = "bg:" .. id,
    tail = 0,
    on_exit = function(_, code)
      -- The job callback must not yield; finalize writes the index and notifies.
      maki.async.spawn(function()
        finalize(rec, code, rec.timed_out and "killed" or "exited")
      end)
    end,
  })
  if not job_id then
    maki.fs.rm(log, { force = true })
    return nil, err or "jobstart failed"
  end

  rec.job_id = job_id
  table.insert(records, 1, rec)
  save()
  arm_timeout(rec)
  prune()
  return rec
end

local function reattach(rec)
  if not rec.job_id then
    rec.status = "lost"
    rec.ended_at = rec.ended_at or now()
    rec.notified = true
    return
  end
  local info = maki.fn.jobinfo(rec.job_id)
  if not info then
    rec.status = "lost"
    rec.ended_at = rec.ended_at or now()
    rec.notified = true
    return
  end
  if info.status == "exited" then
    finalize(rec, info.exit_code, rec.status == "killed" and "killed" or "exited")
    return
  end
  maki.fn.jobattach(rec.job_id, {
    on_exit = function(_, code)
      maki.async.spawn(function()
        finalize(rec, code, rec.timed_out and "killed" or "exited")
      end)
    end,
  })
  arm_timeout(rec)
end

maki.api.register_tool({
  name = "bg_run",
  kind = "execute",
  description = [[Start a shell command as a managed background job and return immediately.

Use it for long-running work (scans, builds, servers, migrations, long test suites)
so the conversation can continue instead of blocking on `bash`. The command runs
through bash -c with stdout and stderr appended to a durable log file. You get a
job id for bg_status, bg_logs, bg_wait and bg_kill.

Jobs survive /reload and live until their session ends. Prefer `bash` for short,
synchronous commands; use `bg_run` when the command may outlive a normal tool call.]],
  schema = {
    type = "object",
    properties = {
      command = { type = "string", description = "Shell command to run (bash -c)", required = true },
      description = { type = "string", description = "Short label shown in status and completion notices" },
      workdir = { type = "string", description = "Working directory (default: session cwd)" },
      timeout_secs = {
        type = "integer",
        description = "Kill the job after this many seconds (default: no timeout, max 86400)",
        minimum = 1,
        maximum = 86400,
      },
      wake = {
        type = "boolean",
        description = "Wake the session with a completion note when the job finishes (default false)",
      },
    },
    required = { "command" },
  },
  permission = "run",
  permission_scopes = "command",
  handler = function(input, ctx)
    -- R1 (audit du 2026-11-11) : le mode handoff garde aussi les commandes de
    -- fond. Sans cet appel, `bg_run` était une porte ouverte sur la suite
    -- complète (mesuré : `bg_run("bash tests/run-impacted.sh")`).
    local okH, handoff = pcall(require, "handoff")
    if okH and type(handoff) == "table" and type(handoff.gate) == "function" then
      local refus = handoff.gate(input and input.command)
      if refus then
        return { llm_output = refus, is_error = true }
      end
    end
    local rec, err = start_job(input)
    if not rec then
      return { llm_output = "error: " .. tostring(err), is_error = true }
    end
    return {
      llm_output = string.format(
        "started %s: %s\nlog: %s\nid: %s",
        rec.id,
        one_line(rec.description, 80),
        rec.log,
        rec.id
      ),
    }
  end,
})

maki.api.register_tool({
  name = "bg_status",
  kind = "execute",
  description = [[List managed background jobs, or show one job in detail.

Returns id, status (running/exited/killed/lost), exit code, elapsed time,
description and log path. Call it after a `bg_run` or when a completion
notification mentions a job.]],
  schema = {
    type = "object",
    properties = {
      id = { type = "string", description = "Job id (omit to list every job)" },
    },
  },
  handler = function(input, ctx)
    if input.id then
      local rec = find(input.id)
      if not rec then
        return { llm_output = "error: no such job: " .. tostring(input.id), is_error = true }
      end
      local lines = {
        "id: " .. rec.id,
        "status: " .. status_text(rec),
        "description: " .. tostring(rec.description or ""),
        "command: " .. tostring(rec.command),
        "cwd: " .. tostring(rec.cwd or "?"),
        "log: " .. tostring(rec.log),
        "started: " .. fmt_time(rec.started_at),
      }
      if rec.ended_at then
        lines[#lines + 1] = "ended: " .. fmt_time(rec.ended_at)
      end
      if rec.exit_code ~= nil then
        lines[#lines + 1] = "exit_code: " .. tostring(rec.exit_code)
      end
      if rec.deadline then
        lines[#lines + 1] = "timeout: " .. duration(rec.timeout_secs or 0)
      end
      return { llm_output = table.concat(lines, "\n") }
    end

    if #records == 0 then
      return { llm_output = "No background jobs." }
    end

    local lines = { string.format("Background jobs (%d):", #records) }
    for _, rec in ipairs(records) do
      lines[#lines + 1] = string.format(
        "%s  %s  %s",
        rec.id,
        status_text(rec),
        one_line(rec.description or rec.command, 70)
      )
      lines[#lines + 1] = "  log: " .. tostring(rec.log)
    end
    return { llm_output = clip(table.concat(lines, "\n"), ctx, 200, MAX_OUTPUT_BYTES) }
  end,
})

maki.api.register_tool({
  name = "bg_logs",
  kind = "execute",
  description = [[Show the last lines of a managed background job's log.

Use it to inspect progress without waiting for the job to finish. The log
contains both stdout and stderr, starting with the job header.]],
  schema = {
    type = "object",
    properties = {
      id = { type = "string", description = "Job id", required = true },
      lines = {
        type = "integer",
        description = "Number of trailing lines to return (default 80, max 1000)",
        minimum = 1,
        maximum = 1000,
      },
    },
    required = { "id" },
  },
  handler = function(input, ctx)
    local rec = find(input.id)
    if not rec then
      return { llm_output = "error: no such job: " .. tostring(input.id), is_error = true }
    end
    local text, err = read_tail(rec.log, input.lines or DEFAULT_LOG_LINES)
    if not text then
      return { llm_output = "error: " .. tostring(err), is_error = true }
    end
    local header = string.format("job %s (%s) log: %s\n", rec.id, status_text(rec), rec.log)
    return {
      llm_output = clip(header .. text, ctx, (tonumber(input.lines) or DEFAULT_LOG_LINES) + 2, MAX_OUTPUT_BYTES),
    }
  end,
})

maki.api.register_tool({
  name = "bg_wait",
  kind = "execute",
  description = [[Wait for a managed background job to finish, then return its status and last lines.

Use it only when the next step depends on this job. Prefer doing other work
and calling bg_status/bg_logs later; waiting blocks the tool call. On timeout
the job keeps running and the tool reports that it is still running.]],
  schema = {
    type = "object",
    properties = {
      id = { type = "string", description = "Job id", required = true },
      timeout_secs = {
        type = "integer",
        description = "Maximum wait in seconds (default 60, max 600)",
        minimum = 1,
        maximum = 600,
      },
    },
    required = { "id" },
  },
  handler = function(input, ctx)
    local rec = find(input.id)
    if not rec then
      return { llm_output = "error: no such job: " .. tostring(input.id), is_error = true }
    end

    local waited = 0
    if rec.status == "running" and rec.job_id then
      local timeout = math.max(1, math.min(math.floor(tonumber(input.timeout_secs) or 60), 600))
      waited = timeout
      maki.fn.jobwait(rec.job_id, timeout * 1000)
      if rec.status == "running" then
        local info = maki.fn.jobinfo(rec.job_id)
        if info and info.status == "exited" then
          finalize(rec, info.exit_code, rec.timed_out and "killed" or "exited")
        end
      end
    end

    local text = read_tail(rec.log, 20) or ""
    local note = ""
    if rec.status == "running" then
      note = string.format("\n(still running after %s; it kept running)", duration(waited))
    end
    return {
      llm_output = clip(
        string.format("job %s: %s%s\n%s", rec.id, status_text(rec), note, text),
        ctx,
        25,
        8192
      ),
    }
  end,
})

maki.api.register_tool({
  name = "bg_kill",
  kind = "execute",
  description = [[Kill a running managed background job.

The job is stopped with SIGKILL. Its log and record stay available, so you
can still read the output with bg_logs. Killing an already finished job is
a no-op that reports its status.]],
  schema = {
    type = "object",
    properties = {
      id = { type = "string", description = "Job id", required = true },
    },
    required = { "id" },
  },
  permission = "run",
  handler = function(input, ctx)
    local rec = find(input.id)
    if not rec then
      return { llm_output = "error: no such job: " .. tostring(input.id), is_error = true }
    end
    if rec.status ~= "running" then
      return { llm_output = string.format("job %s is already %s", rec.id, status_text(rec)) }
    end

    rec.killed_by_user = true
    rec.status = "killed"
    rec.ended_at = now()
    rec.notified = true
    stop_timer(rec.id)
    maki.fn.jobstop(rec.job_id)
    save()
    return { llm_output = string.format("killed job %s", rec.id) }
  end,
})

local function open_text_window(title, text, height)
  local buf = maki.ui.buf({ scratch = true })
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
    buf:line(line)
  end

  local win = maki.ui.open_win(buf, {
    title = title,
    width = "80%",
    height = math.min(math.max(height or 10, 5), 30),
    focus = false,
    keys = { "q", "<Esc>" },
    footer = { { "q", "close" }, { "<Esc>", "close" } },
  })

  maki.async.spawn(function()
    while win:is_open() do
      local ev = win:recv(500)
      if not ev then
        break
      end
      if ev.type == "key" and (ev.key == "q" or ev.key == "<Esc>") then
        break
      end
    end
    if win:is_open() then
      win:close()
    end
  end)
end

maki.api.register_command({
  name = "/jobs",
  description = "List background jobs, show one log, or clear finished jobs (/jobs [id|clear])",
  nargs = "?",
  handler = function(opts)
    local arg = ((opts and opts.args) or ""):match("^%s*(.-)%s*$")

    -- Command handlers must not yield; do the reads/writes in a plugin task.
    maki.async.spawn(function()
      if arg == "clear" then
        local kept = {}
        local removed = 0
        for _, rec in ipairs(records) do
          if rec.status == "running" then
            kept[#kept + 1] = rec
          else
            removed = removed + 1
            maki.fs.rm(rec.log, { force = true })
          end
        end
        records = kept
        save()
        maki.ui.flash(string.format("removed %d finished job(s)", removed))
        return
      end

      if arg ~= "" then
        local rec = find(arg)
        if not rec then
          maki.ui.flash("no such job: " .. arg)
          return
        end
        local text, err = read_tail(rec.log, 200)
        if not text then
          maki.ui.flash("cannot read log: " .. tostring(err))
          return
        end
        open_text_window(
          string.format("Job %s - %s", rec.id, status_text(rec)),
          text,
          30
        )
        return
      end

      if #records == 0 then
        maki.ui.flash("no background jobs")
        return
      end

      local lines = {}
      for _, rec in ipairs(records) do
        lines[#lines + 1] = string.format(
          "%-22s %-14s %s",
          rec.id,
          status_text(rec),
          one_line(rec.description or rec.command, 80)
        )
        lines[#lines + 1] = "  " .. tostring(rec.log)
      end
      open_text_window("Background jobs", table.concat(lines, "\n"), #lines + 2)
    end)
  end,
})

local function boot()
  load()
  for _, rec in ipairs(records) do
    if rec.status == "running" then
      reattach(rec)
    end
  end
  prune()
  save()
end

-- Plugin load must not yield, and reading the index does.
maki.async.spawn(function()
  boot()
end)
