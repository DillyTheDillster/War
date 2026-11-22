-- compat/cryptid.lua
-- Cryptid's deck-select decks (edition, enhancement, sticker, suit, seal) paint
-- their pick onto the *back* of the deck card in a DrawStep. The lobby panel
-- draws its deck face down like the run select screen, so most of that comes
-- along on its own — the sticker and the deck art do. The edition shader does
-- not survive that trip (it is drawn once by Cryptid's step and lands under the
-- panel's stack), so the panel draws it again on the top card.
--
-- Only the decks whose pick is a *shader or a sprite over the art* need this;
-- enhancement and suit decks only swap the art, which Cryptid already does.

if not (SMODS and SMODS.RunSelect) then return end

WAR.COMPAT = WAR.COMPAT or {}

local DECKS = {
    b_cry_e_deck  = { page = "cry_edeck_ed", kind = "edition" },
    b_cry_sl_deck = { page = "cry_edeck_sl", kind = "seal"    },
}

-- The page pick is run-select state, not Cryptid state: the generic sync
-- (compat/runselect.lua) installs the host's choice and exposes the same
-- choices-then-profile read this used to do by hand. The local copy is only for
-- a load where that module is missing.
local function pick(page)
    if type(WAR.COMPAT.page_choice) == "function" then
        return WAR.COMPAT.page_choice(page)
    end
    local choices = SMODS.RunSelect.Setup and SMODS.RunSelect.Setup.choices
    local v = choices and choices[page]
    if v then return v end
    local profile = G.PROFILES and G.SETTINGS and G.PROFILES[G.SETTINGS.profile]
    return profile and profile.last_choices and profile.last_choices[page]
end

local function edition_shader(key)
    if type(key) ~= "string" or key == "default" or key == "random" then return nil end
    if key == "e_negative" then return "negative" end
    local short = key:sub(3)
    if G.SHADERS and G.SHADERS[short] then return short end
    local center = G.P_CENTERS and G.P_CENTERS[key]
    if center and center.shader then return center.shader end
    return nil
end

-- Cryptid hands its shaders the card's own uniform table; a panel card never
-- runs the shadow step that fills it, so an empty one is passed instead.
local function shader_args(card)
    card.ARGS = card.ARGS or {}
    local args = card.ARGS.send_to_shader
    if type(args) ~= "table" then args = {}; card.ARGS.send_to_shader = args end
    args[1] = 1
    args[2] = G.TIMERS and G.TIMERS.REAL or 0
    args[3] = args[3] or 1
    args[4] = args[4] or 1
    return args
end

-- Returns a function(card) that paints the deck's pick over that card's back, or
-- nil for a deck this file does not know.
function WAR.COMPAT.cryptid_deck_overlay(deck_center)
    if type(deck_center) ~= "table" or type(deck_center.key) ~= "string" then return nil end
    local spec = DECKS[deck_center.key]
    if not spec then return nil end
    local value = pick(spec.page)
    if not value or value == "default" or value == "random" then return nil end

    if spec.kind == "edition" then
        local shader = edition_shader(value)
        if not shader then return nil end
        return function(card)
            local back = card.children and card.children.back
            if not back or not back.draw_shader then return end
            local args = shader_args(card)
            back:draw_shader(shader, nil, args)
            if value == "e_negative" then
                back:draw_shader("negative_shine", nil, args)
            end
        end
    end

    if spec.kind == "seal" then
        return function(card)
            local seal = G.shared_seals and G.shared_seals[value]
            local back = card.children and card.children.back
            if not seal or not back then return end
            seal.role.draw_major = card
            seal:draw_shader("dissolve", nil, nil, true, back)
        end
    end

    return nil
end

WAR.log("[WAR] compat/cryptid loaded")
