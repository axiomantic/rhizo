import { spawn as nodeSpawn, spawnSync } from "node:child_process"
import { createInterface } from "node:readline"
import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"
import {
  getRhizoBin,
  isSessionSupposedToListen,
  resolveSessionAgent,
  getSessionIdForAgent,
  readLocalSessionMap
} from "./sessions"
import type {
  ListenerState,
  ActiveListener,
  OpenCodeClient,
  SubprocessHandle,
  OpenCodeSessionInfo,
  Reminder,
  PubSubHandle
} from "./types"

export const activeListeners = new Map<string, ActiveListener>() // agentName -> { state, targetSessionId, pubsub }
export const sessionToAgent = new Map<string, string>() // sessionId -> agentName
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
    const map = readLocalSessionMap()
    const entry = map[`opencode:${sessionId}`]
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
    const proc = nodeSpawn(
      bin,
      ["task", "progress", taskId, "--progress", reason, "--renew", String(renewSec)],
      { stdio: "ignore", env, detached: true }
    )
    if (proc.unref) proc.unref()
    console.error(`[rhizo-ear] extended lease for task '${taskId}' (agent: ${agentName || "unknown"}, renew: ${renewSec}s)`)
    return true
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error(`[rhizo-ear] failed to ping task progress: ${msg}`)
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

export function isListenerAlive(agentName: string): boolean {
  const listener = activeListeners.get(agentName)
  if (!listener || !listener.state) return false
  if (listener.state.aborted) return false
  if (!listener.state.proc) return false
  const proc = listener.state.proc as any
  if (typeof proc.exitCode === "number" && proc.exitCode !== null) return false
  if (proc.killed) return false
  return true
}

export async function* listenLines(name: string, cwd: string, state: ListenerState): AsyncGenerator<string> {
  let firstSpawnFailure = true
  const bin = getRhizoBin()
  for (;;) {
    if (state?.aborted) break
    let proc: SubprocessHandle | null = null
    try {
      if (typeof Bun !== "undefined" && Bun?.spawn) {
        proc = Bun.spawn([bin, "listen", name], { cwd, stdout: "pipe", stderr: "pipe" }) as unknown as SubprocessHandle
      } else {
        proc = nodeSpawn(bin, ["listen", name], { cwd, stdio: ["ignore", "pipe", "pipe"] }) as unknown as SubprocessHandle
      }
      if (state) state.proc = proc
      firstSpawnFailure = true
    } catch (err: unknown) {
      if (firstSpawnFailure) {
        const msg = err instanceof Error ? err.message : String(err)
        console.error("[rhizo-ear] could not spawn `" + bin + " listen`: " + msg)
        firstSpawnFailure = false
      }
      await new Promise((r) => setTimeout(r, 500))
      continue
    }

    if (!proc || !proc.stdout) {
      await new Promise((r) => setTimeout(r, 500))
      continue
    }

    try {
      if (typeof (proc.stdout as any).getReader === "function") {
        // Bun Web ReadableStream
        const dec = new TextDecoder()
        const reader = (proc.stdout as any).getReader()
        let buf = ""
        for (;;) {
          const { done, value } = await reader.read()
          if (done) break
          buf += dec.decode(value, { stream: true })
          let i
          while ((i = buf.indexOf("\n")) >= 0) {
            const line = buf.slice(0, i)
            buf = buf.slice(i + 1)
            const t = line.trim()
            if (t) yield t
          }
        }
        const t = buf.trim()
        if (t) yield t
      } else {
        // Node.js Readable stream
        const rl = createInterface({ input: proc.stdout as NodeJS.ReadableStream })
        for await (const line of rl) {
          const t = line.trim()
          if (t) yield t
        }
      }
    } catch {
      // stream closed / child killed; fall through and re-arm unless aborted
    }
    if (state?.aborted) break
  }
}

