const std = @import("std");
const posix = std.posix;
const Result = @import("result.zig").Result;

const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
});

const TIOCGWINSZ = switch (@import("builtin").os.tag) {
    .macos => 1074295912,
    else => c.TIOCGWINSZ,
};

/// Saved termios state keyed by fd.
var saved_termios: std.AutoHashMapUnmanaged(c_int, c.termios) = .empty;
var saved_mutex: std.Thread.Mutex = .{};

pub fn enable_raw_mode(fd: c_int) callconv(.c) Result {
    saved_mutex.lock();
    defer saved_mutex.unlock();

    var attrs: c.termios = undefined;
    if (c.tcgetattr(fd, &attrs) != 0) return .io_error;

    // Save original before modifying.
    saved_termios.put(std.heap.c_allocator, fd, attrs) catch return .out_of_memory;

    // Input: disable break interrupt, parity check, strip, CR->NL, XON/XOFF.
    attrs.c_iflag &= ~@as(c.tcflag_t, c.BRKINT | c.INPCK | c.ISTRIP | c.ICRNL | c.IXON);
    attrs.c_iflag |= c.IUTF8;
    // Output: disable post-processing.
    attrs.c_oflag &= ~@as(c.tcflag_t, c.OPOST);
    // Local: disable echo, canonical mode, signal generation, extended input.
    attrs.c_lflag &= ~@as(c.tcflag_t, c.ECHO | c.ICANON | c.ISIG | c.IEXTEN);
    // Read returns after 1 byte, no timeout.
    attrs.c_cc[c.VMIN] = 1;
    attrs.c_cc[c.VTIME] = 0;

    if (c.tcsetattr(fd, c.TCSANOW, &attrs) != 0) return .io_error;
    return .success;
}

pub fn disable_raw_mode(fd: c_int) callconv(.c) Result {
    saved_mutex.lock();
    defer saved_mutex.unlock();

    const original = saved_termios.get(fd) orelse return .io_error;
    if (c.tcsetattr(fd, c.TCSANOW, &original) != 0) return .io_error;
    _ = saved_termios.remove(fd);
    return .success;
}

pub fn get_size(fd: c_int, cols: *u16, rows: *u16) callconv(.c) Result {
    var ws: c.winsize = undefined;
    if (c.ioctl(fd, TIOCGWINSZ, @intFromPtr(&ws)) < 0) return .io_error;
    cols.* = ws.ws_col;
    rows.* = ws.ws_row;
    return .success;
}

test "enable and disable raw mode on pty" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) return error.SkipZigTest;

    const pty_c = @cImport({
        @cInclude("pty.h");
    });

    var master: c_int = undefined;
    var slave: c_int = undefined;
    if (pty_c.openpty(&master, &slave, null, null, null) < 0) return error.SkipZigTest;
    defer {
        _ = posix.system.close(master);
        _ = posix.system.close(slave);
    }

    const testing = std.testing;

    try testing.expectEqual(Result.success, enable_raw_mode(slave));

    var attrs: c.termios = undefined;
    try testing.expect(c.tcgetattr(slave, &attrs) == 0);
    try testing.expectEqual(@as(c.tcflag_t, 0), attrs.c_lflag & c.ECHO);
    try testing.expectEqual(@as(c.tcflag_t, 0), attrs.c_lflag & c.ICANON);

    try testing.expectEqual(Result.success, disable_raw_mode(slave));

    try testing.expect(c.tcgetattr(slave, &attrs) == 0);
    try testing.expect((attrs.c_lflag & c.ECHO) != 0);
}

test "get terminal size on pty" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) return error.SkipZigTest;

    const pty_c = @cImport({
        @cInclude("pty.h");
        @cInclude("sys/ioctl.h");
    });

    const TIOCSWINSZ_C = switch (builtin.os.tag) {
        .macos => 2148037735,
        else => pty_c.TIOCSWINSZ,
    };

    var master: c_int = undefined;
    var slave: c_int = undefined;
    if (pty_c.openpty(&master, &slave, null, null, null) < 0) return error.SkipZigTest;
    defer {
        _ = posix.system.close(master);
        _ = posix.system.close(slave);
    }

    var ws = pty_c.winsize{
        .ws_col = 132,
        .ws_row = 43,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    if (pty_c.ioctl(master, TIOCSWINSZ_C, @intFromPtr(&ws)) < 0) return error.SkipZigTest;

    const testing = std.testing;
    var cols: u16 = 0;
    var rows: u16 = 0;
    try testing.expectEqual(Result.success, get_size(slave, &cols, &rows));
    try testing.expectEqual(@as(u16, 132), cols);
    try testing.expectEqual(@as(u16, 43), rows);
}
