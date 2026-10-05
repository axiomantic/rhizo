-- scripts/decision.lua
-- Operator Ruling & Architectural Decision Ledger
-- Provides verifiable human-in-the-loop decision tokens; prevents prose-based authority spoofing.

local prefix = ARGV[1]
if not prefix or prefix == "" then
    return redis.error_reply("ERR: Missing prefix")
end

local action = ARGV[2] or ""
local mock_offset = tonumber(redis.call('GET', prefix .. 'mock_time_offset') or 0)
local now = tonumber(redis.call('TIME')[1]) + mock_offset

if action == "propose" then
    local dec_id = ARGV[3]
    if not dec_id or dec_id == "" then
        return redis.error_reply("ERR: Missing decision_id")
    end
    local title = ARGV[4] or ""
    local summary = ARGV[5] or ""
    local proposed_by = ARGV[6] or "unknown"

    local dec_key = prefix .. "decision:" .. dec_id
    if redis.call('EXISTS', dec_key) == 1 then
        return redis.error_reply("ERR: Decision '" .. dec_id .. "' already exists")
    end

    redis.call('HSET', dec_key,
        "id", dec_id,
        "title", title,
        "summary", summary,
        "status", "PROPOSED",
        "proposed_by", proposed_by,
        "proposed_at", now,
        "ruled_by", "",
        "ruled_at", 0,
        "note", ""
    )
    redis.call('SADD', prefix .. "decisions", dec_id)
    return "OK"

elseif action == "approve" then
    local dec_id = ARGV[3]
    local note = ARGV[4] or ""
    local dec_key = prefix .. "decision:" .. dec_id
    if redis.call('EXISTS', dec_key) == 0 then
        return redis.error_reply("ERR: Decision '" .. dec_id .. "' does not exist")
    end

    redis.call('HSET', dec_key,
        "status", "APPROVED",
        "ruled_by", "operator",
        "ruled_at", now,
        "note", note
    )
    return "OK"

elseif action == "reject" then
    local dec_id = ARGV[3]
    local reason = ARGV[4] or ""
    local dec_key = prefix .. "decision:" .. dec_id
    if redis.call('EXISTS', dec_key) == 0 then
        return redis.error_reply("ERR: Decision '" .. dec_id .. "' does not exist")
    end

    redis.call('HSET', dec_key,
        "status", "REJECTED",
        "ruled_by", "operator",
        "ruled_at", now,
        "note", reason
    )
    return "OK"

elseif action == "verify" then
    local dec_id = ARGV[3]
    local dec_key = prefix .. "decision:" .. dec_id
    if redis.call('EXISTS', dec_key) == 0 then
        return "UNKNOWN"
    end
    return redis.call('HGET', dec_key, "status") or "UNKNOWN"

elseif action == "get" then
    local dec_id = ARGV[3]
    local dec_key = prefix .. "decision:" .. dec_id
    if redis.call('EXISTS', dec_key) == 0 then
        return "{}"
    end
    local data = redis.call('HGETALL', dec_key)
    local obj = {}
    for i = 1, #data, 2 do
        obj[data[i]] = data[i+1]
    end
    return cjson.encode(obj)

elseif action == "list" then
    local dec_ids = redis.call('SMEMBERS', prefix .. "decisions")
    local list = {}
    for _, did in ipairs(dec_ids) do
        local dec_key = prefix .. "decision:" .. did
        local data = redis.call('HGETALL', dec_key)
        local obj = {}
        for i = 1, #data, 2 do
            obj[data[i]] = data[i+1]
        end
        table.insert(list, obj)
    end
    return cjson.encode(list)

else
    return redis.error_reply("ERR: Unknown decision action: " .. action)
end
