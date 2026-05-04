# tmux-ai-usage

Minimal tmux plugin that shows estimated AI usage remaining as a single percent:

```text
73%
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
- `jq`
- Claude Code for `claude`

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
```

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

## Cache

Output is cached for `@ai_usage_interval` seconds at:

```text
${XDG_CACHE_HOME:-$HOME/.cache}/tmux-ai-usage/tmux-ai-usage-status.txt
```

The plugin also stores cache metadata alongside it so option changes invalidate stale cached output.

For Claude Code, the statusline helper stores the latest 5-hour window payload at:

```text
${XDG_CACHE_HOME:-$HOME/.cache}/tmux-ai-usage/tmux-ai-usage-claude-rate-limits.json
```

## Unavailable Data

If `jq` or provider data is unavailable, the plugin outputs:

```text
?
```

## Notes

For the `claude` provider, the displayed value is derived from Claude Code's own `rate_limits.five_hour.used_percentage` statusline field. For the `codex` provider, it is derived from Codex's local `token_count` session events with `rate_limits.primary.used_percent`.
