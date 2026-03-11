const std = @import("std");
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const Terminal = @import("../Terminal.zig");
const ReadonlyHandler = @import("../stream_readonly.zig").Handler;
const ReadonlyStream = @import("../stream_readonly.zig").Stream;
const Result = @import("result.zig").Result;
const pagepkg = @import("../page.zig");
const stylepkg = @import("../style.zig");
const point = @import("../point.zig");
const PageList = @import("../PageList.zig");

/// Wrapper that holds the terminal, stream handler, stream, and allocator.
/// All four fields live in one heap-allocated struct so pointers stay stable
/// (Handler holds *Terminal).
const Wrapper = struct {
    terminal: Terminal,
    handler: ReadonlyHandler,
    stream: ReadonlyStream,
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
    wrapper.handler = ReadonlyHandler.init(&wrapper.terminal);
    wrapper.stream = ReadonlyStream.initAlloc(alloc, wrapper.handler);
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
