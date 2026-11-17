WAR.RULESETS["weeworld"] = {
    key         = "weeworld",
    layers      = {},

    -- wowie ME, BITTERDOES did something here!!
    -- removes majority of all Jokers, Consumables and Vouchers, other than that

    -- only sets listed here are touched; everything else (sleeves, card backs,
    -- editions, enhancements, etc.) is left alone
    targetSets = {
        Joker    = true,
        Tarot    = true,
        Planet   = true,
        Spectral = true,
        Booster  = true,
        Voucher  = true,
        Tag      = true,
    }
}

local maxSets = {
    -- set name = int
    Joker    = 30,
    Tarot    = 8,
    Planet   = 6,
    Spectral = 8,
    Booster  = 16,
    Voucher  = 4,
    Tag      = 12,
}

WAR.RULESETS["weeworld"]["calculate"] = function(self, context)
    if not context.war_gameStart then return end -- my precious indents*

    print("Hello World!")

    G.GAME.banned_keys = G.GAME.banned_keys or {}

    local sets = {}
    local t2Vouchers = {}

    for _, object in pairs(G.P_CENTERS) do -- differentiate sets
        if
            not object.set or not object.key or
            not WAR.RULESETS["weeworld"].targetSets[object.set]
        then goto continue end

        if object.requires then table.insert(t2Vouchers, object) goto continue end

        sets[object.set] = sets[object.set] or {}
        table.insert(sets[object.set], object)

        ::continue::
    end

    -- Tags live in G.P_TAGS / G.P_CENTER_POOLS["Tag"], not G.P_CENTERS.
    -- Their requires field is a discovery gate (string key), not a dependency
    -- chain, so they go straight into the pool with no t2 processing.
    if WAR.RULESETS["weeworld"].targetSets["Tag"] and G.P_CENTER_POOLS["Tag"] then
        sets["Tag"] = sets["Tag"] or {}
        for _, object in ipairs(G.P_CENTER_POOLS["Tag"]) do
            if object.key then
                table.insert(sets["Tag"], object)
            end
        end
    end
    -- where the magic happens, shuffles set tables, then top to bottom until hitting maxSet
    for set, objects in pairs(sets) do
        table.sort(objects, function(a, b) return a.key < b.key end)

        for ix = #objects, 2, -1 do
            local j = pseudorandom(objects[ix].key, 1, ix)
            objects[ix], objects[j] = objects[j], objects[ix]
        end

        for i = #objects, (maxSets[set] or math.floor(#objects*1/4)) + 1, -1 do -- keep exactly maxSets[set] items
            WAR.log(objects[i].key)
            G.GAME.banned_keys[objects[i].key] = true
        end
    end


    -- remove corresponding tier two vouchers
    for _, voucher in pairs(t2Vouchers) do
        for _, required in pairs(voucher.requires) do
            if G.GAME.banned_keys[required] then
                G.GAME.banned_keys[voucher.key] = true
                break
            end
        end
    end
end


-- hooks
local showman_ref = SMODS.showman
function SMODS.showman(card_key)
    if WAR.GAME.active
        and WAR.LOBBY.config.ruleset == "weeworld"
        and WAR.LOBBY.config.weeworld_showman
    then return true end
	return showman_ref(card_key)
end
