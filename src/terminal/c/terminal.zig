const std = @import("std");
const testing = std.testing;
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const ZigTerminal = @import("../Terminal.zig");
const Stream = @import("../stream_terminal.zig").Stream;
const ScreenSet = @import("../ScreenSet.zig");
const PageList = @import("../PageList.zig");
const kitty = @import("../kitty/key.zig");
const modes = @import("../modes.zig");
const ReadonlyHandler = @import("../stream_terminal.zig").Handler;
const streampkg = @import("../stream.zig");
const StreamAction = streampkg.Action;
const point = @import("../point.zig");
const size = @import("../size.zig");
const cell_c = @import("cell.zig");
const row_c = @import("row.zig");
const grid_ref_c = @import("grid_ref.zig");
const style_c = @import("style.zig");
const formatter = @import("../formatter.zig");
const Result = @import("result.zig").Result;

const log = std.log.scoped(.terminal_c);

/// Wrapper around ZigTerminal that tracks additional state for C API usage,
/// such as the persistent VT stream needed to handle escape sequences split
/// across multiple vt_write calls.
const TerminalWrapper = struct {
    terminal: *ZigTerminal,
    stream: Stream,
};

/// C: GhosttyTerminal
pub const Terminal = ?*TerminalWrapper;

/// C: GhosttyTerminalOptions
pub const Options = extern struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    max_scrollback: usize,
};

const NewError = error{
    InvalidValue,
    OutOfMemory,
};

pub fn new(
    alloc_: ?*const CAllocator,
    result: *Terminal,
    opts: Options,
) callconv(.c) Result {
    result.* = new_(alloc_, opts) catch |err| {
        result.* = null;
        return switch (err) {
            error.InvalidValue => .invalid_value,
            error.OutOfMemory => .out_of_memory,
        };
    };

    return .success;
}

fn new_(
    alloc_: ?*const CAllocator,
    opts: Options,
) NewError!*TerminalWrapper {
    if (opts.cols == 0 or opts.rows == 0) return error.InvalidValue;

    const alloc = lib_alloc.default(alloc_);
    const t = alloc.create(ZigTerminal) catch
        return error.OutOfMemory;
    errdefer alloc.destroy(t);

    const wrapper = alloc.create(TerminalWrapper) catch
        return error.OutOfMemory;
    errdefer alloc.destroy(wrapper);

    // Setup our terminal
    t.* = try .init(alloc, .{
        .cols = opts.cols,
        .rows = opts.rows,
        .max_scrollback = opts.max_scrollback,
    });
    errdefer t.deinit(alloc);

    // Setup our stream
    const handler: Stream.Handler = t.vtHandler();

    wrapper.* = .{
        .terminal = t,
        .stream = .initAlloc(alloc, handler),
    };

    return wrapper;
}

pub fn vt_write(
    terminal_: Terminal,
    ptr: [*]const u8,
    len: usize,
) callconv(.c) void {
    const wrapper = terminal_ orelse return;
    wrapper.stream.nextSlice(ptr[0..len]);
}

/// C: GhosttyTerminalScrollViewport
pub const ScrollViewport = ZigTerminal.ScrollViewport.C;

pub fn scroll_viewport(
    terminal_: Terminal,
    behavior: ScrollViewport,
) callconv(.c) void {
    const t: *ZigTerminal = (terminal_ orelse return).terminal;
    t.scrollViewport(switch (behavior.tag) {
        .top => .top,
        .bottom => .bottom,
        .delta => .{ .delta = behavior.value.delta },
    });
}

pub fn resize(
    terminal_: Terminal,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) callconv(.c) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    if (cols == 0 or rows == 0) return .invalid_value;
    t.resize(t.gpa(), cols, rows) catch return .out_of_memory;
    return .success;
}

pub fn reset(terminal_: Terminal) callconv(.c) void {
    const t: *ZigTerminal = (terminal_ orelse return).terminal;
    t.fullReset();
}

