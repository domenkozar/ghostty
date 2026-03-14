const std = @import("std");
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const Terminal = @import("../Terminal.zig");
const ReadonlyHandler = @import("../stream_readonly.zig").Handler;
const streampkg = @import("../stream.zig");
const Action = streampkg.Action;
const Result = @import("result.zig").Result;
const pagepkg = @import("../page.zig");
const stylepkg = @import("../style.zig");
const point = @import("../point.zig");
const PageList = @import("../PageList.zig");
const modespkg = @import("../modes.zig");
const formatter = @import("../formatter.zig");

/// Maximum size of a captured raw escape sequence.
/// Sequences longer than this are truncated in the callback.
const MAX_SEQ_BUF = 4096;

/// C: GhosttySequenceCallback
pub const SequenceCallback = *const fn (c_int, i64, [*]const u8, usize, ?*anyopaque) callconv(.c) void;

/// Handler that wraps ReadonlyHandler with optional sequence callback support.
const CallbackHandler = struct {
    inner: ReadonlyHandler,
    callback: ?SequenceCallback = null,
    userdata: ?*anyopaque = null,

    /// Buffer for accumulating raw bytes of the current escape sequence.
    seq_buf: [MAX_SEQ_BUF]u8 = undefined,
    /// Number of valid bytes in seq_buf.
    seq_len: usize = 0,
    /// True when we are inside an escape sequence (parser not in ground).
    in_sequence: bool = false,

    pub fn init(terminal: *Terminal) CallbackHandler {
        return .{ .inner = ReadonlyHandler.init(terminal) };
    }

    pub fn deinit(self: *CallbackHandler) void {
        self.inner.deinit();
    }

    /// Called by the stream for each input byte during escape sequences.
    /// Accumulates raw bytes into seq_buf for the callback.
    pub fn rawByte(self: *CallbackHandler, byte: u8) void {
        if (self.in_sequence) {
            if (self.seq_len < MAX_SEQ_BUF) {
                self.seq_buf[self.seq_len] = byte;
                self.seq_len += 1;
            }
        }
    }

    /// Start accumulating a new sequence (called when ESC is seen).
    pub fn seqStart(self: *CallbackHandler) void {
        self.in_sequence = true;
        // The ESC byte itself is part of the sequence.
        self.seq_buf[0] = 0x1B;
        self.seq_len = 1;
    }

    /// End sequence accumulation (called when parser returns to ground).
    pub fn seqEnd(self: *CallbackHandler) void {
        self.in_sequence = false;
    }

    pub fn vt(
        self: *CallbackHandler,
        comptime action: Action.Tag,
        value: Action.Value(action),
    ) !void {
        try self.inner.vt(action, value);
        if (self.callback) |cb| {
            const c_value: i64 = comptime_value: {
                // Mode number (DEC private mode or ANSI mode).
                if (action == .set_mode or
                    action == .reset_mode or
                    action == .save_mode or
                    action == .restore_mode or
                    action == .request_mode)
                    break :comptime_value @intCast(@intFromEnum(value.mode));

                // Kitty keyboard: flags for push/set variants, pop count for pop.
                if (action == .kitty_keyboard_push or
                    action == .kitty_keyboard_set or
                    action == .kitty_keyboard_set_or or
                    action == .kitty_keyboard_set_not)
                    break :comptime_value @intCast(@as(u5, @bitCast(value.flags)));

                if (action == .kitty_keyboard_pop)
                    break :comptime_value @intCast(value);

                // Size report style (XTWINOPS): enum index.
                if (action == .size_report)
                    break :comptime_value @intCast(@intFromEnum(value));

                // Modify key format (XTMODIFYOTHERKEYS): enum index.
                if (action == .modify_key_format)
                    break :comptime_value @intCast(@intFromEnum(value));

                break :comptime_value 0;
            };
            const raw_len = if (self.in_sequence) self.seq_len else 0;
            cb(@intFromEnum(action), c_value, &self.seq_buf, raw_len, self.userdata);
        }
    }
};

const CallbackStream = streampkg.Stream(CallbackHandler);

/// Wrapper that holds the terminal, stream handler, stream, and allocator.
/// All four fields live in one heap-allocated struct so pointers stay stable
/// (Handler holds *Terminal).
const Wrapper = struct {
    terminal: Terminal,
    handler: CallbackHandler,
    stream: CallbackStream,
    alloc: std.mem.Allocator,
};

