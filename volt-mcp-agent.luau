-- Volt MCP agent: runs the commands volt_mcp.py drops into workspace/mcp/in/<userId>/ and writes each result to
-- workspace/mcp/out/<userId>/. Installed into Volt's autoexec; one copy per DataModel (a teleport starts a new one).
local Players = game:GetService("Players")
local me = Players.LocalPlayer
while not me do task.wait(0.5); me = Players.LocalPlayer end
local env = getgenv()
local mine = {} -- this run's token: a newer copy replaces it and this loop ends
env.__VoltMCP = mine

local Http = game:GetService("HttpService")
local setIdentity = setthreadidentity or setidentity
local uid = tostring(me.UserId)
local inbox, outbox = "mcp/in/" .. uid, "mcp/out/" .. uid
for _, folder in ipairs({ "mcp", "mcp/in", "mcp/out", "mcp/clients", inbox, outbox }) do
    if not isfolder(folder) then makefolder(folder) end
end

-- Console: the last 500 lines, each { n, t, kind, text }.
local lines, count = {}, 0
local kinds = { [Enum.MessageType.MessageOutput] = "print", [Enum.MessageType.MessageInfo] = "info",
    [Enum.MessageType.MessageWarning] = "warn", [Enum.MessageType.MessageError] = "error" }
local function record(kind, text)
    count += 1
    table.insert(lines, { n = count, t = os.time(), kind = kind, text = string.sub(tostring(text), 1, 2000) })
    if #lines > 500 then table.remove(lines, 1) end
end
local logging = game:GetService("LogService").MessageOut:Connect(function(text, kind) record(kinds[kind] or "print", text) end)
-- Volt sends an executor script's print and warn to its own console, not to LogService (seen live), so prints from other
-- executor scripts and from an eval never reach MessageOut. The shared globals are wrapped once to record them too.
-- ponytail: with Volt's redirectOutput switched off these lines would show twice; dedupe here if that is ever used.
env.__VoltMCPSink = record
if not env.__VoltMCPWrapped then
    env.__VoltMCPWrapped = true
    for kind, real in pairs({ print = print, warn = warn }) do
        env[kind] = function(...)
            local sink, parts = env.__VoltMCPSink, table.pack(...)
            for i = 1, parts.n do parts[i] = tostring(parts[i]) end
            if sink then pcall(sink, kind, table.concat(parts, " ")) end
            return real(...)
        end
    end
end
local function since(n, limit)
    local out = {}
    for _, line in ipairs(lines) do if line.n > n then table.insert(out, line) end end
    while limit and #out > limit do table.remove(out, 1) end
    return out
end

-- A value JSON can carry: Instances become their full name, other Roblox types their tostring.
local function plain(value, depth, seen)
    local kind = typeof(value)
    if kind == "nil" or kind == "boolean" then return value end
    if kind == "string" then return utf8.len(value) and value or "<binary string, " .. #value .. " bytes>" end
    if kind == "number" then return (value ~= value or math.abs(value) == math.huge) and tostring(value) or value end
    if kind == "Instance" then return value:GetFullName() end
    if kind ~= "table" then return tostring(value) end
    if seen[value] then return "<cycle>" end
    if depth > 8 then return "<table>" end
    seen[value] = true
    local keys = 0
    for _ in pairs(value) do keys += 1 end
    local out = {}
    if keys == #value then
        for i, item in ipairs(value) do out[i] = plain(item, depth + 1, seen) end
    else
        for key, item in pairs(value) do out[tostring(key)] = plain(item, depth + 1, seen) end
    end
    seen[value] = nil
    return out
end

local function reply(id, result)
    result.id = id
    local ok, text = pcall(Http.JSONEncode, Http, result)
    if not ok then text = Http:JSONEncode({ id = id, ok = false, error = "result could not be encoded: " .. tostring(text) }) end
    writefile(outbox .. "/" .. id .. ".json", text)
end

local function run(cmd)
    if cmd.kind == "console" then return reply(cmd.id, { ok = true, value = since(0, tonumber(cmd.limit) or 100) }) end
    -- An expression returns its value; anything else runs as a block.
    local fn, err = loadstring("return " .. cmd.code, "=mcp")
    if not fn then fn, err = loadstring(cmd.code, "=mcp") end
    if not fn then return reply(cmd.id, { ok = false, error = "compile error: " .. tostring(err) }) end
    local from = count
    if cmd.kind == "execute" then
        local failed
        task.spawn(function()
            if setIdentity then pcall(setIdentity, 8) end
            local ok, e = xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end)
            if not ok then failed = e; warn("[volt-mcp] " .. tostring(e)) end
        end)
        task.wait(0.4) -- long enough to catch code that dies on its first frame
        return reply(cmd.id, { ok = failed == nil, value = "scheduled", error = failed, output = since(from) })
    end
    if setIdentity then pcall(setIdentity, 8) end
    local got = table.pack(xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end))
    task.wait() -- prints from the run reach MessageOut a frame later
    if not got[1] then return reply(cmd.id, { ok = false, error = tostring(got[2]), output = since(from) }) end
    local value
    if got.n <= 2 then value = plain(got[2], 0, {}) else
        value = {}
        for i = 2, got.n do value[i - 1] = plain(got[i], 0, {}) end
    end
    reply(cmd.id, { ok = true, value = value, output = since(from) })
end

local beatAt = 0
while env.__VoltMCP == mine do
    local now = os.clock()
    if now >= beatAt then
        beatAt = now + 2
        pcall(writefile, "mcp/clients/" .. uid .. ".json", Http:JSONEncode({ userId = me.UserId, username = me.Name,
            displayName = me.DisplayName, placeId = game.PlaceId, gameId = game.GameId, jobId = game.JobId,
            loaded = game:IsLoaded(), at = os.time() }))
    end
    local ok, files = pcall(listfiles, inbox)
    for _, path in ipairs(ok and files or {}) do
        if string.sub(path, -5) == ".json" then
            local read, text = pcall(readfile, path)
            pcall(delfile, path)
            local decoded, cmd = pcall(Http.JSONDecode, Http, read and text or "")
            -- A command left over from before this window opened is dropped, not run late.
            if decoded and type(cmd) == "table" and cmd.id and os.time() - (tonumber(cmd.at) or 0) < 120 then
                task.spawn(function()
                    local fine, e = pcall(run, cmd)
                    if not fine then pcall(reply, cmd.id, { ok = false, error = "agent error: " .. tostring(e) }) end
                end)
            end
        end
    end
    task.wait(0.25)
end
logging:Disconnect()
