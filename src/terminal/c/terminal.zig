const std = @import("std");
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const Terminal = @import("../Terminal.zig");
const ReadonlyHandler = @import("../stream_readonly.zig").Handler;
const ReadonlyStream = @import("../stream_readonly.zig").Stream;
const Result = @import("result.zig").Result;

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