/// Opaque handle to a terminal instance.
/// C: GhosttyTerminal
pub const Handle = ?*Wrapper;

/// A heap-allocated string returned by plain_string.
/// C: GhosttyTerminalString
pub const String = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

pub fn new(
    alloc_: ?*const CAllocator,
    cols: u16,
    rows: u16,
    result: *Handle,
) callconv(.c) Result {
    const alloc = lib_alloc.default(alloc_);
    const wrapper = alloc.create(Wrapper) catch
        return .out_of_memory;
    wrapper.terminal = Terminal.init(alloc, .{
        .cols = cols,
        .rows = rows,
    }) catch {
        alloc.destroy(wrapper);
        return .out_of_memory;
    };
    wrapper.handler = CallbackHandler.init(&wrapper.terminal);
    wrapper.stream = CallbackStream.initAlloc(alloc, wrapper.handler);
    wrapper.alloc = alloc;
    result.* = wrapper;
    return .success;
}

pub fn free(handle: Handle) callconv(.c) void {
    const wrapper = handle orelse return;
    wrapper.stream.deinit();
    wrapper.terminal.deinit(wrapper.alloc);
    wrapper.alloc.destroy(wrapper);
}

pub fn full_reset(handle: Handle) callconv(.c) void {
    const wrapper = handle orelse return;
    wrapper.terminal.fullReset();
}

pub fn write(
    handle: Handle,
    data: [*]const u8,
    len: usize,
) callconv(.c) Result {
    const wrapper = handle orelse return .success;
    wrapper.stream.nextSlice(data[0..len]) catch
        return .out_of_memory;
    return .success;
}

pub fn get_size(
    handle: Handle,
    out_cols: *u16,
    out_rows: *u16,
) callconv(.c) void {
    const wrapper = handle orelse {
        out_cols.* = 0;
        out_rows.* = 0;
        return;
    };
    out_cols.* = wrapper.terminal.cols;
    out_rows.* = wrapper.terminal.rows;
}

pub fn get_cursor_pos(
    handle: Handle,
    out_x: *usize,
    out_y: *usize,
) callconv(.c) void {
    const wrapper = handle orelse {
        out_x.* = 0;
        out_y.* = 0;
        return;
    };
    out_x.* = wrapper.terminal.screens.active.cursor.x;
    out_y.* = wrapper.terminal.screens.active.cursor.y;
}

pub fn resize(
    handle: Handle,
    cols: u16,
    rows: u16,
) callconv(.c) Result {
    const wrapper = handle orelse return .success;
    wrapper.terminal.resize(wrapper.alloc, cols, rows) catch
        return .out_of_memory;
    return .success;
}

pub fn plain_string(
    handle: Handle,
    result: *String,
) callconv(.c) Result {
    const wrapper = handle orelse return .success;
    const str = wrapper.terminal.plainString(wrapper.alloc) catch
        return .out_of_memory;
    result.* = .{
        .ptr = str.ptr,
        .len = str.len,
    };
    return .success;
}

pub fn plain_string_free(
    handle: Handle,
    str: String,
) callconv(.c) void {
    const wrapper = handle orelse return;
    const ptr = str.ptr orelse return;
    wrapper.alloc.free(ptr[0..str.len]);
}

// ---------------------------------------------------------------------------
// Extended constructor / write / dump
// ---------------------------------------------------------------------------

pub fn new_ex(
    alloc_: ?*const CAllocator,
    cols: u16,
    rows: u16,
    max_scrollback: usize,
    result: *Handle,
) callconv(.c) Result {
    const alloc = lib_alloc.default(alloc_);
    const wrapper = alloc.create(Wrapper) catch
        return .out_of_memory;
    wrapper.terminal = Terminal.init(alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = max_scrollback,
    }) catch {
        alloc.destroy(wrapper);
        return .out_of_memory;
    };
    wrapper.handler = CallbackHandler.init(&wrapper.terminal);
    wrapper.stream = CallbackStream.initAlloc(alloc, wrapper.handler);
    wrapper.alloc = alloc;
    result.* = wrapper;
    return .success;
}

/// C: GhosttyTerminalWriteResult
pub const WriteResult = extern struct {
    result: Result,
    total_rows_before: usize,
    total_rows_after: usize,
};