pub fn mode_get(
    terminal_: Terminal,
    tag: modes.ModeTag.Backing,
    out_value: *bool,
) callconv(.c) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const mode_tag: modes.ModeTag = @bitCast(tag);
    const mode = modes.modeFromInt(mode_tag.value, mode_tag.ansi) orelse return .invalid_value;
    out_value.* = t.modes.get(mode);
    return .success;
}

pub fn mode_set(
    terminal_: Terminal,
    tag: modes.ModeTag.Backing,
    value: bool,
) callconv(.c) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const mode_tag: modes.ModeTag = @bitCast(tag);
    const mode = modes.modeFromInt(mode_tag.value, mode_tag.ansi) orelse return .invalid_value;
    t.modes.set(mode, value);
    return .success;
}

/// C: GhosttyTerminalScreen
pub const TerminalScreen = ScreenSet.Key;

/// C: GhosttyTerminalScrollbar
pub const TerminalScrollbar = PageList.Scrollbar.C;

/// C: GhosttyTerminalData
pub const TerminalData = enum(c_int) {
    invalid = 0,
    cols = 1,
    rows = 2,
    cursor_x = 3,
    cursor_y = 4,
    cursor_pending_wrap = 5,
    active_screen = 6,
    cursor_visible = 7,
    kitty_keyboard_flags = 8,
    scrollbar = 9,
    cursor_style = 10,
    mouse_tracking = 11,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: TerminalData) type {
        return switch (self) {
            .invalid => void,
            .cols, .rows, .cursor_x, .cursor_y => size.CellCountInt,
            .cursor_pending_wrap, .cursor_visible, .mouse_tracking => bool,
            .active_screen => TerminalScreen,
            .kitty_keyboard_flags => u8,
            .scrollbar => TerminalScrollbar,
            .cursor_style => style_c.Style,
        };
    }
};

pub fn get(
    terminal_: Terminal,
    data: TerminalData,
    out: ?*anyopaque,
) callconv(.c) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(TerminalData, @intFromEnum(data)) catch {
            log.warn("terminal_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| getTyped(
            terminal_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

fn getTyped(
    terminal_: Terminal,
    comptime data: TerminalData,
    out: *data.OutType(),
) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    switch (data) {
        .invalid => return .invalid_value,
        .cols => out.* = t.cols,
        .rows => out.* = t.rows,
        .cursor_x => out.* = t.screens.active.cursor.x,
        .cursor_y => out.* = t.screens.active.cursor.y,
        .cursor_pending_wrap => out.* = t.screens.active.cursor.pending_wrap,
        .active_screen => out.* = t.screens.active_key,
        .cursor_visible => out.* = t.modes.get(.cursor_visible),
        .kitty_keyboard_flags => out.* = @as(u8, t.screens.active.kitty_keyboard.current().int()),
        .scrollbar => out.* = t.screens.active.pages.scrollbar().cval(),
        .cursor_style => out.* = .fromStyle(t.screens.active.cursor.style),
        .mouse_tracking => out.* = t.modes.get(.mouse_event_x10) or
            t.modes.get(.mouse_event_normal) or
            t.modes.get(.mouse_event_button) or
            t.modes.get(.mouse_event_any),
    }

    return .success;
}

pub fn grid_ref(
    terminal_: Terminal,
    pt: point.Point.C,
    out_ref: ?*grid_ref_c.CGridRef,
) callconv(.c) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const zig_pt: point.Point = switch (pt.tag) {
        .active => .{ .active = pt.value.active },
        .viewport => .{ .viewport = pt.value.viewport },
        .screen => .{ .screen = pt.value.screen },
        .history => .{ .history = pt.value.history },
    };
    const p = t.screens.active.pages.pin(zig_pt) orelse
        return .invalid_value;
    if (out_ref) |out| out.* = grid_ref_c.CGridRef.fromPin(p);
    return .success;
}

