/**
 * pi-ear.ts — Native TypeScript Extension for Pi Coding Agent (pi.dev / @earendil-works/pi-coding-agent)
 *
 * Automatically loaded by Pi from ~/.pi/agent/extensions/*.ts (or project .pi/extensions/)
 * via jiti without compilation.
 *
 * Responsibilities:
 * 1. Automatically binds Pi session ID to Rhizo agent identity ("pi:<sessionId>" -> "<agent>").
 * 2. Injects RHIZO_SESSION_ID and RHIZO_AGENT_NAME into tool execution environments.
 * 3. Runs an asynchronous background ear streaming `rhizo listen <agent> 0`.
 * 4. Stimulates Pi's conversation turn loop when messages arrive.
 * 5. Handles urgent in-flight preemption for `--immediate` tasks.
 */

import { spawn, spawnSync } from "node:child_process"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import process from "node:process"

export interface RhizoMessagePayload {
  id: string
  from: string
  to: string
  type: string
  subject: string
  body: string
  urgency?: "immediate" | "soon"
  host?: string
  timestamp?: string
  reminders?: Reminder[]
}

export interface Reminder {
  id: string
  priority: "CRITICAL" | "HIGH" | "MED" | "LOW" | "INFO" | string
  scope?: string
  text?: string
  directive?: string
  target?: string
  author?: string
  created_at?: string
  expires_at?: string
  cadence_sec?: string
  ack_count?: number
}

export interface PubSubHandle {
  kill: () => void
  procs?: any[]
}

export const activeTaskMap = new Map<string, string>() // agentName -> taskId
export const lastKeepAliveMap = new Map<string, number>() // taskId -> timestamp

export function setActiveTask(agentName: string, taskId: string): void {
  if (!agentName || !taskId) return
  activeTaskMap.set(agentName, taskId)
}

export function getActiveTask(agentName: string): string | null {
  if (!agentName) return null
  return activeTaskMap.get(agentName) || null
}

export function resolveActiveTaskId(agentName: string, sessionId?: string): string | null {
  if (agentName && activeTaskMap.has(agentName)) {
    return activeTaskMap.get(agentName)!
  }
  if (sessionId) {
    const map = loadLocalSessionMap()
    const entry = map[`pi:${sessionId}`]
    if (entry && typeof entry === "object" && entry.task_id) {
      if (agentName) activeTaskMap.set(agentName, entry.task_id)
      return entry.task_id
    }
  }
  try {
    const home = process.env.HOME || process.env.USERPROFILE || ""
    const currentTaskPath = join(home, ".config", "rhizo", "current_task.json")
    if (existsSync(currentTaskPath)) {
      const data = JSON.parse(readFileSync(currentTaskPath, "utf8"))
      if (data && (data.id || data.task_id)) {
        const id = data.id || data.task_id
        if (agentName) activeTaskMap.set(agentName, id)
        return id
      }
    }
  } catch {}
  return null
}

export async function pingTaskProgress(
  bin: string = getRhizoBin(),
  taskId: string,
  agentName: string,
  reason: string = "Active tool execution",
  renewSec: number = 180,
  force: boolean = false
): Promise<boolean> {
  if (!taskId) return false
  const now = Date.now()
  const lastPing = lastKeepAliveMap.get(taskId) || 0
  if (!force && now - lastPing < 15000) {
    return false
  }
  lastKeepAliveMap.set(taskId, now)

  try {
    const env = { ...process.env }
    if (agentName) env.RHIZO_AGENT_NAME = agentName
    const proc = spawn(
      bin,
      ["task", "progress", taskId, "--progress", reason, "--renew", String(renewSec)],
      { stdio: "ignore", env, detached: true }
    )
    if (proc.unref) proc.unref()
    console.error(`[rhizo-pi-ear] extended lease for task '${taskId}' (agent: ${agentName || "unknown"}, renew: ${renewSec}s)`)
    return true
  } catch (err: any) {
    console.error(`[rhizo-pi-ear] failed to ping task progress: ${err?.message}`)
    return false
  }
}

export function queryActiveReminders(bin: string = getRhizoBin()): Reminder[] {
  try {
    const res = spawnSync(bin, ["reminder", "list", "--json"], {
      encoding: "utf8",
      timeout: 3000,
    })
    if (res.status === 0 && res.stdout) {
      const parsed = JSON.parse(res.stdout)
      if (Array.isArray(parsed.reminders)) {
        return parsed.reminders
      }
    }
  } catch {}
  return []
}