pub fn write_ex(
    handle: Handle,
    data: [*]const u8,
    len: usize,
) callconv(.c) WriteResult {
    const wrapper = handle orelse return .{
        .result = .success,
        .total_rows_before = 0,
        .total_rows_after = 0,
    };
    const rows_before = wrapper.terminal.screens.active.pages.total_rows;
    wrapper.stream.nextSlice(data[0..len]) catch
        return .{
            .result = .out_of_memory,
            .total_rows_before = rows_before,
            .total_rows_after = rows_before,
        };
    const rows_after = wrapper.terminal.screens.active.pages.total_rows;
    return .{
        .result = .success,
        .total_rows_before = rows_before,
        .total_rows_after = rows_after,
    };
}

pub fn dump(
    handle: Handle,
    result: *String,
) callconv(.c) Result {
    const wrapper = handle orelse return .success;
    const tf: formatter.TerminalFormatter = .{
        .terminal = &wrapper.terminal,
        .opts = .vt,
        .content = .{ .selection = null },
        .extra = .all,
        .pin_map = null,
    };
    var builder: std.Io.Writer.Allocating = .init(wrapper.alloc);
    tf.format(&builder.writer) catch {
        builder.deinit();
        return .out_of_memory;
    };
    const slice = builder.toOwnedSlice() catch {
        builder.deinit();
        return .out_of_memory;
    };
    result.* = .{
        .ptr = slice.ptr,
        .len = slice.len,
    };
    return .success;
}

// ---------------------------------------------------------------------------
// Sequence event callbacks
// ---------------------------------------------------------------------------

pub fn set_sequence_callback(
    handle: Handle,
    callback: ?SequenceCallback,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const wrapper = handle orelse return;
    // Must set on the stream's handler (which owns the copy used during parsing),
    // not on wrapper.handler (which is the init-time copy).
    wrapper.stream.handler.callback = callback;
    wrapper.stream.handler.userdata = userdata;
}

// ---------------------------------------------------------------------------
// Terminal state queries
// ---------------------------------------------------------------------------

pub fn get_cursor_visible(handle: Handle) callconv(.c) bool {
    const wrapper = handle orelse return false;
    return wrapper.terminal.modes.get(.cursor_visible);
}

pub fn is_mode_set(handle: Handle, mode_raw: u16) callconv(.c) bool {
    const wrapper = handle orelse return false;
    const mode = modespkg.modeFromInt(
        @as(u15, @truncate(mode_raw)),
        mode_raw & 0x8000 != 0,
    ) orelse return false;
    return wrapper.terminal.modes.get(mode);
}

pub fn is_alt_screen(handle: Handle) callconv(.c) bool {
    const wrapper = handle orelse return false;
    return wrapper.terminal.screens.active_key == .alternate;
}

pub fn kitty_keyboard_depth(handle: Handle) callconv(.c) u32 {
    const wrapper = handle orelse return 0;
    return @intCast(wrapper.terminal.screens.active.kitty_keyboard.idx);
}

// ---------------------------------------------------------------------------
// Row / cell / style / grapheme access (screen coordinates)
// ---------------------------------------------------------------------------

/// C: GhosttyTerminalRow
pub const RowData = extern struct {
    wrap: bool,
    wrap_continuation: bool,
    styled: bool,
    hyperlink: bool,
    semantic_prompt: u8, // 0=none, 1=prompt, 2=continuation
};

/// C: GhosttyTerminalCell
pub const CellData = extern struct {
    codepoint: u32,
    style_id: u16,
    content_tag: u8, // 0=codepoint, 1=grapheme, 2=bg_palette, 3=bg_rgb
    wide: u8, // 0=narrow, 1=wide, 2=spacer_tail, 3=spacer_head
    bg_palette: u8,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    has_grapheme: bool,
    is_hyperlink: bool,
    semantic_content: u8, // 0=output, 1=input, 2=prompt
    is_protected: bool,
};

/// C: GhosttyTerminalColor
pub const StyleColor = extern struct {
    tag: u8, // 0=none, 1=palette, 2=rgb
    palette: u8,
    r: u8,
    g: u8,
    b: u8,
};

/// C: GhosttyTerminalStyle
pub const StyleData = extern struct {
    fg: StyleColor,
    bg: StyleColor,
    underline_color: StyleColor,
    underline: u8, // 0=none, 1=single, 2=double, 3=curly, 4=dotted, 5=dashed
    bold: bool,
    italic: bool,
    faint: bool,
    blink: bool,
    inverse: bool,
    invisible: bool,
    strikethrough: bool,
    overline: bool,
};

