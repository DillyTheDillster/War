-- core/game_hooks.lua

local _auto_login_done = false

WAR.GAME.prob_hits = 0

-- Oops counts probability rolls that land. Mod jokers roll through
-- SMODS.pseudorandom_probability, which posts a pseudorandom_result context a
-- frame later; vanilla jokers roll with plain pseudorandom(seed, 1, n) and never
-- reach that path, so wrap the global and pick up the rolls that come back at
-- the low end of the range (the "1 in n landed" case).
function WAR.GAME.prob_hit()
    if not WAR.GAME.active or not WAR.GAME.pvp_round() then return end
    WAR.GAME.prob_hits = (WAR.GAME.prob_hits or 0) + 1
    if WAR.GAME.prob_hits >= 25 then
        check_for_unlock({ type = 'war_oops' })
    end
end

if pseudorandom and not WAR.GAME._prob_wrapped then
    WAR.GAME._prob_wrapped = true
    local _pseudorandom = pseudorandom
    pseudorandom = function(seed, min, max)
        local ret = _pseudorandom(seed, min, max)
        if min and max and max > 1 and ret == min then
            WAR.GAME.prob_hit()
        end
        return ret
    end
end


-- The pause menu row is hidden by a Lovely patch; this stops the copy button
-- (or any mod that calls it) from putting the seed on the clipboard.
local _orig_copy_seed = G.FUNCS.copy_seed
G.FUNCS.copy_seed = function(e)
    if WAR.GAME.active then return end
    if _orig_copy_seed then return _orig_copy_seed(e) end
end

local _orig_game_update = Game.update
function Game:update(dt)
    _orig_game_update(self, dt)
    if not _auto_login_done then
        _auto_login_done = true
        WAR.AUTH.auto_login(function(ok)
            if ok then
                WAR.log("[WAR AUTH] auto-login as " .. tostring(WAR.AUTH.user))
            end
            if WAR.UI.update_connection_status then WAR.UI.update_connection_status() end
        end)
    end
    -- Tick round-counter timer display while waiting for readyBlind.
    -- DynaText already reads G.GAME.round each frame, so just overwrite it.
    if WAR.GAME._pvp_timer and G.TIMERS and G.GAME then
        local t = WAR.GAME._pvp_timer
        t._orig_round = t._orig_round or G.GAME.round
        if t.paused then
            G.GAME.round = t._paused_remaining or t.secs
        else
            local elapsed = G.TIMERS.REAL - t.start
            local left    = math.max(0, math.ceil(t.secs - elapsed))
            G.GAME.round  = left
            -- Final ten seconds: one click per second, keyed off the countdown
            -- so a slow frame can neither double up nor skip a click.
            if left > 0 and left <= 10 and t._last_click ~= left then
                t._last_click = left
                play_sound("war_timer", 1, 1)
            end
        end
    end
    if WAR.UI.sync_rival_icons then WAR.UI.sync_rival_icons() end
    if WAR.NET.connected() then
        local ok, err = pcall(WAR.SYNC.tick)
        if not ok then WAR.log("[WAR TICK] " .. tostring(err)) end
    end
    -- Score goes out on hand end, blind start, deck-out and hand-count gains.
    -- Never mid-scoring: those frames carry partial totals.
    -- Keep the rival icons glued to their chips (sprites never move children)
    if WAR.UI.sync_rival_icons then WAR.UI.sync_rival_icons() end
    -- Drag repositioning for lobby panels (main menu only)
    if WAR.UI.update_panel_drag and G.STAGE == G.STAGES.MAIN_MENU then
        WAR.UI.update_panel_drag()
    end
    -- Force-advance to NEW_ROUND when endPvP arrives in non-HAND_PLAYED states
    -- (e.g. arrives while drawing cards or selecting hand). HAND_PLAYED is now
    -- handled directly in update_hand_played, so this only covers other states.
    if WAR.GAME.active and WAR.GAME.end_pvp_pending and G.STAGE == G.STAGES.RUN then
        local state = G.STATE
        if state ~= G.STATES.NEW_ROUND
           and not (G.GAME.STOP_USE and G.GAME.STOP_USE > 0) then
            WAR.GAME.end_pvp_pending = false
            WAR.GAME.is_pvp_blind    = false
            if G.hand then G.hand:unhighlight_all() end
            G.STATE_COMPLETE = false
            G.STATE          = G.STATES.NEW_ROUND
        end
    end
    -- Keep the vanilla card visible so the Card's mouse-tilt shader still works.
    -- We only suppress it if it was already invisible before the lobby opened.
end

local _orig_main_menu = Game.main_menu
function Game:main_menu(change_context)
    _orig_main_menu(self, change_context)
    -- Safety net: restore original profile if the player quit a War run via vanilla means.
    if WAR.UI.exit_war_profile then WAR.UI.exit_war_profile() end
    if WAR.UI.update_connection_status then
        WAR.UI.update_connection_status()
    end
end

