WAR.RULESETS["standard"] = {
    key         = "standard",
    layers      = {},
    -- Nothing is banned: a rival round is a real vanilla boss with the rival
    -- layered on top, so Chicot / Luchador / boss rerolls act on the boss half
    -- and stay legal. Add fields here (or to a layer) to ban things again.
}

--[[ this is here so i do less work when copy/pasting
WAR.RULESETS["standard"]["calculate"] = function(self, context)
    -- I do nothing!
end
]]