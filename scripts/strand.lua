-- scripts/strand.lua
-- Pure Redis Strand State Management & Three-Key Integration Gate State Machine
-- Invariants:
-- 1. Complete elimination of on-disk .vine.json dependency; Redis is the single source of truth.
-- 2. Strand metadata stored in HASH prefix .. "strand:" .. strand_id
-- 3. Strict lifecycle state machine: PROVISIONED -> SUBMITTED -> (RATIFIED | REJECTED) -> WOVEN
-- 4. Atomic ratification gate:
--    - Enforces independent auditor invariant: auditor_pubkey != author_pubkey (auditor != author)
--    - Enforces auditor liveness: checks active heartbeat lease (heartbeat:<auditor> or agent:<auditor> TTL)
--    - Enforces anti-blink temporal floor: audit review cannot occur faster than minimum temporal duration
--    - Atomic state transition and index set maintenance across states and projects
--
-- ARGV[1]: prefix (e.g. "rhizo:")
-- ARGV[2]: action ("create", "submit", "ratify", "reject", "weave", "get", "list")
-- ARGV[3..]: action-specific parameters

local prefix = ARGV[1]
if not prefix or prefix == "" then
    return redis.error_reply("ERR: Missing prefix")
end

local action = string.lower(ARGV[2] or "")
if action == "" then
    return redis.error_reply("ERR: Missing action")
end

-- Virtual / Mock time resolution for deterministic testing and live clusters
local mock_offset = tonumber(redis.call('GET', prefix .. 'mock_time_offset') or 0)
local now = tonumber(redis.call('TIME')[1]) + mock_offset

--------------------------------------------------------------------------------
-- Helper: Atomic State & Index Set Maintenance
--------------------------------------------------------------------------------
local function update_strand_state(strand_id, old_state, new_state, project)
    if old_state and old_state ~= "" then
        redis.call('SREM', prefix .. "strands:state:" .. string.lower(old_state), strand_id)
    end
    redis.call('SADD', prefix .. "strands:state:" .. string.lower(new_state), strand_id)
    redis.call('SADD', prefix .. "strands", strand_id)
    if project and project ~= "" then
        redis.call('SADD', prefix .. "strands:project:" .. string.lower(project), strand_id)
    end
end

--------------------------------------------------------------------------------
-- 1. ACTION: create
-- ARGV[3]: strand_id
-- ARGV[4]: project
-- ARGV[5]: strand_path
-- ARGV[6]: branch
-- ARGV[7]: base_branch
-- ARGV[8]: base_commit
-- ARGV[9]: author / worker
-- ARGV[10]: author_pubkey
-- ARGV[11]: orchestrator
-- ARGV[12]: canonical_repo
--------------------------------------------------------------------------------
if action == "create" then
    local strand_id = string.lower(ARGV[3] or "")
    if strand_id == "" then
        return redis.error_reply("ERR: Missing strand_id")
    end

    local strand_key = prefix .. "strand:" .. strand_id
    if redis.call('EXISTS', strand_key) == 1 then
        local current_state = redis.call('HGET', strand_key, "state") or ""
        if current_state ~= "WOVEN" then
            return redis.error_reply("ERR: Strand '" .. strand_id .. "' already exists in state '" .. current_state .. "'")
        end
    end

    local project = string.lower(ARGV[4] or "")
    local strand_path = ARGV[5] or ""
    local branch = ARGV[6] or ""
    local base_branch = ARGV[7] or "main"
    local base_commit = ARGV[8] or ""
    local author = ARGV[9] or ""
    local author_pubkey = ARGV[10] or author
    local orchestrator = ARGV[11] or ""
    local canonical_repo = ARGV[12] or ""

    redis.call('HSET', strand_key,
        "id", strand_id,
        "task_id", strand_id,
        "project", project,
        "strand_path", strand_path,
        "branch", branch,
        "base_branch", base_branch,
        "parent_branch", base_branch,
        "base_commit", base_commit,
        "intended_merge_base", base_commit,
        "author", author,
        "author_pubkey", author_pubkey,
        "worker", author,
        "orchestrator", orchestrator,
        "canonical_repo", canonical_repo,
        "state", "PROVISIONED",
        "lifecycle_state", "PROVISIONED",
        "created_at", tostring(now),
        "submitted_at", "0",
        "ratified_at", "0",
        "rejected_at", "0",
        "woven_at", "0",
        "gate_token", "",
        "audit_token", "",
        "auditor", "",
        "auditor_pubkey", "",
        "rejection_reason", "",
        "notes", ""
    )

    update_strand_state(strand_id, nil, "PROVISIONED", project)

    return cjson.encode({
        status = "OK",
        id = strand_id,
        task_id = strand_id,
        project = project,
        state = "PROVISIONED",
        lifecycle_state = "PROVISIONED",
        strand_path = strand_path,
        branch = branch,
        base_commit = base_commit,
        author = author,
        author_pubkey = author_pubkey,
        created_at = now
    })