pub fn free(terminal_: Terminal) callconv(.c) void {
    const wrapper = terminal_ orelse return;
    const t = wrapper.terminal;

    wrapper.stream.deinit();
    const alloc = t.gpa();
    t.deinit(alloc);
    alloc.destroy(t);
    alloc.destroy(wrapper);
}

test "new/free" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));

    try testing.expect(t != null);
    free(t);
}

test "new invalid value" {
    var t: Terminal = null;

    try testing.expectEqual(Result.invalid_value, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 0,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    try testing.expect(t == null);

    try testing.expectEqual(Result.invalid_value, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 0,
            .max_scrollback = 10_000,
        },
    ));
    try testing.expect(t == null);
}

test "free null" {
    free(null);
}

test "scroll_viewport" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 5,
            .rows = 2,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    const zt = t.?.terminal;

    // Write "hello" on the first line
    vt_write(t, "hello", 5);

    // Push "hello" into scrollback with 3 newlines (index = ESC D)
    vt_write(t, "\x1bD\x1bD\x1bD", 6);
    {
        // Viewport should be empty now since hello scrolled off
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Scroll to top: "hello" should be visible again
    scroll_viewport(t, .{ .tag = .top, .value = undefined });
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }

    // Scroll to bottom: viewport should be empty again
    scroll_viewport(t, .{ .tag = .bottom, .value = undefined });
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Scroll up by delta to bring "hello" back into view
    scroll_viewport(t, .{ .tag = .delta, .value = .{ .delta = -3 } });
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }
}

test "scroll_viewport null" {
    scroll_viewport(null, .{ .tag = .top, .value = undefined });
}

test "reset" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    vt_write(t, "Hello", 5);
    reset(t);

    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("", str);
}

test "reset null" {
    reset(null);
}

test "resize" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    try testing.expectEqual(Result.success, resize(t, 40, 12));
    try testing.expectEqual(40, t.?.terminal.cols);
    try testing.expectEqual(12, t.?.terminal.rows);
}

test "resize null" {
    try testing.expectEqual(Result.invalid_value, resize(null, 80, 24));
}

test "resize invalid value" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    try testing.expectEqual(Result.invalid_value, resize(t, 0, 24));
    try testing.expectEqual(Result.invalid_value, resize(t, 80, 0));
}

test "mode_get and mode_set" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var value: bool = undefined;

    // DEC mode 25 (cursor_visible) defaults to true
    const cursor_visible: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    try testing.expectEqual(Result.success, mode_get(t, cursor_visible, &value));
    try testing.expect(value);

    // Set it to false
    try testing.expectEqual(Result.success, mode_set(t, cursor_visible, false));
    try testing.expectEqual(Result.success, mode_get(t, cursor_visible, &value));
    try testing.expect(!value);

    // ANSI mode 4 (insert) defaults to false
    const insert: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 4, .ansi = true });
    try testing.expectEqual(Result.success, mode_get(t, insert, &value));
    try testing.expect(!value);

    try testing.expectEqual(Result.success, mode_set(t, insert, true));
    try testing.expectEqual(Result.success, mode_get(t, insert, &value));
    try testing.expect(value);
}

test "mode_get null" {
    var value: bool = undefined;
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    try testing.expectEqual(Result.invalid_value, mode_get(null, tag, &value));
}

test "mode_set null" {
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    try testing.expectEqual(Result.invalid_value, mode_set(null, tag, true));
}

test "mode_get unknown mode" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var value: bool = undefined;
    const unknown: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 9999, .ansi = false });
    try testing.expectEqual(Result.invalid_value, mode_get(t, unknown, &value));
}

test "mode_set unknown mode" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const unknown: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 9999, .ansi = false });
    try testing.expectEqual(Result.invalid_value, mode_set(t, unknown, true));
}

pub fn total_rows(terminal_: Terminal) callconv(.c) usize {
    const t: *ZigTerminal = (terminal_ orelse return 0).terminal;
    return t.screens.active.pages.total_rows;
}

