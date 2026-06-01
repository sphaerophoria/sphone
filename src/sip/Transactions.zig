const std = @import("std");
const sip = @import("../sip.zig");
const sphtud = @import("sphtud");
const Transport = @import("Transport.zig");
const transaction = @import("transaction.zig");
const sip_parse = sip.parse_utils;
const parsem = @import("../parse.zig");

const max_actions = 10;

const TransactionManager = @This();

// FIXME: We might end up nuking this :)
inner: sphtud.util.hash_map.StringHashMap(usize),

const Self = @This();

pub fn init(arena: std.mem.Allocator, expansion: sphtud.util.ExpansionAlloc, typical_transactions: usize, max_transactions: usize) !TransactionManager {
    return .{
        .inner = try .init(
            arena,
            expansion,
            typical_transactions,
            max_transactions,
        ),
    };
}

pub fn register(self: *Self, branch_id: []const u8, id: usize) !void {
    try self.inner.putNoClobber(branch_id, id);
}

pub fn resolve(self: *Self, message: []const u8) !?usize {
    const branch_id = try findBranchId(message);
    return self.inner.get(branch_id);
}

pub fn remove(self: *Self, branch_id: []const u8) void {
    _ = self.inner.remove(branch_id);
}

fn findBranchId(message: []const u8) ![]const u8 {

    const without_start = blk: {
        var tc = parsem.TokenConsumer.init(message);
        _ = sip_parse.startLine(&tc) orelse return error.InvalidMessage;
        break :blk tc.remaining();
    };

    var mp = sip.MessageParser.init(without_start);

    while (try mp.nextHeader()) |h| {
        var tc = sip.parse.TokenConsumer.init(h.val);

        if (h.key == .via) {
            _ = sip.parse_utils.viaParm(&tc) orelse break;
            while (true) {
                const param = sip.parse_utils.viaParams(&tc) orelse break;
                switch (param) {
                    .branch => |br| {
                        return br.data(h.val);
                    },
                    else => {},
                }
            }
        }
    }

    return error.NoBranch;
}
