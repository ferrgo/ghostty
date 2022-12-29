//! Rendering implementation for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const imgui = @import("imgui");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const Terminal = terminal.Terminal;
const gl = @import("opengl/main.zig");
const trace = @import("tracy").trace;
const math = @import("../math.zig");
const lru = @import("../lru.zig");
const DevMode = @import("../DevMode.zig");
const Window = @import("../Window.zig");

const log = std.log.scoped(.grid);

// The LRU is keyed by (screen, row_id) since we need to cache rows
// separately for alt screens. By storing that in the key, we very likely
// have the cache already for when the primary screen is reactivated.
const CellsLRU = lru.AutoHashMap(struct {
    selection: ?terminal.Selection,
    screen: terminal.Terminal.ScreenType,
    row_id: terminal.Screen.RowHeader.Id,
}, std.ArrayListUnmanaged(GPUCell));

alloc: std.mem.Allocator,

/// Current cell dimensions for this grid.
cell_size: renderer.CellSize,

/// The current set of cells to render. Each set of cells goes into
/// a separate shader call.
cells_bg: std.ArrayListUnmanaged(GPUCell),
cells: std.ArrayListUnmanaged(GPUCell),

/// The LRU that stores our GPU cells cached by row IDs. This is used to
/// prevent high CPU activity when shaping rows.
cells_lru: CellsLRU,

/// The size of the cells list that was sent to the GPU. This is used
/// to detect when the cells array was reallocated/resized and handle that
/// accordingly.
gl_cells_size: usize = 0,

/// The last length of the cells that was written to the GPU. This is used to
/// determine what data needs to be rewritten on the GPU.
gl_cells_written: usize = 0,

/// Shader program for cell rendering.
program: gl.Program,
vao: gl.VertexArray,
ebo: gl.Buffer,
vbo: gl.Buffer,
texture: gl.Texture,
texture_color: gl.Texture,

/// The font structures.
font_group: *font.GroupCache,
font_shaper: font.Shaper,

/// Whether the cursor is visible or not. This is used to control cursor
/// blinking.
cursor_visible: bool,
cursor_style: renderer.CursorStyle,
cursor_color: ?terminal.color.RGB,

/// Default foreground color
foreground: terminal.color.RGB,

/// Default background color
background: terminal.color.RGB,

/// Default selection color
selection_background: ?terminal.color.RGB,
selection_foreground: ?terminal.color.RGB,

/// True if the window is focused
focused: bool,

/// Padding options
padding: renderer.Options.Padding,

/// The mailbox for communicating with the window.
window_mailbox: Window.Mailbox,

/// The raw structure that maps directly to the buffer sent to the vertex shader.
/// This must be "extern" so that the field order is not reordered by the
/// Zig compiler.
const GPUCell = extern struct {
    /// vec2 grid_coord
    grid_col: u16,
    grid_row: u16,

    /// vec2 glyph_pos
    glyph_x: u32 = 0,
    glyph_y: u32 = 0,

    /// vec2 glyph_size
    glyph_width: u32 = 0,
    glyph_height: u32 = 0,

    /// vec2 glyph_size
    glyph_offset_x: i32 = 0,
    glyph_offset_y: i32 = 0,

    /// vec4 fg_color_in
    fg_r: u8,
    fg_g: u8,
    fg_b: u8,
    fg_a: u8,

    /// vec4 bg_color_in
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    bg_a: u8,

    /// uint mode
    mode: GPUCellMode,

    /// The width in grid cells that a rendering takes.
    grid_width: u8,
};

const GPUCellMode = enum(u8) {
    bg = 1,
    fg = 2,
    fg_color = 7,
    cursor_rect = 3,
    cursor_rect_hollow = 4,
    cursor_bar = 5,
    strikethrough = 8,

    // Non-exhaustive because masks change it
    _,

    pub fn fromCursor(cursor: renderer.CursorStyle) GPUCellMode {
        return switch (cursor) {
            .box => .cursor_rect,
            .box_hollow => .cursor_rect_hollow,
            .bar => .cursor_bar,
        };
    }

    /// Apply a mask to the mode.
    pub fn mask(self: GPUCellMode, m: GPUCellMode) GPUCellMode {
        return @intToEnum(
            GPUCellMode,
            @enumToInt(self) | @enumToInt(m),
        );
    }
};