pub fn scrollback_rows(terminal_: Terminal) callconv(.c) usize {
    const t: *ZigTerminal = (terminal_ orelse return 0).terminal;
    return t.screens.active.pages.total_rows - t.rows;
}

test "total_rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer free(t);

    // A fresh terminal should have at least as many rows as the viewport
    try testing.expect(total_rows(t) >= 24);
}

test "total_rows null" {
    try testing.expectEqual(@as(usize, 0), total_rows(null));
}

test "scrollback_rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer free(t);

    // A fresh terminal should have 0 scrollback rows
    try testing.expectEqual(@as(usize, 0), scrollback_rows(t));
}

test "scrollback_rows null" {
    try testing.expectEqual(@as(usize, 0), scrollback_rows(null));
}

/// C: GhosttyTerminalString
pub const String = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

pub fn plain_string(
    terminal_: Terminal,
    result: *String,
) callconv(.c) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const str = t.plainString(t.gpa()) catch
        return .out_of_memory;
    result.* = .{
        .ptr = str.ptr,
        .len = str.len,
    };
    return .success;
}

pub fn plain_string_free(
    terminal_: Terminal,
    str: String,
) callconv(.c) void {
    const t: *ZigTerminal = (terminal_ orelse return).terminal;
    const ptr = str.ptr orelse return;
    t.gpa().free(ptr[0..str.len]);
}

pub fn dump(
    terminal_: Terminal,
    result: *String,
) callconv(.c) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const alloc = t.gpa();
    const tf: formatter.TerminalFormatter = .{
        .terminal = t,
        .opts = .vt,
        .content = .{ .selection = null },
        .extra = .all,
        .pin_map = null,
    };
    var builder: std.Io.Writer.Allocating = .init(alloc);
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

pub fn dump_free(
    terminal_: Terminal,
    str: String,
) callconv(.c) void {
    plain_string_free(terminal_, str);
}

test "plain_string" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    var str: String = undefined;
    try testing.expectEqual(Result.success, plain_string(t, &str));
    defer plain_string_free(t, str);

    const slice = (str.ptr orelse unreachable)[0..str.len];
    // Should contain "Hello" somewhere
    try testing.expect(std.mem.indexOf(u8, slice, "Hello") != null);
}

test "plain_string null" {
    var str: String = undefined;
    try testing.expectEqual(Result.invalid_value, plain_string(null, &str));
}

test "dump" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    var str: String = undefined;
    try testing.expectEqual(Result.success, dump(t, &str));
    defer dump_free(t, str);

    try testing.expect(str.len > 0);
}

test "dump null" {
    var str: String = undefined;
    try testing.expectEqual(Result.invalid_value, dump(null, &str));
}

/// C: GhosttyTerminalWriteResult
pub const WriteResult = extern struct {
    result: Result,
    total_rows_before: usize,
    total_rows_after: usize,
};

pub fn vt_write_ex(
    terminal_: Terminal,
    ptr: [*]const u8,
    len: usize,
) callconv(.c) WriteResult {
    const wrapper = terminal_ orelse return .{
        .result = .invalid_value,
        .total_rows_before = 0,
        .total_rows_after = 0,
    };
    const rows_before = wrapper.terminal.screens.active.pages.total_rows;
    wrapper.stream.nextSlice(ptr[0..len]);
    const rows_after = wrapper.terminal.screens.active.pages.total_rows;
    return .{
        .result = .success,
        .total_rows_before = rows_before,
        .total_rows_after = rows_after,
    };
}

test "vt_write_ex" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer free(t);

    const wr = vt_write_ex(t, "Hello\r\nWorld\r\nThird", 19);
    try testing.expectEqual(Result.success, wr.result);
    try testing.expect(wr.total_rows_after >= wr.total_rows_before);
}

test "vt_write_ex null" {
    const wr = vt_write_ex(null, "x", 1);
    try testing.expectEqual(Result.invalid_value, wr.result);
}

/// C: GhosttySequenceCallback
pub const SequenceCallback = *const fn (c_int, i64, ?*anyopaque) callconv(.c) void;