--------------------------------------------------------------------------------
-- 2. ACTION: submit
-- ARGV[3]: strand_id
-- ARGV[4]: gate_token (Keys 1 & 2 verification token)
-- ARGV[5]: author / worker (optional, update if provided)
-- ARGV[6]: author_pubkey (optional, update if provided)
-- ARGV[7]: head_commit (optional)
--------------------------------------------------------------------------------
elseif action == "submit" then
    local strand_id = string.lower(ARGV[3] or "")
    if strand_id == "" then
        return redis.error_reply("ERR: Missing strand_id")
    end

    local strand_key = prefix .. "strand:" .. strand_id
    if redis.call('EXISTS', strand_key) == 0 then
        return redis.error_reply("ERR: Strand '" .. strand_id .. "' does not exist")
    end

    local meta = redis.call('HMGET', strand_key, "state", "project", "author", "author_pubkey")
    local old_state = meta[1] or ""
    local project = meta[2] or ""
    local curr_author = meta[3] or ""
    local curr_author_pubkey = meta[4] or ""

    if old_state == "SUBMITTED" then
        return redis.error_reply("ERR: Strand '" .. strand_id .. "' is already in SUBMITTED state")
    elseif old_state == "RATIFIED" then
        return redis.error_reply("ERR: Strand '" .. strand_id .. "' is already RATIFIED; cannot re-submit")
    elseif old_state == "WOVEN" then
        return redis.error_reply("ERR: Strand '" .. strand_id .. "' is already WOVEN")
    end

    local gate_token = ARGV[4] or ""
    if gate_token == "" then
        return redis.error_reply("ERR: Missing gate_token from Key 1 and Key 2 verification")
    end

    local author = ARGV[5] or curr_author
    local author_pubkey = ARGV[6] or (author ~= "" and author or curr_author_pubkey)
    local head_commit = ARGV[7] or ""

    redis.call('HSET', strand_key,
        "gate_token", gate_token,
        "state", "SUBMITTED",
        "lifecycle_state", "SUBMITTED",
        "submitted_at", tostring(now),
        "author", author,
        "author_pubkey", author_pubkey
    )
    if head_commit ~= "" then
        redis.call('HSET', strand_key, "head_commit", head_commit)
    end

    update_strand_state(strand_id, old_state, "SUBMITTED", project)

    return cjson.encode({
        status = "OK",
        id = strand_id,
        state = "SUBMITTED",
        lifecycle_state = "SUBMITTED",
        gate_token = gate_token,
        submitted_at = now,
        author = author,
        author_pubkey = author_pubkey
    })

