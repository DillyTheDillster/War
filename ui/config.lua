SMODS.Mods["War"].config_tab = function()
    -- Rebuilding the config tab;

    -- Request a fresh stats fetch whenever the tab is opened.
    if WAR.AUTH.state == "logged_in" and WAR.NET.connected() then
        WAR.NET.send({ action = "stats", username = WAR.AUTH.user })
    end

    -- Container for all UI on this page;
    -- Additions to this will be created separately to improve readability
    local ui_definition = {
        n = G.UIT.ROOT,
        config = { r = 0.1, minw = 10, minh = 6, align = "cm", padding = 0.1, colour = G.C.CLEAR },
    };

    ---- Account related config setup
    local accounts = {
        n = G.UIT.C,
        config = { r = 0.1, minw = 3.2, minh = 5.6, align = "cm", padding = 0.1, colour = G.C.CLEAR },
    }

    -- This section holds the player's name, icon & eventually a win/loss ratio and potentially ELO
    local profile = {
        n = G.UIT.R,
        config = { r = 0.1, minh = 4.2, align = "cm", padding = 0.1, colour = G.C.BLACK },
        nodes = {}
    }

    -- Preparing wins/losses boxes for the next section
    -- G.C.L_BLACK is the fucking bg color
    local wins = {
        n = G.UIT.C, config = { r = 0.1, minw = 1.2, minh = 1.4, align = "cm", padding = 0, colour = G.C.CLEAR }, nodes = {
            {
                n = G.UIT.R,
                config = { r = 0.1, minw = 1.1, minh = 0.4, padding = 0.1, colour = G.C.CLEAR, align = "cm" },
                nodes = {
                    { 
                        n = G.UIT.T, 
                        config = { 
                            text   = localize("war_wins"), 
                            scale  = 0.3,
                            colour = G.C.CHIPS, 
                            shadow = true 
                        }
                    }
                }
            },
            {
                n = G.UIT.R,
                config = { r = 0.1, minw = 1.1, minh = 0.75, padding = 0.2, colour = G.C.L_BLACK, align = "cm" },
                nodes = {
                    {
                        n = G.UIT.T,
                        config = { ref_table = WAR.AUTH.stats, ref_value = "wins", scale = 0.5, colour = G.C.CHIPS, shadow = true }
                    }
                }
            }
        }
    }

    local losses = {
        n = G.UIT.C, config = { r = 0.1, minw = 1.2, minh = 1.4, align = "cm", padding = 0, colour = G.C.CLEAR }, nodes = {
            {
                n = G.UIT.R,
                config = { r = 0.1, minw = 1.1, minh = 0.4, padding = 0.1, colour = G.C.CLEAR, align = "cm" },
                nodes = {
                    { 
                        n = G.UIT.T, 
                        config = { 
                            text   = localize("war_losses"), 
                            scale  = 0.3,
                            colour = G.C.MULT, 
                            shadow = true 
                        }
                    }
                }
            },
            {
                n = G.UIT.R,
                config = { r = 0.1, minw = 1.1, minh = 0.75, padding = 0.2, colour = G.C.L_BLACK, align = "cm" },
                nodes = {
                    {
                        n = G.UIT.T,
                        config = { ref_table = WAR.AUTH.stats, ref_value = "losses", scale = 0.5, colour = G.C.MULT, shadow = true }
                    }
                }
            }
        }
    }

    local winrate = {
        n = G.UIT.C, config = { r = 0.1, minw = 1.2, minh = 1.4, align = "cm", padding = 0, colour = G.C.CLEAR }, nodes = {
            {
                n = G.UIT.R,
                config = { r = 0.1, minw = 1.1, minh = 0.4, padding = 0.1, colour = G.C.CLEAR, align = "cm" },
                nodes = {
                    { 
                        n = G.UIT.T, 
                        config = { 
                            text   = localize("war_win_percent"), 
                            scale  = 0.3,
                            colour = G.C.PURPLE, 
                            shadow = true 
                        }
                    }
                }
            },
            {
                n = G.UIT.R,
                config = { r = 0.1, minw = 1.1, minh = 0.75, padding = 0.2, colour = G.C.L_BLACK, align = "cm" },
                nodes = {
                    {
                        n = G.UIT.T,
                        config = { ref_table = WAR.AUTH.stats, ref_value = "win_percent", scale = 0.5, colour = G.C.PURPLE, shadow = true }
                    }
                }
            }
        }
    }

    -- This holds the player's name and their icon
    local profile_info = {
        n = G.UIT.C,
        config = { r = 0.1, minh = 4.2, align = "cm", colour = G.C.CLEAR },
        nodes = {
            {
                n = G.UIT.R, config = { minw = 2.8, minh = 0.4, align = "cm", padding = 0.05, colour = G.C.CLEAR },
                nodes = {
                    { 
                        n = G.UIT.T, 
                        config = { 
                            text   = (WAR.AUTH.state == "logged_in") and localize('war_signed_in_as') or localize('war_not_logged_in'), 
                            scale  = 0.3,
                            colour = G.C.UI.TEXT_INACTIVE, 
                            shadow = true 
                        }
                    }
                }
            },
            {
                n = G.UIT.R, config = { minw = 2.8, minh = 0.4, align = "cm", padding = 0.05, colour = G.C.CLEAR },
                nodes = {
                    { 
                        n = G.UIT.T, 
                        config = { 
                            text   = (WAR.AUTH.state == "logged_in") and WAR.AUTH.user or localize('war_guest_display_name'), 
                            scale  = 0.5,
                            colour = G.C.GOLD, 
                            shadow = true 
                        }
                    }
                }
            },
            {
                n = G.UIT.R, config = { minw = 2.8, minh = 1.2, align = "cm", padding = 0.05, colour = G.C.CLEAR },
                nodes = { 
                    {
                        n = G.UIT.O,
                        config = { object = WAR.UI.create_dummy_avatar(nil, true) }
                    }
                }
            },
            {
                n = G.UIT.R, config = { minw = 2.8, minh = 1.4, align = "cm", padding = 0.1, colour = G.C.CLEAR },
                nodes = { 
                    wins, winrate, losses
                }
            }
        }
    }

    profile.nodes = { profile_info };

    -- This section just holds the manage account button
    local manage_accounts = {
        n = G.UIT.R,
        config = { r = 0.1, minh = 1.2, align = "cm", padding = 0.1, colour = G.C.CLEAR },
        nodes = {
            UIBox_button({ label={localize('war_manage_account')}, button="war_open_account",
                colour=G.C.BLUE, minw=2.4 })
        }
    }

    accounts.nodes = { profile, manage_accounts }

    -- Regular config, right-hand column. Everything here is stored in
    -- config/War.jkr for this client only — nothing is pushed to the relay, so
    -- each player keeps their own copy.
    local _config = {
        n = G.UIT.C,
        config = { r = 0.1, minw = 6.6, minh = 5.6, align = "cm", padding = 0.1, colour = G.C.BLACK },
        nodes = {}
    }

    -- Timer Auto Start: on (default) the opponent's clock starts counting the
    -- second we ready up; off opens it paused at full time and leaves it to us
    -- to release from the HUD.
    if WAR.config and WAR.config.timer_auto_start == nil then
        WAR.config.timer_auto_start = true
    end
    local timer_setting = create_toggle {
        label     = localize('war_cfg_timer_auto'),
        ref_table = WAR.config or {},
        ref_value = 'timer_auto_start',
        callback  = function()
            -- Saved on the click, not on closing the menu, so a crash mid-run
            -- can't lose the choice.
            if SMODS and SMODS.save_mod_config then SMODS.save_mod_config(WAR) end
        end,
    }

    _config.nodes = { timer_setting }

    ui_definition.nodes = { accounts, _config }
    return ui_definition

    -- return {
    --     n = G.UIT.ROOT,
    --     config = { r=0.1, minw=6, align="cm", padding=0.3, colour=G.C.BLACK },
    --     nodes = {
    --         { n=G.UIT.R, config={ align="cm", padding=0.1 }, nodes={
    --             { n=G.UIT.T, config={ text=localize('war_account_label'), scale=0.4,
    --                 colour=G.C.UI.TEXT_LIGHT, shadow=true }},
    --             { n=G.UIT.T, config={
    --                 ref_table=WAR.AUTH, ref_value="user",
    --                 scale=0.4, colour=G.C.GREEN, shadow=true }},
    --         }},
    --         { n=G.UIT.R, config={ align="cm", minh=0.15 }, nodes={} },
    --         UIBox_button({ label={localize('war_manage_account')}, button="war_open_account",
    --             colour=G.C.BLUE, minw=5 }),
    --         { n=G.UIT.R, config={ align="cm", minh=0.15 }, nodes={} },
    --         UIBox_button({ label={localize('war_icon')}, button="war_open_icon_select",
    --             colour=G.C.GREEN, minw=5 }),
    --     },
    -- }
end

function WAR.UI.on_stats(m)
    local w = tonumber(m.wins)   or 0
    local p = tonumber(m.played) or 0
    local l = p - w
    WAR.AUTH.stats.wins        = tostring(w)
    WAR.AUTH.stats.losses      = tostring(l)
    WAR.AUTH.stats.win_percent = p > 0 and (math.floor(w / p * 100) .. "%") or "-%"
end