/// Stream handler that wraps ReadonlyHandler and fires a C callback.
const CallbackHandler = struct {
    inner: ReadonlyHandler,
    callback: ?SequenceCallback = null,
    userdata: ?*anyopaque = null,

    pub fn init(terminal: *ZigTerminal) CallbackHandler {
        return .{ .inner = ReadonlyHandler.init(terminal) };
    }

    pub fn deinit(self: *CallbackHandler) void {
        self.inner.deinit();
    }

    pub fn vt(
        self: *CallbackHandler,
        comptime action: StreamAction.Tag,
        value: StreamAction.Value(action),
    ) void {
        self.inner.vt(action, value);
        if (self.callback) |cb| {
            cb(@intFromEnum(action), 0, self.userdata);
        }
    }
};

const CallbackStream = streampkg.Stream(CallbackHandler);

/// Wrapper that holds the terminal, callback handler, stream, and allocator.
const CallbackWrapper = struct {
    terminal: *ZigTerminal,
    handler: CallbackHandler,
    stream: CallbackStream,
    alloc: std.mem.Allocator,
};

/// Opaque handle for a callback-enabled write session.
/// C: GhosttyTerminalCallbackWriter
pub const CallbackWriter = ?*CallbackWrapper;

pub fn callback_writer_new(
    terminal_: Terminal,
    result: *CallbackWriter,
    callback: SequenceCallback,
    userdata: ?*anyopaque,
) callconv(.c) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const alloc = t.gpa();
    const wrapper = alloc.create(CallbackWrapper) catch
        return .out_of_memory;
    wrapper.terminal = t;
    wrapper.handler = CallbackHandler.init(t);
    wrapper.handler.callback = callback;
    wrapper.handler.userdata = userdata;
    wrapper.stream = CallbackStream.initAlloc(alloc, wrapper.handler);
    wrapper.alloc = alloc;
    result.* = wrapper;
    return .success;
}

pub fn callback_writer_free(writer_: CallbackWriter) callconv(.c) void {
    const wrapper = writer_ orelse return;
    wrapper.stream.deinit();
    wrapper.alloc.destroy(wrapper);
}

pub fn callback_writer_write(
    writer_: CallbackWriter,
    ptr: [*]const u8,
    len: usize,
) callconv(.c) void {
    const wrapper = writer_ orelse return;
    wrapper.stream.nextSlice(ptr[0..len]);
}

test "callback_writer" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer free(t);

    const S = struct {
        var call_count: i32 = 0;
        fn cb(_: c_int, _: i64, _: ?*anyopaque) callconv(.c) void {
            call_count += 1;
        }
    };
    S.call_count = 0;

    var writer: CallbackWriter = null;
    try testing.expectEqual(Result.success, callback_writer_new(t, &writer, &S.cb, null));
    defer callback_writer_free(writer);

    // Write text that triggers VT actions
    callback_writer_write(writer, "A", 1);
    try testing.expect(S.call_count > 0);
}

test "callback_writer null" {
    callback_writer_write(null, "x", 1);
    callback_writer_free(null);
}

test "vt_write" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Hello", str);
}

test "vt_write split escape sequence" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    // Write "Hello" in bold by splitting the CSI bold sequence across two writes.
    // ESC [ 1 m  = bold on, ESC [ 0 m = reset
    // Split ESC from the rest of the CSI sequence.
    vt_write(t, "Hello \x1b", 7);
    vt_write(t, "[1mBold\x1b[0m", 10);

    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    // If the escape sequence leaked, we'd see "[1mBold" as literal text.
    try testing.expectEqualStrings("Hello Bold", str);
}

test "get cols and rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var cols: size.CellCountInt = undefined;
    var rows: size.CellCountInt = undefined;
    try testing.expectEqual(Result.success, get(t, .cols, @ptrCast(&cols)));
    try testing.expectEqual(Result.success, get(t, .rows, @ptrCast(&rows)));
    try testing.expectEqual(80, cols);
    try testing.expectEqual(24, rows);
}

