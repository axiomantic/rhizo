// tests/test_opencode_ear.test.js
// Tests for OpenCode ear plugin session mapping, environment injection, and lifecycle hooks.

import { describe, it, expect, beforeEach, afterEach } from "bun:test"
import { readFileSync, writeFileSync, rmSync, existsSync, mkdirSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
import RhizoEar from "../skills/rhizo/opencode-ear.js"

const Ear = RhizoEar

describe("opencode-ear plugin", () => {
  let tempHome
  let originalHome

  beforeEach(() => {
    tempHome = join(tmpdir(), "rhizo-test-home-" + Math.random().toString(36).slice(2))
    mkdirSync(join(tempHome, ".config", "rhizo"), { recursive: true })
    originalHome = process.env.HOME
    process.env.HOME = tempHome
  })

  afterEach(() => {
    process.env.HOME = originalHome
    try {
      rmSync(tempHome, { recursive: true, force: true })
    } catch {}
  })

  it("exports a default function and handles RHIZO_EAR_DISABLED", async () => {
    expect(typeof Ear).toBe("function")
    const prev = process.env.RHIZO_EAR_DISABLED
    try {
      process.env.RHIZO_EAR_DISABLED = "1"
      const res = await Ear({ client: {}, directory: tempHome })
      expect(res).toEqual({})
    } finally {
      if (prev === undefined) delete process.env.RHIZO_EAR_DISABLED
      else process.env.RHIZO_EAR_DISABLED = prev
    }
  })

  it("injects RHIZO_SESSION_ID and RHIZO_AGENT_NAME via shell.env hook", async () => {
    // Pre-populate a session mapping
    const sessionsPath = join(tempHome, ".config", "rhizo", "sessions.json")
    const initialSessions = {
      "opencode:ses_test_abc": {
        agent: "lead-dev",
        updated_at: new Date().toISOString()
      }
    }
    writeFileSync(sessionsPath, JSON.stringify(initialSessions, null, 2))

    const mockClient = {
      session: {
        list: async () => [{ id: "ses_test_abc", title: "Test Session" }]
      }
    }

    const hooks = await Ear({ client: mockClient, directory: tempHome })
    expect(typeof hooks["shell.env"]).toBe("function")

    const output = { env: {} }
    await hooks["shell.env"]({ sessionID: "ses_test_abc" }, output)

    expect(output.env.RHIZO_SESSION_ID).toBe("opencode:ses_test_abc")
    expect(output.env.RHIZO_AGENT_NAME).toBe("lead-dev")
  })

  it("auto-assigns agent name for unmapped sessions and cleans up on session.deleted", async () => {
    const sessionsPath = join(tempHome, ".config", "rhizo", "sessions.json")
    const mockClient = {
      session: {
        list: async () => []
      }
    }

    const hooks = await Ear({ client: mockClient, directory: tempHome })
    const output = { env: {} }
    await hooks["shell.env"]({ sessionID: "ses_new_999" }, output)

    expect(output.env.RHIZO_SESSION_ID).toBe("opencode:ses_new_999")
    expect(output.env.RHIZO_AGENT_NAME).toBe("opencode-_new_999")

    // Verify it was written to global sessions.json
    expect(existsSync(sessionsPath)).toBe(true)
    const saved = JSON.parse(readFileSync(sessionsPath, "utf8"))
    expect(saved["opencode:ses_new_999"]).toBeDefined()
    expect(saved["opencode:ses_new_999"].agent).toBe("opencode-_new_999")

    // Fire session.deleted event
    await hooks.event({
      event: {
        type: "session.deleted",
        properties: { info: { id: "ses_new_999" } }
      }
    })

    const afterDelete = JSON.parse(readFileSync(sessionsPath, "utf8"))
    expect(afterDelete["opencode:ses_new_999"]).toBeUndefined()
  })

  it("interruptSessionIfBusy aborts busy session unless RHIZO_INTERRUPT=0", async () => {
    let abortedId = null
    let statusCallCount = 0

    const mockClient = {
      session: {
        status: async () => {
          statusCallCount++
          return statusCallCount === 1
            ? { "ses_busy_1": { type: "busy" } }
            : { "ses_busy_1": { type: "idle" } }
        },
        abort: async ({ path }) => {
          abortedId = path.id
        }
      }
    }

    // Default: when called on a busy session, aborts it
    await Ear.interruptSessionIfBusy(mockClient, "ses_busy_1")
    expect(abortedId).toBe("ses_busy_1")

    // Idle session: should NOT call abort
    abortedId = null
    const idleClient = {
      session: {
        status: async () => ({ "ses_idle_1": { type: "idle" } }),
        abort: async ({ path }) => { abortedId = path.id }
      }
    }
    await Ear.interruptSessionIfBusy(idleClient, "ses_idle_1")
    expect(abortedId).toBeNull()

    // RHIZO_INTERRUPT=0 disables abort even when busy
    const prevInterrupt = process.env.RHIZO_INTERRUPT
    try {
      process.env.RHIZO_INTERRUPT = "0"
      abortedId = null
      const busyClient = {
        session: {
          status: async () => ({ "ses_busy_2": { type: "busy" } }),
          abort: async ({ path }) => { abortedId = path.id }
        }
      }
      await Ear.interruptSessionIfBusy(busyClient, "ses_busy_2")
      expect(abortedId).toBeNull()
    } finally {
      if (prevInterrupt === undefined) delete process.env.RHIZO_INTERRUPT
      else process.env.RHIZO_INTERRUPT = prevInterrupt
    }
  })

  it("deliverPrompt prefers promptAsync and falls back to prompt", async () => {
    let promptAsyncCalled = null
    let promptCalled = null

    const modernClient = {
      session: {
        promptAsync: async (payload) => { promptAsyncCalled = payload },
        prompt: async (payload) => { promptCalled = payload }
      }
    }

    await Ear.deliverPrompt(modernClient, "ses_1", "Hello from Rhizo", [])
    expect(promptAsyncCalled).toEqual({
      path: { id: "ses_1" },
      body: { parts: [{ type: "text", text: "Hello from Rhizo" }] }
    })
    expect(promptCalled).toBeNull()

    // Fallback client with only prompt
    const legacyClient = {
      session: {
        prompt: async (payload) => { promptCalled = payload }
      }
    }
    await Ear.deliverPrompt(legacyClient, "ses_2", "Fallback turn", [])
    expect(promptCalled).toEqual({
      path: { id: "ses_2" },
      body: { parts: [{ type: "text", text: "Fallback turn" }] }
    })
  })

  it("resolveMessageUrgency correctly parses immediate vs soon", () => {
    expect(Ear.resolveMessageUrgency('[rhizo:agent] {"id":"123","urgency":"immediate"}')).toBe("immediate")
    expect(Ear.resolveMessageUrgency('[rhizo:agent] {"id":"123","delivery":"immediate"}')).toBe("immediate")
    expect(Ear.resolveMessageUrgency('[rhizo:agent] {"id":"123","urgency":"now"}')).toBe("immediate")
    expect(Ear.resolveMessageUrgency('[rhizo:agent] {"id":"123","urgency":"urgent"}')).toBe("immediate")
    expect(Ear.resolveMessageUrgency('[rhizo:agent] {"id":"123","urgency":"soon"}')).toBe("soon")
    expect(Ear.resolveMessageUrgency('[rhizo:agent] {"id":"123","delivery":"soon"}')).toBe("soon")
    expect(Ear.resolveMessageUrgency('[rhizo:agent] {"id":"123"}')).toBe("soon")
    expect(Ear.resolveMessageUrgency('raw text without json')).toBe("soon")
  })

  it("verifies and resumes listeners only for active sessions and ignores closed ones", async () => {
    const sessionsPath = join(tempHome, ".config", "rhizo", "sessions.json")
    const testSessions = {
      "opencode:ses_active": {
        agent: "worker-active",
        status: "active",
        updated_at: new Date().toISOString()
      },
      "opencode:ses_closed": {
        agent: "worker-closed",
        status: "closed",
        closed_at: new Date().toISOString()
      }
    }
    writeFileSync(sessionsPath, JSON.stringify(testSessions, null, 2))

    // isSessionSupposedToListen checks
    expect(Ear.isSessionSupposedToListen("ses_active")).toBe("worker-active")
    expect(Ear.isSessionSupposedToListen("ses_closed")).toBeNull()
    expect(Ear.isSessionSupposedToListen("ses_unregistered")).toBeNull()

    const mockClient = {
      session: {
        list: async () => [
          { id: "ses_active", title: "Active Session" },
          { id: "ses_closed", title: "Closed Session" },
          { id: "ses_unregistered", title: "Scratch Session" }
        ]
      }
    }

    const hooks = await Ear({ client: mockClient, directory: tempHome })

    // Closed session verification should return false and not spawn
    const closedResult = Ear.verifyAndEnsureListener(mockClient, "ses_closed", tempHome)
    expect(closedResult).toBe(false)

    // Unregistered session verification should return false
    const unregResult = Ear.verifyAndEnsureListener(mockClient, "ses_unregistered", tempHome)
    expect(unregResult).toBe(false)

    // Active session verification should return true
    const activeResult = Ear.verifyAndEnsureListener(mockClient, "ses_active", tempHome)
    expect(activeResult).toBe(true)

    // Testing session.resumed event
    await hooks.event({
      event: {
        type: "session.resumed",
        properties: { info: { id: "ses_active" } }
      }
    })

    // Now close the active session explicitly
    Ear.closeSessionAgent("opencode:ses_active")
    expect(Ear.isSessionSupposedToListen("ses_active")).toBeNull()
    const afterCloseResult = Ear.verifyAndEnsureListener(mockClient, "ses_active", tempHome)
    expect(afterCloseResult).toBe(false)
  })

  it("automatically arms listener and registers agent on session.created without waiting for shell.env", async () => {
    const sessionsPath = join(tempHome, ".config", "rhizo", "sessions.json")
    const mockClient = {
      session: {
        list: async () => []
      }
    }

    const hooks = await Ear({ client: mockClient, directory: tempHome })

    // Simulate brand new session created event in GUI
    await hooks.event({
      event: {
        type: "session.created",
        properties: { info: { id: "ses_auto_arm_42", title: "Refactor Work" } }
      }
    })

    // Verify it was immediately registered and armed in sessions.json
    expect(existsSync(sessionsPath)).toBe(true)
    const saved = JSON.parse(readFileSync(sessionsPath, "utf8"))
    expect(saved["opencode:ses_auto_arm_42"]).toBeDefined()
    expect(saved["opencode:ses_auto_arm_42"].agent).toBe("refactor-work")
    expect(saved["opencode:ses_auto_arm_42"].status).toBe("active")

    // Verify isListenerAlive
    expect(Ear.isListenerAlive("refactor-work")).toBe(true)
  })

  it("injects high-priority advisories when reminders are present", async () => {
    let deliveredText = null
    const mockClient = {
      session: {
        promptAsync: async (payload) => {
          deliveredText = payload.body.parts[0].text
        }
      }
    }

    const testReminders = [
      {
        id: "rem-gate-1",
        priority: "CRITICAL",
        text: "Enforce Two-Key Gate before weaving"
      },
      {
        id: "rem-audit-2",
        priority: "HIGH",
        text: "Run memory ordering verification"
      },
      {
        id: "rem-info-3",
        priority: "INFO",
        text: "Low priority info note"
      }
    ]

    await Ear.deliverPrompt(mockClient, "ses_adv", "Please implement task", testReminders)
    expect(deliveredText).toContain("[ACTIVE ADVISORY - PRIORITY: CRITICAL (rem-gate-1)]:")
    expect(deliveredText).toContain("Enforce Two-Key Gate before weaving")
    expect(deliveredText).toContain("[ACTIVE ADVISORY - PRIORITY: HIGH (rem-audit-2)]:")
    expect(deliveredText).toContain("Run memory ordering verification")
    // INFO priority should NOT be in the advisory block
    expect(deliveredText).not.toContain("rem-info-3")
    expect(deliveredText).toContain("Please implement task")
  })

  it("manages active tasks and keeps lease alive with throttling", async () => {
    // 1. Task mapping
    Ear.setActiveTask("worker-test", "task-999")
    expect(Ear.getActiveTask("worker-test")).toBe("task-999")
    expect(Ear.resolveActiveTaskId("worker-test")).toBe("task-999")

    // 2. pingTaskProgress with throttling
    const res1 = await Ear.pingTaskProgress(Ear.getRhizoBin(), "task-999", "worker-test", "Test progress 1", 180, true)
    expect(typeof res1).toBe("boolean")

    // Immediate second ping without force should be throttled
    const res2 = await Ear.pingTaskProgress(Ear.getRhizoBin(), "task-999", "worker-test", "Test progress 2", 180, false)
    expect(res2).toBe(false)

    // With force = true, ping proceeds
    const res3 = await Ear.pingTaskProgress(Ear.getRhizoBin(), "task-999", "worker-test", "Test progress 3", 180, true)
    expect(typeof res3).toBe("boolean")
  })

  it("triggers lease keep-alive on tool execution and file edit hooks and events", async () => {
    const mockClient = {
      session: {
        list: async () => [{ id: "ses_tool_test", title: "Tool Session" }]
      }
    }

    const hooks = await Ear({ client: mockClient, directory: tempHome })
    expect(typeof hooks["tool.execute.before"]).toBe("function")
    expect(typeof hooks["tool.execute.after"]).toBe("function")
    expect(typeof hooks["fs.write"]).toBe("function")
    expect(typeof hooks["file.edited"]).toBe("function")

    Ear.setActiveTask("lead-worker", "task-tool-1")
    process.env.RHIZO_AGENT_NAME = "lead-worker"

    // Call tool hook
    await hooks["tool.execute.before"]({ name: "bash", sessionID: "ses_tool_test" })
    await hooks["tool.execute.after"]({ name: "bash", sessionID: "ses_tool_test" })
    await hooks["fs.write"]({ path: "/tmp/foo.txt", sessionID: "ses_tool_test" })
    await hooks["file.edited"]({ path: "/tmp/bar.txt", sessionID: "ses_tool_test" })

    // Call event hook with tool event
    await hooks.event({
      event: {
        type: "tool.execute",
        properties: { info: { id: "ses_tool_test" } }
      }
    })

    // Call event hook with file event
    await hooks.event({
      event: {
        type: "file.edited",
        properties: { info: { id: "ses_tool_test" } }
      }
    })
  })

  it("pubsub preemption starts and cleans up properly", () => {
    const mockClient = {
      session: {
        list: async () => [],
        status: async () => ({}),
        abort: async () => {}
      }
    }

    const pubsub = Ear.startPubSubPreemption(mockClient, "test-preempt-worker", "ses_preempt")
    expect(pubsub).toBeDefined()
    expect(typeof pubsub.kill).toBe("function")
    expect(Array.isArray(pubsub.procs)).toBe(true)

    // Cleanup
    pubsub.kill()
  })
})