pub fn init(alloc: Allocator, options: renderer.Options) !OpenGL {
    // Create the initial font shaper
    var shape_buf = try alloc.alloc(font.shape.Cell, 1);
    errdefer alloc.free(shape_buf);
    var shaper = try font.Shaper.init(alloc, shape_buf);
    errdefer shaper.deinit();

    // Create our shader
    const program = try gl.Program.createVF(
        @embedFile("shaders/cell.v.glsl"),
        @embedFile("shaders/cell.f.glsl"),
    );

    // Setup our font metrics uniform
    const metrics = try resetFontMetrics(alloc, program, options.font_group);

    // Set our cell dimensions
    const pbind = try program.use();
    defer pbind.unbind();
    try program.setUniform("cell_size", @Vector(2, f32){ metrics.cell_width, metrics.cell_height });
    try program.setUniform("strikethrough_position", metrics.strikethrough_position);
    try program.setUniform("strikethrough_thickness", metrics.strikethrough_thickness);

    // Set all of our texture indexes
    try program.setUniform("text", 0);
    try program.setUniform("text_color", 1);

    // Setup our VAO
    const vao = try gl.VertexArray.create();
    errdefer vao.destroy();
    try vao.bind();
    defer gl.VertexArray.unbind() catch null;

    // Element buffer (EBO)
    const ebo = try gl.Buffer.create();
    errdefer ebo.destroy();
    var ebobind = try ebo.bind(.ElementArrayBuffer);
    defer ebobind.unbind();
    try ebobind.setData([6]u8{
        0, 1, 3, // Top-left triangle
        1, 2, 3, // Bottom-right triangle
    }, .StaticDraw);

    // Vertex buffer (VBO)
    const vbo = try gl.Buffer.create();
    errdefer vbo.destroy();
    var vbobind = try vbo.bind(.ArrayBuffer);
    defer vbobind.unbind();
    var offset: usize = 0;
    try vbobind.attributeAdvanced(0, 2, gl.c.GL_UNSIGNED_SHORT, false, @sizeOf(GPUCell), offset);
    offset += 2 * @sizeOf(u16);
    try vbobind.attributeAdvanced(1, 2, gl.c.GL_UNSIGNED_INT, false, @sizeOf(GPUCell), offset);
    offset += 2 * @sizeOf(u32);
    try vbobind.attributeAdvanced(2, 2, gl.c.GL_UNSIGNED_INT, false, @sizeOf(GPUCell), offset);
    offset += 2 * @sizeOf(u32);
    try vbobind.attributeAdvanced(3, 2, gl.c.GL_INT, false, @sizeOf(GPUCell), offset);
    offset += 2 * @sizeOf(i32);
    try vbobind.attributeAdvanced(4, 4, gl.c.GL_UNSIGNED_BYTE, false, @sizeOf(GPUCell), offset);
    offset += 4 * @sizeOf(u8);
    try vbobind.attributeAdvanced(5, 4, gl.c.GL_UNSIGNED_BYTE, false, @sizeOf(GPUCell), offset);
    offset += 4 * @sizeOf(u8);
    try vbobind.attributeIAdvanced(6, 1, gl.c.GL_UNSIGNED_BYTE, @sizeOf(GPUCell), offset);
    offset += 1 * @sizeOf(u8);
    try vbobind.attributeIAdvanced(7, 1, gl.c.GL_UNSIGNED_BYTE, @sizeOf(GPUCell), offset);
    try vbobind.enableAttribArray(0);
    try vbobind.enableAttribArray(1);
    try vbobind.enableAttribArray(2);
    try vbobind.enableAttribArray(3);
    try vbobind.enableAttribArray(4);
    try vbobind.enableAttribArray(5);
    try vbobind.enableAttribArray(6);
    try vbobind.enableAttribArray(7);
    try vbobind.attributeDivisor(0, 1);
    try vbobind.attributeDivisor(1, 1);
    try vbobind.attributeDivisor(2, 1);
    try vbobind.attributeDivisor(3, 1);
    try vbobind.attributeDivisor(4, 1);
    try vbobind.attributeDivisor(5, 1);
    try vbobind.attributeDivisor(6, 1);
    try vbobind.attributeDivisor(7, 1);

    // Build our texture
    const tex = try gl.Texture.create();
    errdefer tex.destroy();
    {
        const texbind = try tex.bind(.@"2D");
        try texbind.parameter(.WrapS, gl.c.GL_CLAMP_TO_EDGE);
        try texbind.parameter(.WrapT, gl.c.GL_CLAMP_TO_EDGE);
        try texbind.parameter(.MinFilter, gl.c.GL_LINEAR);
        try texbind.parameter(.MagFilter, gl.c.GL_LINEAR);
        try texbind.image2D(
            0,
            .Red,
            @intCast(c_int, options.font_group.atlas_greyscale.size),
            @intCast(c_int, options.font_group.atlas_greyscale.size),
            0,
            .Red,
            .UnsignedByte,
            options.font_group.atlas_greyscale.data.ptr,
        );
    }

    // Build our color texture
    const tex_color = try gl.Texture.create();
    errdefer tex_color.destroy();
    {
        const texbind = try tex_color.bind(.@"2D");
        try texbind.parameter(.WrapS, gl.c.GL_CLAMP_TO_EDGE);
        try texbind.parameter(.WrapT, gl.c.GL_CLAMP_TO_EDGE);
        try texbind.parameter(.MinFilter, gl.c.GL_LINEAR);
        try texbind.parameter(.MagFilter, gl.c.GL_LINEAR);
        try texbind.image2D(
            0,
            .RGBA,
            @intCast(c_int, options.font_group.atlas_color.size),
            @intCast(c_int, options.font_group.atlas_color.size),
            0,
            .BGRA,
            .UnsignedByte,
            options.font_group.atlas_color.data.ptr,
        );
    }

    return OpenGL{
        .alloc = alloc,
        .cells_bg = .{},
        .cells = .{},
        .cells_lru = CellsLRU.init(0),
        .cell_size = .{ .width = metrics.cell_width, .height = metrics.cell_height },
        .program = program,
        .vao = vao,
        .ebo = ebo,
        .vbo = vbo,
        .texture = tex,
        .texture_color = tex_color,
        .font_group = options.font_group,
        .font_shaper = shaper,
        .cursor_visible = true,
        .cursor_style = .box,
        .cursor_color = if (options.config.@"cursor-color") |col| col.toTerminalRGB() else null,
        .background = options.config.background.toTerminalRGB(),
        .foreground = options.config.foreground.toTerminalRGB(),
        .selection_background = if (options.config.@"selection-background") |bg|
            bg.toTerminalRGB()
        else
            null,
        .selection_foreground = if (options.config.@"selection-foreground") |bg|
            bg.toTerminalRGB()
        else
            null,
        .focused = true,
        .padding = options.padding,
        .window_mailbox = options.window_mailbox,
    };
}

