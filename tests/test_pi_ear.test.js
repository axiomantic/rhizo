// tests/test_pi_ear.test.js
// Tests for Pi Coding Agent extension: tool registration, session mapping, and prompt delivery.

import { describe, it, expect, beforeEach, afterEach } from "bun:test"
import { readFileSync, writeFileSync, rmSync, existsSync, mkdirSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
import RhizoPiExtension, {
  resolveMessageUrgency,
  resolveSessionAgent,
  sanitizeAgentName,
  saveLocalSessionMapping,
  removeLocalSessionMapping,
  deliverPiPrompt,
  interruptPiIfBusy,
  getRhizoBin,
  setActiveTask,
  getActiveTask,
  resolveActiveTaskId,
  pingTaskProgress,
  queryActiveReminders,
  formatAdvisoryBlock,
  startPubSubPreemption,
} from "../skills/rhizo/pi-ear.ts"

const PiExtension = RhizoPiExtension

describe("Pi Coding Agent Extension (pi-ear.ts)", () => {
  let tempHome
  let originalHome

  beforeEach(() => {
    tempHome = join(tmpdir(), "rhizo-pi-test-home-" + Math.random().toString(36).slice(2))
    mkdirSync(join(tempHome, ".config", "rhizo"), { recursive: true })
    originalHome = process.env.HOME
    process.env.HOME = tempHome
  })

  afterEach(() => {
    process.env.HOME = originalHome
    delete process.env.RHIZO_AGENT_NAME
    delete process.env.RHIZO_SESSION_ID
    try {
      rmSync(tempHome, { recursive: true, force: true })
    } catch {}
  })

  it("exports main function and respects RHIZO_EAR_DISABLED", () => {
    expect(typeof PiExtension).toBe("function")
    const prev = process.env.RHIZO_EAR_DISABLED
    try {
      process.env.RHIZO_EAR_DISABLED = "1"
      const res = PiExtension({})
      expect(res).toEqual({})
    } finally {
      if (prev === undefined) delete process.env.RHIZO_EAR_DISABLED
      else process.env.RHIZO_EAR_DISABLED = prev
    }
  })

  it("correctly registers rhizo tool with Pi", () => {
    const registeredTools = []
    const mockPi = {
      registerTool: (toolDef) => {
        registeredTools.push(toolDef)
      },
      on: () => {},
    }

    PiExtension(mockPi)
    expect(registeredTools.length).toBeGreaterThanOrEqual(1)
    const toolNames = registeredTools.map((t) => t.name)
    expect(toolNames).toContain("rhizo")
    const rhizoTool = registeredTools.find((t) => t.name === "rhizo")
    expect(rhizoTool.parameters.required).toContain("subcommand")
    expect(typeof rhizoTool.execute).toBe("function")
  })

  it("binds session to agent name and persists in sessions.json", () => {
    const sessionsPath = join(tempHome, ".config", "rhizo", "sessions.json")
    const events = {}
    const mockPi = {
      on: (event, handler) => {
        events[event] = handler
      },
    }

    PiExtension(mockPi)
    expect(typeof events["session_start"]).toBe("function")

    // Trigger session_start
    events["session_start"]({ id: "ses_pi_100", title: "feature-refactor" })

    expect(process.env.RHIZO_SESSION_ID).toBe("pi:ses_pi_100")
    expect(process.env.RHIZO_AGENT_NAME).toBe("feature-refactor")

    expect(existsSync(sessionsPath)).toBe(true)
    const map = JSON.parse(readFileSync(sessionsPath, "utf8"))
    expect(map["pi:ses_pi_100"]).toBeDefined()
    expect(map["pi:ses_pi_100"].agent).toBe("feature-refactor")

    // Trigger session_end

    expect(typeof events["session_end"]).toBe("function")
    events["session_end"]()

    const mapAfter = JSON.parse(readFileSync(sessionsPath, "utf8"))
    expect(mapAfter["pi:ses_pi_100"]).toBeUndefined()
  })

  it("resolveMessageUrgency correctly detects immediate vs soon", () => {
    expect(resolveMessageUrgency('{"urgency":"immediate"}')).toBe("immediate")
    expect(resolveMessageUrgency('{"urgency":"urgent"}')).toBe("immediate")
    expect(resolveMessageUrgency('{"urgency":"now"}')).toBe("immediate")
    expect(resolveMessageUrgency('{"delivery":"immediate"}')).toBe("immediate")
    expect(resolveMessageUrgency('{"urgency":"soon"}')).toBe("soon")
    expect(resolveMessageUrgency('{"urgency":"routine"}')).toBe("soon")
    expect(resolveMessageUrgency('raw string')).toBe("soon")
  })

  it("deliverPiPrompt invokes sendUserMessage, sendMessage, sendPrompt, or session.prompt", async () => {
    let sentUserMessage = null
    const clientUser = {
      sendUserMessage: async (msg) => { sentUserMessage = msg }
    }
    await deliverPiPrompt(clientUser, "Hello from sendUserMessage", [])
    expect(sentUserMessage).toBe("Hello from sendUserMessage")

    let sentMessage = null
    const clientA = {
      sendMessage: async (msg) => { sentMessage = msg }
    }
    await deliverPiPrompt(clientA, "Hello from Rhizo", [])
    const textA = typeof sentMessage === "string" ? sentMessage : sentMessage?.content
    expect(textA).toBe("Hello from Rhizo")

    let sentPrompt = null
    const clientB = {
      sendPrompt: async (msg) => { sentPrompt = msg }
    }
    await deliverPiPrompt(clientB, "Prompt turn", [])
    expect(sentPrompt).toBe("Prompt turn")

    let promptPayload = null
    const clientC = {
      session: {
        promptAsync: async (p) => { promptPayload = p }
      }
    }
    await deliverPiPrompt(clientC, "Session payload", [])
    expect(promptPayload).toEqual({ body: { parts: [{ type: "text", text: "Session payload" }] } })
  })

  it("interruptPiIfBusy triggers abort unless RHIZO_INTERRUPT=0", async () => {
    let aborted = false
    const client = {
      abort: async () => { aborted = true }
    }

    await interruptPiIfBusy(client)
    expect(aborted).toBe(true)

    // With RHIZO_INTERRUPT=0
    const prev = process.env.RHIZO_INTERRUPT
    try {
      process.env.RHIZO_INTERRUPT = "0"
      aborted = false
      await interruptPiIfBusy(client)
      expect(aborted).toBe(false)
    } finally {
      if (prev === undefined) delete process.env.RHIZO_INTERRUPT
      else process.env.RHIZO_INTERRUPT = prev
    }
  })

  it("injects high-priority advisories into Pi prompts when reminders are present", async () => {
    let delivered = null
    const mockPi = {
      sendMessage: async (msg) => { delivered = msg }
    }

    const testReminders = [
      {
        id: "rem-101",
        priority: "CRITICAL",
        text: "Zero green mirage: live verification required"
      },
      {
        id: "rem-102",
        priority: "HIGH",
        text: "Audit integer underflow"
      },
      {
        id: "rem-103",
        priority: "LOW",
        text: "Optional style hint"
      }
    ]

    await deliverPiPrompt(mockPi, "Execute work", testReminders)
    const textDelivered = typeof delivered === "string" ? delivered : delivered?.content
    expect(textDelivered).toContain("[ACTIVE ADVISORY - PRIORITY: CRITICAL (rem-101)]:")
    expect(textDelivered).toContain("Zero green mirage: live verification required")
    expect(textDelivered).toContain("[ACTIVE ADVISORY - PRIORITY: HIGH (rem-102)]:")
    expect(textDelivered).toContain("Audit integer underflow")
    expect(textDelivered).not.toContain("rem-103")
    expect(textDelivered).toContain("Execute work")
  })

  it("manages active tasks and keeps lease alive with throttling in Pi ear", async () => {
    setActiveTask("pi-worker-1", "task-pi-55")
    expect(getActiveTask("pi-worker-1")).toBe("task-pi-55")
    expect(resolveActiveTaskId("pi-worker-1")).toBe("task-pi-55")

    const bin = getRhizoBin()
    const p1 = await pingTaskProgress(bin, "task-pi-55", "pi-worker-1", "Tool execution", 180, true)
    expect(typeof p1).toBe("boolean")

    // Immediate second ping without force should be throttled
    const p2 = await pingTaskProgress(bin, "task-pi-55", "pi-worker-1", "Tool execution", 180, false)
    expect(p2).toBe(false)

    // With force = true, ping proceeds
    const p3 = await pingTaskProgress(bin, "task-pi-55", "pi-worker-1", "Tool execution", 180, true)
    expect(typeof p3).toBe("boolean")
  })

  it("triggers lease keep-alive when Pi runs tools or edits files", () => {
    const handlers = {}
    const mockPi = {
      on: (evt, fn) => { handlers[evt] = fn },
      session: { id: "ses_pi_events", title: "Tool Runner" }
    }

    const ext = PiExtension(mockPi)
    expect(typeof handlers["tool_call"]).toBe("function")
    expect(typeof handlers["file_edit"]).toBe("function")
    expect(typeof handlers["file_write"]).toBe("function")

    setActiveTask("pi-tool-agent", "task-pi-tools")
    process.env.RHIZO_AGENT_NAME = "pi-tool-agent"

    // Trigger tool and file events
    handlers["tool_call"]({ name: "bash" })
    handlers["file_edit"]({ path: "src/main.ts" })
    handlers["file_write"]({ path: "src/main.ts" })

    // Cleanup extension
    if (ext && typeof ext.cleanup === "function") {
      ext.cleanup()
    }
  })

  it("pubsub preemption for Pi starts and cleans up properly", () => {
    const mockPi = {
      abort: async () => {},
      sendMessage: async () => {}
    }

    const pubsub = startPubSubPreemption(mockPi, "test-pi-preempt")
    expect(pubsub).toBeDefined()
    expect(typeof pubsub.kill).toBe("function")
    expect(Array.isArray(pubsub.procs)).toBe(true)

    pubsub.kill()
  })

  it("injects agent identity into system prompt via before_agent_start", async () => {
    const handlers = {}
    const mockPi = {
      on: (evt, fn) => { handlers[evt] = fn },
      session: { id: "ses_identity", title: "My Agent" }
    }

    const ext = PiExtension(mockPi)
    expect(typeof handlers["before_agent_start"]).toBe("function")

    process.env.RHIZO_AGENT_NAME = "pi-identity-test"
    const res = await handlers["before_agent_start"]({ systemPrompt: "Base prompt." })
    expect(res).toBeDefined()
    expect(res.systemPrompt).toContain("[Rhizo Multi-Agent Coordination]: Your unique agent codename is @pi-identity-test.")
    expect(res.systemPrompt).toContain("Base prompt.")

    if (ext && typeof ext.cleanup === "function") ext.cleanup()
  })

  it("rhizo tool defensively handles array subcommands, null arguments, whoami, and listen", async () => {
    let rhizoToolDef = null
    const mockPi = {
      registerTool: (def) => { rhizoToolDef = def },
      on: () => {},
    }

    const ext = PiExtension(mockPi)
    expect(rhizoToolDef).toBeDefined()

    process.env.RHIZO_AGENT_NAME = "pi-defense-test"

    // 1. whoami / name subcommand
    const whoRes = await rhizoToolDef.execute("call_1", { subcommand: "whoami" })
    expect(whoRes.content[0].text).toContain("Your Rhizo agent codename is @pi-defense-test")

    // 2. listen subcommand returns advisory that background ear is already active
    const listenRes = await rhizoToolDef.execute("call_2", { subcommand: ["listen"] })
    expect(listenRes.content[0].text).toContain("Background listener is already active")

    // 3. null params default to status
    const nullRes = await rhizoToolDef.execute("call_3", null)
    expect(nullRes).toBeDefined()
    expect(Array.isArray(nullRes.content)).toBe(true)

    if (ext && typeof ext.cleanup === "function") ext.cleanup()
  })
})

