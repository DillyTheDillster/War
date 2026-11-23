-- core/net.lua
-- Relay networking. Both players connect to the relay server.
-- Relay assigns lobby codes and forwards messages between clients.

local json = require("json")

WAR.NET.RELAY_HOST = "167.71.87.77"
WAR.NET.RELAY_PORT = 7777

local sock      = nil
local unsent   = ""
local recv_buf  = ""
WAR.NET._expected_seq = nil   -- next expected _seq from server; nil = first message

function WAR.NET.connect()
    if sock then return true end
    local socket = require("socket")
    local s = socket.tcp()
    s:settimeout(8)
    local port = WAR.beta_test == 1 and 7778 or WAR.NET.RELAY_PORT
    local ok, err = s:connect(WAR.NET.RELAY_HOST, port)
    if not ok then s:close(); return false, err end
    s:settimeout(0)
    -- Ask the OS to send keepalive probes on idle connections.
    -- This catches dead sockets that TCP itself wouldn't detect for minutes.
    pcall(function() s:setoption("keepalive", true) end)
    pcall(function() s:setoption("tcp-nodelay", true) end)
    sock = s
    WAR.NET.sock = sock
    recv_buf = ""
    WAR.NET._expected_seq = nil
    WAR.log(string.format("[WAR NET] connected to relay %s:%d", WAR.NET.RELAY_HOST, port))
    return true
end

function WAR.NET.disconnect()
    if sock then
        pcall(function() sock:close() end)
        unsent = ""
        sock = nil
        WAR.NET.sock = nil
        recv_buf = ""
        WAR.NET._expected_seq = nil
    end
end

function WAR.NET.connected()
    return sock ~= nil
end

function WAR.NET.frame_writable()
    return sock ~= nil and unsent == ""
end

local function send_bytes(bytes)
    -- On timeout, partial is the index of the last byte sent.
    -- https://lunarmodules.github.io/luasocket/tcp.html#send
    local sent, err, partial = sock:send(bytes)
    unsent = sent and "" or bytes:sub((partial or 0) + 1)
    if err and err ~= "timeout" then WAR.log("[WAR NET] send err: " .. tostring(err)) end
end

function WAR.NET.send(msg)
    if not sock then return end
    if unsent ~= "" and msg.action == "watchFrame" then return end
    send_bytes(unsent .. json.encode(msg) .. "\n")
end

-- Achievement plumbing. Call sites name the achievement key and nothing else,
-- so the wire shape lives in one place per direction.
function WAR.NET.claim_achievement(key)
    if not key then return end
    WAR.NET.send({ action = "claimAchievement", key = key })
end

function WAR.NET.increment_achievement(key, count)
    if not key or not count or count <= 0 then return end
    WAR.NET.send({ action = "incrementAchievement", key = key, count = count })
end

function WAR.NET.poll()
    if not sock then return {} end
    if unsent ~= "" then send_bytes(unsent) end
    -- A timeout can still return data in partial.
    local chunk, err, partial = sock:receive(512 * 1024)
    if chunk then
        recv_buf = recv_buf .. chunk
    elseif partial and #partial > 0 then
        recv_buf = recv_buf .. partial
    elseif err == "closed" then
        WAR.log("[WAR NET] relay disconnected")
        WAR.NET.disconnect()
        WAR.NET.on_relay_disconnected()
        return {}
    end

    local msgs = {}
    local start = 1
    while true do
        local stop = recv_buf:find("\n", start, true)
        if not stop then break end
        local line = recv_buf:sub(start, stop - 1)
        start = stop + 1
        local ok, decoded = pcall(json.decode, line)
        if ok and decoded then
            -- Track sequence numbers from server to detect relay bugs.
            local seq = decoded._seq
            if seq ~= nil then
                if WAR.NET._expected_seq ~= nil and seq ~= WAR.NET._expected_seq then
                    WAR.log("[WAR NET] seq gap: expected " .. WAR.NET._expected_seq
                          .. " got " .. seq)
                end
                WAR.NET._expected_seq = seq + 1
            end

            -- Respond to heartbeat pings here, before they reach game logic.
            if decoded.action == "ping" then
                WAR.NET.send({action = "pong"})
            else
                msgs[#msgs+1] = decoded
            end
        end
    end
    if start > 1 then recv_buf = recv_buf:sub(start) end
    return msgs
end

function WAR.NET.on_relay_disconnected() end

WAR.log("[WAR] net loaded")