pub fn deinit(self: *OpenGL) void {
    self.font_shaper.deinit();
    self.alloc.free(self.font_shaper.cell_buf);

    self.texture.destroy();
    self.texture_color.destroy();
    self.vbo.destroy();
    self.ebo.destroy();
    self.vao.destroy();
    self.program.destroy();

    self.resetCellsLRU();
    self.cells_lru.deinit(self.alloc);

    self.cells.deinit(self.alloc);
    self.cells_bg.deinit(self.alloc);
    self.* = undefined;
}

fn resetCellsLRU(self: *OpenGL) void {
    // Preserve the old capacity so that we have space in our LRU
    const cap = self.cells_lru.capacity;

    // Our LRU values are array lists so we need to deallocate those first
    var it = self.cells_lru.queue.first;
    while (it) |node| {
        it = node.next;
        node.data.value.deinit(self.alloc);
    }
    self.cells_lru.deinit(self.alloc);

    // Initialize our new LRU
    self.cells_lru = CellsLRU.init(cap);
}

/// Returns the hints that we want for this
pub fn glfwWindowHints() glfw.Window.Hints {
    return .{
        .context_version_major = 3,
        .context_version_minor = 3,
        .opengl_profile = .opengl_core_profile,
        .opengl_forward_compat = true,
        .cocoa_graphics_switching = builtin.os.tag == .macos,
        .cocoa_retina_framebuffer = true,
    };
}

/// This is called early right after window creation to setup our
/// window surface as necessary.
pub fn windowInit(win: apprt.runtime.Window) !void {
    // Treat this like a thread entry
    const self: OpenGL = undefined;
    try self.threadEnter(win);

    // Blending for text
    try gl.enable(gl.c.GL_BLEND);
    try gl.blendFunc(gl.c.GL_SRC_ALPHA, gl.c.GL_ONE_MINUS_SRC_ALPHA);

    // These are very noisy so this is commented, but easy to uncomment
    // whenever we need to check the OpenGL extension list
    // if (builtin.mode == .Debug) {
    //     var ext_iter = try gl.ext.iterator();
    //     while (try ext_iter.next()) |ext| {
    //         log.debug("OpenGL extension available name={s}", .{ext});
    //     }
    // }
}

/// This is called just prior to spinning up the renderer thread for
/// final main thread setup requirements.
pub fn finalizeWindowInit(self: *const OpenGL, win: apprt.runtime.Window) !void {
    _ = self;
    _ = win;
}

/// This is called if this renderer runs DevMode.
pub fn initDevMode(self: *const OpenGL, win: apprt.runtime.Window) !void {
    _ = self;

    if (DevMode.enabled) {
        // Initialize for our window
        assert(imgui.ImplGlfw.initForOpenGL(
            @ptrCast(*imgui.ImplGlfw.GLFWWindow, win.window.handle),
            true,
        ));
        assert(imgui.ImplOpenGL3.init("#version 330 core"));
    }
}

/// This is called if this renderer runs DevMode.
pub fn deinitDevMode(self: *const OpenGL) void {
    _ = self;

    if (DevMode.enabled) {
        imgui.ImplOpenGL3.shutdown();
        imgui.ImplGlfw.shutdown();
    }
}

/// Callback called by renderer.Thread when it begins.
pub fn threadEnter(self: *const OpenGL, win: apprt.runtime.Window) !void {
    _ = self;

    // We need to make the OpenGL context current. OpenGL requires
    // that a single thread own the a single OpenGL context (if any). This
    // ensures that the context switches over to our thread. Important:
    // the prior thread MUST have detached the context prior to calling
    // this entrypoint.
    try glfw.makeContextCurrent(win.window);
    errdefer glfw.makeContextCurrent(null) catch |err|
        log.warn("failed to cleanup OpenGL context err={}", .{err});
    try glfw.swapInterval(1);

    // Load OpenGL bindings. This API is context-aware so this sets
    // a threadlocal context for these pointers.
    const version = try gl.glad.load(&glfw.getProcAddress);
    errdefer gl.glad.unload();
    log.info("loaded OpenGL {}.{}", .{
        gl.glad.versionMajor(@intCast(c_uint, version)),
        gl.glad.versionMinor(@intCast(c_uint, version)),
    });
}

/// Callback called by renderer.Thread when it exits.
pub fn threadExit(self: *const OpenGL) void {
    _ = self;

    gl.glad.unload();
    glfw.makeContextCurrent(null) catch {};
}

