// opencode plugin: mirrors the Claude Code and Codex hooks onto opencode's
// plugin API, so the tmux status icon and the sleep inhibitor see opencode
// sessions too.
//
// Register it in opencode.json:
//   { "plugin": ["/absolute/path/to/tmux-ai-usage/plugins/opencode.js"] }

import { spawn } from "node:child_process"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "..", "scripts", "ai-activity")

// The plugin runs inside the opencode process, so its PID is the owner the
// pruner should watch -- no need to guess by walking the process tree.
function mark(action, sessionID) {
  if (!sessionID) return

  try {
    const child = spawn(
      SCRIPT,
      ["--agent", "opencode", "--pid", String(process.pid), action, sessionID],
      { stdio: "ignore", detached: true },
    )
    child.on("error", () => {})
    child.unref()
  } catch {
    // Never let status decoration break a session.
  }
}

export const AiUsageActivity = async () => ({
  "chat.message": async ({ sessionID }) => mark("begin", sessionID),
  "tool.execute.before": async ({ sessionID }) => mark("begin", sessionID),
  "tool.execute.after": async ({ sessionID }) => mark("begin", sessionID),
  event: async ({ event }) => {
    switch (event.type) {
      case "session.idle":
      case "session.error":
      case "session.deleted":
        mark("end", event.properties?.sessionID)
        break
    }
  },
})
