const std = @import("std");
const testing = std.testing;
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const VtParser = @import("../Parser.zig");
const Result = @import("result.zig").Result;

/// Wrapper that holds the parser, allocator, and cached action data.
const Wrapper = struct {
    parser: VtParser,
    alloc: std.mem.Allocator,

    /// Cached data from the last actions returned by next().
    /// Valid until the next call to next().
    last_csi: ?CSI = null,
    last_esc: ?ESC = null,
    last_dcs: ?DCS = null,
};

/// C: GhosttyParser
pub const Parser = ?*Wrapper;

/// C: GhosttyParserActionTag
pub const ActionTag = enum(c_int) {
    none = 0,
    print = 1,
    execute = 2,
    csi_dispatch = 3,
    esc_dispatch = 4,
    osc_dispatch = 5,
    dcs_hook = 6,
    dcs_put = 7,
    dcs_unhook = 8,
    apc_start = 9,
    apc_put = 10,
    apc_end = 11,
};

/// C: GhosttyParserCSI
pub const CSI = extern struct {
    intermediates: [*]const u8,
    intermediates_len: u8,
    params: [*]const u16,
    params_len: u8,
    final: u8,
    /// Bitmask of separator types. Bit i set means colon, unset means semicolon.
    params_sep: u32,

    comptime {
        if (VtParser.MAX_PARAMS > 32) @compileError("MAX_PARAMS exceeds params_sep u32 capacity");
    }
};

/// C: GhosttyParserESC
pub const ESC = extern struct {
    intermediates: [*]const u8,
    intermediates_len: u8,
    final: u8,
};

/// C: GhosttyParserDCS
pub const DCS = extern struct {
    intermediates: [*]const u8,
    intermediates_len: u8,
    params: [*]const u16,
    params_len: u8,
    final: u8,
};

/// C: GhosttyParserAction
pub const Action = extern struct {
    tag: ActionTag,
    value: u32,
};

/// C: GhosttyParserActions
pub const Actions = extern struct {
    actions: [3]Action,
    count: u8,
};

pub fn new(
    alloc_: ?*const CAllocator,
    result: *Parser,
) callconv(.c) Result {
    const alloc = lib_alloc.default(alloc_);
    const ptr = alloc.create(Wrapper) catch
        return .out_of_memory;
    ptr.* = .{
        .parser = VtParser.init(),
        .alloc = alloc,
    };
    result.* = ptr;
    return .success;
}

pub fn free(parser_: Parser) callconv(.c) void {
    const wrapper = parser_ orelse return;
    wrapper.parser.deinit();
    wrapper.alloc.destroy(wrapper);
}

pub fn reset(parser_: Parser) callconv(.c) void {
    const wrapper = parser_ orelse return;
    wrapper.parser.deinit();
    wrapper.parser = VtParser.init();
    wrapper.last_csi = null;
    wrapper.last_esc = null;
    wrapper.last_dcs = null;
}

pub fn next(parser_: Parser, byte: u8, result: *Actions) callconv(.c) void {
    const wrapper = parser_ orelse {
        result.count = 0;
        return;
    };
    const raw_actions = wrapper.parser.next(byte);

    wrapper.last_csi = null;
    wrapper.last_esc = null;
    wrapper.last_dcs = null;

    var count: u8 = 0;
    for (raw_actions) |maybe_action| {
        if (maybe_action) |action| {
            result.actions[count] = convertAction(wrapper, action);
            count += 1;
        }
    }
    result.count = count;
}

fn convertAction(wrapper: *Wrapper, action: VtParser.Action) Action {
    return switch (action) {
        .print => |cp| .{ .tag = .print, .value = @intCast(cp) },
        .execute => |b| .{ .tag = .execute, .value = b },
        .csi_dispatch => |c| csi: {
            wrapper.last_csi = .{
                .intermediates = c.intermediates.ptr,
                .intermediates_len = @intCast(c.intermediates.len),
                .params = c.params.ptr,
                .params_len = @intCast(c.params.len),
                .final = c.final,
                .params_sep = @intCast(c.params_sep.mask),
            };
            break :csi .{ .tag = .csi_dispatch, .value = c.final };
        },
        .esc_dispatch => |e| esc: {
            wrapper.last_esc = .{
                .intermediates = e.intermediates.ptr,
                .intermediates_len = @intCast(e.intermediates.len),
                .final = e.final,
            };
            break :esc .{ .tag = .esc_dispatch, .value = e.final };
        },
        .osc_dispatch => .{ .tag = .osc_dispatch, .value = 0 },
        .dcs_hook => |d| dcs: {
            wrapper.last_dcs = .{
                .intermediates = d.intermediates.ptr,
                .intermediates_len = @intCast(d.intermediates.len),
                .params = d.params.ptr,
                .params_len = @intCast(d.params.len),
                .final = d.final,
            };
            break :dcs .{ .tag = .dcs_hook, .value = d.final };
        },
        .dcs_put => |b| .{ .tag = .dcs_put, .value = b },
        .dcs_unhook => .{ .tag = .dcs_unhook, .value = 0 },
        .apc_start => .{ .tag = .apc_start, .value = 0 },
        .apc_put => |b| .{ .tag = .apc_put, .value = b },
        .apc_end => .{ .tag = .apc_end, .value = 0 },
    };
}