local _orig_start_run = Game.start_run
function Game:start_run(start_params)
    if WAR.GAME.active and (WAR.LOBBY.config.seed or WAR.LOBBY.config.sleeve) then
        start_params = start_params or {}
        if WAR.LOBBY.config.seed then
            start_params.seed = tostring(WAR.LOBBY.config.seed)
        end
        -- CardSleeves only looks at the run args, so a mid-match restart needs
        -- the sleeve put back or the new run comes up without it.
        if WAR.LOBBY.config.sleeve then
            start_params.casl_sleeve_choice = WAR.LOBBY.config.sleeve
        end
    end
    _orig_start_run(self, start_params)
    if WAR.GAME.active then
        -- Record stake and deck for end-of-match achievement increments.
        WAR.GAME.match_stake = G.GAME and G.GAME.stake
        WAR.GAME.match_deck  = G.GAME and G.GAME.back and G.GAME.back.name
        -- Bans come from the gamemode + ruleset pair so the ruleset screen can
        -- show exactly what is disabled. Fall back to the standard ruleset when
        -- a lobby was created before a ruleset was recorded.
        local rs_key = WAR.LOBBY.config.ruleset or "standard"
        local gm_key = WAR.LOBBY.config.gamemode or "vanilla"
        G.GAME.banned_keys = G.GAME.banned_keys or {}
        for k in pairs(WAR.banned_keys_for(gm_key, rs_key)) do
            G.GAME.banned_keys[k] = true
        end

        SMODS.calculate_context({war_gameStart = true}) -- no need to pass more, WAR.LOBBY.config and WAR have it already

        -- The first round's blind tags are pre-computed inside _orig_start_run
        -- before banned_keys is populated, so they can be banned items.
        -- Re-pick them now that the full ban list is final. Only fires when
        -- something is actually banned; standard ruleset skips this entirely.
        -- Both players in the same lobby use the same ruleset, so both re-pick
        -- the same number of times and the pseudorandom sequence stays in sync.
        if next(G.GAME.banned_keys) and G.GAME.round_resets and G.GAME.round_resets.blind_tags then
            if G.GAME.round_resets.blind_tags.Small then
                G.GAME.round_resets.blind_tags.Small = get_next_tag_key()
            end
            if G.GAME.round_resets.blind_tags.Big then
                G.GAME.round_resets.blind_tags.Big = get_next_tag_key()
            end
        end
        -- Same issue: the first ante's voucher is pre-picked inside _orig_start_run
        -- before banned_keys is populated. get_current_pool already filters banned
        -- items, so a fresh call returns a non-banned voucher.
        if G.GAME.current_round and G.GAME.banned_keys[G.GAME.current_round.voucher] then
            G.GAME.current_round.voucher = get_next_voucher_key()
        end
    end
    if WAR.GAME.active and WAR.UI.setup_lives_hud then
        G.E_MANAGER:add_event(Event({
            trigger = "after", delay = 0.5, blockable = false,
            func = function() WAR.UI.setup_lives_hud(); return true end,
        }))
    end
end

local _orig_reroll_boss = G.FUNCS.reroll_boss
if _orig_reroll_boss then
    G.FUNCS.reroll_boss = function(e)
        _orig_reroll_boss(e)
    end
end

-- update_hand_played is the only place that runs exactly once per finished
-- hand, after the chip total has settled. Evaluating G.FUNCS.evaluate_round
-- instead reports the score once per *blind* (it is the cash-out screen),
-- which is why the opponent saw 0 hands / 0 score for a whole round.

function WAR.GAME.hands_left()
    return (G.GAME and G.GAME.current_round and G.GAME.current_round.hands_left) or 0
end

-- G.GAME.chips is a number in vanilla, an Amulet BigNum table once Amulet loads.
-- Try .number, then :to_number(), then the printed form.
function WAR.GAME.my_chips()
    local raw = G.GAME and G.GAME.chips
    -- tonumber handles plain numbers directly.
    local n = tonumber(raw)
    if n then return n end
    -- BigNum: may be a Lua table (other mods, or Amulet with enable_compat=true)
    -- or an FFI cdata struct (Amulet OmegaNum with enable_compat=false, type()=="cdata").
    -- Access .number via pcall so the same path covers both without a type-check branch.
    if raw ~= nil then
        local ok, v = pcall(function() return raw.number end)
        if ok and type(v) == "number" and v == v then return v end   -- v==v: skip NaN
        ok, v = pcall(function() return raw:to_number() end)
        if ok and type(v) == "number" and v == v then return v end
    end
    return tonumber((tostring(raw):gsub(",", ""):gsub("%s", ""))) or 0
end

function WAR.GAME.send_hand_state(score, hands)
    -- Capture raw chips BEFORE settle_chips converts a BigNum to a plain float
    -- (which would lose the actual exponent, e.g. 800 for 10^800).
    local raw_chips = (score == nil) and (G.GAME and G.GAME.chips) or nil
    if not score then WAR.GAME.settle_chips() end
    -- Jolly and Droll are judged in the evaluate_poker_hand context instead: by
    -- the time this runs the played cards have already left G.play.
    -- Missing joker: invalidate if joker slots are full at any hand.
    if WAR.GAME.missing_joker_valid and G.jokers then
        local lim = G.jokers.config and G.jokers.config.card_limit or 5
        if #G.jokers.cards >= lim then
            WAR.GAME.missing_joker_valid = false
        end
    end
    -- Riff-raff: invalidate the moment any non-Common joker is detected.
    if WAR.GAME.riff_raff_valid and G.jokers and G.jokers.cards then
        for _, jkr in ipairs(G.jokers.cards) do
            local rar = jkr.config and jkr.config.center and jkr.config.center.rarity
            if rar and rar ~= 1 then
                WAR.GAME.riff_raff_valid = false
                break
            end
        end
    end
    local out_score = score or WAR.GAME.my_chips()
    local out_hands = hands or WAR.GAME.hands_left()
    WAR.NET.send({
        action    = "playHand",
        score     = WAR.SCORE.encode(out_score),
        log_score = string.format("%.17g", WAR.SCORE.log10_of(raw_chips ~= nil and raw_chips or out_score)),
        handsLeft = out_hands,
        skips     = (G.GAME and G.GAME.skips) or 0,
    })
    WAR.log(("[WAR NET] playHand score=%s hands=%s"):format(WAR.SCORE.encode(out_score), out_hands))
