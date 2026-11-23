-- War.lua
-- Copyright (C) 2026 Amolyte
-- Licensed under the GNU General Public License v3.0 — see LICENSE.

WAR = SMODS.current_mod
WAR.ROOT = WAR.path

-- TODO: add code for instant game crash if you're soulware

-- Set to 0 to silence verbose in-game logging (scoring, auth, network events).
-- Error and warning prints are always shown regardless.
WAR.console_log = 0

-- Set to 1 to connect to the beta relay (port 7778) instead of the live server.
WAR.beta_test = 1

function WAR.log(...)
    if WAR.console_log == 1 then print(...) end
end

function WAR.load(path)
    return SMODS.load_file(path)()
end

function WAR.load_dir(dir, skip)
    local init = dir .. "/_init.lua"
    local ok = SMODS.load_file(init)
    if ok then ok() end
    for _, f in ipairs(NFS.getDirectoryItems(WAR.ROOT .. dir)) do
        if f:match("%.lua$") and f ~= "_init.lua" and not (skip and skip[f]) then
            SMODS.load_file(dir .. "/" .. f)()
        end
    end
end

WAR.load("core/globals.lua")
WAR.load("core/net.lua")
WAR.load("core/lobby.lua")
WAR.load("core/auth.lua")
WAR.load("core/avatar.lua")
WAR.load("core/spectator.lua")
WAR.load("core/sync.lua")
WAR.load("core/game_hooks.lua")

-- One line per boot so logs can be matched to a build.
WAR.log(string.format("[WAR] v%s loaded", WAR.mod_version()))

-- Load saved pfp choice once all modules are initialised.
if WAR.AVATAR then WAR.AVATAR.load_choice() end

WAR.load_dir("objects/blinds")
WAR.load_dir("gamemodes")
WAR.load_dir("rulesets")

-- Custom cues. SMODS resolves `path` under the mod's assets/sounds/, and this
-- Steamodded version does not scan that folder by itself, so each file is
-- registered explicitly under the code the mod plays.
SMODS.Sound { key = "war_timer",    path = "war_timer.ogg",    pitch = 1, volume = 1 }
SMODS.Sound { key = "war_opp_lost", path = "war_opp_lost.ogg", pitch = 1, volume = 1 }

-- UI: explicit order (lobby last; it references symbols from earlier files)
WAR.load("ui/_init.lua")
WAR.load("ui/utils.lua")
WAR.load("ui/home.lua")
WAR.load("ui/account.lua")
WAR.load("ui/config.lua")
WAR.load("ui/screens.lua")
WAR.load("ui/icon_select.lua")
WAR.load("ui/hud.lua")
WAR.load("ui/popups.lua")
WAR.load("ui/challenges.lua")
WAR.load("ui/lobby.lua")

-- TEMPORARY
-- WAR.load("ui/temp/avatar.lua") -- merged into ui/icon_select.lua
WAR.load("ui/temp/account.lua") -- Still working on account pages, then will move to ui/account.lua
-- WAR.load("ui/temp/config.lua") -- moved to ui/config.lua (permanent change)
-- WAR.load("ui/temp/icon_select.lua")

-- Compat modules that are kept on disk but not loaded. Add a filename to mute
-- it for a test run; remove the line to load it again.
WAR.COMPAT_SKIP = {
}

WAR.load_dir("compat", WAR.COMPAT_SKIP)