export function formatAdvisoryBlock(reminders: Reminder[]): string {
  if (!reminders || reminders.length === 0) return ""
  const highPriority = reminders.filter((r) => {
    const p = String(r.priority || "").toUpperCase()
    return p === "CRITICAL" || p === "HIGH" || p === "URGENT"
  })
  if (highPriority.length === 0) return ""

  const blocks = highPriority.map((r) => {
    const priority = String(r.priority || "HIGH").toUpperCase()
    const id = r.id || "unspecified"
    const text = r.text || r.directive || ""
    return `[ACTIVE ADVISORY - PRIORITY: ${priority} (${id})]:\n${text}`
  })

  return blocks.join("\n\n") + "\n\n"
}

export function getRhizoBin(): string {
  if (process.env.RHIZO_BIN && existsSync(process.env.RHIZO_BIN)) {
    return process.env.RHIZO_BIN
  }
  const home = process.env.HOME || process.env.USERPROFILE || ""
  const candidates = [
    join(home, ".local", "bin", "rhizo"),
    join(home, ".nimble", "bin", "rhizo"),
    "/opt/homebrew/bin/rhizo",
    "/usr/local/bin/rhizo",
  ]
  for (const p of candidates) {
    if (existsSync(p)) return p
  }
  return "rhizo"
}

export function getSessionsFile(): string {
  const home = process.env.HOME || process.env.USERPROFILE || ""
  const rhizoDir = join(home, ".config", "rhizo")
  const rhizoFile = join(rhizoDir, "sessions.json")
  if (existsSync(rhizoFile)) return rhizoFile
  try {
    mkdirSync(rhizoDir, { recursive: true })
  } catch {}
  return rhizoFile
}

export function loadLocalSessionMap(): Record<string, any> {
  const file = getSessionsFile()
  if (existsSync(file)) {
    try {
      return JSON.parse(readFileSync(file, "utf8"))
    } catch {}
  }
  return {}
}

export function saveLocalSessionMapping(sessionKey: string, agentName: string): void {
  const file = getSessionsFile()
  const map = loadLocalSessionMap()
  map[sessionKey] = {
    agent: agentName,
    updated_at: new Date().toISOString(),
  }
  try {
    writeFileSync(file, JSON.stringify(map, null, 2))
  } catch (err: any) {
    console.error(`[rhizo-pi-ear] could not save session mapping: ${err?.message}`)
  }
}

export function removeLocalSessionMapping(sessionKey: string): void {
  const file = getSessionsFile()
  const map = loadLocalSessionMap()
  if (map[sessionKey]) {
    delete map[sessionKey]
    try {
      writeFileSync(file, JSON.stringify(map, null, 2))
    } catch (err: any) {
      console.error(`[rhizo-pi-ear] could not remove session mapping: ${err?.message}`)
    }
  }
}

export function sanitizeAgentName(name: string): string {
  if (!name) return ""
  return name.toLowerCase().replace(/[^a-z0-9_-]/g, "-").replace(/^-+|-+$/g, "").slice(0, 32)
}

export function resolveSessionAgent(sessionId: string, fallbackTitle?: string): string {
  const envAgent = process.env.RHIZO_AGENT_NAME
  if (envAgent) return envAgent
  const sessionKey = `pi:${sessionId}`
  const map = loadLocalSessionMap()
  if (map[sessionKey]) {
    const val = map[sessionKey]
    return typeof val === "string" ? val : val.agent || val.agent_name || ""
  }
  const cleanTitle = sanitizeAgentName(fallbackTitle || "")
  const autoName = cleanTitle && cleanTitle.length >= 3 ? cleanTitle : `pi-${sessionId.slice(-8)}`
  saveLocalSessionMapping(sessionKey, autoName)
  return autoName
}

export function resolveMessageUrgency(text: string): "immediate" | "soon" {
  try {
    const jsonStart = text.indexOf("{")
    if (jsonStart >= 0) {
      const parsed = JSON.parse(text.slice(jsonStart))
      const u = String(parsed.urgency || parsed.delivery || "").toLowerCase()
      if (u === "immediate" || u === "now" || u === "urgent") return "immediate"
    }
  } catch {}
  return "soon"
}

export async function deliverPiPrompt(pi: any, text: string, reminders?: Reminder[]): Promise<void> {
  let promptText = text
  const activeReminders = reminders !== undefined ? reminders : queryActiveReminders()
  const advisory = formatAdvisoryBlock(activeReminders)
  if (advisory && !promptText.includes("[ACTIVE ADVISORY")) {
    promptText = advisory + promptText
  }

  if (typeof pi?.sendMessage === "function") {
    await pi.sendMessage(promptText)
  } else if (typeof pi?.sendPrompt === "function") {
    await pi.sendPrompt(promptText)
  } else if (typeof pi?.session?.promptAsync === "function") {
    await pi.session.promptAsync({ body: { parts: [{ type: "text", text: promptText }] } })
  } else if (typeof pi?.session?.prompt === "function") {
    await pi.session.prompt({ body: { parts: [{ type: "text", text: promptText }] } })
  } else {
    // Fallback: emit to standard output
    console.log(promptText)
  }
}