fn convertStyleColor(c: stylepkg.Style.Color) StyleColor {
    return switch (c) {
        .none => .{ .tag = 0, .palette = 0, .r = 0, .g = 0, .b = 0 },
        .palette => |p| .{ .tag = 1, .palette = p, .r = 0, .g = 0, .b = 0 },
        .rgb => |rgb| .{ .tag = 2, .palette = 0, .r = rgb.r, .g = rgb.g, .b = rgb.b },
    };
}

fn screenPin(t: *Terminal, screen_y: usize) ?PageList.Pin {
    return t.screens.active.pages.pin(.{ .screen = .{
        .x = 0,
        .y = std.math.cast(u32, screen_y) orelse return null,
    } });
}

pub fn scrollback_rows(handle: Handle) callconv(.c) usize {
    const wrapper = handle orelse return 0;
    const pages = &wrapper.terminal.screens.active.pages;
    return pages.total_rows -| pages.rows;
}

pub fn total_rows(handle: Handle) callconv(.c) usize {
    const wrapper = handle orelse return 0;
    return wrapper.terminal.screens.active.pages.total_rows;
}

pub fn get_row(
    handle: Handle,
    screen_y: usize,
    out: *RowData,
) callconv(.c) void {
    const wrapper = handle orelse {
        out.* = std.mem.zeroes(RowData);
        return;
    };
    const p = screenPin(&wrapper.terminal, screen_y) orelse {
        out.* = std.mem.zeroes(RowData);
        return;
    };
    const row = p.rowAndCell().row;
    out.* = .{
        .wrap = row.wrap,
        .wrap_continuation = row.wrap_continuation,
        .styled = row.styled,
        .hyperlink = row.hyperlink,
        .semantic_prompt = @intFromEnum(row.semantic_prompt),
    };
}

pub fn get_cells(
    handle: Handle,
    screen_y: usize,
    cells_buf: [*]CellData,
    max_cells: usize,
) callconv(.c) usize {
    const wrapper = handle orelse return 0;
    const p = screenPin(&wrapper.terminal, screen_y) orelse return 0;
    const row = p.rowAndCell().row;
    const page = &p.node.data;
    const cells = page.getCells(row);
    const count = @min(cells.len, max_cells);

    for (0..count) |i| {
        const cell = cells[i];
        cells_buf[i] = .{
            .codepoint = switch (cell.content_tag) {
                .codepoint, .codepoint_grapheme => cell.content.codepoint,
                .bg_color_palette, .bg_color_rgb => 0,
            },
            .style_id = cell.style_id,
            .content_tag = @intFromEnum(cell.content_tag),
            .wide = @intFromEnum(cell.wide),
            .bg_palette = if (cell.content_tag == .bg_color_palette) cell.content.color_palette else 0,
            .bg_r = if (cell.content_tag == .bg_color_rgb) cell.content.color_rgb.r else 0,
            .bg_g = if (cell.content_tag == .bg_color_rgb) cell.content.color_rgb.g else 0,
            .bg_b = if (cell.content_tag == .bg_color_rgb) cell.content.color_rgb.b else 0,
            .has_grapheme = cell.content_tag == .codepoint_grapheme,
            .is_hyperlink = cell.hyperlink,
            .semantic_content = @intFromEnum(cell.semantic_content),
            .is_protected = cell.protected,
        };
    }
    return count;
}

pub fn get_style(
    handle: Handle,
    screen_y: usize,
    style_id: u16,
    out: *StyleData,
) callconv(.c) Result {
    const wrapper = handle orelse {
        out.* = std.mem.zeroes(StyleData);
        return .success;
    };
    const p = screenPin(&wrapper.terminal, screen_y) orelse {
        out.* = std.mem.zeroes(StyleData);
        return .invalid_value;
    };
    const page = &p.node.data;

    // Style ID 0 is always the default style.
    if (style_id == stylepkg.default_id) {
        out.* = std.mem.zeroes(StyleData);
        return .success;
    }

    const s = page.styles.get(page.memory, style_id).*;
    out.* = .{
        .fg = convertStyleColor(s.fg_color),
        .bg = convertStyleColor(s.bg_color),
        .underline_color = convertStyleColor(s.underline_color),
        .underline = @intFromEnum(s.flags.underline),
        .bold = s.flags.bold,
        .italic = s.flags.italic,
        .faint = s.flags.faint,
        .blink = s.flags.blink,
        .inverse = s.flags.inverse,
        .invisible = s.flags.invisible,
        .strikethrough = s.flags.strikethrough,
        .overline = s.flags.overline,
    };
    return .success;
}

