-- Packaged ruleset: replace each shop joker/consumable slot with a pack of the matching type.
-- Both players share the same relay seed so G.GAME._packaged_ctr advances identically on both
-- clients, keeping pack picks in sync.
WAR.RULESETS["packaged"] = {
    key    = "packaged",
    layers = {},
}


WAR.RULESETS["packaged"]["calculate"] = function(self, context)
    if context.create_shop_card and context.cardarea == G.shop_jokers then
        local type_to_packs = {
            Joker    = { 'p_buffoon_normal_1',   'p_buffoon_jumbo_1'   },
            Tarot    = { 'p_arcana_normal_1',    'p_arcana_jumbo_1'    },
            Planet   = { 'p_celestial_normal_1', 'p_celestial_jumbo_1' },
            Spectral = { 'p_spectral_normal_1',  'p_spectral_jumbo_1'  },
        }
        local packs = type_to_packs[context.set]
        if packs then
            G.GAME._packaged_ctr = (G.GAME._packaged_ctr or 0) + 1
            local r = pseudorandom(pseudoseed('packaged_shop'
                .. G.GAME.round_resets.ante .. G.GAME._packaged_ctr))
            return { shop_create_flags = { set = 'Booster', key = r > 0.75 and packs[2] or packs[1] } }
        end
    end
end