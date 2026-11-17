WAR.RULESETS["xmas"] = {
    key         = "xmas",
    layers      = {},

    ignoredSets = { -- to b implemented
        Booster=true,
        Default=true,
        Voucher=true,
    }
    -- Merry balalamas!
    -- everything is wrapped up to hide their actual card
    -- jokers have special colours to show their rarity (mayb i'll add ui)
}

WAR.RULESETS["xmas"]["calculate"] = function(self, context)
    if context.modify_shop_card or context.modify_booster_card then

        local center = context.card.config and context.card.config.center
        local spriteCenter = context.card.children.center -- i think this is the sprite's center

        context.card.config.atlas = spriteCenter.atlas          -- store atlas
        spriteCenter.atlas = G.ASSET_ATLAS.war_rs_giftcards

        local x = (center.rarity and (tonumber(center.rarity)-1 or 4) ) or 2    -- which sprite to use
        spriteCenter:set_sprite_pos({x= x,y= 0})

        context.card.config.scale = spriteCenter.scale          -- store scale
        print(spriteCenter.scale)
        spriteCenter.scale = {x=71, y=95}

    elseif context.card_added then
        -- set to default
        local center = context.card.children.center     -- child's center
        center.atlas = context.card.config.atlas or center.atlas
        center:set_sprite_pos(context.card.config.center.pos)
        print(context.card.config.scale or center.scale)
        center.scale = context.card.config.scale or center.scale
    end
end