export async function interruptSessionIfBusy(client: OpenCodeClient, sessionId: string): Promise<void> {
  if (process.env.RHIZO_INTERRUPT === "0") return
  if (!client?.session) return

  try {
    let isBusy = false
    if (typeof client.session.status === "function") {
      const statusRes = await client.session.status()
      const statuses = (statusRes && statusRes.data) || statusRes || {}
      const current = statuses[sessionId]
      if (current && (current.type === "busy" || current.type === "retry")) {
        isBusy = true
      }
    }

    if (isBusy && typeof client.session.abort === "function") {
      console.error(`[rhizo-ear] session ${sessionId} is busy; aborting to deliver Rhizo message...`)
      await client.session.abort({ path: { id: sessionId } })
      // Wait briefly for OpenCode fiber to transition to idle
      for (let i = 0; i < 7; i++) {
        await new Promise((r) => setTimeout(r, 50))
        if (typeof client.session.status === "function") {
          const sRes = await client.session.status().catch(() => null)
          const sMap = (sRes && sRes.data) || sRes || {}
          if (!sMap[sessionId] || sMap[sessionId].type === "idle") break
        }
      }
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error(`[rhizo-ear] could not interrupt session ${sessionId}:`, msg)
  }
}

export async function deliverPrompt(
  client: OpenCodeClient,
  sessionId: string,
  text: string,
  reminders?: Reminder[]
): Promise<void> {
  let promptText = text
  const activeReminders = reminders !== undefined ? reminders : queryActiveReminders()
  const advisory = formatAdvisoryBlock(activeReminders)
  if (advisory && !promptText.includes("[ACTIVE ADVISORY")) {
    promptText = advisory + promptText
  }

  const payload = {
    path: { id: sessionId },
    body: { parts: [{ type: "text", text: promptText }] },
  }

  if (typeof client?.session?.promptAsync === "function") {
    await client.session.promptAsync(payload)
  } else if (typeof client?.session?.prompt === "function") {
    await client.session.prompt(payload)
  } else {
    throw new Error("client.session has no prompt or promptAsync method")
  }
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

export function startPubSubPreemption(
  client: OpenCodeClient,
  agentName: string,
  targetSessionId: string | null,
  cwd: string = process.cwd()
): PubSubHandle {
  const bin = getRhizoBin()
  const procs: SubprocessHandle[] = []
  let active = true

  const channels = ["cancel", "immediate"]
  if (agentName) {
    channels.push(agentName)
  }

  for (const chan of channels) {
    try {
      const child = nodeSpawn(bin, ["sub", chan], {
        cwd,
        stdio: ["ignore", "pipe", "pipe"],
      }) as unknown as SubprocessHandle
      procs.push(child)

      if (child.stdout) {
        const rl = createInterface({ input: child.stdout as NodeJS.ReadableStream })
        rl.on("line", async (line) => {
          if (!active) return
          const trimmed = line.trim()
          if (!trimmed) return

          console.error(`[rhizo-ear] pubsub message on '${chan}': ${trimmed}`)
          let shouldPreempt = true
          let cancelReason = "Preempted via Redis pub/sub"

          try {
            const parsed = JSON.parse(trimmed)
            if (parsed.target && parsed.target !== "*" && parsed.target !== agentName) {
              shouldPreempt = false
            }
            if (parsed.reason) cancelReason = parsed.reason
            if (parsed.action && parsed.action !== "cancel" && parsed.urgency !== "immediate") {
              shouldPreempt = false
            }
          } catch {}

          if (shouldPreempt) {
            let sid = targetSessionId || getSessionIdForAgent(agentName)
            if (!sid && client?.session?.list) {
              try {
                const res = await client.session.list()
                const list = Array.isArray(res) ? res : ((res && "data" in res && Array.isArray(res.data)) ? res.data : [])
                sid = list[0]?.id || null
              } catch {}
            }

            if (sid) {
              console.error(`[rhizo-ear] in-flight preemption triggered for session ${sid}: ${cancelReason}`)
              await interruptSessionIfBusy(client, sid)
              deliverPrompt(client, sid, `[RHIZO PREEMPTION: Operation cancelled via Redis pub/sub (${cancelReason})]`).catch(() => {})
            }
          }
        })
      }
    } catch (err: unknown) {
      console.error(`[rhizo-ear] could not start pubsub listener for channel ${chan}:`, err)
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

export function stopAgentListener(name: string): void {
  const listener = activeListeners.get(name)
  if (listener) {
    if (listener.pubsub) {
      try { listener.pubsub.kill() } catch {}
    }
    if (listener.state) listener.state.aborted = true
    if (listener.state?.proc?.kill) {
      try {
        listener.state.proc.kill()
      } catch {}
    }
    activeListeners.delete(name)
  }
}

export function startAgentListener(
  client: OpenCodeClient,
  name: string,
  cwd: string,
  targetSessionId: string | null
): void {
  if (targetSessionId) {
    const existingAgent = sessionToAgent.get(targetSessionId)
    if (existingAgent && existingAgent !== name) {
      stopAgentListener(existingAgent)
    }
    sessionToAgent.set(targetSessionId, name)
  }

  if (activeListeners.has(name)) return
  const state: ListenerState = { aborted: false, proc: null }
  const pubsub = startPubSubPreemption(client, name, targetSessionId, cwd)
  activeListeners.set(name, { state, targetSessionId, pubsub })

  let busy = false
  const queue: string[] = []

  function next() {
    busy = false
    if (queue.length) {
      const item = queue.shift()
      if (item) offer(item)
    }
  }

  async function resolveTargetSession(): Promise<string | null> {
    if (targetSessionId) return targetSessionId
    const mappedSid = getSessionIdForAgent(name)
    if (mappedSid) return mappedSid
    try {
      if (!client.session?.list) return null
      const res = await client.session.list()
      const list: OpenCodeSessionInfo[] = Array.isArray(res) ? res : (res && "data" in res && Array.isArray(res.data) ? res.data : [])
      if (!Array.isArray(list) || list.length === 0) return null
      const live = list
        .filter((s) => !(s.time && s.time.archived))
        .sort((a, b) => ((b.time && b.time.updated) || 0) - ((a.time && a.time.updated) || 0))
      return live[0]?.id || null
    } catch {
      return null
    }
  }

  async function run(text: string, attempt: number) {
    try {
      const id = await resolveTargetSession()
      if (!id) throw new Error("no opencode session")

      let isImmediate = false
      const allowInterrupt = process.env.RHIZO_INTERRUPT !== "0"
      if (allowInterrupt) {
        if (
          process.env.RHIZO_ABORT_ON_BUSY === "1" ||
          process.env.RHIZO_INTERRUPT === "1"
        ) {
          isImmediate = true
        } else {
          isImmediate = resolveMessageUrgency(text) === "immediate"
        }
      }

      if (isImmediate) {
        await interruptSessionIfBusy(client, id)
      }
      await deliverPrompt(client, id, text)
      next()
    } catch (err) {
      if (attempt >= 8) {
        queue.unshift(text)
        next()
      } else {
        setTimeout(() => run(text, attempt + 1), 250 * (attempt + 1))
      }
    }
  }

  function offer(text: string) {
    const isImmediate = resolveMessageUrgency(text) === "immediate"
    if (busy) {
      if (isImmediate) {
        console.error(`[rhizo-ear] urgent in-flight preemption: aborting busy session...`)
        resolveTargetSession().then(async (id) => {
          if (id) {
            await interruptSessionIfBusy(client, id)
          }
        }).catch(() => {})
      }
      queue.push(text)
      return
    }
    busy = true
    run(text, 0)
  }

  console.error(`[rhizo-ear] armed for ${name} (bin: ${getRhizoBin()})`)

  ;(async () => {
    try {
      for await (const line of listenLines(name, cwd, state)) {
        if (state.aborted) break
        try {
          const jsonStart = line.indexOf("{")
          if (jsonStart >= 0) {
            const parsed = JSON.parse(line.slice(jsonStart))
            const taskId = parsed.task_id || (typeof parsed.id === "string" && parsed.id.startsWith("task-") ? parsed.id : null)
            if (taskId) {
              setActiveTask(name, taskId)
            }
            if (typeof parsed.body === "string") {
              const match = parsed.body.match(/Task ID:\s*([a-zA-Z0-9_-]+)/i)
              if (match && match[1]) {
                setActiveTask(name, match[1])
              }
            }
          }
        } catch {}
        offer(`[rhizo:${name}] ${line}`)
      }
    } catch (e) {
      console.error(`[rhizo-ear] listener error for ${name}:`, e)
    } finally {
      if (pubsub) {
        try { pubsub.kill() } catch {}
      }
      activeListeners.delete(name)
    }
  })()
}

export function verifyAndEnsureListener(
  client: OpenCodeClient,
  sessionId?: string | null,
  cwd: string = process.cwd()
): boolean {
  if (!sessionId) return false
  const agentName = isSessionSupposedToListen(sessionId)
  if (!agentName) {
    // Session is NOT supposed to have a listener. Ensure any existing one is stopped.
    const runningAgent = sessionToAgent.get(sessionId)
    if (runningAgent) {
      stopAgentListener(runningAgent)
      sessionToAgent.delete(sessionId)
    }
    return false
  }

  // Session IS supposed to have a listener for agentName
  sessionToAgent.set(sessionId, agentName)
  if (!isListenerAlive(agentName)) {
    console.error(`[rhizo-ear] Verifying session ${sessionId}: reviving listener for @${agentName}`)
    startAgentListener(client, agentName, cwd, sessionId)
    return true
  }

  return true
}

export async function syncSessions(client: OpenCodeClient, directory?: string): Promise<void> {
  const cwd = directory || process.cwd()
  console.error(`[rhizo-ear] syncSessions called for cwd: ${cwd}`)
  try {
    if (!client.session?.list) {
      console.error(`[rhizo-ear] client.session.list is not available!`)
      return
    }
    const res = await client.session.list()
    console.error(`[rhizo-ear] client.session.list in ${cwd}:`, typeof res === "object" ? JSON.stringify(res).slice(0, 200) : res)
    const list: OpenCodeSessionInfo[] = Array.isArray(res) ? res : (res && "data" in res && Array.isArray(res.data) ? res.data : [])
    if (!Array.isArray(list)) return

    for (const s of list) {
      if (s.time && s.time.archived) continue
      const name = isSessionSupposedToListen(s.id)
      if (name) {
        verifyAndEnsureListener(client, s.id, cwd)
      }
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error("[rhizo-ear] could not sync sessions:", msg)
  }
}