test "get cursor position" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    var x: size.CellCountInt = undefined;
    var y: size.CellCountInt = undefined;
    try testing.expectEqual(Result.success, get(t, .cursor_x, @ptrCast(&x)));
    try testing.expectEqual(Result.success, get(t, .cursor_y, @ptrCast(&y)));
    try testing.expectEqual(5, x);
    try testing.expectEqual(0, y);
}

test "get null" {
    var cols: size.CellCountInt = undefined;
    try testing.expectEqual(Result.invalid_value, get(null, .cols, @ptrCast(&cols)));
}

test "get cursor_visible" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var visible: bool = undefined;
    try testing.expectEqual(Result.success, get(t, .cursor_visible, @ptrCast(&visible)));
    try testing.expect(visible);

    // DEC mode 25 controls cursor visibility
    const cursor_visible_mode: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    try testing.expectEqual(Result.success, mode_set(t, cursor_visible_mode, false));
    try testing.expectEqual(Result.success, get(t, .cursor_visible, @ptrCast(&visible)));
    try testing.expect(!visible);
}

test "get active_screen" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var screen: TerminalScreen = undefined;
    try testing.expectEqual(Result.success, get(t, .active_screen, @ptrCast(&screen)));
    try testing.expectEqual(.primary, screen);
}

test "get kitty_keyboard_flags" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var flags: u8 = undefined;
    try testing.expectEqual(Result.success, get(t, .kitty_keyboard_flags, @ptrCast(&flags)));
    try testing.expectEqual(0, flags);

    // Push kitty flags via VT sequence: CSI > 3 u (push disambiguate | report_events)
    vt_write(t, "\x1b[>3u", 5);

    try testing.expectEqual(Result.success, get(t, .kitty_keyboard_flags, @ptrCast(&flags)));
    try testing.expectEqual(3, flags);
}

test "get mouse_tracking" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var tracking: bool = undefined;
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(!tracking);

    // Enable X10 mouse (DEC mode 9)
    const x10_mode: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 9, .ansi = false });
    try testing.expectEqual(Result.success, mode_set(t, x10_mode, true));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable X10, enable normal mouse (DEC mode 1000)
    try testing.expectEqual(Result.success, mode_set(t, x10_mode, false));
    const normal_mode: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 1000, .ansi = false });
    try testing.expectEqual(Result.success, mode_set(t, normal_mode, true));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable normal, enable button mouse (DEC mode 1002)
    try testing.expectEqual(Result.success, mode_set(t, normal_mode, false));
    const button_mode: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 1002, .ansi = false });
    try testing.expectEqual(Result.success, mode_set(t, button_mode, true));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable button, enable any mouse (DEC mode 1003)
    try testing.expectEqual(Result.success, mode_set(t, button_mode, false));
    const any_mode: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 1003, .ansi = false });
    try testing.expectEqual(Result.success, mode_set(t, any_mode, true));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable all - should be false again
    try testing.expectEqual(Result.success, mode_set(t, any_mode, false));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(!tracking);
}

test "get invalid" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    try testing.expectEqual(Result.invalid_value, get(t, .invalid, null));
}

test "grid_ref" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    var out_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &out_ref));

    // Extract cell from grid ref and verify it contains 'H'
    var out_cell: cell_c.CCell = undefined;
    try testing.expectEqual(Result.success, grid_ref_c.grid_ref_cell(&out_ref, &out_cell));

    var cp: u32 = 0;
    try testing.expectEqual(Result.success, cell_c.get(out_cell, .codepoint, @ptrCast(&cp)));
    try testing.expectEqual(@as(u32, 'H'), cp);
}

test "grid_ref null terminal" {
    var out_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.invalid_value, grid_ref(null, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &out_ref));
}

test "grid_ref out of bounds" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var out_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.invalid_value, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 100, .y = 0 } },
    }, &out_ref));
}