pub fn csi(parser_: Parser, result: *CSI) callconv(.c) bool {
    const wrapper = parser_ orelse return false;
    const cached = wrapper.last_csi orelse return false;
    result.* = cached;
    return true;
}

pub fn esc(parser_: Parser, result: *ESC) callconv(.c) bool {
    const wrapper = parser_ orelse return false;
    const cached = wrapper.last_esc orelse return false;
    result.* = cached;
    return true;
}

pub fn dcs(parser_: Parser, result: *DCS) callconv(.c) bool {
    const wrapper = parser_ orelse return false;
    const cached = wrapper.last_dcs orelse return false;
    result.* = cached;
    return true;
}

test "alloc and free" {
    var p: Parser = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &p,
    ));
    free(p);
}

test "parse print action" {
    var p: Parser = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &p,
    ));
    defer free(p);

    var actions: Actions = undefined;
    next(p, 'A', &actions);
    try testing.expectEqual(@as(u8, 1), actions.count);
    try testing.expectEqual(ActionTag.print, actions.actions[0].tag);
    try testing.expectEqual(@as(u32, 'A'), actions.actions[0].value);
}

test "parse execute action" {
    var p: Parser = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &p,
    ));
    defer free(p);

    var actions: Actions = undefined;
    next(p, 0x0A, &actions);
    try testing.expectEqual(@as(u8, 1), actions.count);
    try testing.expectEqual(ActionTag.execute, actions.actions[0].tag);
    try testing.expectEqual(@as(u32, 0x0A), actions.actions[0].value);
}

test "parse CSI sequence" {
    var p: Parser = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &p,
    ));
    defer free(p);

    var actions: Actions = undefined;

    // ESC [ 1 ; 2 H (cursor position)
    next(p, 0x1B, &actions);
    next(p, '[', &actions);
    next(p, '1', &actions);
    next(p, ';', &actions);
    next(p, '2', &actions);
    next(p, 'H', &actions);

    var found_csi = false;
    for (0..actions.count) |i| {
        if (actions.actions[i].tag == .csi_dispatch) {
            found_csi = true;
            try testing.expectEqual(@as(u32, 'H'), actions.actions[i].value);
        }
    }
    try testing.expect(found_csi);

    var csi_data: CSI = undefined;
    try testing.expect(csi(p, &csi_data));
    try testing.expectEqual(@as(u8, 'H'), csi_data.final);
    try testing.expectEqual(@as(u8, 2), csi_data.params_len);
    try testing.expectEqual(@as(u16, 1), csi_data.params[0]);
    try testing.expectEqual(@as(u16, 2), csi_data.params[1]);
}

test "parse ESC sequence" {
    var p: Parser = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &p,
    ));
    defer free(p);

    var actions: Actions = undefined;

    // ESC D (index down)
    next(p, 0x1B, &actions);
    next(p, 'D', &actions);

    var found_esc = false;
    for (0..actions.count) |i| {
        if (actions.actions[i].tag == .esc_dispatch) {
            found_esc = true;
        }
    }
    try testing.expect(found_esc);

    var esc_data: ESC = undefined;
    try testing.expect(esc(p, &esc_data));
    try testing.expectEqual(@as(u8, 'D'), esc_data.final);
}

test "reset clears state" {
    var p: Parser = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &p,
    ));
    defer free(p);

    var actions: Actions = undefined;

    // Start a CSI sequence but don't finish it
    next(p, 0x1B, &actions);
    next(p, '[', &actions);
    next(p, '1', &actions);

    reset(p);

    // Regular character should print normally
    next(p, 'A', &actions);
    try testing.expectEqual(@as(u8, 1), actions.count);
    try testing.expectEqual(ActionTag.print, actions.actions[0].tag);
}

test "null parser safety" {
    var actions: Actions = undefined;
    next(null, 'A', &actions);
    try testing.expectEqual(@as(u8, 0), actions.count);
    free(null);
    reset(null);
    var csi_data: CSI = undefined;
    try testing.expect(!csi(null, &csi_data));
    var esc_data: ESC = undefined;
    try testing.expect(!esc(null, &esc_data));
    var dcs_data: DCS = undefined;
    try testing.expect(!dcs(null, &dcs_data));
}
