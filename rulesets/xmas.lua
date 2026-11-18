WAR.RULESETS["xmas"] = {
    key         = "xmas",
    layers      = {},

    ignoredSets = {
        Booster  = true,
        Default  = true,     -- plain playing cards
        Enhanced = true,     -- enhanced playing cards (Steel, Gold, Stone, etc.)
        Voucher  = true,
    },
    -- Merry balalamas!
    -- everything is wrapped up to hide their actual card
    -- jokers have special colours to show their rarity (mayb i'll add ui)
}

-- True when this card lives in a shop/pack area and should appear gift-wrapped.
-- Uses card.area (set in the update loop) so it's always current for hover checks.
local function is_wrapped(card)
    if not (WAR.GAME and WAR.GAME.active) then return false end
    if WAR.LOBBY.config.ruleset ~= 'xmas' then return false end
    local area = card.area
    if area ~= G.shop_jokers and area ~= G.shop_booster and area ~= G.pack_cards then return false end
    local ignored = WAR.RULESETS['xmas'].ignoredSets
    if ignored and card.ability and ignored[card.ability.set] then return false end
    return true
end

-- Replace children.center with the gift-wrap atlas and lock in a standard
-- scale so Photograph / Half Joker / Square Joker (which vanilla modifies
-- children.center.scale.y for) all draw at the same full-card size.
-- Also sets front_hidden = true so the joker frame border doesn't overlay
-- the wrap art, and no_shadow = true for a clean presentation.
-- Editions, debuff, and other DrawSteps that run on children.center still
-- work — they just apply to the wrap texture instead of the joker art.
local function wrap_sprites(card)
    if card._war_xmas_wrapped then return end
    local center = card.children.center
    if not center then return end

    local wrap_atlas = G.ASSET_ATLAS['war_rs_giftcards']
    -- Row 0: rarity-based joker wraps (common→blue, uncommon→teal, rare→red,
    --        legendary→purple, unknown/modded→grey).
    -- Row 1: consumable-type wraps (tarot x=0, planet x=1, spectral x=2).
    local ability_set = card.ability and card.ability.set
    local x, y
    if     ability_set == 'Tarot'    then x, y = 0, 1
    elseif ability_set == 'Planet'   then x, y = 1, 1
    elseif ability_set == 'Spectral' then x, y = 2, 1
    else
        local rarity = card.config.center.rarity and tonumber(card.config.center.rarity)
        x = (rarity == 1 and 0) or (rarity == 2 and 1) or (rarity == 3 and 2) or (rarity == 4 and 3) or 4
        y = 0
    end

    card._war_xmas_wrapped = true
    card._war_xmas_orig = {
        atlas     = center.atlas,
        pos       = { x = center.sprite_pos.x, y = center.sprite_pos.y },
        scale_x   = center.scale.x,
        scale_y   = center.scale.y,
        scale_mag = center.scale_mag,
        front_hid = card.front_hidden,
        no_shadow = card.no_shadow,
        T_w       = card.T.w,
        T_h       = card.T.h,
    }

    center.atlas     = wrap_atlas
    center.scale.x   = wrap_atlas.px   -- 71; undo any Photograph/Half/Square modification
    center.scale.y   = wrap_atlas.py   -- 95
    center.scale_mag = math.min(wrap_atlas.px / G.CARD_W, wrap_atlas.py / G.CARD_H)
    center:set_sprite_pos({ x = x, y = y })

    -- Force layout dimensions to standard card size so the buy/select button and
    -- collider always sit at the right position regardless of the joker's actual size.
    -- VT is locked to match in the DrawStep each frame.
    card.T.w = G.CARD_W
    card.T.h = G.CARD_H

    card.front_hidden = true   -- hides the joker frame border (front DrawStep checks this)
    card.no_shadow    = true
end

-- Restore the original atlas, scale, and flags.
local function unwrap_sprites(card)
    if not card._war_xmas_wrapped then return end
    local center = card.children.center
    local o      = card._war_xmas_orig
    if not center or not o then card._war_xmas_wrapped = nil; return end

    center.atlas     = o.atlas
    center.scale.x   = o.scale_x
    center.scale.y   = o.scale_y
    center.scale_mag = o.scale_mag
    center:set_sprite_pos(o.pos)

    card.T.w          = o.T_w
    card.T.h          = o.T_h
    card.front_hidden = o.front_hid
    card.no_shadow    = o.no_shadow

    card._war_xmas_wrapped = nil
    card._war_xmas_orig    = nil
end

-- Build the h_popup definition shown when a wrapped card is hovered.
-- Injects a fake ability_UIBox_table into the card, delegates to vanilla's
-- G.UIDEF.card_h_popup so the result is pixel-identical to a real card
-- tooltip (dark outer box, name at top, white description box, set/rarity
-- badge at the bottom), then restores the original AUT.
-- card.config.center is never touched by the wrap system so get_type_colour
-- and the rarity badge read the real joker/consumable values correctly.
local function wrapped_h_popup_def(card)
    local name  = localize('war_rs_xmas_cardName')
    local lines = localize('war_rs_xmas_cardDesc')
    if type(lines) ~= 'table' then lines = {tostring(lines or '')} end

    -- Parse {C:key}text{} color codes into a row of T nodes,
    -- using vanilla's loc_colour() for the same colour values as card descriptions.
    local function text_row(str)
        local nodes = {}
        local pos   = 1
        local cur   = G.C.UI.TEXT_DARK
        while pos <= #str do
            local s, e, ctrl = str:find('{([^}]*)}', pos)
            local chunk = str:sub(pos, s and s - 1 or nil)
            if #chunk > 0 then
                nodes[#nodes+1] = {n=G.UIT.T, config={text=chunk, scale=0.35, colour=cur}}
            end
            if not s then break end
            if ctrl:sub(1, 2) == 'C:' then
                cur = (loc_colour and loc_colour(ctrl:sub(3))) or G.C.UI.TEXT_DARK
            elseif ctrl == '' then
                cur = G.C.UI.TEXT_DARK
            end
            pos = e + 1
        end
        return nodes
    end

    local main = {}
    for _, line in ipairs(lines) do
        local row = text_row(line)
        if #row > 0 then main[#main+1] = row end
    end

    local fake_AUT = {
        -- card_type drives the badge label and name-area background colour.
        -- 'Joker' makes card_h_popup substitute the actual rarity word
        -- (Common/Uncommon/Rare/Legendary) from card.config.center.rarity.
        card_type = (card.ability and card.ability.set) or 'Joker',
        name = {
            {n=G.UIT.O, config={object=DynaText({
                string  = {name}, maxw = 4,
                colours = {G.C.WHITE}, shadow = true,
                bump = true, scale = 0.5, pop_in = 0, silent = true,
            })}},
        },
        main   = main,
        badges = {card_type = true},   -- show the set/rarity badge
        info   = {},
    }

    local orig = card.ability_UIBox_table
    card.ability_UIBox_table = fake_AUT
    local popup = G.UIDEF.card_h_popup(card)
    card.ability_UIBox_table = orig
    return popup
end

-- Card:hover override.
-- card.config.h_popup is set INSIDE Card:hover() (update loop), then
-- Node.hover() immediately creates the UIBox from it.  Any DrawStep runs in
-- the render loop — always too late to intercept it.
-- For wrapped cards: run juice/sound so hover still feels responsive, then
-- show the wrapped-present name and description instead of the real card info.
local _orig_Card_hover = Card.hover
function Card:hover()
    if is_wrapped(self) then
        self:juice_up(0.05, 0.03)
        play_sound('paper1', math.random()*0.2 + 0.9, 0.35)
        if self.facing == 'front'
           and (not self.states.drag.is or G.CONTROLLER.HID.touch)
           and not self.no_ui and not G.debug_tooltip_toggle then
            self.config.h_popup        = wrapped_h_popup_def(self)
            self.config.h_popup_config = self:align_h_popup()
            Node.hover(self)
        end
        return
    end
    return _orig_Card_hover(self)
end

-- DrawStep -1001: runs before shadow (-1000) and before center (-10).
-- Applies the sprite swap on the first draw frame a card is in a watched area
-- (wrap_sprites guards against repeated calls), and restores as soon as the
-- card leaves (bought, selected from pack, etc.).
-- Because this fires before every other draw step, the card always renders as
-- a gift wrap while in shop/pack — correct hitbox, button placement, and size
-- are all inherited from the unmodified card T dimensions.
SMODS.DrawStep {
    key   = 'war_xmas_pre',
    order = -1001,
    func  = function(self)
        if is_wrapped(self) then
            wrap_sprites(self)
            -- Lock visual size to standard card dimensions every render frame.
            -- The update loop may animate VT back toward T (or a layout manager may
            -- reset T), so we override here — after update, before any draw step.
            self.VT.w = G.CARD_W
            self.VT.h = G.CARD_H
        else
            unwrap_sprites(self)
        end
    end,
}
