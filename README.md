# maki-config

My [Maki](https://maki.sh) customizations in one place: settings, permission
rules, and Lua plugins. Clone it on a new machine and you get everything back.

## What's inside

| Path | Role |
| --- | --- |
| `init.lua` | Settings (`always_yolo`) and plugin loading |
| `permissions.toml` | Bash/shell permission rules |
| `plugin.toml` | Permissions for the Lua files in this directory |
| `pack-lock.json` | Pins the external `stress-test-user-feature` skill package |
| `lua/relance.lua` | `/relance`: auto-relaunch driven by the project's `suivi.md` |
| `lua/ocgo.lua` | `ocgo` provider: OpenCode Go + the DeepSeek V4 thinking-mode fix |
| `lua/tps.lua` | Last-turn output speed (`tok/s`) under the chat input |
| `lua/autocompact.lua` | Auto-compaction at 30% of the context window, and an automatic resume afterwards |
| `lua/jobs.lua` | Managed background jobs (`bg_run`, `bg_status`, `bg_logs`, `bg_wait`, `bg_kill`) and `/jobs` |
| `lua/handoff.lua` | `/handoff`: one feature at a time, targeted tests only, human validation |
| `plugin/ocgo.lua` | Package entry point, so the repo also installs as a Maki package |
| `plugin/tps.lua` | Package entry point for the speed counter |
| `plugin/autocompact.lua` | Package entry point for auto-compaction |
| `plugin/jobs.lua` | Package entry point for background jobs |
| `plugin/relance.lua` | Package entry point for `/relance` |
| `plugin/handoff.lua` | Package entry point for handoff mode |
| `tests/resume-matrix.sh` | Proof of the resume path: five isolated Maki runs, expected matrix in the header |
| `commands/humanizer.md` | `/user:humanizer <text>` — wraps the `humanizer` skill |
| `skills/chrome-devtools-axi/SKILL.md` | `chrome-devtools-axi` browser skill, imported from the pi setup |
| `commands/chrome-devtools-axi.md` | `/user:chrome-devtools-axi <tâche>` — invokes that skill |
| `skills/lavish/SKILL.md` | `lavish` skill: HTML artifacts reviewed and annotated via `npx -y lavish-axi` |
| `commands/lavish.md` | `/user:lavish <ce que l'artefact doit montrer>` — invokes that skill |
| `commands/stress-test-user-feature.md` | `/user:stress-test-user-feature <feature>` — invokes the external skill |

## Install

### Option A — clone the whole config (recommended)

```bash
git clone https://github.com/Anhydrite/maki-config.git ~/.config/maki
```

That is it: `init.lua` loads the plugins, `plugin.toml` grants their
permissions, and `permissions.toml` comes along. Start Maki and pick the
provider:

```
/model ocgo/deepseek-v4.1-flash
```

The `ocgo` provider reuses the OpenCode Go key already saved by Maki. If it is
not there yet:

```bash
maki auth login opencode-go
```

To update, `git -C ~/.config/maki pull`. To add a new customization, edit
`lua/<name>.lua` and commit from that directory.

> `~/.config/maki` must not already exist (or move it aside first). If you
> already have a `~/.maki/`, Maki reads that one first and this clone is
> ignored.

### Option B — install it as a Maki package

If you want to keep your own `init.lua` and only pull the plugins, declare the
repo as a package in the global `~/.config/maki/init.lua`:

```lua
maki.pack.add({
  { src = "https://github.com/Anhydrite/maki-config", version = "v0.2.0" },
})
```

`plugin/ocgo.lua` is the entry point; `lua/ocgo.lua` is the module it
requires. Restart Maki, accept the install, then approve the permissions prompt
(`fs_read`, `net` limited to `opencode.ai`, `agent` for `/compact`). In this
mode the settings in `init.lua` (such as `always_yolo` and
`agent.compaction_buffer`) are **not** applied — only the plugins are, and
auto-compaction then falls back to its own defaults.

Do not combine the two options: the config clone already loads `lua/ocgo.lua`,
and installing the package on top registers the `ocgo` provider twice.

To update a managed install: `/packupdate maki-config`.

## What the `ocgo` provider fixes

DeepSeek V4 in thinking mode requires `reasoning_content` on every assistant
turn that made a tool call. The generic OpenCode provider only sends it for
turns that actually produced thinking, so a tool-only turn without reasoning
poisons the next request:

```
API error (400): The `reasoning_content` in the thinking mode must be passed
back to the API.
```

`lua/ocgo.lua` registers a custom provider on the same Zen Go endpoint that:

- back-fills `reasoning_content = ""` on assistant turns that have none
  (the same remedy Maki's bundled `deepseek` provider applies),
- sends the `x-opencode-session` header Zen requires,
- forwards thinking as `reasoning_effort` (adaptive → `medium`),
- reads the existing `opencode-go` credentials, so there is no second key.

Models: `ocgo/deepseek-v4.1-flash` (medium) and `ocgo/deepseek-v4-pro`
(strong). The built-in `opencode-go` provider is left untouched; switch back
whenever you want.

## Usage and speed

`/usage` (the Maki usage modal) shows the OpenCode Go subscription windows
queried from `GET /zen/go/v1/usage`:

- **5-hour** — the rolling window
- **Weekly**
- **Monthly**

Each row shows the percentage used and when it resets. The modal also keeps
Maki's own session totals and per-model breakdown.

`lua/tps.lua` reports the last turn's output speed (`42.3 tok/s`) in the hint
line under the chat input. There is no per-stream hook for plugins, so it
measures `TurnStart` → `TurnEnd` wall time minus the time tools ran
(`ToolDone.duration_ms`): generation plus network/queueing. `os.time()` has
one-second resolution, so very short turns read rough.

## Auto-compaction

Maki compacts by itself only once the context reaches
`context_window - agent.compaction_buffer`, and that buffer is capped at 50%
of the window, so the earliest native trigger is half the context.
`lua/autocompact.lua` ports the idea of
[pi-auto-compact](https://github.com/capyup/pi-auto-compact) to Maki: it
watches `maki.session.read()` and runs the built-in `/compact` command once
the context crosses a configurable share, 30% by default.

It checks at the end of every run (`TurnEnd`), when a tab becomes idle, and
when a session is focused (startup and resume). Maki queues a `/compact`
issued while the agent is streaming, so the run is never aborted: the
compaction happens at the next run boundary, before the next prompt.

That boundary is also where the agent used to stop: the compaction lands
between two turns, so the tab sits idle until the human types again. Measured
2026-10-25 in a real session, turn end 13:50:22, compaction done 13:50:44,
next work 14:03:11 — a prompt. So once the compaction reports back
(`CompactionDone`), the plugin posts a resume note with
`maki.session.notify(..., { wake = true })` and the agent carries on with the
work in flight, the way pi-auto-compact does.

Three things keep that honest:

- a manual `/compact` never resumes: the user asked for the summary, not for
the work to carry on, so no flag is set and nothing is posted;
- a turn that ended with Esc (`cancelled` / `dropped`) never resumes, even if
Maki's own trigger compacted afterwards;
- a run already in flight, a prompt the user queued, or a half-written prompt
in the input receives the note without a wake: waking on top of it would buy
a second turn nobody asked for. Two compactions inside
`resume_min_gap_secs` post one note, not two.

Only the focused session is compacted, because `maki.api.run_command` always
targets the focused tab. Background tabs keep Maki's native trigger.
`init.lua` also sets `agent.compaction_buffer = "50%"`, the earliest native
trigger, as a backstop when the plugin is off or a run is headless. A plugin
threshold above 50% is therefore superseded by that backstop.

```
/auto-compact              # status: context, threshold, resume, guidance
/auto-compact 35           # compact at 35% of the window (current process)
/auto-compact tokens 200000
/auto-compact instructions Keep the repro steps and failing test names.
/auto-compact resume off   # or "on": wake the agent after a compaction
/auto-compact simulate     # self-test: fire CompactionDone, no summarising
/auto-compact off          # or "on"
/auto-compact reset        # back to the defaults from init.lua
```

Settings are in-memory, so a change made with `/auto-compact` lasts until
Maki restarts. Persist one by editing the `setup` call in `init.lua`:

```lua
require("autocompact").setup({ percent = 30, min_regrow_percent = 10, resume = true })
```

The `keep-recent` / `keep-bookends` / `summarize-all` strategies from the pi
extension are not ported: Maki's summarizer owns the transcript layout and
exposes no equivalent knob.

Proof, without waiting for a real 300k-token compaction:

```bash
bash tests/resume-matrix.sh   # 5 short runs, expected matrix in the header
```

## Background jobs

`lua/jobs.lua` gives the agent a managed alternative to `bash` for long-running
commands: scans, builds, servers, migrations, long test suites. The command
returns immediately with a job id, while stdout and stderr go to a durable log.

| Tool | Purpose |
| --- | --- |
| `bg_run` | Start a command in the background (`command`, optional `description`, `workdir`, `timeout_secs`, `wake`) |
| `bg_status` | List jobs or show one job in detail |
| `bg_logs` | Tail a job's log (`lines`, default 80) |
| `bg_wait` | Wait for a job, bounded by `timeout_secs` (default 60) |
| `bg_kill` | SIGKILL a running job |

A job is owned by the session it was started from: it survives `/reload` and
dies when that session ends. There is no detached daemon, so a job does not
outlive Maki itself. Metadata and logs live under
`<state_dir>/jobs/` (`~/.local/state/maki/jobs/` by default), in `index.json`
and one `<id>.log` per job. The index keeps the 50 most recent records; running
jobs are never pruned.

From the input bar:

```text
/jobs              # list jobs
/jobs <id>         # open one job's log
/jobs clear        # remove finished jobs and their logs
```

Completion is reported through `maki.notify` (desktop notification with the
`notifications = "notify"` setting in `init.lua`). Pass `wake = true` to
`bg_run` to also wake the originating session with the completion note; it
costs a turn, so it is off by default.

Permissions: the plugin needs `fs_write` and `run` in `plugin.toml`. `bg_run`
declares `permission_scopes = "command"`, so it has its own `[bg_run]` rules in
`permissions.toml`; it does **not** inherit `[bash]` rules. With
`always_yolo = true` (the default here) no prompt is shown, so treat `bg_run`
as equivalent to `bash` when deciding what this config may run.

## Handoff mode

`/handoff` adds a third way of working next to build and plan (Maki 0.7.0 has
no native mode slot, so the plugin emulates it; it does not appear in the Tab
cycle). The point is one feature, one request, and a validation handed back to
the human instead of the agent claiming the suite is green.

```text
/handoff                 # toggle
/handoff on              # arm
/handoff off             # disarm, clears a pending unlock
/handoff status          # current state
/handoff allow-tests     # allow ONE blocked test command
/handoff check <cmd>     # show the classifier verdict, runs nothing
```

While it is on, a system-prompt block tells the agent to skip planning and full
CI, change only what was asked, and run only the test that change touches
(one file, a `::nodeid`, or `-k` on a named file). Self-validation is read-only
plus lint/format, and the turn must end with an "À valider" block listing what
was and was not run.

A bash input layer enforces the test rule. It blocks whole-suite and
whole-project commands: `pytest` with no file or node id, bare `make`,
`make test`, `make all`, `make doc`, `make docker-ci`, `npm test`, `cargo test`,
`go test`, `tox`, `ctest`, and the other runners listed in the classifier.
`make format`, `make lint`, `ruff`, and a targeted test file or node id pass.
A blocked command returns a short reason to the model, which proposes the
targeted test instead. `/handoff check <cmd>` shows the same verdict without
running anything, which is the quick way to debug a false positive.

When a broader run is genuinely needed, `/handoff allow-tests` unlocks exactly
one blocked command; the next one is blocked again. The status line shows
`handoff tests débloqués (1)` while the unlock is pending.

The `on` flag persists in `~/.local/state/maki/handoff.json`, so `/reload` and
a restart keep the mode armed; only `/handoff off` clears it. The one-command
unlock stays in memory and is lost on reload.

Limits: the hook covers `bash` only. `code_execution`, MCP shells, and other
tools that start processes (like the `bg_run` job runner) are not intercepted
(the prompt forbids them, but there is no hard guarantee), and a line typed
with `!` in the input bypasses it on purpose, since the human may always run
what they want.

## Relance mode

`/relance` wakes the agent after each turn while the project ledger still holds
unfinished work. The ledger is the arbiter, never the transcript: a `REQ-…` row
is done when its state cell starts with `fait` (`fait, publié` passes) and a
checkbox is done when it is `[x]`.

```text
/relance init            # create docs/suivi.md with the template and the rules
/relance                 # arm (never disarms)
/relance off             # stop
/relance status          # which file, how many lines left, strikes
/relance 20              # cap at 20 relaunches (default: no cap)
/relance path/to/suivi.md  # pick another ledger
```

`/relance init` only writes when no ledger exists yet: it searches the usual
candidates from the working directory upwards (`suivi.md`, `SUIVI.md`,
`docs/design/SUIVI.md`, `docs/suivi.md`, …) and refuses to overwrite one. The
created file documents the two accepted shapes, the state vocabulary (`fait`,
`terminé`, `livré`… are done; `décision`/`arbitrage` and `attente — publication`
are blocked and get raised as questions), and the rule that the turn doing the
work updates its own row. Its example identifiers (`REQ-AAAAMMJJ-NN`) are not
counted, so a fresh ledger does not launch a loop until a real line is written.

Guards, in order: no unfinished line, cancelled turn, two relaunches without the
file changing, then the optional cap. Arming is written to
`~/.local/state/maki/relance/state.json`, so it survives `/reload`, a restart
and an auto-compaction. The file also records `runs` and the ledger `path` after
every relaunch, so it tells the truth about what happened.

The loop never takes the floor from you: if the session is still `working`, has
a queued prompt, or has text in the input box, it steps aside — but it retries
every 3 s instead of going silent, and after 40 attempts it only slows down to
15 s rather than stopping: waiting is not a reason to end the loop. It also wakes
on its own when the floor comes back — `SessionStatusChanged` to `idle` and
`InputChanged` both reset the counter and call `step` at once, which covers the
`/btw` case where the main session receives no `TurnEnd` while the parallel
agent answers.

## Commands

`commands/humanizer.md` exposes `/user:humanizer <text>`: it loads the
[`humanizer`](https://github.com/blader/humanizer) skill and rewrites the text
without the usual AI tells. Custom commands are namespaced by scope in Maki —
`/user:` for this directory, `/project:` for `.maki/commands/` — so the short
`/humanizer` does not resolve.

The skill itself is not vendored here. Install it once per machine:

```bash
mkdir -p ~/.agents/skills/humanizer
curl -fsSL https://raw.githubusercontent.com/blader/humanizer/main/SKILL.md \
  -o ~/.agents/skills/humanizer/SKILL.md
```

Restart Maki after adding or changing a command: commands are discovered at
launch, not by `/reload`.

## Skills

`skills/chrome-devtools-axi/SKILL.md` is a copy of the
[`chrome-devtools-axi`](https://github.com/kunchenguid/chrome-devtools-axi)
skill from the pi setup, so cloning this config also gives Maki the browser
tool outside pi. The skill is a pointer: the CLI itself is invoked as
`npx -y chrome-devtools-axi ...`, so nothing else is vendored here.

Maki looks for skills in this order, and the last one found wins on a name
clash:

1. `~/.config/maki/skills/` (this repo)
2. `~/.claude/skills/`, `~/.config/opencode/skills/`, `~/.agents/skills/`
3. the project's `.maki/skills/`, `.claude/skills/`, `.opencode/skills/`,
   `.agents/skills/`, walking up to the git root

On a machine where the `skills` CLI already installed it, the
`~/.agents/skills/chrome-devtools-axi` copy is the one Maki loads, because it
comes last; this copy is the portable fallback. To refresh it after an
upstream update:

```bash
cp ~/.agents/skills/chrome-devtools-axi/SKILL.md \
  skills/chrome-devtools-axi/SKILL.md
```

Maki does not show skills in the UI and does not turn them into slash
commands (pi does when `enableSkillCommands` is on). The agent sees them only
through the `skill` tool. `commands/chrome-devtools-axi.md` is the visible
entry point, `/user:chrome-devtools-axi <tâche>`, on the same pattern as the
`humanizer` command: it asks the agent to load the skill first. Custom
commands are discovered at launch, not by `/reload`, so restart Maki after
adding or changing one.

| Skill | Command |
| --- | --- |
| `chrome-devtools-axi` | `/user:chrome-devtools-axi <tâche>` |
| `humanizer` | `/user:humanizer <texte>` |
| `stress-test-user-feature` | `/user:stress-test-user-feature <feature>` |

`stress-test-user-feature` is not vendored here. `init.lua` declares
[`Anhydrite/stress-test-user-feature`](https://github.com/Anhydrite/stress-test-user-feature)
as a Maki package, and a custom loader syncs its `SKILL.md` and `references/`
into `skills/stress-test-user-feature/` at startup. The package asks for
`fs_read` and `fs_write` on first install; approve it once. `pack-lock.json`
pins the revision. The skill maps a feature, defines proof-of-use criteria,
builds a test protocol, executes it, and reports a verdict with evidence. It
presents the report in the conversation only; it proposes permanent tests and
fixes but does not modify code until the user explicitly agrees.

## Adding a customization

1. Put the code in `lua/<name>.lua` (it uses the global `maki` API).
2. `require("<name>")` from `init.lua`.
3. If it needs reading files, network, processes… grant it in `plugin.toml`
   (a key not named there is denied in a package install, and defaults to
   granted for a hand-written `plugin.toml`, so be explicit).
4. To make the same code available through the package install, add a one-line
   `plugin/<name>.lua` that requires the module.
5. Commit and push. Other machines: `git pull` or `/packupdate maki-config`.

## Security notes

- No secret is stored in this repo. Provider keys live in
  `~/.local/state/maki/auth/` (mode 0600) and stay out of Git.
- `init.lua` enables `always_yolo`, which skips permission prompts. Keep that
  in mind before sharing a machine where this config is active.

## License

MIT
