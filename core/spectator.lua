local S = {}
WAR.SPECTATOR = S
local ffi = require("ffi")
local panes, sdl = {}, nil
local linear_stretch
local watching, pending = false, false
local next_pull, deadline = 0, 0
local capture_until, next_frame, next_ack = 0, 0, 0
local newest, ack = {}, {}
local capture_targets, pack_shader = {}, nil
local main_window, filter_events, exit_requested
local main_hidden = false
local panes_by_id = {}
local lobby, lobby_preview, return_requested, claim_requested, switching
local slot_bounds = {}
local roster_code, roster_names, own_roster_row

function S.viewer_names(code)
    if code == roster_code then return roster_names or {} end
    return {}
end

local resolutions = {3840,3200,2560,1920,1600,1280,960,720,480}
local capture_width = 960
local retry_width_at = {}
local roles = {"host", "guest"}

local place_panes
local pane_serial = 0
if ffi.os == "Linux" then
    if os.getenv("HYPRLAND_INSTANCE_SIGNATURE") then
        local function shell_arg(value)
            return "'"..value:gsub("'", "'\\''").."'"
        end

        place_panes = function(layout)
            local args = {
                "unset LD_PRELOAD LD_LIBRARY_PATH; python3",
                shell_arg(WAR.ROOT .. "core/spectator_hyprland.py"),
                shell_arg(layout[1].output or "")
            }
            for _, pane in ipairs(layout) do
                args[#args+1] = shell_arg(pane.title)
            end
            os.execute(table.concat(args, " ").." </dev/null &")
        end
    elseif os.getenv("KDE_FULL_SESSION") == "true" or (os.getenv("XDG_CURRENT_DESKTOP") or ""):upper():find("KDE",1,true) then
        WAR.load("core/spectator_kwin.lua")
        place_panes = WAR.place_kwin_panes
    end
    if place_panes then ffi.cdef("int getpid(void);") end
end

local linux_gl = ffi.os == "Linux"
if linux_gl then WAR.load("core/spectator_gl.lua") end

local function backend()
    if sdl then return end
    ffi.cdef[[
        void* SDL_CreateWindow(const char*,int,int,int,int,unsigned int);
        void SDL_DestroyWindow(void*);
        void* SDL_GetWindowSurface(void*);
        void* SDL_CreateRGBSurfaceFrom(void*,int,int,int,int,unsigned int,unsigned int,unsigned int,unsigned int);
        int SDL_UpperBlitScaled(void*,const void*,void*,const void*);
        int SDL_UpdateWindowSurface(void*);
        void SDL_FreeSurface(void*);
        void* SDL_CreateRGBSurfaceWithFormat(unsigned int,int,int,int,unsigned int);
        int SDL_SoftStretchLinear(void*,const void*,void*,const void*);
        int SDL_UpperBlit(void*,const void*,void*,void*);
        int SDL_FillRect(void*,const void*,unsigned int);
        void SDL_GetClipRect(void*, int*);
        int SDL_GetWindowDisplayIndex(void*);
        const char* SDL_GetDisplayName(int);
        int SDL_GetDisplayBounds(int,int*);
        int SDL_GetDisplayUsableBounds(int,int*);
        void* SDL_GL_GetCurrentWindow(void);
        void* SDL_GL_GetCurrentContext(void);
        void* SDL_GL_CreateContext(void*);
        void SDL_GL_DeleteContext(void*);
        int SDL_GL_MakeCurrent(void*,void*);
        void* SDL_GL_GetProcAddress(const char*);
        void SDL_GL_GetDrawableSize(void*,int*,int*);
        int SDL_GL_SetSwapInterval(int);
        void SDL_GL_SwapWindow(void*);
        const char* SDL_GetError(void);
        void SDL_HideWindow(void*);
        void SDL_ShowWindow(void*);
        void SDL_RaiseWindow(void*);
        unsigned int SDL_GetWindowID(void*);
        void SDL_GetWindowSize(void*, int*, int*);
        void SDL_SetWindowMinimumSize(void*, int, int);
        void SDL_PumpEvents(void);
        typedef int (*WarPaneFilter)(void*, void*);
        void SDL_FilterEvents(WarPaneFilter, void*);
        void SDL_SetWindowTitle(void*,const char*);
    ]]
    if ffi.os == "Linux" then
        local ok, main = pcall(function() return ffi.C.SDL_GL_GetCurrentWindow() end)
        if ok and main ~= nil then sdl = ffi.C; return end
    end
    for _, name in ipairs({"SDL2","libSDL2-2.0.so.0","libSDL2-2.0.0.dylib"}) do
        local ok, lib = pcall(ffi.load, name)
        if ok and lib.SDL_GL_GetCurrentWindow() ~= nil then sdl = lib; break end
    end
    assert(sdl, "SDL2 unavailable")
end

-- Catch pane closes before LÖVE treats them as a quit.
local function install_controls()
    if filter_events then return end
    local function filter(_, event)
        -- Field offsets below come from the SDL2 window, keyboard and mouse event structs.
        -- https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL_events.h
        local fields = ffi.cast("const uint32_t*",event)
        local kind = fields[0]
        if kind ~= 0x200 and not (kind >= 0x300 and kind <= 0x305)
            and not (kind >= 0x400 and kind <= 0x403) then return 1 end
        local pane = panes_by_id[tonumber(fields[2])]
        if not pane then return 1 end
        local bytes = ffi.cast("const uint8_t*",event)
        if kind == 0x200 then
            local action = bytes[12]
            if action == 14 then exit_requested = true end -- SDL_WINDOWEVENT_CLOSE
            if action == 3 or action == 5 or action == 6 or action == 9 then
                pane.redraw = true -- exposed, resized, size changed or restored
            end
        elseif kind == 0x402 and bytes[16] == 1 and lobby and not lobby.playing and pane.frame_rect then
            local rect = pane.frame_rect
            -- Slot bounds are relative to the video inside the window.
            local x = (tonumber(fields[5]) * pane.w / pane.size[0] - rect[0]) / rect[2]
            local y = (tonumber(fields[6]) * pane.h / pane.size[1] - rect[1]) / rect[3]
            for slot,box in pairs(pane.slots or {}) do
                if x >= box[1] and x <= box[3] and y >= box[2] and y <= box[4] then
                    if slot == "spectators" then
                        return_requested = true
                    elseif slot == "guest" and lobby.seats.host and not lobby.seats.guest then
                        claim_requested = true
                    end
                end
            end
        elseif kind == 0x300 and fields[5] == 108 and lobby and not lobby.playing then
            return_requested = true -- L opens the lobby
        elseif kind == 0x300 and fields[5] == 27 then
            exit_requested = true -- Escape
        end
        return 0
    end
    jit.off(filter,true)
    filter_events = ffi.cast("WarPaneFilter",filter)
    local pump = love.event.pump
    local function pump_panes(...)
        if main_window then
            sdl.SDL_PumpEvents()
            sdl.SDL_FilterEvents(filter_events,nil)
            if exit_requested then
                G.FUNCS.war_stop_watch()
            elseif return_requested then
                G.FUNCS.war_watch_lobby()
            elseif claim_requested then
                claim_requested = nil
                G.FUNCS.war_take_guest()
            end
        end
        return pump(...)
    end
    jit.off(pump_panes,true)
    love.event.pump = pump_panes
end

local function title(role, live, name)
    return "War - " .. (name or (role == "host" and "Host" or "Guest"))
        .. (live and "" or " (waiting)")
        .. (lobby and not lobby.playing and "  |  L: lobby" or "")
        .. "  |  Esc or close to leave"
end

local function update_title(role, pane)
    if not pane.placement_until then
        sdl.SDL_SetWindowTitle(pane.window, title(role,pane.live,pane.name))
    end
end

local function destroy_pane(pane)
    if pane.context ~= nil then sdl.SDL_GL_DeleteContext(pane.context) end
    if pane.rgba then sdl.SDL_FreeSurface(pane.rgba) end
    if pane.scaled then sdl.SDL_FreeSurface(pane.scaled) end
    sdl.SDL_DestroyWindow(pane.window)
end

local function close_panes()
    if main_hidden then sdl.SDL_ShowWindow(main_window) end
    main_hidden = false
    for _, pane in pairs(panes) do destroy_pane(pane) end
    if main_window then sdl.SDL_RaiseWindow(main_window) end
    main_window, exit_requested, panes_by_id = nil, false, {}
    panes, newest, ack = {}, {}, {}
    return_requested,claim_requested = false,nil
end

function S.reset()
    close_panes()
    lobby,lobby_preview,switching = nil,false,nil
    capture_until = 0
    retry_width_at = {}
    watching, pending = false, false
end

local function open_panes(names)
    backend()
    if not linux_gl and linear_stretch == nil then
        local ok, fn = pcall(function() return sdl.SDL_SoftStretchLinear end)
        linear_stretch = ok and fn or false
    end
    install_controls()
    local main = main_window or sdl.SDL_GL_GetCurrentWindow()
    assert(main ~= nil,"Could not locate the Balatro window")
    local bounds = ffi.new("int[4]")
    local display = math.max(0,sdl.SDL_GetWindowDisplayIndex(main))
    if sdl.SDL_GetDisplayUsableBounds(display,bounds) ~= 0 and sdl.SDL_GetDisplayBounds(display,bounds) ~= 0 then
        bounds[2],bounds[3] = love.window.getDesktopDimensions(display+1)
    end
    -- Host gets the left half of Balatro's display. If you change the margins or aspect
    -- ratio here, match pane_rect in spectator_hyprland.py and placePanes in spectator_kwin.lua.
    -- https://wiki.libsdl.org/SDL2/SDL_GetDisplayUsableBounds
    local w = math.floor(bounds[2] / 2) - 16
    local h = math.min(bounds[3] - 100, math.floor(w * 9 / 16))
    local layout = {}
    for i, role in ipairs(roles) do
        local occupied = not lobby or lobby.seats[role]
        local pane = panes[role]
        if occupied and not pane then
            local name = names and names[role]
            local x, y = bounds[0]+8+(i-1)*(w+16), bounds[1]+40
            local caption = title(role,false,name)
            if place_panes then
                pane_serial = pane_serial + 1
                -- The compositor uses this title to find the pane owned by this client.
                caption = string.format("War pane %d-%d-%s", ffi.C.getpid(), pane_serial, role)
                local output = sdl.SDL_GetDisplayName(display)
                layout[#layout + 1] = {
                    title = caption, role = role,
                    output = output ~= nil and ffi.string(output) or nil
                }
            end
            local win = sdl.SDL_CreateWindow(caption, x, y, w, h, linux_gl and 0x26 or 0x24)
            assert(win ~= nil, "Could not open "..role.." window")
            panes[role] = {
                window = win, name = name, w = w, h = h,
                size = ffi.new("int[2]"), clip = ffi.new("int[4]")
            }
            if place_panes then panes[role].placement_until = love.timer.getTime() + 4 end
            panes_by_id[tonumber(sdl.SDL_GetWindowID(win))] = panes[role]
            sdl.SDL_SetWindowMinimumSize(win,240,135)
        elseif not occupied and pane then
            panes_by_id[tonumber(sdl.SDL_GetWindowID(pane.window))] = nil
            destroy_pane(pane)
            panes[role],newest[role] = nil,nil
        end
    end
    if not next(panes) then
        close_panes()
        lobby_preview = false
    elseif not main_window then
        main_window = main
    end
    if #layout > 0 then
        local ok, err = pcall(place_panes, layout)
        if not ok then WAR.log("[WAR] Could not position spectator panes: "..tostring(err)) end
    end
end

function S.track_slot(node, slot)
    if not node then return end
    local draw = node.draw_self
    function node:draw_self(...)
        if capture_until > love.timer.getTime() and self.states.visible and not G.OVERLAY_MENU and not G.screenwipe then
            prep_draw(self,1)
            local x1,y1 = love.graphics.transformPoint(0,0)
            local x2,y2 = love.graphics.transformPoint(self.VT.w,self.VT.h)
            love.graphics.pop()
            slot_bounds[slot] = {x1,y1,x2,y2,draw=G.FRAMES.DRAW}
        end
        return draw(self,...)
    end
end

local function frame_slots(width,height,scale,sw)
    if WAR.GAME.active or not WAR.LOBBY.code or G.OVERLAY_MENU or G.screenwipe then return end
    local slots = {}
    local pad = (width-sw*scale)/2
    for slot,box in pairs(slot_bounds) do
        if box.draw == G.FRAMES.DRAW then
            slots[slot] = {(pad+box[1]*scale)/width,box[2]*scale/height,
                           (pad+box[3]*scale)/width,box[4]*scale/height}
        end
    end
    return slots
end

local function blit_frame(pane,src,dest,rect,w,h)
    local dw,dh = rect[2],rect[3]
    if linear_stretch and (dw ~= w or dh ~= h) then
        local argb8888 = 0x16362004
        if not pane.rgba or pane.rw ~= w or pane.rh ~= h then
            if pane.rgba then sdl.SDL_FreeSurface(pane.rgba) end
            pane.rgba = sdl.SDL_CreateRGBSurfaceWithFormat(0,w,h,32,argb8888)
            pane.rw,pane.rh = w,h
        end
        if not pane.scaled or pane.dw ~= dw or pane.dh ~= dh then
            if pane.scaled then sdl.SDL_FreeSurface(pane.scaled) end
            pane.scaled = sdl.SDL_CreateRGBSurfaceWithFormat(0,dw,dh,32,argb8888)
            pane.dw,pane.dh = dw,dh
        end
        if pane.rgba ~= nil and pane.scaled ~= nil and sdl.SDL_UpperBlit(src,nil,pane.rgba,nil) == 0
            and linear_stretch(pane.rgba,nil,pane.scaled,nil) == 0 then
            return sdl.SDL_UpperBlit(pane.scaled,nil,dest,rect) == 0
        end
    end
    return sdl.SDL_UpperBlitScaled(src,nil,dest,rect) == 0
end

local function paint(role, msg)
    local pane = panes[role]
    if not pane then return end
    pane.last_frame = msg
    sdl.SDL_GetWindowSize(pane.window,pane.size,pane.size+1)
    local dest
    if linux_gl then
        sdl.SDL_GL_GetDrawableSize(pane.window,pane.clip+2,pane.clip+3)
    else
        dest = sdl.SDL_GetWindowSurface(pane.window)
        if dest == nil then return end
        sdl.SDL_GetClipRect(dest,pane.clip)
    end
    if pane.clip[2] <= 0 or pane.clip[3] <= 0 or pane.size[0] <= 0 or pane.size[1] <= 0 then return end
    local needs_redraw = pane.w ~= pane.clip[2] or pane.h ~= pane.clip[3] or pane.redraw
    pane.w,pane.h,pane.redraw = pane.clip[2],pane.clip[3],false
    pane.slots,pane.frame_rect = nil,nil
    local h = tonumber(msg.height) or 0
    local live = false
    local w = msg.width or 480
    if type(w) ~= "number" or w < 480 or w > 3840 or w%2 ~= 0 then return end
    if h >= 1 and h <= math.min(2160,w*0.75) and #msg.pixels > 0 then
        local bytes = love.data.decode("string","base64",msg.pixels)
        if msg.codec == "lz4" then
            if #bytes < 5 or love.data.unpack("<I4",bytes) ~= w*h*2 then return end
            local ok, raw = pcall(love.data.decompress,"string","lz4",bytes)
            if not ok then return end
            bytes = raw
        end
        if #bytes == w*h*2 then
            local scale = math.min(pane.w/w,pane.h/h)
            local w2,h2 = math.floor(scale*w), math.floor(scale*h)
            local rect = ffi.new("int[4]",{(pane.w-w2)/2,(pane.h-h2)/2,w2,h2})
            if linux_gl then
                S.present_gl(sdl,pane,bytes,w,h,rect)
                live = true
            else
                local src = sdl.SDL_CreateRGBSurfaceFrom(ffi.cast("void*",bytes),w,h,16,w*2,0xf800,0x7e0,0x1f,0)
                if src ~= nil then
                    if needs_redraw or pane.height ~= h or pane.width ~= w then sdl.SDL_FillRect(dest,nil,0) end
                    pane.height,pane.width = h,w
                    live = blit_frame(pane,src,dest,rect,w,h)
                    sdl.SDL_FreeSurface(src)
                end
            end
            if live then pane.slots,pane.frame_rect = msg.slots,rect end
        end
    end
    if not live then
        if pane.live == false and not needs_redraw then return end
        if linux_gl then S.present_gl(sdl,pane) else sdl.SDL_FillRect(dest,nil,0) end
    end
    if pane.live ~= live then
        pane.live = live
        update_title(role, pane)
    end
    local presented = linux_gl or sdl.SDL_UpdateWindowSurface(pane.window) == 0
    -- Keep the lobby visible until there's a player frame on screen to replace it.
    if presented and live and main_window and not main_hidden then
        sdl.SDL_HideWindow(main_window)
        sdl.SDL_RaiseWindow(pane.window)
        main_hidden = true
    end
end

local function send_capture(source, sw, sh, width)
    local scale = math.min(width/sw, math.min(2160,width*0.75)/sh)
    local height = math.max(1,math.floor(sh*scale))
    local target = capture_targets[width]
    if not target or target:getHeight() ~= height then
        target = love.graphics.newCanvas(width/2,height,{format="rgba8",dpiscale=1})
        capture_targets[width] = target
    end
    if not pack_shader then
        -- Pack two RGB565 pixels into each RGBA texel, low byte first.
        pack_shader = love.graphics.newShader([[
            extern number halfStep;
            vec2 pack565(vec3 color) {
                vec3 q = floor(clamp(color, 0.0, 1.0) * vec3(31.0,63.0,31.0) + 0.5);
                return vec2(mod(q.g,8.0)*32.0+q.b, q.r*8.0+floor(q.g/8.0))/255.0;
            }
            vec4 effect(vec4 tint, Image tex, vec2 uv, vec2 screen) {
                vec2 dx = vec2(halfStep,0.0);
                return vec4(pack565(Texel(tex,uv-dx).rgb), pack565(Texel(tex,uv+dx).rgb));
            }
        ]])
    end
    pack_shader:send("halfStep",0.5/(sw*scale))
    love.graphics.push("all")
    love.graphics.setCanvas(target)
    love.graphics.origin()
    love.graphics.setShader(pack_shader)
    love.graphics.setBlendMode("replace","premultiplied")
    love.graphics.setScissor()
    love.graphics.clear(0,0,0,0)
    love.graphics.draw(source,(width-sw*scale)/4,0,0,scale/2,scale)
    love.graphics.pop()
    local image = target:newImageData()
    local raw = image:getString()
    image:release()
    local codec, bytes = "lz4", love.data.compress("string","lz4",raw)
    if width == 480 and #bytes >= #raw then codec,bytes = nil,raw end
    -- Leave room for base64 when checking the frame against the relay limit.
    if #bytes <= (width > 960 and 1572864 or 346000) then
        WAR.NET.send({
            action = "watchFrame", codec = codec, width = width, height = height,
            slots = frame_slots(width, height, scale, sw),
            pixels = love.data.encode("string", "base64", bytes)
        })
        return true
    end
end

-- Capture before the CRT effect so card text stays sharp.
local function capture_sharp()
    local source = G.CANVAS
    local sw,sh = source:getDimensions()
    local native_w = source:getPixelDimensions()
    local first_width_index = #resolutions
    for i, width in ipairs(resolutions) do
        if width <= capture_width then
            first_width_index = i
            if width <= native_w or not resolutions[i + 1] or resolutions[i + 1] < native_w then
                break
            end
        end
    end
    local now = love.timer.getTime()
    local retried_width = false
    for i = first_width_index, #resolutions do
        local width = resolutions[i]
        local retry_at = retry_width_at[width]
        -- Retrying several oversized widths would encode the same frame several times.
        if not retry_at or (not retried_width and now >= retry_at) then
            if retry_at then retried_width = true end
            if send_capture(source, sw, sh, width) then
                retry_width_at[width] = nil
                return
            end
            retry_width_at[width] = now + 2
        end
    end
end

local function leave()
    WAR.NET.send({action="unwatch"})
    S.reset()
end

local function seat_request(action, role)
    local version, smods = WAR.mod_versions()
    WAR.NET.send({
        action = action, seat = role, stream = 1, codec = "lz4",
        mod_version = version, smods_version = smods,
        pfp = WAR.AVATAR and WAR.AVATAR.selected or "default"
    })
end

function G.FUNCS.war_give_up_seat()
    if WAR.LOBBY.code and not WAR.GAME.active then
        switching = WAR.LOBBY.code
        seat_request("giveUpSeat")
    end
end

function G.FUNCS.war_take_guest() seat_request("takeSeat","guest") end

local function show_roster()
    local rows = {}
    local function label(text)
        return {n=G.UIT.R,config={align="cm"},nodes={
            {n=G.UIT.T,config={text=text,scale=0.4,colour=G.C.WHITE}}}}
    end
    rows[1] = label("Spectating lobby "..lobby.code)
    for _,role in ipairs(roles) do
        local name = lobby.seats[role]
        local seat = role == "host" and "Host" or "Guest"
        if name then
            rows[#rows+1] = label(seat.." - "..name..(lobby[role.."_ready"] and " (ready)" or ""))
        elseif role == "guest" and lobby.seats.host then
            rows[#rows+1] = UIBox_button({label={"Take open "..seat.." seat"},button="war_take_"..role,minw=5})
        else
            rows[#rows+1] = label(seat.." - waiting")
        end
    end
    rows[#rows+1] = label("Spectators: "..lobby.viewers)
    local names = {}
    for i, name in ipairs(S.viewer_names(lobby.code)) do
        names[i] = i == own_roster_row and (name.." (you)") or name
    end
    if #names > 3 then
        rows[#rows+1] = create_option_cycle({options=names, current_option=own_roster_row or 1,
            no_pips=true, w=5, scale=0.8, colour=G.C.GREY})
    else
        for _, name in ipairs(names) do rows[#rows+1] = label(name) end
    end
    if lobby.seats.host or lobby.seats.guest then
        rows[#rows+1] = UIBox_button({label={"Spectate room"},button="war_preview_lobby",minw=5})
    end
    WAR.UI.open_instant(create_UIBox_generic_options({back_func="war_stop_watch",contents=rows}))
end

function G.FUNCS.war_watch_lobby()
    close_panes()
    lobby_preview = false
    show_roster()
end

local function display_panes(names)
    local ok, err = pcall(open_panes,names)
    if not ok then
        leave()
        WAR.UI.show_message(tostring(err))
    end
end

function G.FUNCS.war_preview_lobby()
    if not watching or not lobby or main_window then return end
    lobby_preview = true
    display_panes(lobby.seats)
    for role in pairs(panes) do paint(role,{height=0,pixels=""}) end
end

local function update_roster(state,names)
    if not state then return end
    local old = lobby
    lobby = state
    if main_window and (not old or old.seats.host ~= state.seats.host or old.seats.guest ~= state.seats.guest
        or old.playing ~= state.playing) then
        display_panes(names)
        if not watching then return end
        for role,pane in pairs(panes) do
            pane.redraw = true
            local same_player = old and old.seats[role] == state.seats[role]
            paint(role,same_player and pane.last_frame or {height=0,pixels=""})
        end
    end
    if state.playing then
        if not main_window then display_panes(names) end
    elseif not main_window and (not old or old.viewers ~= state.viewers
        or old.host_ready ~= state.host_ready or old.guest_ready ~= state.guest_ready
        or old.seats.host ~= state.seats.host or old.seats.guest ~= state.seats.guest) then
        show_roster()
    end
end

function G.FUNCS.war_stop_watch()
    leave()
    G.FUNCS.war_private()
end

function G.FUNCS.war_spectate()
    local code = (WAR.UI._join_code.code or ""):upper()
    if not code or #code ~= 5 then return end
    local ok, err = WAR.NET.connect()
    if not ok then WAR.UI.show_message(tostring(err)); return end
    pending,deadline = true,love.timer.getTime()+8
    WAR.NET.send({action="spectate",code=code,codec="lz4",stream=1})
    WAR.UI.open(create_UIBox_generic_options({back_func="war_stop_watch",contents={
        UIBox_button({label={"Stop spectating"},button="war_stop_watch",minw=5})}}))
end

function S.tick()
    local t = love.timer.getTime()
    if capture_until > t and (WAR.GAME.active or WAR.LOBBY.code) and G.CANVAS and t >= next_frame and WAR.NET.frame_writable() then
        capture_sharp()
        next_frame = math.max(t, next_frame + 1/60)
    end
    if watching then
        for role,pane in pairs(panes) do
            if pane.placement_until and t >= pane.placement_until then
                pane.placement_until = nil
                update_title(role, pane)
            end
            if pane.received_at and t - pane.received_at > 2 and not newest[role] then
                pane.received_at = nil
                paint(role,{height=0,pixels=""})
            elseif pane.redraw and pane.last_frame and not newest[role] then
                paint(role, pane.last_frame)
            end
        end
        for _,role in ipairs(roles) do
            local frame = newest[role]
            if frame then
                newest[role] = nil
                if panes[role] then panes[role].received_at = t end
                paint(role,frame)
                ack[role] = frame.frame
            end
        end
        if t >= next_ack and (ack.host or ack.guest) then
            WAR.NET.send({action="watchAck",host=ack.host,guest=ack.guest})
            ack, next_ack = {}, t+1/30
        end
    end
    if pending and t > deadline then
        leave()
        WAR.UI.show_message("Spectator relay timed out")
    elseif watching and not pending and t >= next_pull then
        pending, deadline = true,t+8
        next_pull = t + 0.5
        local widths = {}
        for role, pane in pairs(panes) do
            widths[role] = math.max(1, math.min(3840, pane.w))
        end
        WAR.NET.send({action="watchPull",lobby_preview=lobby_preview or nil,pane_widths=widths})
    end
end

function S.handle(m)
    if m.action == "spectatorRoster" then
        if m.code == WAR.LOBBY.code or (watching and lobby and lobby.code == m.code) then
            roster_code,roster_names,own_roster_row = m.code,m.names,m.your_row
            if watching and lobby and not main_window and not lobby.playing then
                show_roster()
            elseif G.WAR_LOBBY_SPECTATORS and WAR.LOBBY.code == m.code then
                WAR.UI.create_lobby_panels()
            end
        end
    elseif m.action == "watchCapture" then
        capture_width = tonumber(m.width) or 960
        if m.stream == 1 and (WAR.GAME.active or m.lobby_preview) then
            capture_until = love.timer.getTime()+1.5
        end
    elseif m.action == "watchJoined" then
        local from_join = WAR.LOBBY_STATE == "joining"
        if from_join then WAR.LOBBY_STATE = "none" end
        local from_seat = m.switched and m.lobby and switching == m.lobby.code and WAR.LOBBY.code == switching
        switching = nil
        if from_seat then
            WAR.LOBBY.leave_local()
            WAR.UI.hide_lobby()
        end
        if (pending and not watching) or from_join or from_seat then
            watching,pending,next_pull = true,false,0
            if m.lobby then
                update_roster(m.lobby, m.names)
            else
                display_panes(m.names)
            end
        end
    elseif watching and (m.action == "joined" or m.action == "promoted_to_host") then
        S.reset()
        WAR.LOBBY_STATE = "in_lobby"
        -- Let the normal join or promotion handler finish taking the seat.
        return false
    elseif m.action == "seatUnavailable" then
        switching = nil
        if watching then
            next_pull = 0
        elseif m.reason == "last_player" then
            WAR.UI.show_message("Another player needs to join before you can spectate.")
        else
            WAR.UI.show_message("Seats are locked during a match.")
        end
    elseif m.action == "watchView" then
        if watching and (m.role == "host" or m.role == "guest") then
            if m.frame then newest[m.role] = m end
        end
    elseif m.action == "watchReady" then
        if not watching then return true end
        update_roster(m.lobby,m.names)
        if m.names then
            for role,pane in pairs(panes) do
                if pane.name ~= m.names[role] then
                    pane.name = m.names[role]
                    update_title(role, pane)
                end
            end
        end
        pending = false
    elseif m.action == "watchEnded" then
        S.reset()
        WAR.UI.show_message(m.reason or "Room closed")
    else
        return false
    end
    return true
end
