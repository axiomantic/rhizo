// @bun
// src/sessions.ts
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "fs";
import { join, dirname } from "path";
function getRhizoBin() {
  if (process.env.RHIZO_BIN && existsSync(process.env.RHIZO_BIN)) {
    return process.env.RHIZO_BIN;
  }
  const home = process.env.HOME || process.env.USERPROFILE || "";
  const candidates = [
    join(home, ".local", "bin", "rhizo"),
    join(home, ".nimble", "bin", "rhizo"),
    "/opt/homebrew/bin/rhizo",
    "/usr/local/bin/rhizo"
  ];
  for (const p of candidates) {
    if (existsSync(p))
      return p;
  }
  return "rhizo";
}
function getSessionsPath() {
  const home = process.env.HOME || process.env.USERPROFILE || "";
  return join(home, ".config", "rhizo", "sessions.json");
}
function readLocalSessionMap() {
  try {
    return JSON.parse(readFileSync(getSessionsPath(), "utf8"));
  } catch {
    return {};
  }
}
function isSessionSupposedToListen(sessionId) {
  if (!sessionId)
    return null;
  const sessionKey = `opencode:${sessionId}`;
  const map = readLocalSessionMap();
  const entry = map[sessionKey];
  if (entry && typeof entry === "object" && (entry.status === "closed" || entry.disabled === true)) {
    return null;
  }
  const envAgent = process.env.RHIZO_AGENT_NAME;
  if (envAgent)
    return envAgent;
  if (!entry)
    return null;
  const name = typeof entry === "string" ? entry : entry.agent;
  return name || null;
}
function getSessionIdForAgent(agentName) {
  const map = readLocalSessionMap();
  for (const [key, val] of Object.entries(map)) {
    if (typeof val === "object" && val.status === "closed")
      continue;
    const name = typeof val === "string" ? val : val?.agent;
    if (name === agentName && key.startsWith("opencode:")) {
      return key.slice("opencode:".length);
    }
  }
  return null;
}
function setMappedAgent(sessionKey, agentName, status = "active") {
  try {
    const p = getSessionsPath();
    mkdirSync(dirname(p), { recursive: true });
    const map = readLocalSessionMap();
    map[sessionKey] = {
      agent: agentName,
      status,
      updated_at: new Date().toISOString()
    };
    writeFileSync(p, JSON.stringify(map, null, 2) + `
`);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[rhizo-ear] could not write session mapping:", msg);
  }
}
function closeSessionAgent(sessionKey) {
  try {
    const p = getSessionsPath();
    const map = readLocalSessionMap();
    if (map[sessionKey]) {
      if (typeof map[sessionKey] === "object") {
        map[sessionKey].status = "closed";
        map[sessionKey].closed_at = new Date().toISOString();
      } else {
        map[sessionKey] = {
          agent: map[sessionKey],
          status: "closed",
          closed_at: new Date().toISOString()
        };
      }
      writeFileSync(p, JSON.stringify(map, null, 2) + `
`);
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[rhizo-ear] could not close session mapping:", msg);
  }
}
function removeMappedAgent(sessionKey) {
  try {
    const p = getSessionsPath();
    const map = readLocalSessionMap();
    if (map[sessionKey]) {
      delete map[sessionKey];
      writeFileSync(p, JSON.stringify(map, null, 2) + `
`);
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[rhizo-ear] could not remove session mapping:", msg);
  }
}
function sanitizeAgentName(name) {
  if (!name)
    return "";
  return name.toLowerCase().replace(/[^a-z0-9_-]/g, "-").replace(/^-+|-+$/g, "").slice(0, 32);
}
function resolveSessionAgent(sessionId, fallbackName) {
  if (sessionId) {
    const map = readLocalSessionMap();
    const entry = map[`opencode:${sessionId}`];
    if (entry && typeof entry === "object" && (entry.status === "closed" || entry.disabled === true)) {
      return "";
    }
    const supposed = isSessionSupposedToListen(sessionId);
    if (supposed)
      return supposed;
  }
  const envAgent = process.env.RHIZO_AGENT_NAME;
  if (envAgent)
    return envAgent;
  if (sessionId) {
    const sanitized = sanitizeAgentName(fallbackName);
    const autoName = sanitized && sanitized.length >= 3 ? sanitized : `opencode-${sessionId.slice(-8)}`;
    setMappedAgent(`opencode:${sessionId}`, autoName, "active");
    return autoName;
  }
  return "";
}

// src/supervisor.ts
import { spawn as nodeSpawn, spawnSync } from "child_process";
import { createInterface } from "readline";
import { existsSync as existsSync2, readFileSync as readFileSync2 } from "fs";
import { join as join2 } from "path";
var activeListeners = new Map;
var sessionToAgent = new Map;
var activeTaskMap = new Map;
var lastKeepAliveMap = new Map;
function setActiveTask(agentName, taskId) {
  if (!agentName || !taskId)
    return;
  activeTaskMap.set(agentName, taskId);
}
function getActiveTask(agentName) {
  if (!agentName)
    return null;
  return activeTaskMap.get(agentName) || null;
}
function resolveActiveTaskId(agentName, sessionId) {
  if (agentName && activeTaskMap.has(agentName)) {
    return activeTaskMap.get(agentName);
  }
  if (sessionId) {
    const map = readLocalSessionMap();
    const entry = map[`opencode:${sessionId}`];
    if (entry && typeof entry === "object" && entry.task_id) {
      if (agentName)
        activeTaskMap.set(agentName, entry.task_id);
      return entry.task_id;
    }
  }
  try {
    const home = process.env.HOME || process.env.USERPROFILE || "";
    const currentTaskPath = join2(home, ".config", "rhizo", "current_task.json");
    if (existsSync2(currentTaskPath)) {
      const data = JSON.parse(readFileSync2(currentTaskPath, "utf8"));
      if (data && (data.id || data.task_id)) {
        const id = data.id || data.task_id;
        if (agentName)
          activeTaskMap.set(agentName, id);
        return id;
      }
    }
  } catch {}
  return null;
}
async function pingTaskProgress(bin = getRhizoBin(), taskId, agentName, reason = "Active tool execution", renewSec = 180, force = false) {
  if (!taskId)
    return false;
  const now = Date.now();
  const lastPing = lastKeepAliveMap.get(taskId) || 0;
  if (!force && now - lastPing < 15000) {
    return false;
  }
  lastKeepAliveMap.set(taskId, now);
  try {
    const env = { ...process.env };
    if (agentName)
      env.RHIZO_AGENT_NAME = agentName;
    const proc = nodeSpawn(bin, ["task", "progress", taskId, "--progress", reason, "--renew", String(renewSec)], { stdio: "ignore", env, detached: true });
    if (proc.unref)
      proc.unref();
    console.error(`[rhizo-ear] extended lease for task '${taskId}' (agent: ${agentName || "unknown"}, renew: ${renewSec}s)`);
    return true;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[rhizo-ear] failed to ping task progress: ${msg}`);
    return false;
  }
}
function queryActiveReminders(bin = getRhizoBin()) {
  try {
    const res = spawnSync(bin, ["reminder", "list", "--json"], {
      encoding: "utf8",
      timeout: 3000
    });
    if (res.status === 0 && res.stdout) {
      const parsed = JSON.parse(res.stdout);
      if (Array.isArray(parsed.reminders)) {
        return parsed.reminders;
      }
    }
  } catch {}
  return [];
}
function formatAdvisoryBlock(reminders) {
  if (!reminders || reminders.length === 0)
    return "";
  const highPriority = reminders.filter((r) => {
    const p = String(r.priority || "").toUpperCase();
    return p === "CRITICAL" || p === "HIGH" || p === "URGENT";
  });
  if (highPriority.length === 0)
    return "";
  const blocks = highPriority.map((r) => {
    const priority = String(r.priority || "HIGH").toUpperCase();
    const id = r.id || "unspecified";
    const text = r.text || r.directive || "";
    return `[ACTIVE ADVISORY - PRIORITY: ${priority} (${id})]:
${text}`;
  });
  return blocks.join(`

`) + `

`;
}
function isListenerAlive(agentName) {
  const listener = activeListeners.get(agentName);
  if (!listener || !listener.state)
    return false;
  if (listener.state.aborted)
    return false;
  if (!listener.state.proc)
    return false;
  const proc = listener.state.proc;
  if (typeof proc.exitCode === "number" && proc.exitCode !== null)
    return false;
  if (proc.killed)
    return false;
  return true;
}
async function* listenLines(name, cwd, state) {
  let firstSpawnFailure = true;
  const bin = getRhizoBin();
  for (;; ) {
    if (state?.aborted)
      break;
    let proc = null;
    try {
      if (typeof Bun !== "undefined" && Bun?.spawn) {
        proc = Bun.spawn([bin, "listen", name], { cwd, stdout: "pipe", stderr: "pipe" });
      } else {
        proc = nodeSpawn(bin, ["listen", name], { cwd, stdio: ["ignore", "pipe", "pipe"] });
      }
      if (state)
        state.proc = proc;
      firstSpawnFailure = true;
    } catch (err) {
      if (firstSpawnFailure) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error("[rhizo-ear] could not spawn `" + bin + " listen`: " + msg);
        firstSpawnFailure = false;
      }
      await new Promise((r) => setTimeout(r, 500));
      continue;
    }
    if (!proc || !proc.stdout) {
      await new Promise((r) => setTimeout(r, 500));
      continue;
    }
    try {
      if (typeof proc.stdout.getReader === "function") {
        const dec = new TextDecoder;
        const reader = proc.stdout.getReader();
        let buf = "";
        for (;; ) {
          const { done, value } = await reader.read();
          if (done)
            break;
          buf += dec.decode(value, { stream: true });
          let i;
          while ((i = buf.indexOf(`
`)) >= 0) {
            const line = buf.slice(0, i);
            buf = buf.slice(i + 1);
            const t2 = line.trim();
            if (t2)
              yield t2;
          }
        }
        const t = buf.trim();
        if (t)
          yield t;
      } else {
        const rl = createInterface({ input: proc.stdout });
        for await (const line of rl) {
          const t = line.trim();
          if (t)
            yield t;
        }
      }
    } catch {}
    if (state?.aborted)
      break;
  }
}
async function interruptSessionIfBusy(client, sessionId) {
  if (process.env.RHIZO_INTERRUPT === "0")
    return;
  if (!client?.session)
    return;
  try {
    let isBusy = false;
    if (typeof client.session.status === "function") {
      const statusRes = await client.session.status();
      const statuses = statusRes && statusRes.data || statusRes || {};
      const current = statuses[sessionId];
      if (current && (current.type === "busy" || current.type === "retry")) {
        isBusy = true;
      }
    }
    if (isBusy && typeof client.session.abort === "function") {
      console.error(`[rhizo-ear] session ${sessionId} is busy; aborting to deliver Rhizo message...`);
      await client.session.abort({ path: { id: sessionId } });
      for (let i = 0;i < 7; i++) {
        await new Promise((r) => setTimeout(r, 50));
        if (typeof client.session.status === "function") {
          const sRes = await client.session.status().catch(() => null);
          const sMap = sRes && sRes.data || sRes || {};
          if (!sMap[sessionId] || sMap[sessionId].type === "idle")
            break;
        }
      }
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[rhizo-ear] could not interrupt session ${sessionId}:`, msg);
  }
}
async function deliverPrompt(client, sessionId, text, reminders) {
  let promptText = text;
  const activeReminders = reminders !== undefined ? reminders : queryActiveReminders();
  const advisory = formatAdvisoryBlock(activeReminders);
  if (advisory && !promptText.includes("[ACTIVE ADVISORY")) {
    promptText = advisory + promptText;
  }
  const payload = {
    path: { id: sessionId },
    body: { parts: [{ type: "text", text: promptText }] }
  };
  if (typeof client?.session?.promptAsync === "function") {
    await client.session.promptAsync(payload);
  } else if (typeof client?.session?.prompt === "function") {
    await client.session.prompt(payload);
  } else {
    throw new Error("client.session has no prompt or promptAsync method");
  }
}
function resolveMessageUrgency(text) {
  try {
    const jsonStart = text.indexOf("{");
    if (jsonStart >= 0) {
      const parsed = JSON.parse(text.slice(jsonStart));
      const u = String(parsed.urgency || parsed.delivery || "").toLowerCase();
      if (u === "immediate" || u === "now" || u === "urgent")
        return "immediate";
    }
  } catch {}
  return "soon";
}
function startPubSubPreemption(client, agentName, targetSessionId, cwd = process.cwd()) {
  const bin = getRhizoBin();
  const procs = [];
  let active = true;
  const channels = ["cancel", "immediate"];
  if (agentName) {
    channels.push(agentName);
  }
  for (const chan of channels) {
    try {
      const child = nodeSpawn(bin, ["sub", chan], {
        cwd,
        stdio: ["ignore", "pipe", "pipe"]
      });
      procs.push(child);
      if (child.stdout) {
        const rl = createInterface({ input: child.stdout });
        rl.on("line", async (line) => {
          if (!active)
            return;
          const trimmed = line.trim();
          if (!trimmed)
            return;
          console.error(`[rhizo-ear] pubsub message on '${chan}': ${trimmed}`);
          let shouldPreempt = true;
          let cancelReason = "Preempted via Redis pub/sub";
          try {
            const parsed = JSON.parse(trimmed);
            if (parsed.target && parsed.target !== "*" && parsed.target !== agentName) {
              shouldPreempt = false;
            }
            if (parsed.reason)
              cancelReason = parsed.reason;
            if (parsed.action && parsed.action !== "cancel" && parsed.urgency !== "immediate") {
              shouldPreempt = false;
            }
          } catch {}
          if (shouldPreempt) {
            let sid = targetSessionId || getSessionIdForAgent(agentName);
            if (!sid && client?.session?.list) {
              try {
                const res = await client.session.list();
                const list = Array.isArray(res) ? res : res && ("data" in res) && Array.isArray(res.data) ? res.data : [];
                sid = list[0]?.id || null;
              } catch {}
            }
            if (sid) {
              console.error(`[rhizo-ear] in-flight preemption triggered for session ${sid}: ${cancelReason}`);
              await interruptSessionIfBusy(client, sid);
              deliverPrompt(client, sid, `[RHIZO PREEMPTION: Operation cancelled via Redis pub/sub (${cancelReason})]`).catch(() => {});
            }
          }
        });
      }
    } catch (err) {
      console.error(`[rhizo-ear] could not start pubsub listener for channel ${chan}:`, err);
    }
  }
  return {
    kill: () => {
      active = false;
      for (const p of procs) {
        try {
          p.kill();
        } catch {}
      }
    },
    procs
  };
}
function stopAgentListener(name) {
  const listener = activeListeners.get(name);
  if (listener) {
    if (listener.pubsub) {
      try {
        listener.pubsub.kill();
      } catch {}
    }
    if (listener.state)
      listener.state.aborted = true;
    if (listener.state?.proc?.kill) {
      try {
        listener.state.proc.kill();
      } catch {}
    }
    activeListeners.delete(name);
  }
}
function startAgentListener(client, name, cwd, targetSessionId) {
  if (targetSessionId) {
    const existingAgent = sessionToAgent.get(targetSessionId);
    if (existingAgent && existingAgent !== name) {
      stopAgentListener(existingAgent);
    }
    sessionToAgent.set(targetSessionId, name);
  }
  if (activeListeners.has(name))
    return;
  const state = { aborted: false, proc: null };
  const pubsub = startPubSubPreemption(client, name, targetSessionId, cwd);
  activeListeners.set(name, { state, targetSessionId, pubsub });
  let busy = false;
  const queue = [];
  function next() {
    busy = false;
    if (queue.length) {
      const item = queue.shift();
      if (item)
        offer(item);
    }
  }
  async function resolveTargetSession() {
    if (targetSessionId)
      return targetSessionId;
    const mappedSid = getSessionIdForAgent(name);
    if (mappedSid)
      return mappedSid;
    try {
      if (!client.session?.list)
        return null;
      const res = await client.session.list();
      const list = Array.isArray(res) ? res : res && ("data" in res) && Array.isArray(res.data) ? res.data : [];
      if (!Array.isArray(list) || list.length === 0)
        return null;
      const live = list.filter((s) => !(s.time && s.time.archived)).sort((a, b) => (b.time && b.time.updated || 0) - (a.time && a.time.updated || 0));
      return live[0]?.id || null;
    } catch {
      return null;
    }
  }
  async function run(text, attempt) {
    try {
      const id = await resolveTargetSession();
      if (!id)
        throw new Error("no opencode session");
      let isImmediate = false;
      const allowInterrupt = process.env.RHIZO_INTERRUPT !== "0";
      if (allowInterrupt) {
        if (process.env.RHIZO_ABORT_ON_BUSY === "1" || process.env.RHIZO_INTERRUPT === "1") {
          isImmediate = true;
        } else {
          isImmediate = resolveMessageUrgency(text) === "immediate";
        }
      }
      if (isImmediate) {
        await interruptSessionIfBusy(client, id);
      }
      await deliverPrompt(client, id, text);
      next();
    } catch (err) {
      if (attempt >= 8) {
        queue.unshift(text);
        next();
      } else {
        setTimeout(() => run(text, attempt + 1), 250 * (attempt + 1));
      }
    }
  }
  function offer(text) {
    const isImmediate = resolveMessageUrgency(text) === "immediate";
    if (busy) {
      if (isImmediate) {
        console.error(`[rhizo-ear] urgent in-flight preemption: aborting busy session...`);
        resolveTargetSession().then(async (id) => {
          if (id) {
            await interruptSessionIfBusy(client, id);
          }
        }).catch(() => {});
      }
      queue.push(text);
      return;
    }
    busy = true;
    run(text, 0);
  }
  console.error(`[rhizo-ear] armed for ${name} (bin: ${getRhizoBin()})`);
  (async () => {
    try {
      for await (const line of listenLines(name, cwd, state)) {
        if (state.aborted)
          break;
        try {
          const jsonStart = line.indexOf("{");
          if (jsonStart >= 0) {
            const parsed = JSON.parse(line.slice(jsonStart));
            const taskId = parsed.task_id || (typeof parsed.id === "string" && parsed.id.startsWith("task-") ? parsed.id : null);
            if (taskId) {
              setActiveTask(name, taskId);
            }
            if (typeof parsed.body === "string") {
              const match = parsed.body.match(/Task ID:\s*([a-zA-Z0-9_-]+)/i);
              if (match && match[1]) {
                setActiveTask(name, match[1]);
              }
            }
          }
        } catch {}
        offer(`[rhizo:${name}] ${line}`);
      }
    } catch (e) {
      console.error(`[rhizo-ear] listener error for ${name}:`, e);
    } finally {
      if (pubsub) {
        try {
          pubsub.kill();
        } catch {}
      }
      activeListeners.delete(name);
    }
  })();
}
function verifyAndEnsureListener(client, sessionId, cwd = process.cwd()) {
  if (!sessionId)
    return false;
  const agentName = isSessionSupposedToListen(sessionId);
  if (!agentName) {
    const runningAgent = sessionToAgent.get(sessionId);
    if (runningAgent) {
      stopAgentListener(runningAgent);
      sessionToAgent.delete(sessionId);
    }
    return false;
  }
  sessionToAgent.set(sessionId, agentName);
  if (!isListenerAlive(agentName)) {
    console.error(`[rhizo-ear] Verifying session ${sessionId}: reviving listener for @${agentName}`);
    startAgentListener(client, agentName, cwd, sessionId);
    return true;
  }
  return true;
}
async function syncSessions(client, directory) {
  const cwd = directory || process.cwd();
  console.error(`[rhizo-ear] syncSessions called for cwd: ${cwd}`);
  try {
    if (!client.session?.list) {
      console.error(`[rhizo-ear] client.session.list is not available!`);
      return;
    }
    const res = await client.session.list();
    console.error(`[rhizo-ear] client.session.list in ${cwd}:`, typeof res === "object" ? JSON.stringify(res).slice(0, 200) : res);
    const list = Array.isArray(res) ? res : res && ("data" in res) && Array.isArray(res.data) ? res.data : [];
    if (!Array.isArray(list))
      return;
    for (const s of list) {
      if (s.time && s.time.archived)
        continue;
      const name = isSessionSupposedToListen(s.id);
      if (name) {
        verifyAndEnsureListener(client, s.id, cwd);
      }
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[rhizo-ear] could not sync sessions:", msg);
  }
}

// src/orientation.ts
function getOrientationReminder(sessionId) {
  if (sessionId) {
    const sessionKey = `opencode:${sessionId}`;
    const map = readLocalSessionMap();
    const entry = map[sessionKey];
    if (typeof entry === "object" && entry.status !== "closed") {
      const workspacePath = entry.strand_path || entry.rifttree_path;
      if (workspacePath) {
        const taskLabel = entry.task_id ? `for task '${entry.task_id}' ` : "";
        return `[RHIZO CONTEXT ANCHOR: You have an active isolated workspace/strand ${taskLabel}at: ` + `${workspacePath}. Do not commit changes to the canonical repository root. ` + `Verify with 'git status' inside your workspace.]`;
      }
    }
  }
  return `[RHIZO NOTICE: If this task was operating in an isolated workspace/strand, inspect active workspaces ` + `(e.g., via 'vine list' or checking ~/Development/workspaces/) and .vine.json to reorient ` + `yourself before making edits in the canonical repository root.]`;
}

// src/index.ts
var armedDirectories = new Set;
async function handleKeepAlive(sessionId, reason) {
  const agent = sessionId ? sessionToAgent.get(sessionId) || isSessionSupposedToListen(sessionId) : process.env.RHIZO_AGENT_NAME;
  const effectiveAgent = agent || process.env.RHIZO_AGENT_NAME || "";
  const taskId = resolveActiveTaskId(effectiveAgent, sessionId);
  if (taskId) {
    return await pingTaskProgress(getRhizoBin(), taskId, effectiveAgent, reason || "Tool/file activity");
  }
  return false;
}
var RhizoEar = async (ctx) => {
  if (process.env.RHIZO_EAR_DISABLED === "1")
    return {};
  const client = ctx.client;
  const directory = ctx.directory || process.cwd();
  console.error("[rhizo-ear] init directory:", directory);
  if (!armedDirectories.has(directory)) {
    armedDirectories.add(directory);
    const envAgent = process.env.RHIZO_AGENT_NAME;
    if (envAgent) {
      startAgentListener(client, envAgent, directory, null);
    }
    syncSessions(client, directory).catch((e) => console.error("[rhizo-ear]", e));
  }
  return {
    "shell.env": async ({ sessionID }, output) => {
      if (sessionID && output && output.env) {
        const sessionKey = `opencode:${sessionID}`;
        output.env.RHIZO_SESSION_ID = sessionKey;
        let name = isSessionSupposedToListen(sessionID);
        if (!name) {
          name = resolveSessionAgent(sessionID);
        }
        if (name) {
          output.env.RHIZO_AGENT_NAME = name;
          verifyAndEnsureListener(client, sessionID, directory);
        }
      }
    },
    "tool.execute.before": async (data) => {
      const sid = data?.sessionID || data?.sessionId || data?.session?.id;
      const toolName = data?.name || data?.tool || "tool";
      await handleKeepAlive(sid, `tool.execute.before:${toolName}`);
    },
    "tool.execute.after": async (data) => {
      const sid = data?.sessionID || data?.sessionId || data?.session?.id;
      const toolName = data?.name || data?.tool || "tool";
      await handleKeepAlive(sid, `tool.execute.after:${toolName}`);
    },
    "fs.write": async (data) => {
      const sid = data?.sessionID || data?.sessionId || data?.session?.id;
      const path = data?.path || data?.file || "file";
      await handleKeepAlive(sid, `fs.write:${path}`);
    },
    "file.edited": async (data) => {
      const sid = data?.sessionID || data?.sessionId || data?.session?.id;
      const path = data?.path || data?.file || "file";
      await handleKeepAlive(sid, `file.edited:${path}`);
    },
    event: async ({ event }) => {
      if (!event)
        return;
      if (event.type && (event.type.startsWith("tool.") || event.type === "tool_call" || event.type === "tool_execution" || event.type.startsWith("file.") || event.type.startsWith("fs."))) {
        const sid = event.properties?.info?.id || event.properties?.sessionID;
        await handleKeepAlive(sid, `event:${event.type}`);
      }
      if (event.type === "session.created" && event.properties?.info?.id) {
        const s = event.properties.info;
        let name = isSessionSupposedToListen(s.id);
        if (!name) {
          name = resolveSessionAgent(s.id, s.title);
        }
        if (name) {
          verifyAndEnsureListener(client, s.id, directory);
        }
      } else if (event.type === "session.deleted" && event.properties?.info?.id) {
        const sid = event.properties.info.id;
        closeSessionAgent(`opencode:${sid}`);
        removeMappedAgent(`opencode:${sid}`);
        const agent = sessionToAgent.get(sid);
        if (agent) {
          stopAgentListener(agent);
          sessionToAgent.delete(sid);
        }
      } else if ((event.type === "session.resumed" || event.type === "session.selected" || event.type === "session.updated") && event.properties?.info?.id) {
        const s = event.properties.info;
        let name = isSessionSupposedToListen(s.id);
        if (!name) {
          name = resolveSessionAgent(s.id, s.title);
        }
        if (name) {
          verifyAndEnsureListener(client, s.id, directory);
        }
      }
    }
  };
};
var attachHelpers = (fn) => {
  fn.getRhizoBin = getRhizoBin;
  fn.sanitizeAgentName = sanitizeAgentName;
  fn.interruptSessionIfBusy = interruptSessionIfBusy;
  fn.deliverPrompt = deliverPrompt;
  fn.resolveMessageUrgency = resolveMessageUrgency;
  fn.isSessionSupposedToListen = isSessionSupposedToListen;
  fn.verifyAndEnsureListener = verifyAndEnsureListener;
  fn.closeSessionAgent = closeSessionAgent;
  fn.isListenerAlive = isListenerAlive;
  fn.setMappedAgent = setMappedAgent;
  fn.getOrientationReminder = getOrientationReminder;
  fn.pingTaskProgress = pingTaskProgress;
  fn.queryActiveReminders = queryActiveReminders;
  fn.formatAdvisoryBlock = formatAdvisoryBlock;
  fn.startPubSubPreemption = startPubSubPreemption;
  fn.setActiveTask = setActiveTask;
  fn.getActiveTask = getActiveTask;
  fn.resolveActiveTaskId = resolveActiveTaskId;
  fn.handleKeepAlive = handleKeepAlive;
  return fn;
};
attachHelpers(RhizoEar);
var src_default = RhizoEar;
export {
  handleKeepAlive,
  src_default as default,
  RhizoEar
};
