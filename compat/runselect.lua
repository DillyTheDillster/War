-- compat/runselect.lua
-- Generic RunSelect page sync, for mods that add a run-select page.
--
-- A SMODS page keeps its pick in SMODS.RunSelect.Setup.choices[page.key] and
-- replays it in the page's start_run hook, which SMODS drives off
-- G.PROFILES[profile].last_choices[page.key]. War builds its runs through
-- G:start_run itself and never goes through SMODS.RunSelect.Functions.start_run,
-- so that table still holds whatever the player's last single-player run left
-- there: two clients on the same deck can walk into a match with different page
-- picks. This module ships the host's picks with the lobby and rebuilds them
-- before the run is built, for every page no compat file claims.
--
-- Wire shape (lobby 'pages' option, echoed in startGame):
--   { v = 1, set = { cry_edeck_ed = "e_foil",
--                    cry_edeck_sk = { sketch_a = true },
--                    hpot_budgets = 150, some_flag = true } }
-- A payload that arrives is authoritative for every page this client has: a
-- page it does not list is cleared, because a leftover local pick would fire
-- that page's start_run hook on a run nobody chose it for. No payload at all
-- means the relay (or the other client) predates this, and local state is left
-- alone rather than cleared on half the match's data.

if not (SMODS and SMODS.RunSelect and SMODS.RunSelectPage) then return end

WAR.COMPAT = WAR.COMPAT or {}
WAR.COMPAT.PAGES_PROTOCOL = 1

