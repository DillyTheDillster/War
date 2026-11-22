-- core/lobby.lua

WAR.LOBBY_STATE = "none"

-- Every option the lobby panel can change, back on the value it shows for a
-- brand new lobby. A lobby inherits this table from the last one, so anything
-- the host flipped there (timer, toggles, ante) has to be put back or the
-- relay quietly serves the previous match's rules.
function WAR.LOBBY.reset_options()
    local cfg = WAR.LOBBY.config
    cfg.lives                   = 4
    cfg.timer_seconds           = 90
    cfg.pvp_start_ante          = 3
    cfg.pvp_ante_set            = nil   -- no explicit ante yet, so the gamemode's default applies
    cfg.death_on_round_loss     = true
    cfg.hide_score_until_played = false
    cfg.comeback_gold           = true
    cfg.pvp_boss_effects        = true
    cfg.weeworld_showman        = true
    cfg.same_deck               = true
    cfg.same_seed               = true
end

-- Deck, stake, sleeve, challenge and seed belong to one lobby's run, never to
-- the mod: a new lobby comes up on the vanilla run choices.
function WAR.LOBBY.reset_run_choices()
    local cfg = WAR.LOBBY.config
    cfg.back      = "Red Deck"
    cfg.stake     = 1
    cfg.sleeve    = nil
    cfg.challenge = nil
    cfg.decksmith = nil
    cfg.printer   = nil
    cfg.pages     = nil
    -- The guest's own picks, used when Same Deck/Stake is off.
    cfg.guest_back      = "Red Deck"
    cfg.guest_stake     = 1
    cfg.guest_sleeve    = nil
    cfg.guest_challenge = nil
    cfg.guest_decksmith = nil
    cfg.guest_printer   = nil
    cfg.guest_pages     = nil
    -- seed is left for the deck selector to pick; the relay calls gen_seed()
    -- when the host never sets one.
    cfg.seed      = nil
    cfg.guest_seed = nil
end

-- The run choices this client actually plays with. With Same Deck/Stake on
-- (default) the host's pick is the match's pick; with it off the guest runs its
-- own deck, stake and sleeve, and Same Seed decides whose seed it starts on.
function WAR.LOBBY.local_choices(cfg)
    cfg = cfg or WAR.LOBBY.config
    local separate = cfg.same_deck == false and not WAR.LOBBY.is_host
    local own_seed = cfg.same_seed == false and not WAR.LOBBY.is_host

    local function pick(key, default)
        -- Explicit branch, not `a and b or c`: a nil guest pick must stay nil
        -- (and take the default) instead of falling back to the host's value.
        local v
        if separate then v = cfg["guest_" .. key] else v = cfg[key] end
        if v == nil or v == "" then v = default end
        return v
    end

    local seed
    if own_seed then seed = cfg.guest_seed else seed = cfg.seed end
    if seed == "" then seed = nil end

    return {
        back      = pick("back", "Red Deck"),
        stake     = tonumber(pick("stake", 1)) or 1,
        sleeve    = pick("sleeve", nil),
        challenge = pick("challenge", nil),
        seed      = seed,
        decksmith = separate and cfg.guest_decksmith or cfg.decksmith,
        printer   = separate and cfg.guest_printer or cfg.printer,
        pages     = separate and cfg.guest_pages or cfg.pages,
    }
end