export async function interruptPiIfBusy(pi: any): Promise<void> {
  if (process.env.RHIZO_INTERRUPT === "0") return
  try {
    if (typeof pi?.abort === "function") {
      await pi.abort()
    } else if (typeof pi?.session?.abort === "function") {
      await pi.session.abort()
    }
  } catch (err: any) {
    console.error(`[rhizo-pi-ear] could not abort Pi session: ${err?.message}`)
  }
}

export function startPubSubPreemption(pi: any, agentName: string, cwd: string = process.cwd()): PubSubHandle {
  const bin = getRhizoBin()
  const procs: any[] = []
  let active = true

  const channels = ["cancel", "immediate"]
  if (agentName) {
    channels.push(agentName)
  }

  for (const chan of channels) {
    try {
      const child = spawn(bin, ["sub", chan], {
        cwd,
        stdio: ["ignore", "pipe", "pipe"],
      })
      procs.push(child)

      let stdoutData = ""
      child.stdout?.on("data", (chunk) => {
        if (!active) return
        stdoutData += chunk.toString("utf8")
        let idx: number
        while ((idx = stdoutData.indexOf("\n")) >= 0) {
          const line = stdoutData.slice(0, idx).trim()
          stdoutData = stdoutData.slice(idx + 1)
          if (!line) continue

          console.error(`[rhizo-pi-ear] pubsub message on '${chan}': ${line}`)
          let shouldPreempt = true
          let cancelReason = "Preempted via Redis pub/sub"

          try {
            const parsed = JSON.parse(line)
            if (parsed.target && parsed.target !== "*" && parsed.target !== agentName) {
              shouldPreempt = false
            }
            if (parsed.reason) cancelReason = parsed.reason
            if (parsed.action && parsed.action !== "cancel" && parsed.urgency !== "immediate") {
              shouldPreempt = false
            }
          } catch {}

          if (shouldPreempt) {
            console.error(`[rhizo-pi-ear] in-flight preemption triggered for @${agentName}: ${cancelReason}`)
            interruptPiIfBusy(pi).catch(() => {})
            deliverPiPrompt(pi, `[RHIZO PREEMPTION: Operation cancelled via Redis pub/sub (${cancelReason})]`).catch(() => {})
          }
        }
      })
    } catch (err: any) {
      console.error(`[rhizo-pi-ear] could not start pubsub listener for channel ${chan}: ${err?.message}`)
    }
  }

  return {
    kill: () => {
      active = false
      for (const p of procs) {
        try { p.kill() } catch {}
      }
    },
    procs,
  }
}

/**
 * Main Pi Extension entrypoint.
 * Registered by Pi during startup.
 */