--------------------------------------------------------------------------------
-- 3. ACTION: ratify
-- Invariants enforced atomically:
--   1. auditor_pubkey != author_pubkey (auditor != author; self-ratification prohibited)
--   2. active heartbeat lease check for auditor
--   3. anti-blink temporal floor check: now - submitted_at >= anti_blink_floor
--   4. atomic transition to RATIFIED and index set update
--
-- ARGV[3]: strand_id
-- ARGV[4]: auditor_pubkey
-- ARGV[5]: auditor_name
-- ARGV[6]: audit_token
-- ARGV[7]: notes / findings
-- ARGV[8]: anti_blink_floor (default 5 seconds)
--------------------------------------------------------------------------------
elseif action == "ratify" then
    local strand_id = string.lower(ARGV[3] or "")
    if strand_id == "" then
        return redis.error_reply("ERR: Missing strand_id")
    end

    local strand_key = prefix .. "strand:" .. strand_id
    if redis.call('EXISTS', strand_key) == 0 then
        return redis.error_reply("ERR: Strand '" .. strand_id .. "' does not exist")
    end

    local meta = redis.call('HMGET', strand_key, "state", "project", "author", "author_pubkey", "submitted_at")
    local current_state = meta[1] or ""
    local project = meta[2] or ""
    local author = meta[3] or ""
    local author_pubkey = meta[4] or ""
    local submitted_at = tonumber(meta[5] or 0) or 0

    if current_state ~= "SUBMITTED" then
        return redis.error_reply("ERR: Strand '" .. strand_id .. "' must be in SUBMITTED state to ratify (current state: " .. current_state .. ")")
    end

    local auditor_pubkey = ARGV[4] or ""
    if auditor_pubkey == "" then
        return redis.error_reply("ERR: Missing auditor_pubkey for Key 3 ratification")
    end

    local auditor_name = ARGV[5] or auditor_pubkey
    local audit_token = ARGV[6] or ""
    if audit_token == "" then
        return redis.error_reply("ERR: Missing audit_token for Key 3 ratification")
    end
    local notes = ARGV[7] or ""
    local anti_blink_floor = tonumber(ARGV[8] or 5) or 5

    -- INVARIANT 1: Independent Auditor (auditor_pubkey != author_pubkey)
    if author_pubkey ~= "" and string.lower(auditor_pubkey) == string.lower(author_pubkey) then
        return redis.error_reply("ERR: Independent auditor required: auditor_pubkey cannot match author_pubkey (self-ratification prohibited)")
    end
    if author ~= "" and string.lower(auditor_name) == string.lower(author) then
        return redis.error_reply("ERR: Independent auditor required: auditor cannot match author (self-ratification prohibited)")
    end

    -- INVARIANT 2: Active Heartbeat Lease Check
    local auditor_norm = string.lower(auditor_name)
    local hb_key = prefix .. "heartbeat:" .. auditor_norm
    local hb_exists = redis.call('EXISTS', hb_key)
    if hb_exists == 0 then
        -- Also check agent record last_seen and heartbeat_ttl
        local agent_meta = redis.call('HMGET', prefix .. "agent:" .. auditor_norm, "last_seen", "heartbeat_ttl")
        local last_seen = tonumber(agent_meta[1] or 0) or 0
        local hb_ttl = tonumber(agent_meta[2] or 150) or 150
        if last_seen == 0 or (now - last_seen) > hb_ttl then
            return redis.error_reply("ERR: Auditor '" .. auditor_name .. "' does not hold an active heartbeat lease")
        end
    end

    -- INVARIANT 3: Anti-Blink Temporal Floor Check
    local elapsed = now - submitted_at
    if elapsed < anti_blink_floor then
        return redis.error_reply("ERR: Anti-blink temporal floor violation: audit duration " .. elapsed .. "s is below minimum required " .. anti_blink_floor .. "s")
    end

    -- INVARIANT 4: Atomic State Transition & Index Set Maintenance
    redis.call('HSET', strand_key,
        "state", "RATIFIED",
        "lifecycle_state", "RATIFIED",
        "ratified_at", tostring(now),
        "auditor", auditor_name,
        "auditor_pubkey", auditor_pubkey,
        "audit_token", audit_token,
        "notes", notes
    )

    update_strand_state(strand_id, "SUBMITTED", "RATIFIED", project)

    return cjson.encode({
        status = "OK",
        id = strand_id,
        state = "RATIFIED",
        lifecycle_state = "RATIFIED",
        ratified_at = now,
        auditor = auditor_name,
        auditor_pubkey = auditor_pubkey,
        audit_token = audit_token,
        audit_duration = elapsed
    })

--------------------------------------------------------------------------------
-- 4. ACTION: reject
-- ARGV[3]: strand_id
-- ARGV[4]: auditor_pubkey
-- ARGV[5]: auditor_name
-- ARGV[6]: reason
-- ARGV[7]: notes
--------------------------------------------------------------------------------
elseif action == "reject" then
    local strand_id = string.lower(ARGV[3] or "")
    if strand_id == "" then
        return redis.error_reply("ERR: Missing strand_id")
    end

    local strand_key = prefix .. "strand:" .. strand_id
    if redis.call('EXISTS', strand_key) == 0 then
        return redis.error_reply("ERR: Strand '" .. strand_id .. "' does not exist")
    end

    local meta = redis.call('HMGET', strand_key, "state", "project", "author", "author_pubkey")
    local current_state = meta[1] or ""
    local project = meta[2] or ""
    local author = meta[3] or ""
    local author_pubkey = meta[4] or ""

    if current_state ~= "SUBMITTED" then
        return redis.error_reply("ERR: Strand '" .. strand_id .. "' must be in SUBMITTED state to reject (current state: " .. current_state .. ")")
    end

    local auditor_pubkey = ARGV[4] or ""
    local auditor_name = ARGV[5] or auditor_pubkey
    local reason = ARGV[6] or ""
    if reason == "" then
        return redis.error_reply("ERR: Missing rejection defect reason")
    end
    local notes = ARGV[7] or ""

    -- Self-rejection check
    if author_pubkey ~= "" and string.lower(auditor_pubkey) == string.lower(author_pubkey) then
        return redis.error_reply("ERR: Independent auditor required: auditor_pubkey cannot match author_pubkey")
    end

    redis.call('HSET', strand_key,
        "state", "REJECTED",
        "lifecycle_state", "REJECTED",
        "rejected_at", tostring(now),
        "auditor", auditor_name,
        "auditor_pubkey", auditor_pubkey,
        "rejection_reason", reason,
        "notes", notes
    )

    update_strand_state(strand_id, "SUBMITTED", "REJECTED", project)

    return cjson.encode({
        status = "OK",
        id = strand_id,
        state = "REJECTED",
        lifecycle_state = "REJECTED",
        rejected_at = now,
        auditor = auditor_name,
        rejection_reason = reason
    })