pub fn get_grapheme(
    handle: Handle,
    screen_y: usize,
    x: u16,
    codepoints: [*]u32,
    max: usize,
) callconv(.c) usize {
    const wrapper = handle orelse return 0;
    const p = screenPin(&wrapper.terminal, screen_y) orelse return 0;
    const page = &p.node.data;
    const row = p.rowAndCell().row;
    const cells = page.getCells(row);
    if (x >= cells.len) return 0;

    const cell = &cells[x];
    var count: usize = 0;

    // First codepoint from the cell itself.
    const cp = cell.codepoint();
    if (cp != 0 and count < max) {
        codepoints[count] = cp;
        count += 1;
    }

    // Extra codepoints from the grapheme map.
    if (cell.content_tag == .codepoint_grapheme) {
        if (page.lookupGrapheme(cell)) |extra| {
            for (extra) |ecp| {
                if (count >= max) break;
                codepoints[count] = ecp;
                count += 1;
            }
        }
    }

    return count;
}

test "alloc and free" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        80,
        24,
        &h,
    ));
    free(h);
}

test "write and plain_string" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        80,
        24,
        &h,
    ));
    defer free(h);

    const text = "Hello";
    try std.testing.expectEqual(Result.success, write(h, text.ptr, text.len));

    var str: String = undefined;
    try std.testing.expectEqual(Result.success, plain_string(h, &str));
    defer plain_string_free(h, str);

    const slice = (str.ptr orelse unreachable)[0..str.len];
    try std.testing.expectEqualStrings("Hello", std.mem.trimRight(u8, slice, "\n"));
}

test "cursor position" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        80,
        24,
        &h,
    ));
    defer free(h);

    const text = "AB";
    try std.testing.expectEqual(Result.success, write(h, text.ptr, text.len));

    var x: usize = undefined;
    var y: usize = undefined;
    get_cursor_pos(h, &x, &y);
    try std.testing.expectEqual(@as(usize, 2), x);
    try std.testing.expectEqual(@as(usize, 0), y);
}

test "resize" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        80,
        24,
        &h,
    ));
    defer free(h);

    try std.testing.expectEqual(Result.success, resize(h, 40, 10));

    var cols: u16 = undefined;
    var rows: u16 = undefined;
    get_size(h, &cols, &rows);
    try std.testing.expectEqual(@as(u16, 40), cols);
    try std.testing.expectEqual(@as(u16, 10), rows);
}

test "full_reset" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        80,
        24,
        &h,
    ));
    defer free(h);

    const text = "Hello";
    try std.testing.expectEqual(Result.success, write(h, text.ptr, text.len));

    full_reset(h);

    var str: String = undefined;
    try std.testing.expectEqual(Result.success, plain_string(h, &str));
    defer plain_string_free(h, str);

    // After reset, content should be empty (just newlines)
    const slice = (str.ptr orelse unreachable)[0..str.len];
    const trimmed = std.mem.trimRight(u8, slice, "\n");
    try std.testing.expectEqual(@as(usize, 0), trimmed.len);
}

test "null handle safety" {
    free(null);
    full_reset(null);

    try std.testing.expectEqual(Result.success, write(null, "x".ptr, 1));

    var cols: u16 = undefined;
    var rows: u16 = undefined;
    get_size(null, &cols, &rows);

    var x: usize = undefined;
    var y: usize = undefined;
    get_cursor_pos(null, &x, &y);

    try std.testing.expectEqual(Result.success, resize(null, 40, 10));

    var str: String = undefined;
    try std.testing.expectEqual(Result.success, plain_string(null, &str));

    plain_string_free(null, .{ .ptr = null, .len = 0 });
}