/// Callback when the focus changes for the terminal this is rendering.
///
/// Must be called on the render thread.
pub fn setFocus(self: *OpenGL, focus: bool) !void {
    self.focused = focus;
}

/// Called to toggle the blink state of the cursor
///
/// Must be called on the render thread.
pub fn blinkCursor(self: *OpenGL, reset: bool) void {
    self.cursor_visible = reset or !self.cursor_visible;
}

/// Set the new font size.
///
/// Must be called on the render thread.
pub fn setFontSize(self: *OpenGL, size: font.face.DesiredSize) !void {
    log.info("set font size={}", .{size});

    // Set our new size, this will also reset our font atlas.
    try self.font_group.setSize(size);

    // Invalidate our cell cache.
    self.resetCellsLRU();

    // Reset our GPU uniforms
    const metrics = try resetFontMetrics(self.alloc, self.program, self.font_group);

    // Recalculate our cell size. If it is the same as before, then we do
    // nothing since the grid size couldn't have possibly changed.
    const new_cell_size = .{ .width = metrics.cell_width, .height = metrics.cell_height };
    if (std.meta.eql(self.cell_size, new_cell_size)) return;
    self.cell_size = new_cell_size;

    // Notify the window that the cell size changed.
    _ = self.window_mailbox.push(.{
        .cell_size = new_cell_size,
    }, .{ .forever = {} });
}

/// Reload the font metrics, recalculate cell size, and send that all
/// down to the GPU.
fn resetFontMetrics(
    alloc: Allocator,
    program: gl.Program,
    font_group: *font.GroupCache,
) !font.face.Metrics {
    // Get our cell metrics based on a regular font ascii 'M'. Why 'M'?
    // Doesn't matter, any normal ASCII will do we're just trying to make
    // sure we use the regular font.
    const metrics = metrics: {
        const index = (try font_group.indexForCodepoint(alloc, 'M', .regular, .text)).?;
        const face = try font_group.group.faceFromIndex(index);
        break :metrics face.metrics;
    };
    log.debug("cell dimensions={}", .{metrics});

    // Set details for our sprite font
    font_group.group.sprite = font.sprite.Face{
        .width = @floatToInt(u32, metrics.cell_width),
        .height = @floatToInt(u32, metrics.cell_height),
        .thickness = 2,
        .underline_position = @floatToInt(u32, metrics.underline_position),
    };

    // Set our uniforms that rely on metrics
    const pbind = try program.use();
    defer pbind.unbind();
    try program.setUniform("cell_size", @Vector(2, f32){ metrics.cell_width, metrics.cell_height });
    try program.setUniform("strikethrough_position", metrics.strikethrough_position);
    try program.setUniform("strikethrough_thickness", metrics.strikethrough_thickness);

    return metrics;
}

/// The primary render callback that is completely thread-safe.
pub fn render(
    self: *OpenGL,
    win: apprt.runtime.Window,
    state: *renderer.State,
) !void {
    // Data we extract out of the critical area.
    const Critical = struct {
        gl_bg: terminal.color.RGB,
        devmode_data: ?*imgui.DrawData,
        active_screen: terminal.Terminal.ScreenType,
        selection: ?terminal.Selection,
        screen: terminal.Screen,
        draw_cursor: bool,
    };

    // Update all our data as tightly as possible within the mutex.
    var critical: Critical = critical: {
        state.mutex.lock();
        defer state.mutex.unlock();

        // Setup our cursor state
        if (self.focused) {
            self.cursor_visible = self.cursor_visible and state.cursor.visible;
            self.cursor_style = renderer.CursorStyle.fromTerminal(state.cursor.style) orelse .box;
        } else {
            self.cursor_visible = true;
            self.cursor_style = .box_hollow;
        }

        // Swap bg/fg if the terminal is reversed
        const bg = self.background;
        const fg = self.foreground;
        defer {
            self.background = bg;
            self.foreground = fg;
        }
        if (state.terminal.modes.reverse_colors) {
            self.background = fg;
            self.foreground = bg;
        }

        // Build our devmode draw data
        const devmode_data = devmode_data: {
            if (state.devmode) |dm| {
                if (dm.visible) {
                    imgui.ImplOpenGL3.newFrame();
                    imgui.ImplGlfw.newFrame();
                    try dm.update();
                    break :devmode_data try dm.render();
                }
            }

            break :devmode_data null;
        };

        // We used to share terminal state, but we've since learned through
        // analysis that it is faster to copy the terminal state than to
        // hold the lock wile rebuilding GPU cells.
        const viewport_bottom = state.terminal.screen.viewportIsBottom();
        var screen_copy = if (viewport_bottom) try state.terminal.screen.clone(
            self.alloc,
            .{ .active = 0 },
            .{ .active = state.terminal.rows - 1 },
        ) else try state.terminal.screen.clone(
            self.alloc,
            .{ .viewport = 0 },
            .{ .viewport = state.terminal.rows - 1 },
        );
        errdefer screen_copy.deinit();

        // Convert our selection to viewport points because we copy only
        // the viewport above.
        const selection: ?terminal.Selection = if (state.terminal.selection) |sel|
            sel.toViewport(&state.terminal.screen)
        else
            null;

        break :critical .{
            .gl_bg = self.background,
            .devmode_data = devmode_data,
            .active_screen = state.terminal.active_screen,
            .selection = selection,
            .screen = screen_copy,
            .draw_cursor = self.cursor_visible and state.terminal.screen.viewportIsBottom(),
        };
    };
    defer critical.screen.deinit();

    // Build our GPU cells
    try self.rebuildCells(
        critical.active_screen,
        critical.selection,
        &critical.screen,
        critical.draw_cursor,
    );

    // Try to flush our atlas, this will only do something if there
    // are changes to the atlas.
    try self.flushAtlas();

    // Clear the surface
    gl.clearColor(
        @intToFloat(f32, critical.gl_bg.r) / 255,
        @intToFloat(f32, critical.gl_bg.g) / 255,
        @intToFloat(f32, critical.gl_bg.b) / 255,
        1.0,
    );
    gl.clear(gl.c.GL_COLOR_BUFFER_BIT);

    // We're out of the critical path now. Let's first render our terminal.
    try self.draw();

    // If we have devmode, then render that
    if (critical.devmode_data) |data| {
        imgui.ImplOpenGL3.renderDrawData(data);
    }

    // Swap our window buffers
    try win.window.swapBuffers();
}

