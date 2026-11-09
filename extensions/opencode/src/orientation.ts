// extensions/opencode/src/orientation.ts
// Generates session-start reorientation prompts to prevent compaction amnesia.

import { readLocalSessionMap } from "./sessions"
import type { SessionEntry } from "./types"

export function getOrientationReminder(sessionId?: string | null): string {
  if (sessionId) {
    const sessionKey = `opencode:${sessionId}`
    const map = readLocalSessionMap()
    const entry = map[sessionKey]
    if (typeof entry === "object" && entry.status !== "closed") {
      const workspacePath = entry.strand_path || entry.rifttree_path
      if (workspacePath) {
        const taskLabel = entry.task_id ? `for task '${entry.task_id}' ` : ""
        return (
          `[RHIZO CONTEXT ANCHOR: You have an active isolated workspace/strand ${taskLabel}at: ` +
          `${workspacePath}. Do not commit changes to the canonical repository root. ` +
          `Verify with 'git status' inside your workspace.]`
        )
      }
    }
  }

  return (
    `[RHIZO NOTICE: If this task was operating in an isolated workspace/strand, inspect active workspaces ` +
    `(e.g., via 'vine list' or checking ~/Development/workspaces/) to reorient ` +
    `yourself before making edits in the canonical repository root.]`
  )
}
