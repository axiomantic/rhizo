-- scripts/reroute.lua
-- Atomically reroutes queued messages from one agent's inbox to another.
-- ARGV[1]: prefix (e.g. "rhizo:")
-- ARGV[2]: source agent name (from_agent)
-- ARGV[3]: destination agent name (to_agent)
-- ARGV[4]: mode ("all" or "unread")

local prefix = ARGV[1]
if not prefix or prefix == "" then
    return redis.error_reply("ERR: Missing prefix")
end

local function sanitize_name(s)
    if not s then return "" end
    s = string.match(s, "^%s*(.-)%s*$") or ""
    local changed = true
    while changed and #s >= 2 do
        changed = false
        local first = string.sub(s, 1, 1)
        local last = string.sub(s, -1, -1)
        if (first == '"' and last == '"') or (first == "'" and last == "'") or (first == "`" and last == "`") or (first == "<" and last == ">") or (first == "[" and last == "]") or (first == "(" and last == ")") then
            s = string.match(string.sub(s, 2, -2), "^%s*(.-)%s*$") or ""
            changed = true
        end
    end
    local low = string.lower(s)
    if string.sub(low, 1, 6) == "agent:" then
        s = string.sub(s, 7)
    elseif string.sub(low, 1, 5) == "user:" then
        s = string.sub(s, 6)
    elseif string.sub(low, 1, 6) == "inbox:" then
        s = string.sub(s, 7)
    end
    while string.sub(s, 1, 1) == "@" or string.sub(s, 1, 1) == "#" do
        s = string.sub(s, 2)
    end
    while #s > 0 and (string.sub(s, -1, -1) == ":" or string.sub(s, -1, -1) == "," or string.sub(s, -1, -1) == ";") do
        s = string.sub(s, 1, -2)
    end
    return string.lower(string.match(s, "^%s*(.-)%s*$") or "")
end

local from_agent = sanitize_name(ARGV[2] or "")
local to_agent = sanitize_name(ARGV[3] or "")
local mode = string.lower(ARGV[4] or "all")

if from_agent == "" or to_agent == "" then
    return redis.error_reply("ERR: Missing source or destination agent name")
end

-- Resolve aliases if configured
local from_alias = redis.call('HGET', prefix .. 'aliases', from_agent)
if from_alias and from_alias ~= false and from_alias ~= '' then
    from_agent = sanitize_name(from_alias)
end
local to_alias = redis.call('HGET', prefix .. 'aliases', to_agent)
if to_alias and to_alias ~= false and to_alias ~= '' then
    to_agent = sanitize_name(to_alias)
end

if from_agent == to_agent then
    return redis.error_reply("ERR: Cannot reroute to self")
end

local from_inbox = prefix .. "inbox:" .. from_agent
local to_inbox = prefix .. "inbox:" .. to_agent

local messages = redis.call("LRANGE", from_inbox, 0, -1)
if not messages or #messages == 0 then
    local res = {
        count = 0,
        from_agent = from_agent,
        to_agent = to_agent,
        status = "EMPTY"
    }
    return cjson.encode(res)
end

-- Clear source inbox
redis.call("DEL", from_inbox)

local rerouted_count = 0
-- Redis LRANGE returns head (newest/last pushed) to tail (oldest).
-- To preserve original FIFO delivery order when using LPUSH, we iterate from tail (#messages) to head (1).
for i = #messages, 1, -1 do
    local raw = messages[i]
    local success, parsed = pcall(cjson.decode, raw)
    if success and type(parsed) == "table" then
        if not parsed["original_recipient"] or parsed["original_recipient"] == "" then
            parsed["original_recipient"] = parsed["rerouted_from"] or parsed["to"] or from_agent
        end
        parsed["to"] = to_agent
        parsed["rerouted_from"] = from_agent
        local updated_json = cjson.encode(parsed)
        updated_json = string.gsub(updated_json, '"tags":{}', '"tags":[]')
        updated_json = string.gsub(updated_json, '"reminders":{}', '"reminders":[]')
        redis.call("LPUSH", to_inbox, updated_json)
        rerouted_count = rerouted_count + 1
    else
        redis.call("LPUSH", to_inbox, raw)
        rerouted_count = rerouted_count + 1
    end
end

-- Refresh inbox TTL (7 days)
redis.call("EXPIRE", to_inbox, 604800)

-- Publish wakeup notification to recipient
redis.call("PUBLISH", prefix .. "notify:" .. to_agent, tostring(rerouted_count))

local res = {
    count = rerouted_count,
    from_agent = from_agent,
    to_agent = to_agent,
    status = "REROUTED"
}
return cjson.encode(res)