/// rebuildCells rebuilds all the GPU cells from our CPU state. This is a
/// slow operation but ensures that the GPU state exactly matches the CPU state.
/// In steady-state operation, we use some GPU tricks to send down stale data
/// that is ignored. This accumulates more memory; rebuildCells clears it.
///
/// Note this doesn't have to typically be manually called. Internally,
/// the renderer will do this when it needs more memory space.
pub fn rebuildCells(
    self: *OpenGL,
    active_screen: terminal.Terminal.ScreenType,
    term_selection: ?terminal.Selection,
    screen: *terminal.Screen,
    draw_cursor: bool,
) !void {
    const t = trace(@src());
    defer t.end();

    // Bg cells at most will need space for the visible screen size
    self.cells_bg.clearRetainingCapacity();
    try self.cells_bg.ensureTotalCapacity(self.alloc, screen.rows * screen.cols);

    // For now, we just ensure that we have enough cells for all the lines
    // we have plus a full width. This is very likely too much but its
    // the probably close enough while guaranteeing no more allocations.
    self.cells.clearRetainingCapacity();
    try self.cells.ensureTotalCapacity(
        self.alloc,

        // * 3 for background modes and cursor and underlines
        // + 1 for cursor
        (screen.rows * screen.cols * 2) + 1,
    );

    // We've written no data to the GPU, refresh it all
    self.gl_cells_written = 0;

    // This is the cell that has [mode == .fg] and is underneath our cursor.
    // We keep track of it so that we can invert the colors so the character
    // remains visible.
    var cursor_cell: ?GPUCell = null;

    // Build each cell
    var rowIter = screen.rowIterator(.viewport);
    var y: usize = 0;
    while (rowIter.next()) |row| {
        defer y += 1;

        // Our selection value is only non-null if this selection happens
        // to contain this row. If the selection changes for any reason,
        // then we invalidate the cache.
        const selection = sel: {
            if (term_selection) |sel| {
                const screen_point = (terminal.point.Viewport{
                    .x = 0,
                    .y = y,
                }).toScreen(screen);

                // If we are selected, we our colors are just inverted fg/bg
                if (sel.containsRow(screen_point)) break :sel sel;
            }

            break :sel null;
        };

        // If this is the row with our cursor, then we may have to modify
        // the cell with the cursor.
        const start_i: usize = self.cells.items.len;
        defer if (self.cursor_visible and
            self.cursor_style == .box and
            screen.viewportIsBottom() and
            y == screen.cursor.y)
        {
            for (self.cells.items[start_i..]) |cell| {
                if (cell.grid_col == screen.cursor.x and
                    cell.mode == .fg)
                {
                    cursor_cell = cell;
                    break;
                }
            }
        };

        // Get our value from the cache.
        const gop = try self.cells_lru.getOrPut(self.alloc, .{
            .selection = selection,
            .screen = active_screen,
            .row_id = row.getId(),
        });
        if (!row.isDirty() and gop.found_existing) {
            var i: usize = self.cells.items.len;
            for (gop.value_ptr.items) |cell| {
                self.cells.appendAssumeCapacity(cell);
                self.cells.items[i].grid_row = @intCast(u16, y);
                i += 1;
            }

            continue;
        }
        // Get the starting index for our row so we can cache any new GPU cells.
        const start = self.cells.items.len;

        // Split our row into runs and shape each one.
        var iter = self.font_shaper.runIterator(self.font_group, row);
        while (try iter.next(self.alloc)) |run| {
            for (try self.font_shaper.shape(run)) |shaper_cell| {
                if (self.updateCell(
                    term_selection,
                    screen,
                    row.getCell(shaper_cell.x),
                    shaper_cell,
                    run,
                    shaper_cell.x,
                    y,
                )) |update| {
                    assert(update);
                } else |err| {
                    log.warn("error building cell, will be invalid x={} y={}, err={}", .{
                        shaper_cell.x,
                        y,
                        err,
                    });
                }
            }
        }

        // Initialize our list
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};

            // If we evicted another value in our LRU for this one, free it
            if (gop.evicted) |kv| {
                var list = kv.value;
                list.deinit(self.alloc);
            }
        }
        var row_cells = gop.value_ptr;

        // Get our new length and cache the cells.
        try row_cells.ensureTotalCapacity(self.alloc, screen.cols);
        row_cells.clearRetainingCapacity();
        try row_cells.appendSlice(self.alloc, self.cells.items[start..]);

        // Set row is not dirty anymore
        row.setDirty(false);
    }

    // Add the cursor at the end so that it overlays everything. If we have
    // a cursor cell then we invert the colors on that and add it in so
    // that we can always see it.
    if (draw_cursor) self.addCursor(screen);
    if (cursor_cell) |*cell| {
        cell.fg_r = 0;
        cell.fg_g = 0;
        cell.fg_b = 0;
        cell.fg_a = 255;
        self.cells.appendAssumeCapacity(cell.*);
    }

    // Some debug mode safety checks
    if (std.debug.runtime_safety) {
        for (self.cells_bg.items) |cell| assert(cell.mode == .bg);
        for (self.cells.items) |cell| assert(cell.mode != .bg);
    }
}