end

-- Final board for the end screen. Keys and display names; names are sent
-- alongside keys so the end screen can show a text fallback for modded jokers
-- even when Card() construction fails on the receiver.
local function _board_entries(area)
    local keys, names = {}, {}
    for _, card in ipairs(area and area.cards or {}) do
        local center = card.config and card.config.center
        if center and center.key then
            keys[#keys + 1]  = center.key
            names[#names + 1] = center.name or center.key
        end
    end
    return keys, names
end

function WAR.GAME.my_board()
    local jkeys, jnames = _board_entries(G.jokers)
    local ckeys         = (_board_entries(G.consumeables))
    return {
        jokers      = jkeys,
        joker_names = jnames,
        consumables = ckeys,
        deck        = G.GAME and G.GAME.back and G.GAME.back.name,
    }
end

function WAR.GAME.send_board_stats()
    if not WAR.NET.connected() then return end
    local board = WAR.GAME.my_board()
    WAR.NET.send({
        action      = "gameStats",
        jokers      = board.jokers,
        joker_names = board.joker_names,
        consumables = board.consumables,
        deck        = board.deck,
    })
    WAR.log(("[WAR NET] gameStats jokers=%d consumables=%d"):format(#board.jokers, #board.consumables))
end

-- Drop the blind target to my score so vanilla ends the round as a pass.
-- Used when the server's PvP result comes in (the target is held at 999M
-- during the blind) and when a normal blind was failed.
function WAR.GAME.force_pass()
    if G.GAME and G.GAME.blind then
        G.GAME.blind.chips = math.floor(WAR.GAME.my_chips())
    end
end

-- The chip counter eases toward the new total, and that ease is still running
-- when vanilla flips STATE_COMPLETE at the end of a hand — reading G.GAME.chips
-- at that moment reports the PREVIOUS hand's total. Settle the pending ease
-- before reporting.
function WAR.GAME.settle_chips()
    -- G.E_MANAGER uses .queues (plural, keyed table), not .queue
    local queues = G.E_MANAGER and G.E_MANAGER.queues
    if not queues then return end
    for _, queue in pairs(queues) do
        if type(queue) == "table" then
            for i = #queue, 1, -1 do
                local e    = queue[i]
                local ease = e and e.ease
                if ease and ease.ref_table == G.GAME and ease.ref_value == "chips" then
                    local ev = ease.end_val
                    local target = tonumber(ev)
                    if not target and ev ~= nil then
                        -- BigNum (table or cdata): try .number, then :to_number(), then tostring.
                        local ok, v = pcall(function() return ev.number end)
                        if ok and type(v) == "number" and v == v then
                            target = v
                        else
                            ok, v = pcall(function() return ev:to_number() end)
                            if ok and type(v) == "number" and v == v then target = v end
                        end
                    end
                    target = math.floor(
                        target
                        or tonumber((tostring(ev):gsub(",",""):gsub("%s","")))
                        or WAR.GAME.my_chips()
                    )
                    G.GAME.chips   = target
                    ease.start_val = target
                    ease.end_val   = target
                    return
                end
            end
        end
    end
end

-- Vanilla advances to NEW_ROUND when chips >= target OR hands_left < 1.
-- During PvP we block both: blind.chips is kept at 999M so vanilla never
-- detects a win, and exhausted hands loops back to HAND_PLAYED while
-- waiting for the server's endPvP signal.

local _orig_update_hand_played = Game.update_hand_played
function Game:update_hand_played(dt)
    if self.buttons then self.buttons:remove(); self.buttons = nil end
    if self.shop    then self.shop:remove();    self.shop    = nil end

    if WAR.GAME.active and WAR.GAME.pvp_round() then
        -- endPvP received — advance unconditionally (follows BMP's approach).
        -- The old guard "if not STATE_COMPLETE" prevented this from firing when
        -- parked waiting for the opponent, which blocked round resolution.
        if WAR.GAME.end_pvp_pending and not (G.GAME.STOP_USE and G.GAME.STOP_USE > 0) then
            WAR.GAME.end_pvp_pending = false
            WAR.GAME.is_pvp_blind    = false
            WAR.GAME.force_pass()
            if G.hand then G.hand:unhighlight_all() end
            WAR.GAME.stop_pvp_timer()
            G.STATE_COMPLETE = false
            G.STATE          = G.STATES.NEW_ROUND
            return
        end
        -- Still playing: advance state; score is tracked per-frame by Game:update.
        if not G.STATE_COMPLETE then
            G.STATE_COMPLETE = true
            G.E_MANAGER:add_event(Event({
                trigger = "immediate",
                func = function()
                    -- Settled total for the hand just played, and the last report
                    -- before the next blind: without it a dropped final frame
                    -- leaves the rival's counter on a partial number.
                    WAR.GAME.send_hand_state()
                    if G.GAME.current_round.hands_left > 0 then
                        G.STATE          = G.STATES.DRAW_TO_HAND
                        G.STATE_COMPLETE = false
                    else
                        -- Hands exhausted: show waiting indicator and park here until
                        -- endPvP arrives. Do NOT discard the hand yet — end_round()
                        -- (called from update_new_round) runs SMODS.calculate_end_of_round_effects
                        -- on G.hand before discarding, so blue seal / gold card effects
                        -- need the cards to still be there.
                        WAR.UI.wait_for_enemy()
                    end
                    return true
                end,
            }))
        end
        return
    end

    _orig_update_hand_played(self, dt)
end

-- win_game() must not fire, but `win_ante` is left at its real value: vanilla
-- gates the finisher bosses in get_new_boss() on `ante % win_ante`, so faking
-- win_ante silently changed which boss ante 8 rolled.

local _orig_win_game = win_game
win_game = function(...)
    if WAR.GAME.active then
        G.GAME.won = nil
        return
    end
    return _orig_win_game(...)
end

-- Same set of send points BMP uses, minus the ones we already cover.

-- Extra hands (Burglar-style gains) must reach the opponent immediately, or
-- their hand counter is stale until your next play.
local _orig_ease_hands_played = ease_hands_played
ease_hands_played = function(mod, instant)
    _orig_ease_hands_played(mod, instant)
    if WAR.GAME.active and WAR.GAME.pvp_round() and (mod or 0) > 0 then
        WAR.GAME.send_hand_state()
    end
end

-- Deck out: nothing left to draw while hands are still on the counter. Report
-- the exhausted state and park in the played state until the relay resolves.
-- Guards both cases: some hands played (partial deck-out) and no hands played
-- yet (deck drained before the first hand could be played).
local _orig_update_selecting_hand = Game.update_selecting_hand
function Game:update_selecting_hand(dt)
    -- Reset the per-hand send flag whenever we're in a selection phase for a
    -- non-pvp blind, so update_draw_to_hand / update_new_round fire once per hand.
    -- Also save the blind chip target here on the first hand selection — this is
    -- after blind.chips is fully computed and before Mr. Bones can fire, making
    -- it more reliable than saving in Blind.set_blind (where self.chips may be
    -- nil or a preliminary value depending on the call site).
    if WAR.GAME.active and not WAR.GAME.pvp_round() then
        WAR.GAME._hand_state_sent = false
        if not WAR.GAME._blind_chips_target and G.GAME and G.GAME.blind then
            local c = G.GAME.blind.chips
            local n = tonumber(c)
            if not n and c ~= nil then
                local ok, v = pcall(function() return c.number end)
                if ok and type(v) == "number" and v == v then n = v end
            end
            n = n or tonumber((tostring(c):gsub(",", ""):gsub("%s", "")))
            if type(n) == "number" and n > 0 and n < math.huge then
                WAR.GAME._blind_chips_target = n
            end
        end
    end
    if WAR.GAME.active and WAR.GAME.pvp_round()
       and (G.GAME.current_round.hands_left or 0) > 0
       and #G.hand.cards < 1 and #G.deck.cards < 1 and #G.play.cards < 1 then
        G.GAME.current_round.hands_left = 0
        WAR.GAME.send_hand_state()
        G.STATE_COMPLETE = false
        G.STATE          = G.STATES.HAND_PLAYED
        return
    end
    _orig_update_selecting_hand(self, dt)
end

-- Non-pvp: state transitions to DRAW_TO_HAND after a hand that didn't beat the
-- blind (more hands remain).  Vanilla owns the state machine fully; we just
-- read the settled total here, one frame after the last scoring event fired.
local _orig_update_draw_to_hand = Game.update_draw_to_hand
function Game:update_draw_to_hand(dt)
    if WAR.GAME.active and not WAR.GAME.pvp_round()
       and not WAR.GAME._hand_state_sent then
        WAR.GAME._hand_state_sent = true
        WAR.GAME.send_hand_state()
    end
    _orig_update_draw_to_hand(self, dt)
end

-- Non-pvp: on first entry to NEW_ROUND the chip total is settled. Report it,
-- check for a failed blind, then block the run-win trigger for the whole
-- round eval (ante 8 mid-match shouldn't end the game).
-- True when Mr. Bones is present, undebuffed, and the last hand scored at
-- least 25% of the blind requirement — mirroring vanilla's own threshold.
-- Mr. Bones still saves the round in War, but the blind counts as a failure:
-- failRound is sent and a life is deducted; only the text on the joker changes
-- (see the card_eval_status_text override below).
local function mr_bones_would_save(chips, target)
    if not (chips and target and chips >= target * 0.25) then return false end
    for _, card in ipairs(G.jokers and G.jokers.cards or {}) do
        local key = card.config and card.config.center and card.config.center.key
        if key == "j_mr_bones" and not card.debuff then return true end
    end
    return false
end

-- Replace Mr. Bones' "SAVED!" popup with a life-lost message during a War
-- match — the joker still rescues the run, but the blind counts as a failed
-- blind (failRound is sent and a life is deducted).
local _orig_card_eval_status_text = card_eval_status_text
card_eval_status_text = function(card, t, mult, x_mult, chips, vars)
    if WAR.GAME.active and vars then
        local center = card and card.config and card.config.center
        if center and center.key == "j_mr_bones" then
            vars = { message = localize("war_life_lost"), colour = G.C.RED }
        end
    end
    return _orig_card_eval_status_text(card, t, mult, x_mult, chips, vars)
end

local _orig_update_new_round = Game.update_new_round
function Game:update_new_round(dt)
    if WAR.GAME.active and not WAR.GAME.pvp_round()
       and not WAR.GAME._hand_state_sent then
        WAR.GAME._hand_state_sent = true
        WAR.GAME.send_hand_state()
        -- Secondary check: if _blind_chips_target is still set here, end_round
        -- hasn't cleared it yet (Mr. Bones path arrives in NEW_ROUND before
        -- end_round fires). Send failRound now; end_round's check is a no-op
        -- once the target is cleared.
        if WAR.GAME._blind_chips_target then
            local chips  = WAR.GAME.my_chips()
            local target = WAR.GAME._blind_chips_target
            WAR.GAME._blind_chips_target = nil
            if chips < target then
                WAR.NET.send({ action = "failRound" })
                if not mr_bones_would_save(chips, target) then
                    WAR.GAME.force_pass()
                end
                WAR.GAME.non_pvp_failed = true
            end
        end
    end
    if WAR.GAME.active then
        local saved = G.GAME and G.GAME.win_ante
        if saved then G.GAME.win_ante = 999 end
        _orig_update_new_round(self, dt)
        if saved then G.GAME.win_ante = saved end
    else
        _orig_update_new_round(self, dt)
    end
end

-- end_round can be reached twice in the same blind (a boss defeat plus a state
-- re-entry). Only the first call per round should run.
-- Non-pvp failure is detected here using the saved _blind_chips_target, which
-- is set once per blind in update_selecting_hand and cleared by new_round.
-- We do NOT check hands_left: by the time end_round fires from the NEW_ROUND
-- state (the Mr. Bones "passed" path), current_round.hands_left has already
-- been reset to the new round's starting value, so < 1 would be false.
-- Using the saved target alone is sufficient — a passed blind has chips >= target
-- and the check never fires, regardless of hands remaining.
local _orig_end_round = end_round
end_round = function(...)
    if WAR.GAME.active then
        if WAR.GAME.round_ended then return end
        WAR.GAME.round_ended = true
        -- Only check when we have a saved target (set at first SELECTING_HAND,
        -- cleared when this fires or when new_round runs for the next blind).
        if not WAR.GAME.pvp_round() and WAR.GAME._blind_chips_target then
            local chips  = WAR.GAME.my_chips()
            local target = WAR.GAME._blind_chips_target
            WAR.GAME._blind_chips_target = nil
            if chips < target then
                WAR.NET.send({ action = "failRound" })
                -- If Mr. Bones would fire (threshold met + joker present), it
                -- handles the round transition itself; skip force_pass so we
                -- don't double-defeat.  failRound + life deduction still apply.
                if not mr_bones_would_save(chips, target) then
                    WAR.GAME.force_pass()
                end
                WAR.GAME.non_pvp_failed = true
            end
        end
    end
    return _orig_end_round(...)
end

-- Cash-out: on a rival round the "score at least" figure is the opponent's
-- final score, not the boss's own requirement.
-- When the player lost and comeback_gold is on, a bonus row is added here.
-- _comeback_pending tracks dollars owed so the bottom row (which sets
-- G.GAME.current_round.dollars) includes the comeback in the Cash Out total.
local _comeback_pending = 0
local _orig_add_round_eval_row = add_round_eval_row
add_round_eval_row = function(config)
    if config and config.name == "blind1" and WAR.GAME.active and WAR.GAME.pvp_round()
       and G.GAME and G.GAME.blind then
        local prev = G.GAME.blind.chip_text
        G.GAME.blind.chip_text = WAR.SCORE.format(WAR.GAME.enemy_score or 0)
        local ok, err = pcall(_orig_add_round_eval_row, config)
        G.GAME.blind.chip_text = prev
        if not ok then error(err) end
        -- Comeback gold: awarded when we lost and the option is enabled.
        -- The $5 is included in the bottom row's total so cash_out awards it.
        if WAR.GAME.pvp_lost and WAR.LOBBY.config.comeback_gold ~= false then
            _comeback_pending = _comeback_pending + 5
            _orig_add_round_eval_row({
                bonus   = true,
                name    = "war_comeback",
                pitch   = (config.pitch or 0.9) + 0.06,
                dollars = 5,
            })
        end
        return
    end
    -- Non-pvp blind failure comeback: awarded when the chip target wasn't met
    -- (even if Mr. Bones saved the run) and comeback_gold is enabled.
    if config and config.name == "blind1" and WAR.GAME.active and not WAR.GAME.pvp_round()
       and WAR.GAME.non_pvp_failed and WAR.LOBBY.config.comeback_gold ~= false then
        WAR.GAME.non_pvp_failed = false
        _orig_add_round_eval_row(config)
        _comeback_pending = _comeback_pending + 5
        _orig_add_round_eval_row({
            bonus   = true,
            name    = "war_comeback",
            pitch   = (config.pitch or 0.9) + 0.06,
            dollars = 5,
        })
        return
    end
    -- Bottom row: inject any pending comeback gold into the Cash Out total.
    -- This is what sets G.GAME.current_round.dollars, which cash_out uses.
    if config and config.name == "bottom" and _comeback_pending > 0 then
        local extra = _comeback_pending
        _comeback_pending = 0
        return _orig_add_round_eval_row({
            name    = "bottom",
            dollars = (config.dollars or 0) + extra,
        })
    end
    return _orig_add_round_eval_row(config)
end
-- The boss blind itself is untouched: a rival round is a real vanilla boss with
-- the rival layered on top. Only the target and the HUD change.

local _orig_set_blind = Blind.set_blind
function Blind:set_blind(blind, reset, silent)
    _orig_set_blind(self, blind, reset, silent)
    -- reset/nil calls clear the blind (Amulet and friends use set_blind(nil, true));
    -- they must not pin a target or leave a badge behind.
    if reset or not blind then return end
    if WAR.GAME.active and WAR.is_rival_blind(blind) then
        -- The boss keeps its real chip target; the race is the win condition and
        -- end_round's game-over branch is suppressed while a rival round is live
        -- (see lovely/war.toml), so nothing here has to fake a number.
        WAR.UI.update_blind_hud()
        local chip = self.children and self.children.animatedSprite
        if chip then WAR.UI.attach_rival_icon(chip, "blind") end
    else
        if self.children and self.children.animatedSprite and WAR.UI.clear_rival_icon then
            WAR.UI.clear_rival_icon(self.children.animatedSprite)
        end
    end
end

local _orig_blind_defeat = Blind.defeat
function Blind:defeat(silent)
    _orig_blind_defeat(self, silent)
    if WAR.GAME.active then
        if WAR.UI.clear_rival_icon and self.children and self.children.animatedSprite then
            WAR.UI.clear_rival_icon(self.children.animatedSprite)
        end
        if WAR.UI.reset_blind_hud then WAR.UI.reset_blind_hud() end
    end
end

-- The barrier fires on the boss blind of a rival ante, whatever boss vanilla
-- rolled — the boss itself stays in place.

local _orig_select_blind = G.FUNCS.select_blind
G.FUNCS.select_blind = function(e)
    if WAR.GAME.active and not WAR.GAME._blind_starting then
        local blind  = e and e.config and e.config.ref_table
        if blind and WAR.is_rival_blind(blind) then
            WAR.GAME._pending_blind_e = e
            WAR.NET.send({ action = "readyBlind", skips = (G.GAME and G.GAME.skips) or 0 })
            WAR.UI.show_waiting(localize('war_pvp_waiting'))
            return
        end
    end
    _orig_select_blind(e)
    if WAR.GAME.active then
        -- Check joker slots at the blind entry point (shop just ended).
        if WAR.GAME.missing_joker_valid and G.jokers then
            local lim = G.jokers.config and G.jokers.config.card_limit or 5
            if #G.jokers.cards >= lim then WAR.GAME.missing_joker_valid = false end
        end
        WAR.NET.send({ action = "setLocation", location = "Blind" })
    end
end

local _orig_ease_ante = ease_ante
ease_ante = function(amt, ...)
    local result = _orig_ease_ante(amt, ...)
    if WAR.GAME.active and G.GAME and G.GAME.round_resets then
        WAR.NET.send({
            action = "setAnte",
            ante   = G.GAME.round_resets.ante,
        })
    end
    return result
end

-- new_round() is a global function (functions/state_events.lua), not a
-- G.FUNCS entry — hooking G.FUNCS.new_round never fired, so the relay never
-- cleared its per-round lives blocker and only the first failed round could
-- ever cost a life.

local _orig_new_round_fn = new_round
new_round = function(...)
    if WAR.GAME.active then
        WAR.NET.send({ action = "newRound" })
        WAR.GAME.round_ended = false
        WAR.GAME._blind_chips_target = nil
        WAR.GAME.non_pvp_failed      = false
    end
    return _orig_new_round_fn(...)
end

local _orig_go_shop = G.FUNCS.to_shop
if _orig_go_shop then
    G.FUNCS.to_shop = function(e)
        if WAR.GAME.active then
            WAR.NET.send({ action = "setLocation", location = "Shop" })
        end
        return _orig_go_shop(e)
    end
end

-- Holding R restarts the run. In a match that would desync or dodge a loss, so
-- swallow the hold while a lobby or run is live.
local _orig_key_hold_update = Controller.key_hold_update
function Controller:key_hold_update(key, dt)
    if key == "r" and (WAR.GAME.active or WAR.LOBBY.code) then
        self.held_key_times[key] = nil
        return
    end
    return _orig_key_hold_update(self, key, dt)
end

-- Some Steamodded builds still call save_run while saving is disabled; in a
-- multiplayer run that crashes on transient hand data.
local _orig_save_run = save_run
save_run = function(...)
    if G and G.F_NO_SAVING then return end
    return _orig_save_run(...)
end

-- Sends cumulative per-game counts to the relay at game end (win or lose).
-- One line per key in WAR.ACH_COUNTERS; the relay owns the targets.
function WAR.GAME.send_end_increments()
    for _, key in ipairs(WAR.ACH_COUNTERS) do
        local n = WAR.GAME.ach[key]
        if n and n > 0 then WAR.NET.increment_achievement(key, n) end
    end
    -- One increment per match for the stake the player ran on.
    local STAKE_KEYS = {
        [1]="white_stake",  [2]="red_stake",    [3]="green_stake", [4]="black_stake",
        [5]="blue_stake",   [6]="purple_stake",  [7]="orange_stake",[8]="gold_stake",
    }
    local sk = WAR.GAME.match_stake and STAKE_KEYS[WAR.GAME.match_stake]
    if sk then WAR.NET.increment_achievement(sk, 1) end
    -- One increment per match for the deck the player ran on.
    local DECK_KEYS = {
        ["Red Deck"]     = "red_deck",    ["Blue Deck"]    = "blue_deck",
        ["Yellow Deck"]  = "yellow_deck", ["Green Deck"]   = "green_deck",
        ["Black Deck"]   = "black_deck",  ["Ghost Deck"]   = "ghost_deck",
        ["Painted Deck"] = "painted_deck",["Plasma Deck"]  = "plasma_deck",
        ["Anaglyph Deck"]= "anaglyph_deck",
    }
    local dk = WAR.GAME.match_deck and DECK_KEYS[WAR.GAME.match_deck]
    if dk then WAR.NET.increment_achievement(dk, 1) end
end

-- General WAR Mod Calculate - Typically used for achievement unlocks
WAR.calculate = function(self, context)
    -- WAR.RULESETS["xmas"]["calculate"](self, context) was using for testing
    if WAR.GAME.active then

        local gm, rs = WAR.LOBBY.config.gamemode, WAR.LOBBY.config.ruleset
        if WAR.GAMEMODES[gm] and WAR.GAMEMODES[gm]["calculate"] then
            WAR.GAMEMODES[gm]["calculate"](self, context)
        end
        if WAR.RULESETS[rs] and WAR.RULESETS[rs]["calculate"] then
            WAR.RULESETS[rs]["calculate"](self, context)
        end

        if context.joker_type_destroyed then
            -- GaryGPT unlock condition
           if context.card.config.center_key == 'j_splash' then
                check_for_unlock({type = 'war_garygpt'})
           end
        end

        if context.selling_card then
            -- Egg unlock condition
            if context.card.config.center_key == 'j_egg' and context.card.sell_cost >= 15 then
                check_for_unlock({type = 'war_egg'})
            end
        end

        if context.using_consumeable then
            -- OneShot unlock condition (cumulative)
            if context.consumeable.config.center_key == 'c_sun' then
                WAR.GAME.count('oneshot')
            end
            -- Black Hole unlock condition
            if context.consumeable.config.center_key == 'c_black_hole' then
                check_for_unlock({ type = 'war_black_hole' })
            end
        end

        if context.tag_added then
            -- Cola unlock condition
            if #G.GAME.tags >= 5 then
                check_for_unlock({type = 'war_cola'})
            end
        end
        
        if context.pseudorandom_result then
            -- Oops: probability rolls from mod jokers (vanilla rolls are caught
            -- by the pseudorandom wrapper above).
            if context.result then WAR.GAME.prob_hit() end
        end

        if context.discard and context.other_card then
            -- Hit the Road: 50 discarded Jacks in a single match.
            if context.other_card.base and context.other_card.base.value == 'Jack' then
                WAR.GAME.jacks_discarded = (WAR.GAME.jacks_discarded or 0) + 1
                if WAR.GAME.jacks_discarded >= 50 then
                    check_for_unlock({ type = 'war_hit_the_road' })
                end
            end
        end

        if context.evaluate_poker_hand then
            -- Supernova: one hand type 25 times in a single match. The same context
            -- also runs to preview the hand while cards are being picked, so only
            -- count it once the played cards have moved into G.play.
            local hand = context.scoring_name
            if hand and G.play and G.play.cards and #G.play.cards > 0 then
                WAR.GAME.hand_counts = WAR.GAME.hand_counts or {}
                local n = (WAR.GAME.hand_counts[hand] or 0) + 1
                WAR.GAME.hand_counts[hand] = n
                if n >= 25 then check_for_unlock({ type = 'war_supernova' }) end
            end

            -- Windows 7: 4OAK of 7s, all four suits present.
            if not WAR.AVATAR.is_entitled('windows_7')
               and context.scoring_name == 'Four of a Kind'
               and G.play and G.play.cards then
                local suits, seven_count = {}, 0
                for _, card in ipairs(G.play.cards) do
                    if card.base and card.base.value == '7' then
                        seven_count = seven_count + 1
                        local s = card.base.suit
                        if s and s ~= 'Wild' then suits[s] = true end
                    end
                end
                local suit_count = 0
                for _ in pairs(suits) do suit_count = suit_count + 1 end
                if seven_count >= 4 and suit_count >= 4 then
                    check_for_unlock({ type = 'war_four_sevens' })
                end
            end

            -- Jolly: every played hand has to contain a pair. Droll: every played
            -- hand has to be a five-card flush. Both read the played cards here
            -- because this is the only context that still has them in G.play.
            local played = G.play and G.play.cards
            if played and #played > 0 then
                local ranks, has_pair = {}, false
                for _, card in ipairs(played) do
                    local r = card.base and card.base.value
                    if r then
                        ranks[r] = (ranks[r] or 0) + 1
                        if ranks[r] >= 2 then has_pair = true end
                    end
                end
                if not has_pair then WAR.GAME.jolly_valid = false end

                local suit, is_flush = nil, (#played == 5)
                if is_flush then
                    for _, card in ipairs(played) do
                        local s = card.base and card.base.suit
                        if s and s ~= "Wild" then
                            if not suit then suit = s
                            elseif s ~= suit then is_flush = false end
                        end
                    end
                end
                if not is_flush then WAR.GAME.droll_valid = false end
            end

            -- Eyes: Photograph and Hanging Chad held at the same time.
            if not WAR.AVATAR.is_entitled('eyes') and G.jokers and G.jokers.cards then
                local photo, chad = false, false
                for _, jkr in ipairs(G.jokers.cards) do
                    local key = (jkr.config.center and jkr.config.center.key) or jkr.config.center_key
                    if key == 'j_photograph' then photo = true end
                    if key == 'j_hanging_chad' then chad = true end
                end
                if photo and chad then check_for_unlock({ type = 'war_eyes' }) end
            end
        end

        if context.individual and context.cardarea == G.play then
            -- Lucky unlock condition
            if context.other_card.lucky_trigger and not context.other_card.repetition_trigger then
                WAR.GAME.count('lucky')
            end

            -- Hack: a rank 2-5 card retriggered, 20 times in a single match.
            local hack_rank = context.other_card.base and context.other_card.base.value
            if context.other_card.repetition_trigger
               and (hack_rank == '2' or hack_rank == '3' or hack_rank == '4' or hack_rank == '5') then
                WAR.GAME.hack_hits = (WAR.GAME.hack_hits or 0) + 1
                if WAR.GAME.hack_hits >= 20 then
                    check_for_unlock({ type = 'war_hack' })
                end
            end

            -- Bloodstone unlock condition
            if context.other_card.base and context.other_card.base.suit == 'Hearts' and not SMODS.has_no_suit(context.other_card) then
                WAR.GAME.count('bloodstone')
            end

            -- Wild unlock condition
            if SMODS.has_enhancement(context.other_card, 'm_wild') then
                WAR.GAME.count('wild')
            end

            -- Mult unlock condition
            if SMODS.has_enhancement(context.other_card, 'm_mult') then
                WAR.GAME.count('mult')
            end

            -- Stone & Osage unlock condition
            -- Stone feeds both: osage counts to 1000, stone to 100.
            if SMODS.has_enhancement(context.other_card, 'm_stone') then
                WAR.GAME.count('stone')
                WAR.GAME.count('osage')
            end

            if context.other_card.seal == 'Gold' then
                WAR.GAME.count('gold_seal')
                WAR.GAME.count('ultrakill_v1')
            end

            -- Pizza: red or gold seal cards, counted once per card per hand.
            if (context.other_card.seal == 'Red' or context.other_card.seal == 'Gold')
               and not context.other_card.repetition_trigger then
                WAR.GAME.count('pizza')
            end
        end

        if context.individual and context.cardarea == G.hand then
            if context.end_of_round then
                -- Gold unlock condition
                if SMODS.has_enhancement(context.other_card, 'm_gold') then
                    WAR.GAME.count('gold')
                end
            else
                -- Steel unlock condition
                if SMODS.has_enhancement(context.other_card, 'm_steel') then
                    WAR.GAME.count('steel')
                end
            end
        end
    end
end

-- Show banned keys as debuffed in the collection when a run with bans is active.
function WAR.key_banned(key)
    if not (WAR.GAME and WAR.GAME.active) then return false end
    if not (key and G.GAME and G.GAME.banned_keys) then return false end
    return G.GAME.banned_keys[key] and true or false
end

-- INIT_COLLECTION_CARD_ALERTS runs after every page flip in all five card
-- collection tabs, so one hook here covers jokers, tarots, planets, spectrals,
-- boosters and vouchers without duplicating logic per tab.
local _orig_init_collection_alerts = INIT_COLLECTION_CARD_ALERTS
function INIT_COLLECTION_CARD_ALERTS()
    _orig_init_collection_alerts()
    if not G.your_collection then return end
    for j = 1, #G.your_collection do
        for _, card in ipairs(G.your_collection[j].cards) do
            if card.config and card.config.center
               and WAR.key_banned(card.config.center.key) then
                card:set_debuff(true)
            end
        end
    end
end

-- Tags never reach that hook. The tag collection builds Tag objects whose art
-- is a bare Sprite: nothing lands in G.your_collection and there is no
-- set_debuff to call. Card:draw paints the debuff shader over its own finished
-- center sprite, so do the same here, after the sprite's draw_steps.
function WAR.debuff_sprite(sprite)
    if not sprite or sprite.war_debuffed then return end
    sprite.war_debuffed = true

    local _orig_draw = sprite.draw
    sprite.draw = function(self, overlay)
        _orig_draw(self, overlay)
        if not self.states.visible then return end
        self.ARGS.send_to_shader = self.ARGS.send_to_shader or {}
        self.ARGS.send_to_shader[1] = math.min(self.VT.r*3, 1) + G.TIMERS.REAL/28
            + (self.juice and self.juice.r*20 or 0)
        self.ARGS.send_to_shader[2] = G.TIMERS.REAL
        self:draw_shader('debuff', nil, self.ARGS.send_to_shader)
    end
end

if Tag and Tag.generate_UI then
    local _orig_tag_generate_UI = Tag.generate_UI
    function Tag:generate_UI(_size)
        local node, sprite = _orig_tag_generate_UI(self, _size)
        if WAR.key_banned(self.key) then WAR.debuff_sprite(sprite) end
        return node, sprite
    end
end

WAR.log("[WAR] game_hooks loaded")
