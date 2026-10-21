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
| `plugin/ocgo.lua` | Package entry point, so the repo also installs as a Maki package |

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
  { src = "https://github.com/Anhydrite/maki-config", version = "v0.1.0" },
})
```

`plugin/ocgo.lua` is the entry point; `lua/ocgo.lua` is the module it
requires. Restart Maki, accept the install, then approve the permissions prompt
(`fs_read`, `net` limited to `opencode.ai`). In this mode the settings in
`init.lua` (such as `always_yolo`) are **not** applied — only the plugins are.

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