test "VT escape processing" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        80,
        24,
        &h,
    ));
    defer free(h);

    // CSI 5;10H moves cursor to row 5, col 10 (1-indexed in VT, 0-indexed internal)
    const seq = "\x1b[5;10H";
    try std.testing.expectEqual(Result.success, write(h, seq.ptr, seq.len));

    var x: usize = undefined;
    var y: usize = undefined;
    get_cursor_pos(h, &x, &y);
    try std.testing.expectEqual(@as(usize, 9), x); // col 10 -> 0-indexed 9
    try std.testing.expectEqual(@as(usize, 4), y); // row 5 -> 0-indexed 4
}

test "get_row and get_cells" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        10,
        5,
        &h,
    ));
    defer free(h);

    const text = "Hi";
    try std.testing.expectEqual(Result.success, write(h, text.ptr, text.len));

    // Row 0 in screen coords (active area starts at scrollback_rows offset)
    const sb = scrollback_rows(h);

    var row: RowData = undefined;
    get_row(h, sb, &row);
    try std.testing.expect(!row.wrap);

    var cells: [10]CellData = undefined;
    const count = get_cells(h, sb, &cells, 10);
    try std.testing.expectEqual(@as(usize, 10), count);
    try std.testing.expectEqual(@as(u32, 'H'), cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 'i'), cells[1].codepoint);
    try std.testing.expectEqual(@as(u32, 0), cells[2].codepoint);
}

test "get_style default" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        10,
        5,
        &h,
    ));
    defer free(h);

    const text = "A";
    try std.testing.expectEqual(Result.success, write(h, text.ptr, text.len));

    const sb = scrollback_rows(h);
    var cells: [10]CellData = undefined;
    _ = get_cells(h, sb, &cells, 10);

    var style: StyleData = undefined;
    try std.testing.expectEqual(Result.success, get_style(h, sb, cells[0].style_id, &style));
    try std.testing.expect(!style.bold);
    try std.testing.expect(!style.italic);
}

test "get_style bold" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        10,
        5,
        &h,
    ));
    defer free(h);

    // ESC[1m turns on bold, then write text
    const text = "\x1b[1mB";
    try std.testing.expectEqual(Result.success, write(h, text.ptr, text.len));

    const sb = scrollback_rows(h);
    var cells: [10]CellData = undefined;
    _ = get_cells(h, sb, &cells, 10);

    var style: StyleData = undefined;
    try std.testing.expectEqual(Result.success, get_style(h, sb, cells[0].style_id, &style));
    try std.testing.expect(style.bold);
}

test "scrollback_rows and total_rows" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        10,
        5,
        &h,
    ));
    defer free(h);

    // Fresh terminal: no scrollback
    try std.testing.expectEqual(@as(usize, 0), scrollback_rows(h));
    try std.testing.expectEqual(@as(usize, 5), total_rows(h));
}

test "get_cells null safety" {
    try std.testing.expectEqual(@as(usize, 0), get_cells(null, 0, undefined, 0));
    try std.testing.expectEqual(@as(usize, 0), scrollback_rows(null));
    try std.testing.expectEqual(@as(usize, 0), total_rows(null));

    var row: RowData = undefined;
    get_row(null, 0, &row);

    var style: StyleData = undefined;
    try std.testing.expectEqual(Result.success, get_style(null, 0, 0, &style));

    try std.testing.expectEqual(@as(usize, 0), get_grapheme(null, 0, 0, undefined, 0));
}

test "sequence callback" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        10,
        5,
        &h,
    ));
    defer free(h);

    const S = struct {
        var call_count: usize = 0;
        fn callback(_: c_int, _: i64, _: [*]const u8, _: usize, _: ?*anyopaque) callconv(.c) void {
            call_count += 1;
        }
    };

    S.call_count = 0;
    set_sequence_callback(h, S.callback, null);

    const text = "AB";
    try std.testing.expectEqual(Result.success, write(h, text.ptr, text.len));
    try std.testing.expect(S.call_count >= 2); // at least 2 print actions

    // Unset callback
    set_sequence_callback(h, null, null);
    S.call_count = 0;
    try std.testing.expectEqual(Result.success, write(h, text.ptr, text.len));
    try std.testing.expectEqual(@as(usize, 0), S.call_count);
}

test "sequence callback null safety" {
    set_sequence_callback(null, null, null);
}

