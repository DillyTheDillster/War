-- compat/revosvault.lua
-- Compatibility with Revo's Vault printer deck.
--
-- The printer deck asks which printer to start with on a RunSelect page
-- ('printer_choice'): the pick is a joker key, and that page's start_run hook
-- adds the card to the run. Only the deck's own selection matters, so the guest
-- has to be put on the deck and given the same key — otherwise it starts the
-- printer deck with whatever its own last local pick was.
--
-- Wire shape (lobby 'printer' option, echoed in startGame):
--   { v = 1, printer = "j_crv_printer" }
-- The key is validated against the local card pool before it is used.

if not (SMODS and SMODS.Mods) then return end

WAR.COMPAT = WAR.COMPAT or {}
WAR.COMPAT.PRINTER_PROTOCOL = 1

-- The printer pick travels as its own lobby option (it has a fallback rule the
-- generic page sync does not know about), so the generic sweep skips the page.
WAR.COMPAT.CLAIMED_PAGES = WAR.COMPAT.CLAIMED_PAGES or {}
WAR.COMPAT.CLAIMED_PAGES.crv_printer_choice = true

local DECK_KEY   = "b_crv_printer_deck"
-- RunSelect pages are SMODS objects, so the mod's prefix is part of the key:
-- the page the deck gates on is 'crv_printer_choice', not 'printer_choice'.
local PAGE_KEY   = "crv_printer_choice"
local FALLBACK   = "j_crv_blueprinter"

-- The mod's own global: SMODS.Mods still lists a mod that Lovely blacklisted
-- (or that failed to load), and the global is what says it actually ran.
local function has_mod()
    return type(RevosVault) == "table" and type(RevosVault.FUNCS) == "table"
end

-- Key shape is the generic one (compat/runselect.lua) when it is loaded; the
-- copy keeps this file working on its own in a test or an odd load order.
local function sane_key(k)
    if type(WAR.COMPAT.page_key_ok) == "function" then return WAR.COMPAT.page_key_ok(k) end
    return type(k) == "string" and #k > 0 and #k <= 48 and k:match("^[%w_]+$") ~= nil
end

local function choices_table()
    return SMODS.RunSelect and SMODS.RunSelect.Setup
        and SMODS.RunSelect.Setup.choices
end

-- Called from the deck-select intercept. Returns what should go on the wire, or
-- nil when the picked deck is not the printer deck.
function WAR.COMPAT.capture_printer()
    if not has_mod() then return nil end
    local choices = choices_table()
    if not choices or choices.deck_choice ~= DECK_KEY then return nil end
    -- No pick yet means the page will default to the blueprinter, so that is
    -- what the other client has to end up on.
    local key = choices[PAGE_KEY]
    if not sane_key(key) then key = FALLBACK end
    return { v = WAR.COMPAT.PRINTER_PROTOCOL, printer = key }
end

function WAR.COMPAT.printer_available()
    return has_mod()
end

-- True when the deck name the relay announced is the printer deck, i.e. a
-- printer pick was supposed to come with it.
function WAR.COMPAT.printer_expected(back_name)
    if not has_mod() or type(back_name) ~= "string" then return false end
    if type(get_deck_from_name) ~= "function" then return false end
    local center = get_deck_from_name(back_name)
    return center ~= nil and center.key == DECK_KEY
end

-- Page value + profile seeding + the deck gate are all generic run-select
-- state now (compat/runselect.lua): install_page writes the pick and remembers
-- it for cleanup, set_deck_choice points SMODS's deck gate at this deck and puts
-- the player's own choice back when the match ends. The fallback below only runs
-- where that module is not loaded.
local function install(key)
    if type(WAR.COMPAT.install_page) == "function" then
        WAR.COMPAT.install_page(PAGE_KEY, key)
        if type(WAR.COMPAT.set_deck_choice) == "function" then
            WAR.COMPAT.set_deck_choice(DECK_KEY)
        end
        return
    end
    local choices = choices_table()
    if choices then
        choices[PAGE_KEY]     = key
        choices.deck_choice   = DECK_KEY
    end
    local profile = G.PROFILES and G.PROFILES[G.SETTINGS.profile]
    if profile then
        profile.last_choices = profile.last_choices or {}
        profile.last_choices[PAGE_KEY] = key
    end
end

-- Installs the printer pick on this client. Nil payload means "not the printer
-- deck this match": any leftover local pick is cleared so the page cannot fire
-- on a War run nobody asked it to.
-- Returns ok, loc_key (loc_key only when ok is false).
function WAR.COMPAT.apply_printer(payload, back_name)
    local choices = choices_table()

    if type(payload) ~= "table" or not sane_key(payload.printer) then
        if choices and choices.deck_choice == DECK_KEY then choices.deck_choice = "b_red" end
        if WAR.COMPAT.printer_expected(back_name) then
            return false, "war_compat_printer_no_data"
        end
        return true
    end
    if not has_mod() then return false, "war_compat_printer_missing" end
    if tonumber(payload.v) ~= WAR.COMPAT.PRINTER_PROTOCOL then
        return false, "war_compat_printer_protocol"
    end

    -- The pick came off the wire: only use it if this install can make the
    -- card, and fall back to the deck's default printer when it cannot.
    local key = payload.printer
    if not (G.P_CENTERS and G.P_CENTERS[key]) then
        WAR.log("[WAR COMPAT] revosvault: printer " .. tostring(key) .. " is not installed")
        if not (G.P_CENTERS and G.P_CENTERS[FALLBACK]) then
            return false, "war_compat_printer_missing"
        end
        key = FALLBACK
    end

    install(key)
    WAR.COMPAT._printer_applied = true
    WAR.log("[WAR COMPAT] revosvault: applied printer " .. tostring(key))
    return true
end

-- Same reasoning as DeckSmith's deck: the printer pick is global run-select
-- state, so it has to be dropped when the match ends or the player's own
-- printer deck would start with the opponent's printer.
function WAR.COMPAT.clear_printer()
    if not WAR.COMPAT._printer_applied then return end
    WAR.COMPAT._printer_applied = nil
    if not has_mod() then return end
    if type(WAR.COMPAT.uninstall_page) == "function" then
        -- runselect also restores the deck gate it was given.
        WAR.COMPAT.uninstall_page(PAGE_KEY)
        return
    end
    local choices = choices_table()
    if choices then
        if choices.deck_choice == DECK_KEY then choices.deck_choice = "b_red" end
        choices[PAGE_KEY] = nil
    end
    local profile = G.PROFILES and G.PROFILES[G.SETTINGS.profile]
    if profile and profile.last_choices then profile.last_choices[PAGE_KEY] = nil end
end

local exit_profile_ref = WAR.UI and WAR.UI.exit_war_profile
if type(exit_profile_ref) == "function" then
    WAR.UI.exit_war_profile = function(...)
        local ret = exit_profile_ref(...)
        WAR.COMPAT.clear_printer()
        return ret
    end
end

-- Revo's Vault has a higher SMODS priority number, so it loads after War: its
-- global may not exist yet here. Everything above is lazy for that reason.
WAR.log("[WAR] compat/revosvault loaded")
