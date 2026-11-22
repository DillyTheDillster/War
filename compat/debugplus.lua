-- compat/debugplus.lua
-- DebugPlus console commands. Nothing here runs during a normal match; this is
-- just a way to poke around
--
--   war wrap    - gift-wrap the card under the mouse
--   war unwrap  - put it back
--
-- The force flag behind it (rulesets/xmas.lua) makes the card wrap outside a
-- shop/pack and outside the Christmas ruleset, so a card in hand or in the
-- collection can be checked.

local ok, dpAPI = pcall(require, "debugplus-api")
if not ok or type(dpAPI) ~= "table" or type(dpAPI.isVersionCompatible) ~= "function"
   or not dpAPI.isVersionCompatible(1) then
    return
end

local dp = dpAPI.registerID("War")
if type(dp) ~= "table" or type(dp.addCommand) ~= "function" then return end

WAR.COMPAT = WAR.COMPAT or {}

local function hovered_card(d)
    local target = d and d.hovered
        or (G.CONTROLLER and G.CONTROLLER.hovering and G.CONTROLLER.hovering.target)
    if type(target) ~= "table" then return nil end
    -- A card is the only hoverable with a centre and an ability table; buttons
    -- and other UI elements have neither.
    if not (target.config and target.config.center and target.ability) then return nil end
    return target
end

local function card_key(card)
    return (card.config and card.config.center and card.config.center.key) or "?"
end

local function war_command(args, rawArgs, d)
    local sub  = tostring((args and args[1]) or ""):lower()
    local xmas = WAR.RULESETS and WAR.RULESETS['xmas']
    if not xmas or type(xmas.wrap_card) ~= "function" then
        return "xmas ruleset is not loaded", "ERROR"
    end
    if sub ~= "wrap" and sub ~= "unwrap" then
        return "usage: war wrap | war unwrap", "ERROR"
    end
    local card = hovered_card(d)
    if not card then
        return "no card under the mouse - hover one first", "ERROR"
    end
    if sub == "wrap" then
        xmas.wrap_card(card)
        local soul = card._war_xmas_soul and " (soul sprite)" or ""
        return ("wrapped %s%s"):format(card_key(card), soul)
    end
    xmas.unwrap_card(card)
    return ("unwrapped %s"):format(card_key(card))
end

dp.addCommand({
    name      = "war",
    shortDesc = "War debug: wrap/unwrap the hovered card",
    desc      = "war wrap   - gift-wrap the card under the mouse\n" ..
                "war unwrap - restore that card\n" ..
                "Works outside a match and outside the Christmas ruleset.",
    exec      = war_command,
})

-- Kept reachable so the headless suite (and a console `lua:` poke) can drive
-- the same path without going through the input box.
WAR.COMPAT.war_command = war_command

WAR.log("[WAR] compat/debugplus loaded")
