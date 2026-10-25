# maki-config

My [Maki](https://maki.sh) customizations in one place: settings, permission
rules, and Lua plugins. Clone it on a new machine and you get everything back.

## What's inside

| Path | Role |
| --- | --- |
| `init.lua` | Settings (`always_yolo`) and plugin loading |
| `permissions.toml` | Bash/shell permission rules |
| `plugin.toml` | Permissions for the Lua files in this directory |
| `lua/ocgo.lua` | `ocgo` provider: OpenCode Go + the DeepSeek V4 thinking-mode fix |
| `lua/tps.lua` | Last-turn output speed (`tok/s`) under the chat input |
| `lua/autocompact.lua` | Auto-compaction at 30% of the context window, and an automatic resume afterwards |
| `plugin/ocgo.lua` | Package entry point, so the repo also installs as a Maki package |
| `plugin/tps.lua` | Package entry point for the speed counter |
| `plugin/autocompact.lua` | Package entry point for auto-compaction |
| `tests/resume-matrix.sh` | Proof of the resume path: five isolated Maki runs, expected matrix in the header |
| `commands/humanizer.md` | `/user:humanizer <text>` — wraps the `humanizer` skill |
| `skills/chrome-devtools-axi/SKILL.md` | `chrome-devtools-axi` browser skill, imported from the pi setup |
| `commands/chrome-devtools-axi.md` | `/user:chrome-devtools-axi <tâche>` — invokes that skill |
| `skills/lavish/SKILL.md` | `lavish` skill: HTML artifacts reviewed and annotated via `npx -y lavish-axi` |
| `commands/lavish.md` | `/user:lavish <ce que l'artefact doit montrer>` — invokes that skill |

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