fn addCursor(self: *OpenGL, screen: *terminal.Screen) void {
    // Add the cursor
    const cell = screen.getCell(
        .active,
        screen.cursor.y,
        screen.cursor.x,
    );

    const color = self.cursor_color orelse terminal.color.RGB{
        .r = 0xFF,
        .g = 0xFF,
        .b = 0xFF,
    };

    self.cells.appendAssumeCapacity(.{
        .mode = GPUCellMode.fromCursor(self.cursor_style),
        .grid_col = @intCast(u16, screen.cursor.x),
        .grid_row = @intCast(u16, screen.cursor.y),
        .grid_width = if (cell.attrs.wide) 2 else 1,
        .fg_r = 0,
        .fg_g = 0,
        .fg_b = 0,
        .fg_a = 0,
        .bg_r = color.r,
        .bg_g = color.g,
        .bg_b = color.b,
        .bg_a = 255,
    });
}

/// Update a single cell. The bool returns whether the cell was updated
/// or not. If the cell wasn't updated, a full refreshCells call is
/// needed.
pub fn updateCell(
    self: *OpenGL,
    selection: ?terminal.Selection,
    screen: *terminal.Screen,
    cell: terminal.Screen.Cell,
    shaper_cell: font.shape.Cell,
    shaper_run: font.shape.TextRun,
    x: usize,
    y: usize,
) !bool {
    const t = trace(@src());
    defer t.end();

    const BgFg = struct {
        /// Background is optional because in un-inverted mode
        /// it may just be equivalent to the default background in
        /// which case we do nothing to save on GPU render time.
        bg: ?terminal.color.RGB,

        /// Fg is always set to some color, though we may not render
        /// any fg if the cell is empty or has no attributes like
        /// underline.
        fg: terminal.color.RGB,
    };

    // The colors for the cell.
    const colors: BgFg = colors: {
        // If we have a selection, then we need to check if this
        // cell is selected.
        // TODO(perf): we can check in advance if selection is in
        // our viewport at all and not run this on every point.
        if (selection) |sel| {
            const screen_point = (terminal.point.Viewport{
                .x = x,
                .y = y,
            }).toScreen(screen);

            // If we are selected, we use the selection colors
            if (sel.contains(screen_point)) {
                break :colors BgFg{
                    .bg = self.selection_background orelse self.foreground,
                    .fg = self.selection_foreground orelse self.background,
                };
            }
        }

        const res: BgFg = if (!cell.attrs.inverse) .{
            // In normal mode, background and fg match the cell. We
            // un-optionalize the fg by defaulting to our fg color.
            .bg = if (cell.attrs.has_bg) cell.bg else null,
            .fg = if (cell.attrs.has_fg) cell.fg else self.foreground,
        } else .{
            // In inverted mode, the background MUST be set to something
            // (is never null) so it is either the fg or default fg. The
            // fg is either the bg or default background.
            .bg = if (cell.attrs.has_fg) cell.fg else self.foreground,
            .fg = if (cell.attrs.has_bg) cell.bg else self.background,
        };
        break :colors res;
    };

    // Calculate the amount of space we need in the cells list.
    const needed = needed: {
        var i: usize = 0;
        if (colors.bg != null) i += 1;
        if (!cell.empty()) i += 1;
        if (cell.attrs.underline != .none) i += 1;
        if (cell.attrs.strikethrough) i += 1;
        break :needed i;
    };
    if (self.cells.items.len + needed > self.cells.capacity) return false;

    // Alpha multiplier
    const alpha: u8 = if (cell.attrs.faint) 175 else 255;

    // If the cell has a background, we always draw it.
    if (colors.bg) |rgb| {
        var mode: GPUCellMode = .bg;

        self.cells_bg.appendAssumeCapacity(.{
            .mode = mode,
            .grid_col = @intCast(u16, x),
            .grid_row = @intCast(u16, y),
            .grid_width = cell.widthLegacy(),
            .glyph_x = 0,
            .glyph_y = 0,
            .glyph_width = 0,
            .glyph_height = 0,
            .glyph_offset_x = 0,
            .glyph_offset_y = 0,
            .fg_r = 0,
            .fg_g = 0,
            .fg_b = 0,
            .fg_a = 0,
            .bg_r = rgb.r,
            .bg_g = rgb.g,
            .bg_b = rgb.b,
            .bg_a = alpha,
        });
    }

    // If the cell has a character, draw it
    if (cell.char > 0) {
        // Render
        const glyph = try self.font_group.renderGlyph(
            self.alloc,
            shaper_run.font_index,
            shaper_cell.glyph_index,
            @floatToInt(u16, @ceil(self.cell_size.height)),
        );

        // If we're rendering a color font, we use the color atlas
        const presentation = try self.font_group.group.presentationFromIndex(shaper_run.font_index);
        const mode: GPUCellMode = switch (presentation) {
            .text => .fg,
            .emoji => .fg_color,
        };

        self.cells.appendAssumeCapacity(.{
            .mode = mode,
            .grid_col = @intCast(u16, x),
            .grid_row = @intCast(u16, y),
            .grid_width = cell.widthLegacy(),
            .glyph_x = glyph.atlas_x,
            .glyph_y = glyph.atlas_y,
            .glyph_width = glyph.width,
            .glyph_height = glyph.height,
            .glyph_offset_x = glyph.offset_x,
            .glyph_offset_y = glyph.offset_y,
            .fg_r = colors.fg.r,
            .fg_g = colors.fg.g,
            .fg_b = colors.fg.b,
            .fg_a = alpha,
            .bg_r = 0,
            .bg_g = 0,
            .bg_b = 0,
            .bg_a = 0,
        });
    }

    if (cell.attrs.underline != .none) {
        const sprite: font.Sprite = switch (cell.attrs.underline) {
            .none => unreachable,
            .single => .underline,
            .double => .underline_double,
            .dotted => .underline_dotted,
            .dashed => .underline_dashed,
            .curly => .underline_curly,
        };

        const underline_glyph = try self.font_group.renderGlyph(
            self.alloc,
            font.sprite_index,
            @enumToInt(sprite),
            null,
        );
        self.cells.appendAssumeCapacity(.{
            .mode = .fg,
            .grid_col = @intCast(u16, x),
            .grid_row = @intCast(u16, y),
            .grid_width = cell.widthLegacy(),
            .glyph_x = underline_glyph.atlas_x,
            .glyph_y = underline_glyph.atlas_y,
            .glyph_width = underline_glyph.width,
            .glyph_height = underline_glyph.height,
            .glyph_offset_x = underline_glyph.offset_x,
            .glyph_offset_y = underline_glyph.offset_y,
            .fg_r = colors.fg.r,
            .fg_g = colors.fg.g,
            .fg_b = colors.fg.b,
            .fg_a = alpha,
            .bg_r = 0,
            .bg_g = 0,
            .bg_b = 0,
            .bg_a = 0,
        });
    }

    if (cell.attrs.strikethrough) {
        self.cells.appendAssumeCapacity(.{
            .mode = .strikethrough,
            .grid_col = @intCast(u16, x),
            .grid_row = @intCast(u16, y),
            .grid_width = cell.widthLegacy(),
            .glyph_x = 0,
            .glyph_y = 0,
            .glyph_width = 0,
            .glyph_height = 0,
            .glyph_offset_x = 0,
            .glyph_offset_y = 0,
            .fg_r = colors.fg.r,
            .fg_g = colors.fg.g,
            .fg_b = colors.fg.b,
            .fg_a = alpha,
            .bg_r = 0,
            .bg_g = 0,
            .bg_b = 0,
            .bg_a = 0,
        });
    }

    return true;
}