export function RhizoPiExtension(pi: any) {
  if (process.env.RHIZO_EAR_DISABLED === "1") return {}

  const rhizoBin = getRhizoBin()
  let activeProc: any = null
  let pubsubHandle: PubSubHandle | null = null
  let running = true

  // 1. Register rhizo CLI tool natively in Pi
  if (typeof pi?.registerTool === "function") {
    const toolParams = {
      type: "object",
      properties: {
        subcommand: {
          type: "string",
          description: "Subcommand to execute (open, send, reply, broadcast, request, claim, ack, status, who)",
        },
        args: {
          type: "array",
          items: { type: "string" },
          description: "Arguments to pass to rhizo CLI",
        },
      },
      required: ["subcommand"],
    }
    const toolExec = async ({ subcommand, args = [] }: { subcommand: string; args?: string[] }) => {
      const fullArgs = [subcommand, ...args]
      const res = spawnSync(rhizoBin, fullArgs, { encoding: "utf8" })
      return {
        stdout: res.stdout,
        stderr: res.stderr,
        exitCode: res.status,
      }
    }

    pi.registerTool({
      name: "rhizo",
      description: "Inter-agent communication bus, distributed locks, queues, and task dispatch over Redis.",
      parameters: toolParams,
      execute: toolExec,
    })
  }

  // 2. Lifecycle hooks
  const onSessionStart = async (sessionInfo?: any) => {
    const sessionId = sessionInfo?.id || sessionInfo?.sessionId || "default"
    const title = sessionInfo?.title || ""
    const agentName = resolveSessionAgent(sessionId, title)

    // Set process environment for child tools
    process.env.RHIZO_SESSION_ID = `pi:${sessionId}`
    process.env.RHIZO_AGENT_NAME = agentName

    // Start background listener fiber
    if (activeProc) {
      try { activeProc.kill() } catch {}
      activeProc = null
    }

    if (pubsubHandle) {
      try { pubsubHandle.kill() } catch {}
      pubsubHandle = null
    }

    // Start pub/sub preemption listener
    pubsubHandle = startPubSubPreemption(pi, agentName)

    // Automated lease keep-alive helper for tools and file edits
    const handleKeepAlive = (reason?: string) => {
      const effAgent = process.env.RHIZO_AGENT_NAME || agentName
      const sid = process.env.RHIZO_SESSION_ID ? process.env.RHIZO_SESSION_ID.replace(/^pi:/, "") : sessionId
      const taskId = resolveActiveTaskId(effAgent, sid)
      if (taskId) {
        pingTaskProgress(rhizoBin, taskId, effAgent, reason || "Tool/file activity")
      }
    }

    if (typeof pi?.on === "function") {
      const toolHandler = (d?: any) => {
        const name = d?.name || d?.tool || "tool"
        handleKeepAlive(`tool:${name}`)
      }
      const fileHandler = (d?: any) => {
        const p = d?.path || d?.file || "file"
        handleKeepAlive(`file:${p}`)
      }
      pi.on("tool_call", toolHandler)
      pi.on("tool.call", toolHandler)
      pi.on("tool_execution", toolHandler)
      pi.on("tool.execute", toolHandler)
      pi.on("tool_start", toolHandler)
      pi.on("tool_end", toolHandler)
      pi.on("file_edit", fileHandler)
      pi.on("file.edit", fileHandler)
      pi.on("file_write", fileHandler)
      pi.on("file.write", fileHandler)
    }

    const startListener = async () => {
      while (running) {
        try {
          const child = spawn(rhizoBin, ["listen", agentName, "0"], {
            stdio: ["ignore", "pipe", "pipe"],
          })
          activeProc = child

          let stdoutData = ""
          child.stdout?.on("data", (chunk) => {
            stdoutData += chunk.toString("utf8")
            let idx: number
            while ((idx = stdoutData.indexOf("\n")) >= 0) {
              const line = stdoutData.slice(0, idx).trim()
              stdoutData = stdoutData.slice(idx + 1)
              if (line) {
                const urgency = resolveMessageUrgency(line)
                ;(async () => {
                  if (urgency === "immediate") {
                    await interruptPiIfBusy(pi)
                  }
                  let promptText = `[rhizo:${agentName}] ${line}`
                  let lineReminders: Reminder[] | undefined
                  try {
                    const parsed = JSON.parse(line)
                    const taskId = parsed.task_id || (typeof parsed.id === "string" && parsed.id.startsWith("task-") ? parsed.id : null)
                    if (taskId) {
                      setActiveTask(agentName, taskId)
                    }
                    if (typeof parsed.body === "string") {
                      const match = parsed.body.match(/Task ID:\s*([a-zA-Z0-9_-]+)/i)
                      if (match && match[1]) {
                        setActiveTask(agentName, match[1])
                      }
                    }
                    if (Array.isArray(parsed.reminders)) {
                      lineReminders = parsed.reminders
                    }
                    const from = parsed.from || "unknown"
                    const host = parsed.host ? ` [host: ${parsed.host}]` : ""
                    const subj = parsed.subject ? ` (subject: "${parsed.subject}")` : ""
                    const urg = parsed.urgency === "immediate" ? " [URGENT: IMMEDIATE]" : ""
                    const body = parsed.body || ""
                    promptText = `[RHIZO BUS message for @${agentName} from @${from}${host}${subj}${urg}]:\n${body}`
                  } catch {}
                  await deliverPiPrompt(pi, promptText, lineReminders)
                })()
              }
            }
          })

          await new Promise((resolve) => {
            child.on("close", resolve)
            child.on("error", resolve)
          })

          if (!running) break
          // Small backoff before restart
          await new Promise((r) => setTimeout(r, 500))
        } catch {
          await new Promise((r) => setTimeout(r, 1000))
        }
      }
    }

    startListener().catch(() => {})
  }

  if (typeof pi?.on === "function") {
    pi.on("session_start", onSessionStart)
    pi.on("session.start", onSessionStart)
    pi.on("session_end", () => {
      running = false
      if (activeProc) {
        try { activeProc.kill() } catch {}
      }
      if (pubsubHandle) {
        try { pubsubHandle.kill() } catch {}
        pubsubHandle = null
      }
      const sid = process.env.RHIZO_SESSION_ID
      if (sid) {
        removeLocalSessionMapping(sid)
      }
    })
  }

  // Initial trigger if session already active
  if (pi?.session?.id) {
    onSessionStart(pi.session)
  }

  return {
    name: "rhizo-pi-ear",
    cleanup: () => {
      running = false
      if (activeProc) {
        try { activeProc.kill() } catch {}
      }
      if (pubsubHandle) {
        try { pubsubHandle.kill() } catch {}
        pubsubHandle = null
      }
    },
    setActiveTask,
    getActiveTask,
    resolveActiveTaskId,
    pingTaskProgress,
    queryActiveReminders,
    formatAdvisoryBlock,
    startPubSubPreemption,
  }
}

export default RhizoPiExtension

