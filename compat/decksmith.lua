-- compat/decksmith.lua
-- Compatibility with the Decksmith mod (custom decks).
--
-- A Decksmith deck is not a file the opponent has to own. Everything the deck
-- does lives in Decksmith.start_args: a flat table of run modifiers plus the
-- starting jokers/consumables/vouchers and the banned keys, which Decksmith's
-- RunSelect pages replay in their start_run hooks. That table is what crosses
-- the relay, so the guest rebuilds the host's deck locally. The .jkr save file
-- is deliberately never sent: it is Lua source that Decksmith loadstring()s,
-- i.e. an execute-anything channel into the other player's game.
--
-- Both clients end up on the same path. War's on_start_game hands the payload
-- to apply(), which installs it before G:start_run, so the same page hooks run
-- on either side and the run comes up identical.
--
-- Wire shape (sent as the lobby's `decksmith` option, echoed in startGame):
--   { v = 1, args = { ds_hands = 4, banned_keys = { j_foo = true },
--                     ds_starting_jokers = { { key = "j_bar" } } } }
-- Only whitelisted keys, finite numbers, short strings and the four known
-- tables survive sanitising, in both directions.

if not (SMODS and SMODS.Mods) then return end

WAR.COMPAT = WAR.COMPAT or {}
WAR.COMPAT.DECKSMITH_PROTOCOL = 1

-- Decksmith's customize pages write into Decksmith.start_args, not into the
-- page choice, and the deck payload above is what carries them. The generic
-- page sync (compat/runselect.lua) skips them.
WAR.COMPAT.CLAIMED_PAGES = WAR.COMPAT.CLAIMED_PAGES or {}
WAR.COMPAT.CLAIMED_PAGES.ds_starting_jokers      = true
WAR.COMPAT.CLAIMED_PAGES.ds_starting_consumables = true
WAR.COMPAT.CLAIMED_PAGES.ds_starting_vouchers    = true

-- Presence is the mod's own global, not its SMODS.Mods entry: a mod that
-- Lovely blacklisted (or that failed to load) is still registered there, so
-- SMODS.Mods alone would have War talking to a Decksmith that never ran.
-- Decksmith has priority 1 and War none, so the global is up before this file
-- loads; the check stays lazy anyway.
local function has_decksmith()
    return type(Decksmith) == "table" and type(Decksmith.start_args) == "table"
end

-- Decksmith's customize pages only run their start_run hooks while this is the
-- selected deck_choice, so the guest has to be put on it explicitly.
local DECK_KEY = "b_ds_custom"

local MAX_KEY_LEN   = 48
local MAX_STR_LEN   = 64
local MAX_NUMBER    = 1e6
local MAX_BANNED    = 4096
local MAX_CARD_LIST = 64
local MAX_VOUCHERS  = 128

local CARD_LIST_KEYS = { ds_starting_jokers = true, ds_starting_consumables = true }

local function sane_key(k)
    return type(k) == "string" and #k > 0 and #k <= MAX_KEY_LEN and k:match("^[%w_]+$") ~= nil
end

local function sane_scalar(v)
    local t = type(v)
    if t == "number" then
        -- nan/inf poison every comparison downstream, and a giant modifier
        -- would just crash the run on this side.
        if v ~= v or math.abs(v) > MAX_NUMBER then return false end
        return true, v
    elseif t == "boolean" then
        return true, v
    elseif t == "string" then
        if #v > MAX_STR_LEN then return false end
        return true, v
    end
    return false
end

-- Sorted so both clients add the same cards in the same order: pairs() order
-- differs per client, and joker order changes scoring.
local function sort_protos(list)
    table.sort(list, function(a, b)
        if a.key ~= b.key then return a.key < b.key end
        return (a.edition or "") < (b.edition or "")
    end)
end

-- Accepts the shapes Decksmith writes: a list of { key, edition } prototypes,
-- or a key -> true / key -> prototype map.
local function sane_card_list(src)
    if type(src) ~= "table" then return nil end
    local out, dropped = {}, 0
    for k, v in pairs(src) do
        local key, edition
        if type(v) == "table" then
            key, edition = v.key, v.edition
        elseif type(v) == "string" then
            key = v
        elseif v == true and type(k) == "string" then
            key = k
        end
        if type(key) ~= "string" or #key == 0 or #key > MAX_KEY_LEN then
            dropped = dropped + 1
        else
            if type(edition) ~= "string" or #edition == 0 or #edition > MAX_STR_LEN then
                edition = nil
            end
            out[#out + 1] = { key = key, edition = edition }
        end
    end
    if #out > MAX_CARD_LIST then
        sort_protos(out)
        for i = #out, MAX_CARD_LIST + 1, -1 do
            out[i] = nil
            dropped = dropped + 1
        end
    else
        sort_protos(out)
    end
    return out, dropped
end

-- Banned keys and voucher picks are sets. Sorting before the cap keeps the
-- truncation identical on both clients.
local function sane_set(src, limit)
    if type(src) ~= "table" then return nil end
    local keys, dropped = {}, 0
    for k, v in pairs(src) do
        if v and sane_key(k) then keys[#keys + 1] = k else dropped = dropped + 1 end
    end
    table.sort(keys)
    if #keys > limit then
        for i = #keys, limit + 1, -1 do
            keys[i] = nil
            dropped = dropped + 1
        end
    end
    local out = {}
    for _, k in ipairs(keys) do out[k] = true end
    return out, dropped
end

-- Returns a JSON-safe copy of a deck table plus how many fields were dropped.
function WAR.COMPAT.sanitize_deck_args(src)
    local out, dropped = {}, 0
    if type(src) ~= "table" then return out, 0 end
    for k, v in pairs(src) do
        if not sane_key(k) then
            dropped = dropped + 1
        elseif CARD_LIST_KEYS[k] then
            local list, d = sane_card_list(v)
            if list then out[k] = list; dropped = dropped + d else dropped = dropped + 1 end
        elseif k == "ds_starting_vouchers" then
            local set, d = sane_set(v, MAX_VOUCHERS)
            if set then out[k] = set; dropped = dropped + d else dropped = dropped + 1 end
        elseif k == "banned_keys" then
            local set, d = sane_set(v, MAX_BANNED)
            if set then out[k] = set; dropped = dropped + d else dropped = dropped + 1 end
        elseif k:match("^ds_") then
            local ok, val = sane_scalar(v)
            if ok then
                out[k] = val
            elseif v ~= "" and v ~= nil then
                -- Empty string is Decksmith's own "unset" marker.
                dropped = dropped + 1
            end
        else
            dropped = dropped + 1
        end
    end
    return out, dropped
end

-- Called from the deck-select intercept in ui/lobby.lua. Returns the deck as
-- it should go on the wire, or nil when the host did not pick a Decksmith deck.
function WAR.COMPAT.capture_decksmith()
    if not has_decksmith() then return nil end
    local choices = SMODS.RunSelect and SMODS.RunSelect.Setup
        and SMODS.RunSelect.Setup.choices
    if not choices or choices.deck_choice ~= DECK_KEY then return nil end

    local ok, args, dropped = pcall(function()
        return WAR.COMPAT.sanitize_deck_args(Decksmith.start_args)
    end)
    if not ok or type(args) ~= "table" or not next(args) then
        WAR.log("[WAR COMPAT] decksmith: could not read the picked deck: " .. tostring(args))
        return nil
    end
    if dropped and dropped > 0 then
        WAR.log(("[WAR COMPAT] decksmith: %d field(s) left out of the deck payload")
                    :format(dropped))
    end
    -- Decksmith.mod is the mod table SMODS handed it while loading.
    local mod = Decksmith.mod
    return {
        v    = WAR.COMPAT.DECKSMITH_PROTOCOL,
        mod  = mod and mod.version or nil,
        args = args,
    }
end

function WAR.COMPAT.decksmith_available()
    return has_decksmith()
end

-- True when the deck name the relay announced is Decksmith's back, i.e. the
-- match is supposed to be running on a custom deck. Used to tell "no custom
-- deck this match" apart from "the deck never arrived".
function WAR.COMPAT.decksmith_expected(back_name)
    if not has_decksmith() or type(back_name) ~= "string" then return false end
    if type(get_deck_from_name) ~= "function" then return false end
    local center = get_deck_from_name(back_name)
    return center ~= nil and center.key == DECK_KEY
end

local function clone(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, sub in pairs(v) do out[k] = clone(sub) end
    return out
end

-- Card keys the local game does not have (opponent runs content mods we do
-- not). Leaving them in would hand SMODS.add_card an unknown key and throw
-- inside a game event, so they are dropped and reported.
local function drop_missing_centers(args)
    if not G.P_CENTERS then return 0 end
    local missing = 0
    local function keep(proto) return proto and G.P_CENTERS[proto.key] ~= nil end

    for key in pairs(CARD_LIST_KEYS) do
        local list = args[key]
        if list then
            local kept = {}
            for _, proto in ipairs(list) do
                if keep(proto) then kept[#kept + 1] = proto else missing = missing + 1 end
            end
            args[key] = kept
        end
    end
    if args.ds_starting_vouchers then
        for k in pairs(args.ds_starting_vouchers) do
            if not G.P_CENTERS[k] then
                args.ds_starting_vouchers[k] = nil
                missing = missing + 1
            end
        end
    end
    return missing
end

-- Installs the host's deck on this client. Nil payload means "no custom deck
-- this match": any leftover local pick is cleared so Decksmith's pages cannot
-- fire on a War run nobody asked them to run on.
-- Returns ok, loc_key (loc_key only when ok is false).
function WAR.COMPAT.apply_decksmith(payload, back_name)
    local choices = SMODS.RunSelect and SMODS.RunSelect.Setup
        and SMODS.RunSelect.Setup.choices

    if type(payload) ~= "table" or type(payload.args) ~= "table" then
        if choices and choices.deck_choice == DECK_KEY then choices.deck_choice = "b_red" end
        -- The relay announced Decksmith's deck but no deck came with it: either
        -- this War never sent one or the relay in front of it drops the option.
        if WAR.COMPAT.decksmith_expected(back_name) then
            return false, "war_compat_ds_no_data"
        end
        return true
    end
    if not has_decksmith() then return false, "war_compat_ds_missing" end
    if tonumber(payload.v) ~= WAR.COMPAT.DECKSMITH_PROTOCOL then
        return false, "war_compat_ds_protocol"
    end

    -- Re-sanitise: this table came off the wire and is not ours.
    local args = WAR.COMPAT.sanitize_deck_args(payload.args)
    if not next(args) then return false, "war_compat_ds_invalid" end

    local missing = drop_missing_centers(args)
    if missing > 0 then
        WAR.log(("[WAR COMPAT] decksmith: deck uses %d card(s) this install does not have")
                    :format(missing))
    end

    -- Decksmith's own importer knows which pages have to be reset; use it when
    -- the installed version has it and fall back to doing it by hand.
    local imported = false
    if type(Decksmith.import_settings) == "function" then
        local ok, ret = pcall(Decksmith.import_settings, args)
        imported = ok and ret == true
    end
    if not imported then
        Decksmith.start_args = args
        local profile = G.PROFILES and G.PROFILES[G.SETTINGS.profile]
        for page in pairs({
            ds_starting_jokers      = true,
            ds_starting_consumables = true,
            ds_starting_vouchers    = true,
        }) do
            local value = clone(args[page] or {})
            if choices then choices[page] = clone(value) end
            if profile then
                profile.last_choices = profile.last_choices or {}
                profile.last_choices[page] = value
            end
        end
    end

    -- The deck gate is generic run-select state (compat/runselect.lua): it also
    -- remembers the player's own choice to put back when the match ends.
    if type(WAR.COMPAT.set_deck_choice) == "function" then
        WAR.COMPAT.set_deck_choice(DECK_KEY)
    elseif choices then
        choices.deck_choice = DECK_KEY
    end
    WAR.COMPAT._applied = true

    WAR.log(("[WAR COMPAT] decksmith: applied \"%s\" (v%s)")
                :format(tostring(args.ds_name or "?"), tostring(payload.mod or "?")))
    return true
end

-- The installed deck is live global state: after the match the player is back
-- on their own profile, and a leftover b_ds_custom selection would have their
-- next single-player run quietly start on the opponent's deck.
function WAR.COMPAT.clear_decksmith()
    if not WAR.COMPAT._applied then return end
    if not has_decksmith() then WAR.COMPAT._applied = nil; return end
    WAR.COMPAT._applied = nil
    -- With runselect loaded it restores the player's own deck choice itself
    -- (they may have been on a different deck before the match, not b_red).
    if type(WAR.COMPAT.set_deck_choice) ~= "function" then
        local choices = SMODS.RunSelect and SMODS.RunSelect.Setup
            and SMODS.RunSelect.Setup.choices
        if choices and choices.deck_choice == DECK_KEY then choices.deck_choice = "b_red" end
    end
    Decksmith.start_args = {}
end

local exit_profile_ref = WAR.UI and WAR.UI.exit_war_profile
if type(exit_profile_ref) == "function" then
    WAR.UI.exit_war_profile = function(...)
        local ret = exit_profile_ref(...)
        WAR.COMPAT.clear_decksmith()
        return ret
    end
end

-- Decksmith has a higher SMODS priority number, so it loads *after* War: its
-- global may not exist yet here. Everything below is lazy for that reason.
WAR.log("[WAR] compat/decksmith loaded")