test "sequence callback value for set_mode" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        80,
        24,
        &h,
    ));
    defer free(h);

    const Ctx = struct {
        target: c_int,
        found_value: i64 = -1,
        fn callback(action_tag: c_int, value: i64, _: [*]const u8, _: usize, ud: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            if (action_tag == self.target) self.found_value = value;
        }
    };
    var ctx = Ctx{ .target = @intFromEnum(Action.Tag.set_mode) };

    set_sequence_callback(h, Ctx.callback, @ptrCast(&ctx));

    // CSI ? 2004 h -- set bracketed paste (no cascading side effects)
    const seq = "\x1b[?2004h";
    try std.testing.expectEqual(Result.success, write(h, seq.ptr, seq.len));
    try std.testing.expectEqual(@as(i64, 2004), ctx.found_value);
}

test "sequence callback value for size_report" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        80,
        24,
        &h,
    ));
    defer free(h);

    const Ctx = struct {
        target: c_int,
        found_value: i64 = -1,
        fn callback(action_tag: c_int, value: i64, _: [*]const u8, _: usize, ud: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            if (action_tag == self.target) self.found_value = value;
        }
    };
    var ctx = Ctx{ .target = @intFromEnum(Action.Tag.size_report) };

    set_sequence_callback(h, Ctx.callback, @ptrCast(&ctx));

    // CSI 18 t -- text area size query (csi_18_t = enum index 2)
    const seq18 = "\x1b[18t";
    try std.testing.expectEqual(Result.success, write(h, seq18.ptr, seq18.len));
    try std.testing.expectEqual(@as(i64, 2), ctx.found_value);

    // CSI 14 t -- pixel size report (csi_14_t = enum index 0)
    ctx.found_value = -1;
    const seq14 = "\x1b[14t";
    try std.testing.expectEqual(Result.success, write(h, seq14.ptr, seq14.len));
    try std.testing.expectEqual(@as(i64, 0), ctx.found_value);
}

test "sequence callback value for modify_key_format" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        80,
        24,
        &h,
    ));
    defer free(h);

    const Ctx = struct {
        target: c_int,
        found_value: i64 = -1,
        fn callback(action_tag: c_int, value: i64, _: [*]const u8, _: usize, ud: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            if (action_tag == self.target) self.found_value = value;
        }
    };
    var ctx = Ctx{ .target = @intFromEnum(Action.Tag.modify_key_format) };

    set_sequence_callback(h, Ctx.callback, @ptrCast(&ctx));

    // CSI > m -- reset to legacy (enum index 0)
    const reset = "\x1b[>m";
    try std.testing.expectEqual(Result.success, write(h, reset.ptr, reset.len));
    try std.testing.expectEqual(@as(i64, 0), ctx.found_value);

    // CSI > 4 m -- other_keys_none (enum index 3)
    ctx.found_value = -1;
    const set4 = "\x1b[>4m";
    try std.testing.expectEqual(Result.success, write(h, set4.ptr, set4.len));
    try std.testing.expectEqual(@as(i64, 3), ctx.found_value);
}

test "sequence callback raw bytes" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        80,
        24,
        &h,
    ));
    defer free(h);

    const S = struct {
        var raw_capture: [64]u8 = undefined;
        var raw_len: usize = 0;
        fn callback(_: c_int, _: i64, raw: [*]const u8, len: usize, _: ?*anyopaque) callconv(.c) void {
            if (len > 0 and len <= 64) {
                @memcpy(raw_capture[0..len], raw[0..len]);
            }
            raw_len = len;
        }
    };

    set_sequence_callback(h, S.callback, null);

    // CSI ? 25 l — hide cursor
    const seq = "\x1b[?25l";
    try std.testing.expectEqual(Result.success, write(h, seq.ptr, seq.len));
    try std.testing.expectEqualStrings(seq, S.raw_capture[0..S.raw_len]);

    // Print a regular character after the escape sequence.
    // raw_len must be 0 for non-escape actions.
    S.raw_len = 99;
    const print_ch = "A";
    try std.testing.expectEqual(Result.success, write(h, print_ch.ptr, print_ch.len));
    try std.testing.expectEqual(@as(usize, 0), S.raw_len);
}

test "cursor visible" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        80,
        24,
        &h,
    ));
    defer free(h);

    // Cursor is visible by default
    try std.testing.expect(get_cursor_visible(h));

    // CSI ? 25 l — hide cursor
    const hide = "\x1b[?25l";
    try std.testing.expectEqual(Result.success, write(h, hide.ptr, hide.len));
    try std.testing.expect(!get_cursor_visible(h));

    // CSI ? 25 h — show cursor
    const show = "\x1b[?25h";
    try std.testing.expectEqual(Result.success, write(h, show.ptr, show.len));
    try std.testing.expect(get_cursor_visible(h));
}

