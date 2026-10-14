# rhizo/tests/test_protocol_tripwire.nim
# Native Nim integration tests for Rhizo with Tripwire Redis passthrough & Lua protocol spying.

import tripwire
import ./plugins/redis_tripwire
import std/[os, strutils, json, tables, unittest]
import config, rhizo

suite "Rhizo Native Tripwire Redis Passthrough Suite":

  test "Registration, Enqueue, and Mutex execute real Lua with Tripwire protocol spying":
    sandbox:
      allow(redisPluginInstance)

      var cfg = resolveFullConfig()
      cfg.prefix = "rhizo:tw_test:"

      # 1. Register agent 'tw_alice' with tag 'worker'
      doOpen(cfg, "tw_alice", "worker")

      # 2. Enqueue a task to 'tw_queue'
      let taskId = doEnqueue(cfg, "tw_queue", "task", "tw_alice", "Math Task", "Compute fast Fourier transform", tags = @["math", "dsp"])
      check taskId.len > 0
      check taskId.startsWith("msg_")

      # 3. Acquire distributed mutex with monotonic fencing token
      let (owner, fence) = doLock(cfg, "tw_mutex", ttlSec = 30, withFencing = true)
      check owner.len > 0
      check fence >= 0

      # 4. Release mutex
      let (unlocked, count) = doUnlock(cfg, "tw_mutex")
      check count >= 0

      # 5. TRIPWIRE SPY: Verify interactions were recorded on the timeline
      let entries = currentVerifier().timeline.entries
      check entries.len >= 4

      var foundRegister = false
      var foundEnqueue = false
      var foundLock = false
      var foundUnlock = false

      for e in entries:
        if e.procName == "runLuaScript" and tables.hasKey(e.args, ".fp"):
          let fp = e.args[".fp"]
          if fp.contains("tw_alice") and fp.contains("worker"):
            foundRegister = true
          if fp.contains("tw_queue") and fp.contains("Compute fast Fourier transform"):
            foundEnqueue = true
          if fp.contains("tw_mutex") and fp.contains("30"):
            foundLock = true
          if fp.contains("tw_mutex") and fp.contains("tw_alice"):
            foundUnlock = true

      check foundRegister
      check foundEnqueue
      check foundLock
      check foundUnlock

  test "Reliable Work Queue: Enqueue, Claim, Renew Lease, and Ack with Tripwire spying":
    sandbox:
      allow(redisPluginInstance)

      var cfg = resolveFullConfig()
      cfg.prefix = "rhizo:tw_queue_test:"

      # 1. Enqueue task
      let taskId = doEnqueue(cfg, "tw_job_queue", "task", "tw_alice", "Job 1", "Heavy payload computation")
      check taskId.len > 0

      # 2. Claim task from queue via claimLua
      let claimRaw = runLuaScript(cfg.redisUrl, claimLua, claimSha, [cfg.prefix, "tw_job_queue", "tw_bob", "60", "3"])
      check claimRaw.len > 0
      let taskObj = parseJson(claimRaw)
      check taskObj["id"].getStr() == taskId

      # 3. Renew lease
      doClaimRenew(cfg, "tw_job_queue", taskId, leaseSec = 180)

      # 4. Acknowledge task completion
      let ackRes = doAck(cfg, "tw_job_queue", taskId)
      check ackRes == 1

      # 5. TRIPWIRE SPY: Verify exact Lua calls occurred in order
      let entries = currentVerifier().timeline.entries
      var foundEnqueue = false
      var foundClaim = false
      var foundRenew = false
      var foundAck = false

      for e in entries:
        if e.procName == "runLuaScript" and tables.hasKey(e.args, ".fp"):
          let fp = e.args[".fp"]
          if fp.contains("tw_job_queue") and fp.contains("Heavy payload computation"):
            foundEnqueue = true
          if fp.contains("tw_job_queue") and fp.contains("tw_bob"):
            foundClaim = true
          if fp.contains("tw_job_queue") and fp.contains("180"):
            foundRenew = true
          if fp.contains("tw_job_queue") and fp.contains(taskId):
            foundAck = true

      check foundEnqueue
      check foundClaim
      check foundRenew
      check foundAck

  test "Shared Memory Blackboard: Set, Get, and Del with Tripwire spying":
    sandbox:
      allow(redisPluginInstance)

      var cfg = resolveFullConfig()
      cfg.prefix = "rhizo:tw_bb_test:"

      # 1. Set key on blackboard
      let setRes = doBlackboard(cfg, "set", "tw_room", "agent_state", "ready_for_work", ttlSec = 300)
      check setRes == "OK"

      # 2. Get key
      let val = doBlackboard(cfg, "get", "tw_room", "agent_state")
      check val == "ready_for_work"

      # 3. Delete key
      let delRes = doBlackboard(cfg, "del", "tw_room", "agent_state")
      check delRes == "OK"

      # 4. Verify gone
      let valAfter = doBlackboard(cfg, "get", "tw_room", "agent_state")
      check valAfter == ""

      # 5. TRIPWIRE SPY: Verify blackboardLua called for set, get, del
      let entries = currentVerifier().timeline.entries
      var foundSet = false
      var foundGet = false
      var foundDel = false

      for e in entries:
        if e.procName == "runLuaScript" and tables.hasKey(e.args, ".fp"):
          let fp = e.args[".fp"]
          if fp.contains("tw_room") and fp.contains("ready_for_work"):
            foundSet = true
          if fp.contains("tw_room") and fp.contains("get"):
            foundGet = true
          if fp.contains("tw_room") and fp.contains("del"):
            foundDel = true

      check foundSet
      check foundGet
      check foundDel

  test "Roundtable Floor Control: Request, Pass, Status, and Yield with Tripwire spying":
    sandbox:
      allow(redisPluginInstance)

      var cfg = resolveFullConfig()
      cfg.prefix = "rhizo:tw_floor_test:"

      # 1. Agent Alice acquires floor
      doFloorRequest(cfg, "tw_panel", "tw_alice", waitSec = 0, leaseSec = 60)

      # 2. Alice passes floor to Bob
      doFloorPass(cfg, "tw_panel", "tw_alice", "tw_bob", force = false, leaseSec = 60)

      # 3. Inspect floor status
      doFloorStatus(cfg, "tw_panel")

      # 4. Bob yields floor
      doFloorYield(cfg, "tw_panel", "tw_bob", force = false, leaseSec = 60)

      # 5. TRIPWIRE SPY: Verify floorLua calls
      let entries = currentVerifier().timeline.entries
      var foundRequest = false
      var foundPass = false
      var foundStatus = false
      var foundYield = false

      for e in entries:
        if e.procName == "runLuaScript" and tables.hasKey(e.args, ".fp"):
          let fp = e.args[".fp"]
          if fp.contains("tw_panel") and fp.contains("tw_alice") and fp.contains("request"):
            foundRequest = true
          if fp.contains("tw_panel") and fp.contains("tw_alice") and fp.contains("tw_bob"):
            foundPass = true
          if fp.contains("tw_panel") and fp.contains("status"):
            foundStatus = true
          if fp.contains("tw_panel") and fp.contains("tw_bob") and fp.contains("yield"):
            foundYield = true

      check foundRequest
      check foundPass
      check foundStatus
      check foundYield

  test "Workflow DAG Orchestration: Define, Next, Resolve, and Status with Tripwire spying":
    sandbox:
      allow(redisPluginInstance)

      var cfg = resolveFullConfig()
      cfg.prefix = "rhizo:tw_wf_test:"
      let flowId = "tw_flow_" & $getCurrentProcessId()

      # 1. Define DAG: step1 -> step2 -> step3
      doWorkflowDefine(cfg, flowId, "step1,step2,step3", "step2:step1;step3:step2", ttlSec = 3600)

      # 2. Next: step1 ready
      doWorkflowNext(cfg, flowId)

      # 3. Resolve step1 -> unlocks step2
      doWorkflowResolve(cfg, flowId, "step1", "output_step1")

      # 4. Next: step2 ready
      doWorkflowNext(cfg, flowId)

      # 5. Resolve step2 -> unlocks step3
      doWorkflowResolve(cfg, flowId, "step2", "output_step2")

      # 6. Resolve step3 -> completes flow
      doWorkflowResolve(cfg, flowId, "step3", "output_step3")

      # 7. Status check
      doWorkflowStatus(cfg, flowId)

      # 8. TRIPWIRE SPY: Verify workflowLua calls
      let entries = currentVerifier().timeline.entries
      var foundDefine = false
      var foundResolve = false
      var foundStatus = false

      for e in entries:
        if e.procName == "runLuaScript" and tables.hasKey(e.args, ".fp"):
          let fp = e.args[".fp"]
          if fp.contains(flowId) and fp.contains("define"):
            foundDefine = true
          if fp.contains(flowId) and fp.contains("resolve"):
            foundResolve = true
          if fp.contains(flowId) and fp.contains("status"):
            foundStatus = true

      check foundDefine
      check foundResolve
      check foundStatus

  test "Blind Consensus Ballot: Open, Cast, and Tally with Tripwire spying":
    sandbox:
      allow(redisPluginInstance)

      var cfg = resolveFullConfig()
      cfg.prefix = "rhizo:tw_bal_test:"
      let ballotId = "tw_bal_" & $getCurrentProcessId()

      # 1. Open ballot
      doBallotOpen(cfg, ballotId, "approve,reject", "tw_voter1,tw_voter2", ttlSec = 3600)

      # 2. Cast votes
      doBallotCast(cfg, ballotId, "tw_voter1", "approve")
      doBallotCast(cfg, ballotId, "tw_voter2", "approve")

      # 3. Tally and close
      doBallotTally(cfg, ballotId, closeBallot = true)

      # 4. TRIPWIRE SPY: Verify ballotLua calls
      let entries = currentVerifier().timeline.entries
      var foundOpen = false
      var foundCast = false
      var foundTally = false

      for e in entries:
        if e.procName == "runLuaScript" and tables.hasKey(e.args, ".fp"):
          let fp = e.args[".fp"]
          if fp.contains(ballotId) and fp.contains("open"):
            foundOpen = true
          if fp.contains(ballotId) and fp.contains("cast") and fp.contains("tw_voter1"):
            foundCast = true
          if fp.contains(ballotId) and fp.contains("tally"):
            foundTally = true

      check foundOpen
      check foundCast
      check foundTally

  test "Leader Mesh Election: Acquire, Renew, and Resign with Tripwire spying":
    sandbox:
      allow(redisPluginInstance)

      var cfg = resolveFullConfig()
      cfg.prefix = "rhizo:tw_ldr_test:"

      # 1. Acquire leadership
      doLeaderAcquire(cfg, "tw_lead_role", "tw_alice", leaseSec = 30)

      # 2. Renew leadership lease
      doLeaderRenew(cfg, "tw_lead_role", "tw_alice", leaseSec = 60)

      # 3. Resign leadership
      doLeaderResign(cfg, "tw_lead_role", "tw_alice")

      # 4. TRIPWIRE SPY: Verify leaderLua calls
      let entries = currentVerifier().timeline.entries
      var foundAcquire = false
      var foundRenew = false
      var foundResign = false

      for e in entries:
        if e.procName == "runLuaScript" and tables.hasKey(e.args, ".fp"):
          let fp = e.args[".fp"]
          if fp.contains("tw_lead_role") and fp.contains("acquire") and fp.contains("tw_alice"):
            foundAcquire = true
          if fp.contains("tw_lead_role") and fp.contains("renew") and fp.contains("tw_alice"):
            foundRenew = true
          if fp.contains("tw_lead_role") and fp.contains("resign") and fp.contains("tw_alice"):
            foundResign = true

      check foundAcquire
      check foundRenew
      check foundResign

  test "Cancellation Tokens: Set and Check with Tripwire HMAC signature spying":
    sandbox:
      allow(redisPluginInstance)

      var cfg = resolveFullConfig()
      cfg.prefix = "rhizo:tw_can_test:"
      let runId = "tw_run_" & $getCurrentProcessId()

      # 1. Set cancellation token
      doCancelSet(cfg, runId, "Emergency stop requested", "tw_alice")

      # 2. Check cancellation token
      doCancelCheck(cfg, runId)

      # 3. TRIPWIRE SPY: Verify cancelLua calls and arguments
      let entries = currentVerifier().timeline.entries
      var foundCancel = false
      var foundCheck = false

      for e in entries:
        if e.procName == "runLuaScript" and tables.hasKey(e.args, ".fp"):
          let fp = e.args[".fp"]
          if fp.contains(runId) and fp.contains("Emergency stop requested") and fp.contains("tw_alice"):
            foundCancel = true
          if fp.contains(runId) and fp.contains("check"):
            foundCheck = true

      check foundCancel
      check foundCheck
