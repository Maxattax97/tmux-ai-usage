# tmux-ai-usage

Minimal tmux plugin that shows estimated AI usage remaining as a single percent,
prefixed with an icon while an agent is actively working:

```text
● 73%
```

It intentionally keeps the status output minimal.

## Install

### TPM

```tmux
set -g @plugin 'yourname/tmux-ai-usage'
```

Then reload tmux and install plugins with `prefix + I`.

### Manual

Clone this repository into your tmux plugins directory and source `ai_usage.tmux` from `.tmux.conf`:

```tmux
run-shell '~/.tmux/plugins/tmux-ai-usage/ai_usage.tmux'
```

## Requirements

- `tmux`
- Claude Code for `claude`, Codex for `codex`, opencode for activity tracking
- Optional, for sleep inhibition: `caffeinate` (macOS, built in) or
  `systemd-inhibit` (Linux, part of systemd)

## Usage

For the `claude` provider, configure Claude Code to refresh the cache that tmux reads:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.tmux/plugins/tmux-ai-usage/scripts/claude-statusline-cache"
  }
}
```

If you installed manually outside TPM, point `command` at your local checkout path instead.

To show the active icon and keep the machine awake while Claude Code is working,
register the activity hooks in the same settings file:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "~/.tmux/plugins/tmux-ai-usage/scripts/ai-activity begin" }] }
    ],
    "PreToolUse": [
      { "hooks": [{ "type": "command", "command": "~/.tmux/plugins/tmux-ai-usage/scripts/ai-activity begin" }] }
    ],
    "PostToolUse": [
      { "hooks": [{ "type": "command", "command": "~/.tmux/plugins/tmux-ai-usage/scripts/ai-activity begin" }] }
    ],
    "Notification": [
      { "hooks": [{ "type": "command", "command": "~/.tmux/plugins/tmux-ai-usage/scripts/ai-activity end" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.tmux/plugins/tmux-ai-usage/scripts/ai-activity end" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "~/.tmux/plugins/tmux-ai-usage/scripts/ai-activity end" }] }
    ]
  }
}
```

`PreToolUse` and `PostToolUse` bracket every tool call, so a long turn keeps
refreshing its own marker rather than aging out.

### Codex

Codex reads lifecycle hooks from `~/.codex/hooks.json`. Merge the shipped
snippet into yours, or symlink it if you have no other codex hooks:

```sh
ln -s ~/.tmux/plugins/tmux-ai-usage/hooks/codex-hooks.json ~/.codex/hooks.json
```

It wires `UserPromptSubmit`, `PreToolUse`, and `PostToolUse` to `begin`, and
`PermissionRequest`, `Stop`, `Interrupt`, and `SessionEnd` to `end`. Codex asks
you to review new hooks the next time it starts; they do not run until trusted.
The commands resolve this checkout through `$AI_USAGE_HOME`, falling back to
`~/.tmux/plugins/tmux-ai-usage`, so set `AI_USAGE_HOME` if you installed it
somewhere else.

### opencode

opencode takes plugins rather than hook commands. Add this one to
`~/.config/opencode/opencode.json` with an absolute path:

```json
{
  "plugin": ["/home/you/.tmux/plugins/tmux-ai-usage/plugins/opencode.js"]
}
```

It marks work on `chat.message` and around every tool call, and clears the
marker on the `session.idle`, `session.error`, and `session.deleted` events.
Because the plugin runs inside the opencode process, it reports that PID
directly instead of relying on the process-tree walk.

Direct script use:

```tmux
set -g status-right "#(~/.tmux/plugins/tmux-ai-usage/scripts/ai-usage)"
```

Option-backed format installed by the plugin:

```tmux
set -g status-right "#{E:@ai_usage}"
```

`#{ai_usage}` is not exposed directly because tmux custom format expansion is option-backed here.

Example with a Nerd Font icon in your own status config:

```tmux
set -g status-right '#[default]\
#[fg=colour236]#[fg=colour255]#[bg=colour236] 󰚩 #{E:@ai_usage}'
```

That renders like:

```text
󰚩 73%
```

## Options

```tmux
set -g @ai_usage_provider "auto"     # auto | claude | codex
set -g @ai_usage_interval "60"
set -g @ai_usage_unknown "?"
set -g @ai_usage_active_icon "●"     # shown while any agent is working
set -g @ai_usage_idle_icon ""        # shown when all agents are idle
set -g @ai_usage_active_ttl "300"    # seconds before an ownerless marker counts as idle
set -g @ai_usage_active_max "3600"   # hard ceiling on how long one marker may hold sleep off
set -g @ai_usage_inhibit_sleep "on"  # on | off
```