/// Returns the grid size for a given screen size. This is safe to call
/// on any thread.
fn gridSize(self: *OpenGL, screen_size: renderer.ScreenSize) renderer.GridSize {
    return renderer.GridSize.init(
        screen_size.subPadding(self.padding.explicit),
        self.cell_size,
    );
}

/// Set the screen size for rendering. This will update the projection
/// used for the shader so that the scaling of the grid is correct.
pub fn setScreenSize(self: *OpenGL, dim: renderer.ScreenSize) !void {
    // Recalculate the rows/columns.
    const grid_size = self.gridSize(dim);

    // Apply our padding
    const padding = self.padding.explicit.add(if (self.padding.balance)
        renderer.Padding.balanced(dim, grid_size, self.cell_size)
    else .{});
    const padded_dim = dim.subPadding(padding);

    log.debug("screen size padded={} screen={} grid={} cell={} padding={}", .{
        padded_dim,
        dim,
        grid_size,
        self.cell_size,
        self.padding.explicit,
    });

    // Update our LRU. We arbitrarily support a certain number of pages here.
    // We also always support a minimum number of caching in case a user
    // is resizing tiny then growing again we can save some of the renders.
    const evicted = try self.cells_lru.resize(self.alloc, @max(80, grid_size.rows * 10));
    if (evicted) |list| {
        for (list) |*value| value.deinit(self.alloc);
        self.alloc.free(list);
    }

    // Update our shaper
    var shape_buf = try self.alloc.alloc(font.shape.Cell, grid_size.columns * 2);
    errdefer self.alloc.free(shape_buf);
    self.alloc.free(self.font_shaper.cell_buf);
    self.font_shaper.cell_buf = shape_buf;

    // Update our viewport for this context to be the entire window.
    // OpenGL works in pixels, so we have to use the pixel size.
    try gl.viewport(
        0,
        0,
        @intCast(i32, dim.width),
        @intCast(i32, dim.height),
    );

    // Update the projection uniform within our shader
    {
        const bind = try self.program.use();
        defer bind.unbind();
        try self.program.setUniform(
            "projection",

            // 2D orthographic projection with the full w/h
            math.ortho2d(
                -1 * padding.left,
                @intToFloat(f32, padded_dim.width) + padding.right,
                @intToFloat(f32, padded_dim.height) + padding.bottom,
                -1 * padding.top,
            ),
        );
    }
}