--------------------------------------------------------------------------------
-- 5. ACTION: weave
-- Enforces: Only RATIFIED strands can be woven into canonical trunk
--
-- ARGV[3]: strand_id
-- ARGV[4]: merge_commit
-- ARGV[5]: by_agent (e.g. orchestrator)
--------------------------------------------------------------------------------
elseif action == "weave" then
    local strand_id = string.lower(ARGV[3] or "")
    if strand_id == "" then
        return redis.error_reply("ERR: Missing strand_id")
    end

    local strand_key = prefix .. "strand:" .. strand_id
    if redis.call('EXISTS', strand_key) == 0 then
        return redis.error_reply("ERR: Strand '" .. strand_id .. "' does not exist")
    end

    local meta = redis.call('HMGET', strand_key, "state", "project")
    local current_state = meta[1] or ""
    local project = meta[2] or ""

    if current_state ~= "RATIFIED" then
        return redis.error_reply("ERR: Cannot weave unratified strand '" .. strand_id .. "' (current state: " .. current_state .. ", required: RATIFIED)")
    end

    local merge_commit = ARGV[4] or ""
    local by_agent = ARGV[5] or ""

    redis.call('HSET', strand_key,
        "state", "WOVEN",
        "lifecycle_state", "WOVEN",
        "woven_at", tostring(now),
        "merge_commit", merge_commit,
        "woven_by", by_agent
    )

    update_strand_state(strand_id, "RATIFIED", "WOVEN", project)

    return cjson.encode({
        status = "OK",
        id = strand_id,
        state = "WOVEN",
        lifecycle_state = "WOVEN",
        woven_at = now,
        merge_commit = merge_commit,
        woven_by = by_agent
    })

--------------------------------------------------------------------------------
-- 6. ACTION: get
-- ARGV[3]: strand_id
--------------------------------------------------------------------------------
elseif action == "get" then
    local strand_id = string.lower(ARGV[3] or "")
    if strand_id == "" then
        return redis.error_reply("ERR: Missing strand_id")
    end

    local strand_key = prefix .. "strand:" .. strand_id
    if redis.call('EXISTS', strand_key) == 0 then
        return redis.error_reply("ERR: Strand '" .. strand_id .. "' does not exist")
    end

    local raw = redis.call('HGETALL', strand_key)
    local strand = {}
    for i = 1, #raw, 2 do
        local k = raw[i]
        local v = raw[i + 1]
        if k == "created_at" or k == "submitted_at" or k == "ratified_at" or k == "rejected_at" or k == "woven_at" then
            strand[k] = tonumber(v) or 0
        else
            strand[k] = v
        end
    end

    return cjson.encode({
        status = "OK",
        strand = strand
    })

--------------------------------------------------------------------------------
-- 7. ACTION: list
-- ARGV[3]: optional state filter (e.g. "submitted", "ratified", or empty for all)
-- ARGV[4]: optional project filter
--------------------------------------------------------------------------------
elseif action == "list" then
    local state_filter = string.lower(ARGV[3] or "")
    local project_filter = string.lower(ARGV[4] or "")

    local target_set
    if state_filter ~= "" and state_filter ~= "*" then
        target_set = prefix .. "strands:state:" .. state_filter
    elseif project_filter ~= "" and project_filter ~= "*" then
        target_set = prefix .. "strands:project:" .. project_filter
    else
        target_set = prefix .. "strands"
    end

    local ids = redis.call('SMEMBERS', target_set)
    local strands = {}

    for _, sid in ipairs(ids) do
        local strand_key = prefix .. "strand:" .. sid
        if redis.call('EXISTS', strand_key) == 1 then
            local raw = redis.call('HGETALL', strand_key)
            local s = {}
            for i = 1, #raw, 2 do
                local k = raw[i]
                local v = raw[i + 1]
                if k == "created_at" or k == "submitted_at" or k == "ratified_at" or k == "rejected_at" or k == "woven_at" then
                    s[k] = tonumber(v) or 0
                else
                    s[k] = v
                end
            end
            -- Apply secondary project filter if state filter was used
            if project_filter == "" or project_filter == "*" or string.lower(s.project or "") == project_filter then
                table.insert(strands, s)
            end
        end
    end

    return cjson.encode({
        status = "OK",
        count = #strands,
        strands = strands
    })

else
    return redis.error_reply("ERR: Unknown strand action '" .. action .. "'")
end