test "is_mode_set" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        80,
        24,
        &h,
    ));
    defer free(h);

    // Bracketed paste off by default
    try std.testing.expect(!is_mode_set(h, 2004));

    // CSI ? 2004 h — enable bracketed paste
    const enable = "\x1b[?2004h";
    try std.testing.expectEqual(Result.success, write(h, enable.ptr, enable.len));
    try std.testing.expect(is_mode_set(h, 2004));

    // CSI ? 2004 l — disable bracketed paste
    const disable = "\x1b[?2004l";
    try std.testing.expectEqual(Result.success, write(h, disable.ptr, disable.len));
    try std.testing.expect(!is_mode_set(h, 2004));

    // Unknown mode returns false
    try std.testing.expect(!is_mode_set(h, 9999));
}

test "is_alt_screen" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        80,
        24,
        &h,
    ));
    defer free(h);

    try std.testing.expect(!is_alt_screen(h));

    // CSI ? 1049 h — enter alt screen
    const enter = "\x1b[?1049h";
    try std.testing.expectEqual(Result.success, write(h, enter.ptr, enter.len));
    try std.testing.expect(is_alt_screen(h));

    // CSI ? 1049 l — leave alt screen
    const leave = "\x1b[?1049l";
    try std.testing.expectEqual(Result.success, write(h, leave.ptr, leave.len));
    try std.testing.expect(!is_alt_screen(h));
}

test "kitty keyboard depth" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        80,
        24,
        &h,
    ));
    defer free(h);

    try std.testing.expectEqual(@as(u32, 0), kitty_keyboard_depth(h));

    // CSI > 1 u — push kitty keyboard flags
    const push = "\x1b[>1u";
    try std.testing.expectEqual(Result.success, write(h, push.ptr, push.len));
    try std.testing.expectEqual(@as(u32, 1), kitty_keyboard_depth(h));

    // CSI < u — pop
    const pop = "\x1b[<u";
    try std.testing.expectEqual(Result.success, write(h, pop.ptr, pop.len));
    try std.testing.expectEqual(@as(u32, 0), kitty_keyboard_depth(h));
}

test "state query null safety" {
    try std.testing.expect(!get_cursor_visible(null));
    try std.testing.expect(!is_mode_set(null, 2004));
    try std.testing.expect(!is_alt_screen(null));
    try std.testing.expectEqual(@as(u32, 0), kitty_keyboard_depth(null));
}

test "new_ex with scrollback" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new_ex(
        &lib_alloc.test_allocator,
        80,
        24,
        500,
        &h,
    ));
    defer free(h);

    const text = "Hello";
    try std.testing.expectEqual(Result.success, write(h, text.ptr, text.len));
}

test "write_ex row tracking" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        10,
        3,
        &h,
    ));
    defer free(h);

    // Write enough lines to push content into scrollback.
    const text = "line1\r\nline2\r\nline3\r\nline4\r\nline5\r\n";
    const res = write_ex(h, text.ptr, text.len);
    try std.testing.expectEqual(Result.success, res.result);
    // After writing 5 lines into a 3-row terminal, total_rows should have grown.
    try std.testing.expect(res.total_rows_after >= res.total_rows_before);
}

test "write_ex null safety" {
    const res = write_ex(null, "x".ptr, 1);
    try std.testing.expectEqual(Result.success, res.result);
    try std.testing.expectEqual(@as(usize, 0), res.total_rows_before);
    try std.testing.expectEqual(@as(usize, 0), res.total_rows_after);
}

test "dump" {
    var h: Handle = undefined;
    try std.testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        80,
        24,
        &h,
    ));
    defer free(h);

    // Write styled text.
    const text = "\x1b[1;31mHello\x1b[0m";
    try std.testing.expectEqual(Result.success, write(h, text.ptr, text.len));

    var str: String = undefined;
    try std.testing.expectEqual(Result.success, dump(h, &str));
    defer plain_string_free(h, str);

    const slice = (str.ptr orelse unreachable)[0..str.len];
    // The dump should contain the text and SGR sequences.
    try std.testing.expect(slice.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, slice, "Hello") != null);
}

test "dump null safety" {
    var str: String = undefined;
    try std.testing.expectEqual(Result.success, dump(null, &str));
}