-- Page keys War handles itself, or that a compat file handles better. Files
-- write into this table at load time; nothing reads it then, so the order
-- compat/*.lua happens to load in does not matter.
WAR.COMPAT.CLAIMED_PAGES = WAR.COMPAT.CLAIMED_PAGES or {}

local OWNED = {
    deck_choice  = true,
    stake_choice = true,
    seed         = true,
    enable_seed  = true,
}

local MAX_KEY_LEN  = 64
local MAX_PAGES    = 64
local MAX_SET_KEYS = 256
local MAX_NUMBER   = 1e6

local function pages_table()
    return SMODS.RunSelect and SMODS.RunSelect.Pages
end

local function choices_table()
    return SMODS.RunSelect.Setup and SMODS.RunSelect.Setup.choices
end

local function profile_table()
    return G and G.PROFILES and G.SETTINGS and G.PROFILES[G.SETTINGS.profile]
end

local function owned(key)
    return (OWNED[key] or WAR.COMPAT.CLAIMED_PAGES[key]) == true
end

-- Every registered page key, sorted so a payload built from it is identical on
-- both clients. Internals.pages is the list SMODS walks when it replays the
-- start_run hooks; Pages covers a page that is registered but not injected yet.
local function page_keys()
    local out, seen = {}, {}
    local internals = SMODS.RunSelect.Internals
    if internals and type(internals.pages) == "table" then
        for _, key in ipairs(internals.pages) do
            if type(key) == "string" and not seen[key] then
                seen[key] = true
                out[#out + 1] = key
            end
        end
    end
    local pages = pages_table()
    if pages then
        for key in pairs(pages) do
            if type(key) == "string" and not seen[key] then
                seen[key] = true
                out[#out + 1] = key
            end
        end
    end
    table.sort(out)
    return out
end

local function sane_key(k)
    return type(k) == "string" and #k > 0 and #k <= MAX_KEY_LEN and k:match("^[%w_]+$") ~= nil
end

-- The keys a page can actually produce. Pages with a generated pool (the usual
-- case) are checked against it, so a pick this install cannot make is dropped
-- instead of reaching a start_run hook that assumes the card exists.
local function pool_keys(page)
    if type(page) ~= "table" or type(page.pool) ~= "table" then return nil end
    local out = {}
    for _, center in ipairs(page.pool) do
        if type(center) == "table" and type(center.key) == "string" then
            out[center.key] = true
        end
    end
    if not next(out) then return nil end
    return out
end

local function sane_value(v)
    local t = type(v)
    if t == "string" then
        if sane_key(v) then return true, v end
        return false
    elseif t == "number" then
        -- nan/inf poison every comparison downstream, and a giant number would
        -- just crash the run on this side.
        if v ~= v or math.abs(v) > MAX_NUMBER then return false end
        return true, v
    elseif t == "boolean" then
        return true, v
    elseif t == "table" then
        -- Pages with selection_limit > 1 hold a key -> true set.
        local keys = {}
        for k, on in pairs(v) do
            if on and sane_key(k) then keys[#keys + 1] = k end
        end
        if #keys == 0 then return false end
        table.sort(keys)
        local out = {}
        for i = 1, math.min(#keys, MAX_SET_KEYS) do out[keys[i]] = true end
        return true, out
    end
    return false
end

local function clone(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, sub in pairs(v) do out[k] = clone(sub) end
    return out
end

-- What a page is set to right now: the live run-select choice, else whatever
-- the profile remembered. Same precedence SMODS uses when it builds a run, so a
-- compat file that has to paint or read a pick can ask here instead of walking
-- both tables itself.
function WAR.COMPAT.page_choice(key)
    local choices = choices_table()
    local v = choices and choices[key]
    if v ~= nil then return v end
    local profile = profile_table()
    return profile and profile.last_choices and profile.last_choices[key]
end

-- Key shape accepted on the wire, for compat files that validate their own
-- picks before they go out.
function WAR.COMPAT.page_key_ok(k)
    return sane_key(k)
end

local function install(key, value)
    local choices = choices_table()
    if choices then choices[key] = clone(value) end
    local profile = profile_table()
    if profile then
        profile.last_choices = profile.last_choices or {}
        profile.last_choices[key] = clone(value)
    end
end

local function uninstall(key)
    local choices = choices_table()
    if choices and choices[key] ~= nil then choices[key] = nil end
    local profile = profile_table()
    if profile and profile.last_choices then profile.last_choices[key] = nil end
end

-- Install a page pick and remember that it came from the other client, so it is
-- dropped again when the match ends. For compat files that carry a page of their
-- own (the value sync, the profile seeding and the cleanup are the same work).
function WAR.COMPAT.install_page(key, value)
    if not sane_key(key) or value == nil then return false end
    install(key, value)
    local installed = WAR.COMPAT._pages_installed or {}
    WAR.COMPAT._pages_installed = installed
    installed[key] = true
    return true
end

function WAR.COMPAT.uninstall_page(key)
    if not sane_key(key) then return false end
    uninstall(key)
    local installed = WAR.COMPAT._pages_installed
    if installed then installed[key] = nil end
    return true
end

-- ── The deck this match is on ─────────────────────────────────────────────
-- War builds the run from the relay's back, so SMODS's own choices.deck_choice
-- still says whatever the player picked in single player. Pages gate their
-- optional()/start_run on it (Cryptid's edition deck, Revo's printer, any mod
-- that ties a page to a deck), so one client would replay the page and the other
-- would skip it. Point it at the deck the match is actually on, and put the
-- player's own value back when the match ends.
local function deck_key(back_name)
    if type(back_name) ~= "string" or type(get_deck_from_name) ~= "function" then return nil end
    local ok, center = pcall(get_deck_from_name, back_name)
    local key = ok and center and center.key
    return type(key) == "string" and key ~= "" and key or nil
end

-- saved the first time, so a compat file that writes the same choice again does
-- not overwrite the player's own value with the match's.
function WAR.COMPAT.set_deck_choice(key)
    local choices = choices_table()
    if not (choices and type(key) == "string" and key ~= "") then return false end
    if WAR.COMPAT._deck_choice_prev == nil then
        WAR.COMPAT._deck_choice_prev = { value = choices.deck_choice, set = key }
    end
    choices.deck_choice = key
    return true
end

-- back_name is the deck name the relay announced ("Red Deck", the mod's deck
-- name...), the same string startGame carries.
function WAR.COMPAT.apply_deck_choice(back_name)
    local key = deck_key(back_name)
    if not key then return false end
    return WAR.COMPAT.set_deck_choice(key)
end

local function restore_deck_choice()
    local prev = WAR.COMPAT._deck_choice_prev
    if not prev then return end
    WAR.COMPAT._deck_choice_prev = nil
    local choices = choices_table()
    -- Only put the player's value back if the gate still holds what this module
    -- set: another compat file's own cleanup may have moved it already, and its
    -- choice is the more specific one.
    if choices and (prev.set == nil or choices.deck_choice == prev.set) then
        choices.deck_choice = prev.value
    end
end

-- Called from the deck-select intercept in ui/lobby.lua. Returns the page picks
-- as they should go on the wire. Always a table, so "the host picked nothing"
-- is a payload of its own and clears the guest's leftovers.
function WAR.COMPAT.capture_pages()
    local choices = choices_table()
    if not choices then return nil end
    local set, count, dropped = {}, 0, 0
    for _, key in ipairs(page_keys()) do
        if not owned(key) then
            local v = choices[key]
            if v ~= nil then
                local ok, out = sane_value(v)
                if ok and count < MAX_PAGES then
                    set[key] = out
                    count = count + 1
                elseif ok then
                    dropped = dropped + 1
                else
                    dropped = dropped + 1
                    WAR.log("[WAR COMPAT] pages: could not read the pick for " .. key)
                end
            end
        end
    end
    if dropped > 0 then
        WAR.log(("[WAR COMPAT] pages: %d page pick(s) left out of the payload"):format(dropped))
    end
    return { v = WAR.COMPAT.PAGES_PROTOCOL, set = set }
end

-- Installs the host's page picks. Called from startGame (before G:start_run) and
-- again when the deck picker opens, so the screen starts on what this client is
-- actually playing with.
-- Nothing here stops a match: a page this install does not have, or a pick it
-- cannot make, is dropped with a log line and both clients play on.
function WAR.COMPAT.apply_pages(payload, back_name)
    -- The deck gate is match state, not page data: set it even when there is no
    -- page payload at all.
    WAR.COMPAT.apply_deck_choice(back_name)
    if payload == nil then return true end
    local choices = choices_table()
    if not choices then return true end
    if type(payload) ~= "table" or tonumber(payload.v) ~= WAR.COMPAT.PAGES_PROTOCOL
       or type(payload.set) ~= "table" then
        WAR.log("[WAR COMPAT] pages: unreadable payload, leaving run-select state alone")
        return true
    end

    local set   = payload.set
    local pages = pages_table() or {}
    local applied, cleared, missing, unknown = 0, 0, 0, 0
    local seen = {}
    local installed = WAR.COMPAT._pages_installed or {}
    WAR.COMPAT._pages_installed = installed

    for _, key in ipairs(page_keys()) do
        if not owned(key) then
            seen[key] = true
            local want = set[key]
            if want == nil then
                if choices[key] ~= nil then cleared = cleared + 1 end
                WAR.COMPAT.uninstall_page(key)
            else
                local ok, value = sane_value(want)
                if ok then
                    local pool = pool_keys(pages[key])
                    if pool and type(value) == "string" then
                        ok = pool[value] == true
                    elseif pool and type(value) == "table" then
                        for k in pairs(value) do
                            if not pool[k] then value[k] = nil end
                        end
                        ok = next(value) ~= nil
                    end
                end
                if ok then
                    WAR.COMPAT.install_page(key, value)
                    applied = applied + 1
                else
                    missing = missing + 1
                    WAR.COMPAT.uninstall_page(key)
                    WAR.log("[WAR COMPAT] pages: " .. key
                            .. " was set to a key this install does not have")
                end
            end
        end
    end

    for key in pairs(set) do
        if not seen[key] then unknown = unknown + 1 end
    end
    if unknown > 0 then
        WAR.log(("[WAR COMPAT] pages: %d page(s) belong to mods this install does not have")
                    :format(unknown))
    end

    WAR.log(("[WAR COMPAT] pages: %d applied, %d cleared, %d unavailable, %d unknown")
                :format(applied, cleared, missing, unknown))
    return true
end

-- Page picks are global run-select state, same as DeckSmith's deck and Revo's
-- printer: left behind, the player's next single-player run would start on the
-- opponent's page choices. Only the pages this module wrote are dropped — a
-- page the player picked for themselves before the match is not ours to clear.
function WAR.COMPAT.clear_pages()
    restore_deck_choice()
    local installed = WAR.COMPAT._pages_installed
    WAR.COMPAT._pages_installed = nil
    if not installed then return end
    if not choices_table() then return end
    for key in pairs(installed) do
        if not owned(key) then uninstall(key) end
    end
end

local exit_profile_ref = WAR.UI and WAR.UI.exit_war_profile
if type(exit_profile_ref) == "function" then
    WAR.UI.exit_war_profile = function(...)
        local ret = exit_profile_ref(...)
        WAR.COMPAT.clear_pages()
        return ret
    end
end

WAR.log("[WAR] compat/runselect loaded")
