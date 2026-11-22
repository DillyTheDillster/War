-- core/sync.lua
-- Protocol dispatcher: routes incoming relay messages to game/UI handlers.
--
-- Message categories (relay → client):
--   auth:     registered, logged_in, logged_out, salt, auth_error
--   lobby:    created, joined, guest_joined, peer_left, peer_rejoined,
--             rejoined, peer_ready, stopGame, lobbyOptions/config, error, stats
--   game:     startGame, startBlind, enemyInfo, playerInfo, enemyLocation,
--             endPvP, winGame, loseGame, chat, achievementUnlocked, entitlementGranted,
--             counters
--
-- WAR.NET.poll() is called every frame from game_hooks.lua and returns a list
-- of decoded JSON messages. Auth messages go to WAR.AUTH.handle; everything
-- else is handled inline in WAR.SYNC.tick or dispatched to a lifecycle function.

WAR.SYNC = {}

function WAR.NET.on_relay_disconnected()
    if WAR.GAME.active then
        WAR.GAME.active = false
        WAR.UI.show_message(localize('war_relay_lost'))
        WAR.UI.hide_waiting()
    elseif WAR.GAME._end_screen ~= nil then
        -- Game already finished: drop cleanly, don't attempt to rejoin the
        -- old lobby (it's closed on the relay side once someone leaves).
        WAR.LOBBY.code    = nil
        WAR.LOBBY.is_host = false
        WAR.LOBBY_STATE   = "none"
        if WAR.UI.update_connection_status then WAR.UI.update_connection_status() end
    elseif WAR.LOBBY.code then
        local code     = WAR.LOBBY.code
        local is_host  = WAR.LOBBY.is_host
        WAR.LOBBY.code    = nil
        WAR.LOBBY.is_host = false
        WAR.LOBBY_STATE   = "none"
        WAR.UI.hide_lobby()
        WAR.UI.show_message(localize('war_disconnected'))
        -- Both hosts and guests can now reconnect; hosts use rejoin_host.
        if WAR.UI.start_reconnect then
            WAR.UI.start_reconnect(code, is_host)
        end
    end
    if WAR.UI.update_connection_status then WAR.UI.update_connection_status() end
end

function WAR.SYNC.tick()
    local msgs = WAR.NET.poll()
    for _, m in ipairs(msgs) do
        local a = m.action

        -- auth
        if a == "registered" or a == "logged_in" or a == "logged_out"
        or a == "salt"       or a == "auth_error" then
            WAR.AUTH.handle(m)

        -- lobby lifecycle
        elseif a == "created" then
            WAR.LOBBY.code    = m.code
            WAR.LOBBY.is_host = true
            if WAR.UI.update_connection_status then WAR.UI.update_connection_status() end
            -- Push the host's options so the relay and the client agree on
            -- defaults even if the settings popup is never opened.
            if WAR.LOBBY.push_config then WAR.LOBBY.push_config() end
            if WAR.UI.on_lobby_created then
                local ok, err = pcall(WAR.UI.on_lobby_created, m.code)
                if not ok then WAR.log("[WAR SYNC] on_lobby_created: " .. tostring(err)) end
            end

        elseif a == "joined" then
            WAR.LOBBY.code    = m.code
            WAR.LOBBY.is_host = false
            if WAR.UI.update_connection_status then WAR.UI.update_connection_status() end
            WAR.LOBBY.peer_version = m.mod_version or m.host_mod_version
            WAR.LOBBY.peer_smods   = m.smods_version
            if WAR.AVATAR then
                WAR.AVATAR.set_enemy("host", m.pfp or m.host_avatar)
            end
            if WAR.UI.on_joined_as_guest then
                WAR.UI.on_joined_as_guest(m.host_username, m.code)
            end
            -- The relay needs the guest's own picks before a match can start on
            -- separate decks/seeds (harmless while Same Deck/Stake is on).
            if WAR.LOBBY.push_guest_choices then WAR.LOBBY.push_guest_choices() end

        elseif a == "guest_joined" then
            WAR.LOBBY.peer_version = m.mod_version
            WAR.LOBBY.peer_smods   = m.smods_version
            if WAR.AVATAR then
                WAR.AVATAR.set_enemy("guest", m.pfp or m.avatar)
            end
            if WAR.UI.on_guest_joined then
                WAR.UI.on_guest_joined(m.username)
            end

        elseif a == "peer_left" then
            if WAR.GAME.active then
                WAR.SYNC.on_stop_game(localize('war_opp_disconnected'))
            else
                if WAR.UI.on_peer_left then WAR.UI.on_peer_left() end
            end

        elseif a == "promoted_to_host" then
            -- The original host left; the relay has transferred the lobby to us.
            WAR.LOBBY.is_host      = true
            WAR.LOBBY.code         = m.code or WAR.LOBBY.code
            WAR.LOBBY.peer_version = nil
            WAR.LOBBY.peer_smods   = nil
            -- Apply the options the original host had configured.
            if m.options and type(m.options) == 'table' then
                for k, v in pairs(m.options) do WAR.LOBBY.config[k] = v end
            end
            if WAR.UI.update_connection_status then WAR.UI.update_connection_status() end
            if WAR.UI.on_promoted_to_host then WAR.UI.on_promoted_to_host() end

        elseif a == "peer_rejoined" then
            -- The other player reconnected to the lobby.
            if m.mod_version then WAR.LOBBY.peer_version = m.mod_version end
            if m.smods_version then WAR.LOBBY.peer_smods = m.smods_version end
            if m.username then
                if WAR.LOBBY.is_host then
                    WAR.LOBBY.guest_name = m.username
                else
                    WAR.LOBBY.host_name = m.username
                end
            end
            if WAR.UI.update_lobby_status then WAR.UI.update_lobby_status() end
            if WAR.UI.update_connection_status then WAR.UI.update_connection_status() end

        elseif a == "rejoined" then
            -- Host successfully reclaimed their lobby after a TCP drop.
            WAR.LOBBY._reconnect_code     = nil
            WAR.LOBBY._reconnect_attempts = 0
            WAR.LOBBY._reconnect_is_host  = false
            WAR.LOBBY.code    = m.code
            WAR.LOBBY.is_host = true
            WAR.LOBBY_STATE   = "in_lobby"
            if m.guest_username then WAR.LOBBY.guest_name = m.guest_username end
            if m.guest_mod_version then WAR.LOBBY.peer_version = m.guest_mod_version end
            if m.guest_smods_version then WAR.LOBBY.peer_smods = m.guest_smods_version end
            if m.options then
                for k, v in pairs(m.options) do WAR.LOBBY.config[k] = v end
            end
            WAR.UI.show_lobby()
            if WAR.UI.update_connection_status then WAR.UI.update_connection_status() end

        elseif a == "peer_ready" then
            WAR.LOBBY.peer_ready = m.ready == true
            if WAR.UI.update_lobby_status then WAR.UI.update_lobby_status() end

        elseif a == "stopGame" then
            -- cause=forfeit when the other player left through the pause
            -- menu, so the message says what actually happened.
            local forfeited = (m.cause == "forfeit")
            if WAR.GAME.active then
                WAR.SYNC.on_stop_game(forfeited and localize('war_opp_forfeit')
                                               or localize('war_opp_left'))
                -- Walking away hands the match to the one who stayed: run the
                -- same win-side unlocks a played-out win would. on_stop_game
                -- has already restored the player's own profile by now.
                if forfeited and check_for_unlock then
                    check_for_unlock({ type = 'war_win' })
                end
            end
            -- The relay closes the lobby on every path that sends stopGame
            -- (forfeit, mid-game leave, mid-game drop) but keeps this socket
            -- open, so the local half has to be dropped here. A mid-game drop
            -- sends peer_left first, which is why this is not gated on
            -- GAME.active — by then on_stop_game has already run once.
            WAR.SYNC.on_lobby_closed()

        elseif a == "error" then
            WAR.UI.show_message(WAR.error_text(m.reason))

        elseif a == "stats" then
            if WAR.UI.on_stats then WAR.UI.on_stats(m) end

        elseif a == "modData" then
            local id = m.mod_id or ""
            WAR.MODCOMPAT._state[id] = m.data or {}
            local h = WAR.MODCOMPAT._handlers[id]
            if h then pcall(h, WAR.MODCOMPAT._state[id]) end

        elseif a == "lobbyOptions" or a == "config" then
            if m.lives     then WAR.LOBBY.config.lives     = tonumber(m.lives) end
            -- gamemode/ruleset decide which bans apply, so the guest has to
            -- track the host's pick or their run would ban a different set.
            if m.gamemode  then WAR.LOBBY.config.gamemode  = m.gamemode end
            if m.ruleset   then WAR.LOBBY.config.ruleset   = m.ruleset end
            if m.seed      then WAR.LOBBY.config.seed      = m.seed end
            if m.back      then WAR.LOBBY.config.back      = m.back end
            if m.stake     then WAR.LOBBY.config.stake     = tonumber(m.stake) end
            if m.challenge then WAR.LOBBY.config.challenge = m.challenge end
            if m.sleeve    ~= nil then WAR.LOBBY.config.sleeve = (m.sleeve ~= "") and m.sleeve or nil end
            if m.printer   ~= nil then WAR.LOBBY.config.printer = (m.printer ~= "") and m.printer or nil end
            -- Only a table counts: the host sends "" to clear a deck it is no
            -- longer running, and anything else is not ours to trust here.
            if m.decksmith ~= nil then
                WAR.LOBBY.config.decksmith = (type(m.decksmith) == "table") and m.decksmith or nil
            end
            if m.pages     ~= nil then
                WAR.LOBBY.config.pages = (type(m.pages) == "table") and m.pages or nil
            end
            if m.same_deck ~= nil then WAR.LOBBY.config.same_deck = m.same_deck == true end
            if m.same_seed ~= nil then WAR.LOBBY.config.same_seed = m.same_seed == true end
            if m.pvp_start_ante then
                WAR.LOBBY.config.pvp_start_ante = tonumber(m.pvp_start_ante)
            end
            if m.death_on_round_loss    ~= nil then WAR.LOBBY.config.death_on_round_loss    = m.death_on_round_loss    end
            if m.hide_score_until_played ~= nil then WAR.LOBBY.config.hide_score_until_played = m.hide_score_until_played end
            if m.comeback_gold           ~= nil then WAR.LOBBY.config.comeback_gold           = m.comeback_gold           end
            if m.pvp_boss_effects        ~= nil then WAR.LOBBY.config.pvp_boss_effects        = m.pvp_boss_effects        end
            if m.weeworld_showman        ~= nil then WAR.LOBBY.config.weeworld_showman        = m.weeworld_showman        end
            if m.timer_seconds           ~= nil then WAR.LOBBY.config.timer_seconds           = tonumber(m.timer_seconds) or 0 end
            if WAR.UI.update_deck_info then WAR.UI.update_deck_info() end
            if WAR.UI.create_lobby_panels then WAR.UI.create_lobby_panels() end

        -- The guest's own run choices, echoed by the relay so the host's panel
        -- shows what the other player is bringing to the match.
        elseif a == "guestChoices" then
            local cfg = WAR.LOBBY.config
            if m.guest_back      ~= nil then cfg.guest_back      = m.guest_back end
            if m.guest_stake     ~= nil then cfg.guest_stake     = tonumber(m.guest_stake) or 1 end
            if m.guest_seed      ~= nil then cfg.guest_seed      = (m.guest_seed ~= "") and m.guest_seed or nil end
            if m.guest_sleeve    ~= nil then cfg.guest_sleeve    = (m.guest_sleeve ~= "") and m.guest_sleeve or nil end
            if m.guest_challenge ~= nil then cfg.guest_challenge = (m.guest_challenge ~= "") and m.guest_challenge or nil end
            if m.guest_decksmith ~= nil then
                cfg.guest_decksmith = (type(m.guest_decksmith) == "table") and m.guest_decksmith or nil
            end
            if m.guest_printer   ~= nil then
                cfg.guest_printer = (m.guest_printer ~= "") and m.guest_printer or nil
            end
            if m.guest_pages     ~= nil then
                cfg.guest_pages = (type(m.guest_pages) == "table") and m.guest_pages or nil
            end
            if WAR.UI.update_deck_info then WAR.UI.update_deck_info() end
            if WAR.UI.create_lobby_panels then WAR.UI.create_lobby_panels() end

        elseif a == "hello" then
            WAR.GAME.enemy_location = ""

        -- game start
        elseif a == "startGame" then
            WAR.SYNC.on_start_game(m)

        -- PvP blind barrier
        elseif a == "blindTimer" then
            local secs = tonumber(m.seconds) or 0
            WAR.log(("[WAR] blindTimer secs=%s late=%s paused=%s"):format(
                tostring(secs), tostring(m.late), tostring(m.paused)))
            if secs > 0 then
                local my_role = WAR.LOBBY.is_host and "host" or "guest"
                WAR.GAME.start_pvp_timer(secs, m.late ~= my_role, m.paused == true)
            else
                WAR.GAME.stop_pvp_timer()
            end

        elseif a == "startBlind" then
            WAR.SYNC.on_start_blind(m)

        -- live game data
        elseif a == "enemyInfo" then
            WAR.SYNC.on_enemy_info(m)

        elseif a == "playerInfo" then
            WAR.GAME.ease_lives({ my = tonumber(m.lives) }, true)
            WAR.UI.refresh_hud()

        elseif a == "enemyStats" then
            WAR.GAME.enemy_stats = {
                jokers      = m.jokers or {},
                joker_names = m.joker_names or {},
                consumables = m.consumables or {},
                deck        = m.deck,
            }
            if WAR.UI.refresh_end_screen then WAR.UI.refresh_end_screen() end

        elseif a == "enemyLocation" then
            WAR.GAME.enemy_location = m.location or ""
            WAR.UI.refresh_hud()

        -- round resolution
        elseif a == "endPvP" then
            WAR.SYNC.on_end_pvp(m)

        -- game over
        elseif a == "winGame" then
            WAR.GAME.score_result = m
            WAR.GAME.send_end_increments()
            -- Missing Joker is judged on the slots as they stand when the win
            -- lands, so a joker slotted in after the last hand still voids it.
            if WAR.GAME.missing_joker_valid and G.jokers then
                local lim = G.jokers.config and G.jokers.config.card_limit or 5
                if #G.jokers.cards >= lim then WAR.GAME.missing_joker_valid = false end
            end
            WAR.GAME.snapshot_legendaries()
            WAR.SYNC.on_game_over(true)
            check_for_unlock({type = 'war_win'})

        elseif a == "loseGame" then
            WAR.GAME.score_result = m
            WAR.GAME.send_end_increments()
            WAR.SYNC.on_game_over(false)

        elseif a == "chat" then
            if WAR.UI.show_chat then WAR.UI.show_chat(m.text) end

        -- entitlements / achievements
        elseif a == "achievementUnlocked" then
            local key = m.key
            if key then
                -- The relay only sends this for a fresh grant, so it is the
                -- one place every unlock is announced: claimed one-offs and
                -- the count-based ones the server settles itself.
                local fresh = not WAR.AVATAR.is_entitled(key)
                WAR.AVATAR.grant_local(key)
                if fresh and WAR.AVATAR.icon(key) then
                    notify_alert(key, 'war_icon')
                end
                if WAR.ICON_SELECT and WAR.ICON_SELECT.refresh then WAR.ICON_SELECT.refresh() end
            end

        elseif a == "entitlementGranted" then
            local key = m.key
            if key then
                WAR.AVATAR.grant_local(key)
                if WAR.ICON_SELECT and WAR.ICON_SELECT.refresh then WAR.ICON_SELECT.refresh() end
            end

        elseif a == "counters" then
            if m.counters and type(m.counters) == "table" then
                if WAR.ACH_PROGRESS_READY then
                    for key, total in pairs(m.counters) do
                        local before = tonumber(WAR.ACH_PROGRESS[key]) or 0
                        local now    = tonumber(total) or 0
                        if now > before then
                            WAR.log(string.format("[WAR] %s incremented (%d) now (%d)",
                                                  WAR.AVATAR.name(key), now - before, now))
                        end
                    end
                end
                WAR.ACH_PROGRESS = m.counters
                WAR.ACH_PROGRESS_READY = true
            end
        end
    end
end

function WAR.SYNC.on_start_game(m)
    WAR.GAME.active       = true
    WAR.GAME.won_with     = {}
    WAR.GAME.my_lives     = tonumber(m.lives) or 4
    WAR.GAME.enemy_lives  = tonumber(m.lives) or 4
    -- Fresh list of sounds for the sound tracer (game_hooks).
    WAR.GAME._sounds_heard = {}
    WAR.GAME.enemy_score  = 0
    WAR.GAME.enemy_score_display = 0
    WAR.GAME._score_ease  = nil
    WAR.GAME.jolly_valid  = true
    WAR.GAME.droll_valid  = true
    WAR.GAME.prob_hits    = 0
    WAR.GAME.hand_counts  = {}
    WAR.GAME.jacks_discarded = 0
    WAR.GAME.hack_hits       = 0
    WAR.GAME.riff_raff_valid   = true
    WAR.GAME.missing_joker_valid = true
    WAR.GAME.match_stake         = nil
    WAR.GAME.match_deck          = nil
    WAR.GAME._hand_state_sent    = true  -- stays true until first SELECTING_HAND
    WAR.GAME.reset_achievements()
    WAR.GAME.enemy_hands  = 0
    WAR.GAME.enemy_hands_masked = false
    WAR.GAME.enemy_skips  = 0
    WAR.GAME.is_pvp_blind    = false
    WAR.GAME.end_pvp_pending = false
    WAR.GAME.enemy_masked    = false
    WAR.MODCOMPAT._state  = {}
    -- Clear any stale end-screen state from the previous match. Without this,
    -- refresh_end_screen fires when enemyStats arrives and re-shows the old screen.
    WAR.GAME._end_screen      = nil
    WAR.GAME._end_won         = nil
    WAR.GAME._stats_refreshed = nil
    WAR.GAME._my_board_snapshot = nil

    if m.lives     then WAR.LOBBY.config.lives     = tonumber(m.lives) end
    if m.seed      then WAR.LOBBY.config.seed      = m.seed end
    if m.back      then WAR.LOBBY.config.back      = m.back end
    if m.stake     then WAR.LOBBY.config.stake     = tonumber(m.stake) end
    if m.challenge then WAR.LOBBY.config.challenge = m.challenge end
    if m.sleeve    ~= nil then WAR.LOBBY.config.sleeve = (m.sleeve ~= "") and m.sleeve or nil end
    if m.decksmith ~= nil then
        WAR.LOBBY.config.decksmith = (type(m.decksmith) == "table") and m.decksmith or nil
    end
    if m.printer   ~= nil then
        WAR.LOBBY.config.printer = (type(m.printer) == "string" and m.printer ~= "") and m.printer or nil
    end
    if m.pages     ~= nil then
        WAR.LOBBY.config.pages = (type(m.pages) == "table") and m.pages or nil
    end

    -- What this client actually plays with. The relay decides it (the host's
    -- choices, or this client's own when the lobby allows separate decks and
    -- seeds), so it is read off the message instead of recomputed from the
    -- lobby config, and a mid-match restart replays exactly this.
    WAR.GAME.local_run = {
        back      = m.back or "Red Deck",
        stake     = tonumber(m.stake) or 1,
        seed      = m.seed,
        sleeve    = (m.sleeve ~= nil and m.sleeve ~= "") and m.sleeve or nil,
        challenge = m.challenge,
    }

    if G.OVERLAY_MENU then G.FUNCS.exit_overlay_menu() end
    WAR.UI.hide_lobby()

    -- Both sides run on the all-unlocked War profile. A guest who never opened
    -- the deck picker is still on their own profile, where the deck back and the
    -- sleeve would draw their locked art even though the run uses them.
    if WAR.UI.enter_war_profile then WAR.UI.enter_war_profile() end

    -- Modded decks (Decksmith custom deck, Revo's Vault printer pick): rebuild
    -- them before the run is built. Both clients come through here, so the data
    -- is installed from the same source rather than from local leftovers. A
    -- guest that cannot rebuild it — no mod, unreadable payload, or a relay
    -- that never carried it — would otherwise run a different deck from the
    -- same relay data, so the match stops instead.
    -- Run-select pages (compat/runselect.lua) are the opposite: they never stop
    -- a match. A page this install does not have is logged and both clients
    -- play on.
    local compat_err = nil
    if WAR.COMPAT then
        for _, entry in ipairs({
            { WAR.COMPAT.apply_decksmith, m.decksmith },
            { WAR.COMPAT.apply_printer,   m.printer   },
            { WAR.COMPAT.apply_pages,     m.pages     },
        }) do
            local apply, payload = entry[1], entry[2]
            if type(apply) == "function" then
                local ok, err = apply(payload, m.back)
                if not ok then compat_err = err end
            end
        end
    end
    if compat_err and not WAR.LOBBY.is_host then
        WAR.log("[WAR COMPAT] cannot start this match: " .. tostring(compat_err))
        WAR.UI.show_message(localize(compat_err))
        WAR.LOBBY.leave()
        return
    end

    -- vanilla start_run wants the challenge object, not its id: it reads
    -- args.challenge.deck / .jokers / .rules when building the run.
    local challenge = WAR.challenge_by_id(m.challenge)
    -- A challenge can run on a deck picked on the challenge screen. That deck
    -- wins over the challenge's own `deck`, which is what game.lua reads first,
    -- so hand start_run a copy with `deck` cleared (false, so the metatable
    -- fallback can't hand the original back) and let args.back drive it.
    if challenge and m.back and m.back ~= "Challenge Deck" then
        local ch = {}
        for k, v in pairs(challenge) do ch[k] = v end
        local mt = getmetatable(challenge)
        if mt then setmetatable(ch, mt) end
        ch.deck = false
        challenge = ch
    end

    local params = {
        seed      = WAR.GAME.local_run.seed,
        stake     = WAR.GAME.local_run.stake,
        back      = WAR.GAME.local_run.back,
        challenge = challenge,
    }
    -- CardSleeves reads the sleeve off the run args while init_game_object
    -- builds G.GAME; without this the run starts sleeveless even though the
    -- lobby panel showed one. Always set casl_sleeve_choice — even when the
    -- relay-authoritative sleeve is nil — so CardSleeves cannot fall back to
    -- G.viewed_sleeve, which may still hold a stale value from a deck browse
    -- the guest did while same_deck was temporarily toggled off.
    params.casl_sleeve_choice = WAR.GAME.local_run.sleeve or "sleeve_casl_none"

    -- Short pause so UI finishes closing, then wipe-transition into the run
    -- A new match starts a fresh run clock for mods that measure elapsed play.
    WAR.GAME._run_time = 0
    G.E_MANAGER:add_event(Event({
        trigger   = "after",
        delay     = 0.1,
        blockable = false,
        func = function()
            G.SETTINGS.paused = true
            G.FUNCS.wipe_on()
            G.E_MANAGER:add_event(Event({
                no_delete = true,
                func = function() G:delete_run(); return true end,
            }))
            G.E_MANAGER:add_event(Event({
                trigger   = "immediate",
                no_delete = true,
                func = function()
                    -- vanilla start_run reads G.GAME.viewed_back, not args.back;
                    -- set it here so both host and guest get the correct deck
                    if params.back then
                        pcall(function()
                            G.GAME.viewed_back = Back(get_deck_from_name(params.back))
                        end)
                    end
                    G:start_run(params)
                    return true
                end,
            }))
            G.FUNCS.wipe_off()
            return true
        end,
    }))

    WAR.log("[WAR SYNC] game started seed=" .. tostring(m.seed))
end

function WAR.SYNC.on_start_blind(m)
    -- A duplicate startBlind (relay resync after a re-sent ready, or a replayed
    -- message) must not reset a blind that is already being played: it would
    -- wipe the score/hand state and stop the clock mid-round.
    if WAR.GAME.is_pvp_blind and G.STATE and G.STATES
       and G.STATE ~= G.STATES.BLIND_SELECT then
        WAR.log("[WAR] on_start_blind: a PvP blind is already live, duplicate ignored")
        return
    end
    WAR.GAME._start_blind_pending = nil
    local hands = (G.GAME.round_resets and G.GAME.round_resets.hands) or 4
    WAR.GAME.enemy_score         = 0
    WAR.GAME.enemy_score_display = 0
    WAR.GAME._score_ease         = nil
    WAR.GAME.enemy_hands  = hands
    WAR.GAME.enemy_hands_masked = true
    WAR.GAME.enemy_skips  = 0
    WAR.GAME.is_pvp_blind = true
    WAR.GAME.enemy_masked = false
    WAR.GAME.pvp_lost     = false
    WAR.GAME.score_result = nil

    WAR.UI.hide_waiting()
    WAR.UI.refresh_hud()

    -- Boss effects are switched off inside the Blind:set_blind hook (see
    -- game_hooks.lua): the blind object is rebuilt by new_round when the round
    -- actually starts, so a flag set here would be wiped before it mattered.

    WAR.GAME.stop_pvp_timer()

    -- Publish my opening state so the rival's HUD shows a real hand count
    -- instead of the server's default until my first hand lands.
    if WAR.GAME.send_hand_state then WAR.GAME.send_hand_state(0, hands) end

    local e = WAR.GAME._pending_blind_e
    WAR.GAME._pending_blind_e = nil
    WAR.GAME._blind_starting  = true
    -- The select screen's rival icon is pinned to the boss chip in the UIBox
    -- that's about to be torn down by select_blind. Clear it before the
    -- transition so the boss_badge sprite is removed from G.ANIMATIONS rather
    -- than left drawing indefinitely behind the blind.
    if WAR.UI and WAR.UI._rival_icons then
        for i = #WAR.UI._rival_icons, 1, -1 do
            if WAR.UI._rival_icons[i].tag == "select" then
                WAR.UI.drop_rival_icon(WAR.UI._rival_icons[i])
                table.remove(WAR.UI._rival_icons, i)
            end
        end
    end
    if not e and G.blind_select_opts and G.blind_select_opts.boss then
        -- startBlind arrived before the player clicked (reconnect edge-case or
        -- rare network timing). Find the Boss button so the blind still starts.
        local fallback = G.blind_select_opts.boss:get_UIE_by_ID('select_blind_button')
        if fallback and fallback.config then e = fallback end
        if e then WAR.log("[WAR] on_start_blind: used fallback button (pending_blind_e was nil)") end
    end
    if e then
        -- pcall so _blind_starting is always reset even if select_blind errors.
        local ok, err = pcall(G.FUNCS.select_blind, e)
        if not ok then WAR.log("[WAR] on_start_blind select_blind error: " .. tostring(err)) end
    else
        -- The message beat the select screen (mid-transition, or a reconnect).
        -- Dropping it left the relay in the blind and the client on the barrier
        -- forever, so retry from the tick while the button is still to come.
        WAR.GAME._start_blind_pending = WAR.GAME.now()
        WAR.log("[WAR] on_start_blind: select button not up yet, will retry")
    end
    WAR.GAME._blind_starting = false
end

-- startBlind can arrive a beat before the select screen exists. Retry the entry
-- for a few seconds instead of leaving the client stuck on the barrier.
function WAR.SYNC.retry_pending_start()
    local at = WAR.GAME._start_blind_pending
    if not at then return end
    if WAR.GAME.now() - at > 5 then
        WAR.GAME._start_blind_pending = nil
        WAR.log("[WAR] startBlind: blind select never appeared, gave up")
        return
    end
    local opts = G.blind_select_opts and G.blind_select_opts.boss
    local btn  = opts and opts.get_UIE_by_ID and opts:get_UIE_by_ID('select_blind_button')
    if not btn then return end
    WAR.GAME._start_blind_pending = nil
    -- _blind_starting makes the select_blind hook pass through to vanilla
    -- instead of treating this as a fresh ready-up.
    WAR.GAME._blind_starting = true
    local ok, err = pcall(G.FUNCS.select_blind, btn)
    WAR.GAME._blind_starting = false
    if not ok then WAR.log("[WAR] deferred select_blind error: " .. tostring(err)) end
end

-- A readyBlind that never draws startBlind leaves the button on "Readied!" and
-- the hook ignores repeat clicks, so nothing can retry: the opponent waits on
-- the barrier forever. Re-ask on a slow interval — the relay ignores a repeat
-- ready for a blind that already started and answers with startBlind, so this
-- can never start a second blind.
function WAR.SYNC.maybe_resend_ready()
    if not (WAR.GAME.active and WAR.GAME._pending_blind_e) then return end
    local now = WAR.GAME.now()
    if now - (WAR.GAME._ready_sent_at or 0) < 8 then return end
    WAR.GAME._ready_resends = (WAR.GAME._ready_resends or 0) + 1
    if WAR.GAME._ready_resends > 4 then return end
    WAR.GAME._ready_sent_at = now
    WAR.log("[WAR] no startBlind yet, re-sending readyBlind #" .. WAR.GAME._ready_resends)
    WAR.NET.send({ action = "readyBlind", skips = (G.GAME and G.GAME.skips) or 0 })
end

function WAR.SYNC.on_enemy_info(m)
    WAR.log(("[WAR NET] enemyInfo score=%s hands=%s%s"):format(
        tostring(m.score), tostring(m.handsLeft), m.noScore and " (hidden)" or ""))
    if m.noScore or m.score == nil then
        WAR.GAME.enemy_masked = true
    else
        local new_score = WAR.SCORE.decode(m.score)
        WAR.GAME.enemy_masked = false
        -- Count up from wherever the display sits, as BMP does with its 0.75s ease.
        WAR.GAME._score_ease = {
            from  = WAR.GAME.enemy_score_display or 0,
            to    = new_score,
            start = G.TIMERS and G.TIMERS.REAL or 0,
            dur   = 0.75,
        }
        WAR.GAME.enemy_score = new_score
    end
    if m.handsLeft ~= nil then
        WAR.GAME.enemy_hands = tonumber(m.handsLeft) or 0
        WAR.GAME.enemy_hands_masked = false
    end
    if m.skips ~= nil then
        -- Skipping is tracked for the blind clock; it has no cue of its own.
        WAR.GAME.enemy_skips = tonumber(m.skips) or 0
    end
    if m.lives ~= nil then
        WAR.GAME.ease_lives({ enemy = tonumber(m.lives) }, true)
    end
    -- DO NOT update G.GAME.blind.chips here — it is held at 999M during PvP
    -- so vanilla never auto-wins. Display is driven by WAR.UI._hud.enemy_score.
    WAR.UI.refresh_hud()
    if WAR.UI.juice_pvp_hud then WAR.UI.juice_pvp_hud() end
end

function WAR.SYNC.on_end_pvp(m)
    -- is_pvp_blind stays set until the state machine actually leaves the
    -- blind; clearing it here let vanilla evaluate the 999M target itself
    -- and end the run.
    WAR.GAME.pvp_lost        = m.lost == true
    WAR.GAME.end_pvp_pending = true
    WAR.UI.show_end_pvp(not m.lost)
end

function WAR.SYNC.on_game_over(i_won)
    WAR.GAME.active       = false
    WAR.GAME.is_pvp_blind = false
    -- Capture board data while game objects (G.jokers etc.) are still live.
    -- G:load_profile inside exit_war_profile may clear joker/consumable state,
    -- so both the relay send and the end-screen snapshot must happen first.
    if WAR.GAME.send_board_stats then WAR.GAME.send_board_stats() end
    WAR.GAME._my_board_snapshot = WAR.GAME.my_board and WAR.GAME.my_board()
    if WAR.UI.exit_war_profile then WAR.UI.exit_war_profile() end
    WAR.GAME._end_screen     = not not i_won
    WAR.GAME._stats_refreshed = nil
    local function show()
        if i_won then WAR.UI.show_win_game() else WAR.UI.show_lose_game() end
    end
    -- Give the relay a beat to bring the opponent's board in before painting it.
    -- Guard: if a new game started before the delay fires, skip the stale show.
    if G.E_MANAGER and Event then
        G.E_MANAGER:add_event(Event({
            trigger = "after", delay = 0.35, blockable = false,
            func = function()
                if not WAR.GAME.active and WAR.GAME._end_screen ~= nil then
                    show()
                end
                return true
            end,
        }))
    else
        show()
    end
    if WAR.ICON_SELECT and WAR.ICON_SELECT.refresh then WAR.ICON_SELECT.refresh() end
end

function WAR.SYNC.on_stop_game(msg)
    WAR.GAME.active       = false
    WAR.GAME.is_pvp_blind = false
    WAR.MODCOMPAT._state  = {}
    if WAR.UI.exit_war_profile then WAR.UI.exit_war_profile() end
    WAR.UI.hide_waiting()
    WAR.UI.show_message(msg or localize('war_game_stopped'))
    if G.STAGE ~= G.STAGES.MAIN_MENU then
        G.FUNCS.go_to_menu()
    end
end

-- The relay has closed the lobby under us: the opponent forfaited, left, or
-- dropped mid-match. Nothing is left to relay to, so drop everything the dead
-- match left running — the same way leaving the end screen does (see
-- G.FUNCS.war_end_to_menu). Without this the main menu keeps the dead code,
-- still reads as connected, and the blind clock keeps counting into G.GAME.round.
function WAR.SYNC.on_lobby_closed()
    if WAR.GAME.stop_pvp_timer then WAR.GAME.stop_pvp_timer() end
    if WAR.LOBBY.code or WAR.LOBBY_STATE ~= "none" then
        WAR.LOBBY.leave_local()
        if WAR.UI.hide_lobby then WAR.UI.hide_lobby() end
    end
    if WAR.UI.update_connection_status then WAR.UI.update_connection_status() end
end

function WAR.SYNC.my_username()
    return WAR.AUTH.user or "Player"
end

function WAR.MODCOMPAT.register(mod_id, handler)
    assert(type(mod_id) == "string" and mod_id ~= "", "WAR.MODCOMPAT.register: mod_id must be a non-empty string")
    assert(type(handler) == "function", "WAR.MODCOMPAT.register: handler must be a function")
    WAR.MODCOMPAT._handlers[mod_id] = handler
end

function WAR.MODCOMPAT.send(mod_id, data)
    if not WAR.NET.connected() then return end
    WAR.NET.send({ action="modData", mod_id=mod_id, data=data })
end

-- Returns the last data table received from the opponent for this mod_id,
-- or nil if nothing has arrived yet this game.
function WAR.MODCOMPAT.get(mod_id)
    return WAR.MODCOMPAT._state[mod_id]
end

WAR.log("[WAR] sync loaded")
