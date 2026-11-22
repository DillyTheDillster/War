-- ui/challenges.lua
-- Challenge screen tweaks only. Staking and deck choice for challenges are NOT
-- handled here for now — that path is parked until we pick it up again, so this
-- file must never open the run setup, queue run args, or start a run by itself.
--
-- What it does:
--   * renames the challenge PLAY button to SELECT and starts the run with a seed
--     typed in the box beside it (WAR.CHALLENGE.run_args)
--   * builds the challenge list in the same frame the screen opens, instead of
--     letting vanilla fill it from G.E_MANAGER a frame or more later

WAR.CHALLENGE = WAR.CHALLENGE or {}
local C = WAR.CHALLENGE
C.seed = C.seed or {}   -- id -> typed seed ("" = random)

local function run_args(id)
    local challenge = WAR.challenge_by_id(id)
    if not challenge then return nil end
    local seed = C.seed[id]
    if seed == '' then seed = nil end
    return { stake = 1, seed = seed, challenge = challenge }
end
WAR.CHALLENGE.run_args = run_args

--------------------------------------------------------------------------------
-- Challenge description: seed box beside SELECT
--------------------------------------------------------------------------------
local orig_challenge_description = G.UIDEF.challenge_description
G.UIDEF.challenge_description = function(_id, daily, is_row)
    if not orig_challenge_description then return nil end
    local t = orig_challenge_description(_id, daily, is_row)
    if daily or is_row or not _id then return t end
    if not (t and t.nodes) then return t end
    C.seed[_id] = C.seed[_id] or ''

    -- play_row (G.UIT.R, align="cm") lays its children horizontally; narrow the
    -- button and prepend a seed column so the pair sits left, inside the panel.
    local play_row = t.nodes[3]
    local btn_node = play_row and play_row.nodes and play_row.nodes[1]
    if btn_node then
        for _, child in ipairs(btn_node.nodes or {}) do
            if child.config and child.config.text then
                child.config.text = localize('war_select_cap')
            end
        end
        btn_node.config.button = 'war_challenge_open_run_setup'
        btn_node.config.minw   = 5.0

        -- Vanilla seed box shape: create_text_input already returns its own
        -- centred column (defaults w 2.5, h 0.7 — same height as the button), so
        -- it sits level with SELECT on the row. No label: same as the regular box.
        local seed_box = create_text_input({
            id          = 'war_ch_seed',
            max_length  = 8,
            all_caps    = true,
            ref_table   = C.seed,
            ref_value   = _id,
            prompt_text = localize('k_enter_seed'),
        })
        play_row.config.align = 'cl'   -- vertical centre, left-anchored
        play_row.nodes = { seed_box, btn_node }
    end

    return t
end

-- SELECT: start straight away with the seed field's value.
-- Lobby deck-select routes through start_challenge_run so lobby.lua's hooks fire.
G.FUNCS.war_challenge_open_run_setup = function(e)
    local id = e and e.config and e.config.id
    if not id then return end
    if WAR._deck_selecting then
        -- Pass the real challenge index: lobby.lua resolves it as
        -- G.CHALLENGES[config.id], and anything else falls through to vanilla's
        -- plain-run start.
        G.FUNCS.start_challenge_run{ config = { id = id } }
        return
    end
    local args = (WAR.CHALLENGE.run_args and WAR.CHALLENGE.run_args(id))
        or { stake = 1, challenge = WAR.challenge_by_id(id) }
    if not args.challenge then return end
    if G.OVERLAY_MENU then G.FUNCS.exit_overlay_menu() end
    G.FUNCS.start_run(e, args)
end

--------------------------------------------------------------------------------
-- Challenge list: build it in the same frame the screen opens.
-- Vanilla queues the population through G.E_MANAGER (UI_definitions.lua:6047),
-- so the list area sits empty for at least one frame after the overlay appears
-- — that reads as a pause. UIBox:new builds its whole child tree synchronously,
-- so right after overlay_menu returns we can populate it inline instead.
--------------------------------------------------------------------------------
-- create_UIBox_generic_options gives the Back button the same 'challenge_list'
-- id (via back_id), so get_UIE_by_ID can hand back the wrong node. Walk the tree
-- for the G.UIT.O container that actually holds the list object.
local function war_find_challenge_list_node(node)
    node = node or (G.OVERLAY_MENU and G.OVERLAY_MENU.UIRoot)
    if not node then return nil end
    if node.UIT == G.UIT.O and node.config and node.config.id == 'challenge_list' then
        return node
    end
    for _, child in ipairs(node.children or {}) do
        local found = war_find_challenge_list_node(child)
        if found then return found end
    end
    return nil
end

local _orig_list_page = G.FUNCS.change_challenge_list_page
G.FUNCS.change_challenge_list_page = function(args)
    if not (args and args.cycle_config) then
        if _orig_list_page then return _orig_list_page(args) end
        return
    end
    local page = (tonumber(args.cycle_config.current_option) or 1) - 1
    local ch_list = war_find_challenge_list_node()
    -- Swallow vanilla's deferred duplicate for the page we already built.
    if ch_list and ch_list.config.war_page == page
        and ch_list.config.war_page_at and (G.TIMERS.REAL - ch_list.config.war_page_at) < 0.25 then
        return
    end
    if _orig_list_page then _orig_list_page(args) end
    if ch_list and ch_list.config then
        ch_list.config.war_page    = page
        ch_list.config.war_page_at = G.TIMERS.REAL
    end
end

local _orig_challenge_list = G.FUNCS.challenge_list
G.FUNCS.challenge_list = function(e)
    if not _orig_challenge_list then return end
    _orig_challenge_list(e)
    local ch_list = war_find_challenge_list_node()
    -- config.object is a plain Moveable until the deferred event replaces it.
    if ch_list and not (ch_list.config.object and ch_list.config.object.get_UIE_by_ID) then
        G.FUNCS.change_challenge_list_page{ cycle_config = { current_option = 1 } }
    end
end

WAR.log("[WAR] ui/challenges.lua loaded")