/// Updates the font texture atlas if it is dirty.
fn flushAtlas(self: *OpenGL) !void {
    {
        const atlas = &self.font_group.atlas_greyscale;
        if (atlas.modified) {
            atlas.modified = false;
            var texbind = try self.texture.bind(.@"2D");
            defer texbind.unbind();

            if (atlas.resized) {
                atlas.resized = false;
                try texbind.image2D(
                    0,
                    .Red,
                    @intCast(c_int, atlas.size),
                    @intCast(c_int, atlas.size),
                    0,
                    .Red,
                    .UnsignedByte,
                    atlas.data.ptr,
                );
            } else {
                try texbind.subImage2D(
                    0,
                    0,
                    0,
                    @intCast(c_int, atlas.size),
                    @intCast(c_int, atlas.size),
                    .Red,
                    .UnsignedByte,
                    atlas.data.ptr,
                );
            }
        }
    }

    {
        const atlas = &self.font_group.atlas_color;
        if (atlas.modified) {
            atlas.modified = false;
            var texbind = try self.texture_color.bind(.@"2D");
            defer texbind.unbind();

            if (atlas.resized) {
                atlas.resized = false;
                try texbind.image2D(
                    0,
                    .RGBA,
                    @intCast(c_int, atlas.size),
                    @intCast(c_int, atlas.size),
                    0,
                    .BGRA,
                    .UnsignedByte,
                    atlas.data.ptr,
                );
            } else {
                try texbind.subImage2D(
                    0,
                    0,
                    0,
                    @intCast(c_int, atlas.size),
                    @intCast(c_int, atlas.size),
                    .BGRA,
                    .UnsignedByte,
                    atlas.data.ptr,
                );
            }
        }
    }
}

/// Render renders the current cell state. This will not modify any of
/// the cells.
pub fn draw(self: *OpenGL) !void {
    const t = trace(@src());
    defer t.end();

    // If we have no cells to render, then we render nothing.
    if (self.cells.items.len == 0) return;

    // Setup our VAO
    try self.vao.bind();
    defer gl.VertexArray.unbind() catch null;

    // Bind EBO
    var ebobind = try self.ebo.bind(.ElementArrayBuffer);
    defer ebobind.unbind();

    // Bind VBO and set data
    var binding = try self.vbo.bind(.ArrayBuffer);
    defer binding.unbind();

    // Bind our textures
    try gl.Texture.active(gl.c.GL_TEXTURE0);
    var texbind = try self.texture.bind(.@"2D");
    defer texbind.unbind();

    try gl.Texture.active(gl.c.GL_TEXTURE1);
    var texbind1 = try self.texture_color.bind(.@"2D");
    defer texbind1.unbind();

    // Pick our shader to use
    const pbind = try self.program.use();
    defer pbind.unbind();

    try self.drawCells(binding, self.cells_bg);
    try self.drawCells(binding, self.cells);
}

/// Loads some set of cell data into our buffer and issues a draw call.
/// This expects all the OpenGL state to be setup.
///
/// Future: when we move to multiple shaders, this will go away and
/// we'll have a draw call per-shader.
fn drawCells(
    self: *OpenGL,
    binding: gl.Buffer.Binding,
    cells: std.ArrayListUnmanaged(GPUCell),
) !void {
    // Todo: get rid of this completely
    self.gl_cells_written = 0;

    // Our allocated buffer on the GPU is smaller than our capacity.
    // We reallocate a new buffer with the full new capacity.
    if (self.gl_cells_size < cells.capacity) {
        log.info("reallocating GPU buffer old={} new={}", .{
            self.gl_cells_size,
            cells.capacity,
        });

        try binding.setDataNullManual(
            @sizeOf(GPUCell) * cells.capacity,
            .StaticDraw,
        );

        self.gl_cells_size = cells.capacity;
        self.gl_cells_written = 0;
    }

    // If we have data to write to the GPU, send it.
    if (self.gl_cells_written < cells.items.len) {
        const data = cells.items[self.gl_cells_written..];
        //log.info("sending {} cells to GPU", .{data.len});
        try binding.setSubData(self.gl_cells_written * @sizeOf(GPUCell), data);

        self.gl_cells_written += data.len;
        assert(data.len > 0);
        assert(self.gl_cells_written <= cells.items.len);
    }

    try gl.drawElementsInstanced(
        gl.c.GL_TRIANGLES,
        6,
        gl.c.GL_UNSIGNED_BYTE,
        cells.items.len,
    );
}