The icon is also available on its own:

```tmux
set -g status-right "#{E:@ai_usage_active} #{E:@ai_usage}"
```

Note that `#{E:@ai_usage}` already includes the icon, so combining both prints it
twice unless you set `@ai_usage_active_icon` to an empty string.

## Provider Behavior

### `claude`

Uses Claude Code's own `statusLine` JSON input as the source of truth. The helper script:

```sh
~/.tmux/plugins/tmux-ai-usage/scripts/claude-statusline-cache
```

reads Claude Code's stdin payload, stores `rate_limits.five_hour.used_percentage` in a cache file, and the tmux script displays `100 - used_percentage`.

### `codex`

Reads the newest local Codex rollout session JSONL in `~/.codex/sessions/**/rollout-*.jsonl`, extracts the latest `token_count` event with `rate_limits.primary.used_percent`, and displays `100 - used_percent` for the 5-hour window.

### `auto`

The default behavior. The plugin prefers Claude Code data first, then falls back to Codex if no recent Claude rate-limit cache is available.

## Activity and Sleep Inhibition

Each working agent session gets a marker file in:

```text
${XDG_CACHE_HOME:-$HOME/.cache}/tmux-ai-usage/active/
```

`ai-activity begin` creates one, `ai-activity end` removes it. While at least one
marker exists the plugin holds the system awake — `caffeinate -i` on macOS,
`systemd-inhibit --what=idle:sleep` on Linux — and drops the inhibitor as soon as
every agent is idle. Idle *system* sleep is what is blocked; the display is still
free to turn off. If neither helper is installed, the icon still works and sleep
inhibition is silently skipped.

Each marker records the PID of the agent process that owns it, found by walking
up from the hook to the first ancestor named after the agent, or reported
directly by an in-process plugin. A marker whose owner is still
alive stays active no matter how long the turn runs, so an hour-long tool call
never lets the machine drop to sleep underneath it. When the owner exits, the
marker goes with it on the next poll.

`@ai_usage_active_ttl` (5 minutes) is the fallback for markers whose owner could
not be identified — those are retired once untouched for that long.

A live owner is not by itself proof of work: interrupting a turn with `Esc` fires
no `Stop` hook, leaving a marker behind on a process that is alive but idle.
`@ai_usage_active_max` (1 hour) caps that, so the worst case is an hour of extra
wakefulness rather than an indefinite one. Any hook on that session resets the
clock, and the next `Stop` clears the marker outright.

Every status poll reconciles all of this, so the inhibitor is released even if no
hook ever fires again. To see what is currently holding it:

```sh
ls ${XDG_CACHE_HOME:-$HOME/.cache}/tmux-ai-usage/active/
```

Claude Code, Codex, and opencode are wired up. Markers are namespaced per agent,
so the icon is active whenever *any* of them is working and sleep is only
released once they are all idle. Another agent can join with:

```sh
scripts/ai-activity --agent someagent [--pid "$owner_pid"] begin "$session_id"
```

`--pid` is for agents that can report their own process; otherwise the owner is
found by walking up the process tree looking for one named after the agent.

Note that this is independent of `@ai_usage_provider`, which only decides whose
usage percent to display. opencode has no single rate-limit window to report, so
it contributes activity but not a percent.

## Cache

Output is cached for `@ai_usage_interval` seconds at:

```text
${XDG_CACHE_HOME:-$HOME/.cache}/tmux-ai-usage/tmux-ai-usage-status.txt
```

The plugin also stores cache metadata alongside it so option changes invalidate stale cached output.

For Claude Code, the statusline helper stores the latest 5-hour window payload at:

```text
${XDG_CACHE_HOME:-$HOME/.cache}/tmux-ai-usage/tmux-ai-usage-claude-rate-limits.txt
```

## Unavailable Data

If provider data is unavailable, the plugin outputs:

```text
?
```

## Notes

For the `claude` provider, the displayed value is derived from Claude Code's own `rate_limits.five_hour.used_percentage` statusline field. For the `codex` provider, it is derived from Codex's local `token_count` session events with `rate_limits.primary.used_percent`.
