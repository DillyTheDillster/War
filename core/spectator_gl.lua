local ffi = require("ffi")
local gl

local function load_gl(sdl)
    local function proc(name, signature)
        local ptr = sdl.SDL_GL_GetProcAddress(name)
        assert(ptr ~= nil, "Missing OpenGL function "..name)
        return ffi.cast(signature, ptr)
    end
    return {
        gen_texture = proc("glGenTextures", "void(*)(int,unsigned*)"),
        bind_texture = proc("glBindTexture", "void(*)(unsigned,unsigned)"),
        image = proc("glTexImage2D", "void(*)(unsigned,int,int,int,int,int,unsigned,unsigned,const void*)"),
        update = proc("glTexSubImage2D", "void(*)(unsigned,int,int,int,int,int,unsigned,unsigned,const void*)"),
        parameter = proc("glTexParameteri", "void(*)(unsigned,unsigned,int)"),
        gen_fbo = proc("glGenFramebuffers", "void(*)(int,unsigned*)"),
        bind_fbo = proc("glBindFramebuffer", "void(*)(unsigned,unsigned)"),
        attach = proc("glFramebufferTexture2D", "void(*)(unsigned,unsigned,unsigned,unsigned,int)"),
        status = proc("glCheckFramebufferStatus", "unsigned(*)(unsigned)"),
        clear = proc("glClear", "void(*)(unsigned)"),
        clear_color = proc("glClearColor", "void(*)(float,float,float,float)"),
        blit = proc("glBlitFramebuffer", "void(*)(int,int,int,int,int,int,int,int,unsigned,unsigned)"),
    }
end

local GL_TEXTURE_2D = 0x0DE1
local GL_TEXTURE_MIN_FILTER, GL_TEXTURE_MAG_FILTER = 0x2801, 0x2800
local GL_LINEAR = 0x2601
local GL_RGB8, GL_RGB, GL_UNSIGNED_SHORT_5_6_5 = 0x8051, 0x1907, 0x8363
local GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 = 0x8CA8, 0x8CE0
local GL_FRAMEBUFFER_COMPLETE, GL_COLOR_BUFFER_BIT = 0x8CD5, 0x4000

local function draw(sdl, pane, pixels, w, h, rect)
    gl = gl or load_gl(sdl)
    if not pane.texture then
        local ids = ffi.new("unsigned[2]")
        gl.gen_texture(1, ids)
        gl.gen_fbo(1, ids + 1)
        pane.texture, pane.fbo = ids[0], ids[1]
        gl.bind_texture(GL_TEXTURE_2D, pane.texture)
        gl.parameter(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
        gl.parameter(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
        gl.bind_fbo(GL_READ_FRAMEBUFFER, pane.fbo)
        gl.attach(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, pane.texture, 0)
        gl.clear_color(0, 0, 0, 1)
    end
    gl.clear(GL_COLOR_BUFFER_BIT)
    if pixels then
        if pane.width ~= w or pane.height ~= h then
            gl.image(GL_TEXTURE_2D, 0, GL_RGB8, w, h, 0, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, pixels)
            assert(gl.status(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "Spectator framebuffer is incomplete")
            pane.width, pane.height = w, h
        else
            gl.update(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, pixels)
        end
        -- The stream starts at the top left, so flip the destination Y coordinates.
        -- https://registry.khronos.org/OpenGL-Refpages/gl4/html/glBlitFramebuffer.xhtml
        local x, top = rect[0], pane.h - rect[1]
        gl.blit(0, 0, w, h, x, top, x + rect[2], top - rect[3], GL_COLOR_BUFFER_BIT, GL_LINEAR)
    end
    sdl.SDL_GL_SwapWindow(pane.window)
end

function WAR.SPECTATOR.present_gl(sdl, pane, pixels, w, h, rect)
    local main, context = sdl.SDL_GL_GetCurrentWindow(), sdl.SDL_GL_GetCurrentContext()
    if pane.context == nil then
        pane.context = sdl.SDL_GL_CreateContext(pane.window)
        assert(pane.context ~= nil, ffi.string(sdl.SDL_GetError()))
        sdl.SDL_GL_SetSwapInterval(0)
    else
        assert(sdl.SDL_GL_MakeCurrent(pane.window, pane.context) == 0, ffi.string(sdl.SDL_GetError()))
    end
    -- Restore Balatro's GL context even if drawing the pane fails.
    local ok, err = pcall(draw, sdl, pane, pixels, w, h, rect)
    assert(sdl.SDL_GL_MakeCurrent(main, context) == 0, ffi.string(sdl.SDL_GetError()))
    if not ok then error(err) end
end
