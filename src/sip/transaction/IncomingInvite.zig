const sip = @import("../../sip.zig");
const std = @import("std");
const Transport = @import("../Transport.zig");
const sip_parse = @import("../parse_utils.zig");
const parse = @import("../../parse.zig");

// FIXME: Obviously more thing will be done here later
from: []const u8,

const IncomingInvite = @This();

const AcceptResult = struct {
    buf: Transport.Buffer,
};

pub fn init(arena: std.mem.Allocator, message: []const u8) !IncomingInvite {
    var tc = parse.TokenConsumer.init(message);

    const request_line = sip_parse.requestLine(&tc) orelse return error.InvalidRequest;

    if (!std.mem.eql(u8, request_line.method.data(message), "INVITE")) return error.InvalidRequest;

    var message_parser = sip.MessageParser.init(tc.remaining());

    var from: []const u8 = &.{};

    while (try message_parser.nextHeader()) |h| {
        switch (h.key) {
            .from => {
                var tc2 = parse.TokenConsumer.init(h.val);
                if (sip_parse.fromSpec(&tc2)) |from_spec| {
                    from = try arena.dupe(u8, from_spec.from.data(h.val));
                }
            },
            else => {},
        }
    }

    return .{
        .from = from,
    };
}

pub fn accept(self: *IncomingInvite) void {
    _ = self;
}