-- Sends the guest's own picks so the relay can hand them back on startGame
-- (and so a lobby that started on the guest's second choice restarts on it).
function WAR.LOBBY.push_guest_choices()
    if WAR.LOBBY.is_host or not WAR.LOBBY.code then return end
    local cfg = WAR.LOBBY.config
    WAR.NET.send({
        action          = "guestChoices",
        guest_back      = cfg.guest_back or "Red Deck",
        guest_stake     = cfg.guest_stake or 1,
        guest_challenge = cfg.guest_challenge or "",
        guest_seed      = cfg.guest_seed or "",
        guest_sleeve    = cfg.guest_sleeve or "",
        guest_decksmith = cfg.guest_decksmith or "",
        guest_printer   = cfg.guest_printer or "",
        guest_pages     = cfg.guest_pages or "",
    })
end

function WAR.LOBBY.create()
    -- Gamemode and ruleset are picked by the selection screens that lead here;
    -- everything else starts from the defaults.
    WAR.LOBBY.reset_options()
    WAR.LOBBY.reset_run_choices()
    if not WAR.LOBBY.config.gamemode then WAR.LOBBY.config.gamemode = "vanilla"  end
    if not WAR.LOBBY.config.ruleset  then WAR.LOBBY.config.ruleset  = "standard" end

    local ok, err = WAR.NET.connect()
    if not ok then return false, err end

    WAR.LOBBY_STATE = "hosting"
    local mod_ver, smods_ver = WAR.mod_versions()
    WAR.NET.send({
        action        = "create",
        gamemode      = WAR.LOBBY.config.gamemode,
        pfp           = WAR.AVATAR and WAR.AVATAR.selected or "default",
        mod_version   = mod_ver,
        smods_version = smods_ver,
    })
    -- code arrives async via sync.lua dispatch (action="created")
    return true
end

function WAR.LOBBY.join(code)
    WAR.LOBBY_STATE = "joining"
    -- Start from the panel defaults too, so the read-only view never shows a
    -- toggle left over from the last match before the host's config lands.
    WAR.LOBBY.reset_options()
    WAR.LOBBY.reset_run_choices()
    local ok, err = WAR.NET.connect()
    if not ok then WAR.LOBBY_STATE = "none"; return false, err end
    local mod_ver, smods_ver = WAR.mod_versions()
    WAR.NET.send({ action="join", code=code:upper():gsub("%s",""),
                   pfp = WAR.AVATAR and WAR.AVATAR.selected or "default",
                   mod_version = mod_ver, smods_version = smods_ver })
    -- confirmation arrives async (action="joined")
    return true
end

-- Send the whole option set so the relay's copy matches the host's defaults
-- the moment the lobby exists (the toggles only send on change).
function WAR.LOBBY.push_config()
    local cfg = WAR.LOBBY.config
    WAR.NET.send({
        action                  = "config",
        lives                   = cfg.lives or 4,
        death_on_round_loss     = cfg.death_on_round_loss ~= false,
        hide_score_until_played = cfg.hide_score_until_played == true,
        comeback_gold           = cfg.comeback_gold ~= false,
        pvp_start_ante          = cfg.pvp_start_ante or 3,
        gamemode                = cfg.gamemode or "vanilla",
        ruleset                 = cfg.ruleset or "standard",
        timer_seconds           = cfg.timer_seconds or 0,
        pvp_boss_effects        = cfg.pvp_boss_effects ~= false,
        weeworld_showman        = cfg.weeworld_showman ~= false,
        back                    = cfg.back or "Red Deck",
        stake                   = cfg.stake or 1,
        sleeve                  = cfg.sleeve or "",
        decksmith               = cfg.decksmith or "",
        printer                 = cfg.printer or "",
        pages                   = cfg.pages or "",
        same_deck               = cfg.same_deck ~= false,
        same_seed               = cfg.same_seed ~= false,
    })
end

function WAR.LOBBY.leave()
    WAR.NET.send({ action = "leave" })
    WAR.LOBBY.leave_local()
end

-- Leaving a live match from the pause menu is a forfeit, not a disconnect: the
-- relay is told at once so the opponent is not left sitting on a dead match
-- until the socket times out.
function WAR.LOBBY.forfeit()
    if not WAR.GAME.active then return false end
    WAR.NET.send({ action = "forfeit" })
    WAR.LOBBY.leave_local()
    return true
end

-- Local half of leaving: everything the next lobby must not inherit.
function WAR.LOBBY.leave_local()
    if WAR.UI and WAR.UI.exit_war_profile then WAR.UI.exit_war_profile() end
    -- keep socket open — reused by the next join/create without re-authing
    WAR.LOBBY.code    = nil
    WAR.LOBBY.is_host = false
    WAR.LOBBY_STATE   = "none"
    WAR.GAME.active   = false
    WAR.MODIFIERS     = {}
    WAR.LOBBY.reset_options()
    -- Run choices belong to the lobby that picked them; without this the next
    -- lobby inherits the deck, stake, sleeve and challenge of the last run.
    WAR.LOBBY.config.seed                    = nil
    WAR.LOBBY.config.back                    = nil
    WAR.LOBBY.config.stake                   = nil
    WAR.LOBBY.config.sleeve                  = nil
    WAR.LOBBY.config.challenge               = nil
    WAR.LOBBY.config.decksmith               = nil
    WAR.LOBBY.config.printer                 = nil
    WAR.LOBBY.config.pages                   = nil
    WAR.LOBBY.config.guest_back              = nil
    WAR.LOBBY.config.guest_stake             = nil
    WAR.LOBBY.config.guest_seed              = nil
    WAR.LOBBY.config.guest_sleeve            = nil
    WAR.LOBBY.config.guest_challenge         = nil
    WAR.LOBBY.config.guest_decksmith         = nil
    WAR.LOBBY.config.guest_printer           = nil
    WAR.LOBBY.config.guest_pages             = nil
    if WAR.AVATAR then
        WAR.AVATAR._enemy_host  = "jimbo"
        WAR.AVATAR._enemy_guest = "jimbo"
    end
end

WAR.log("[WAR] lobby loaded")
