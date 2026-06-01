const sphtud = @import("sphtud");
const std = @import("std");
const sip = @import("../../sip.zig");
const Transport = @import("../Transport.zig");

// copy in Call-ID, From, top Via, and Request-URI from original req
// copy from response To
// copy cseq number from original req, but method ACK

// FIXME: Stash any errors here
negotiated_sdp: []const u8,
call_id: []const u8, // generate with globally unique num
branch_id: []const u8,
sent_by: []const u8,
request_uri: []const u8,
from: []const u8,
cseq: u16,

state: union(enum) {
    wait_ok,
    received_ok: std.Io.Timestamp,
},

const OutgoingInvite = @This();

// This is supposed to be an estimate of the RTT, but for now we just
// hardcode the default
//
// RFC 3261 17.1.1.1
const t1_ms = 500;

pub const MessageAction = union(enum) {
    schedule_timeout: std.Io.Duration,
    send: Transport.Buffer,
    // Tell the caller to look at us
    accepted,
};

pub const TimeoutAction = enum {
    none,
    finish,
};

pub fn onMessage(
    self: *OutgoingInvite,
    message: []const u8,
    now: std.Io.Timestamp,
    out_buf: []u8,
    action_buf: []MessageAction,
) ![]const MessageAction {
    // Parse
    // Check if we are finished
    var ret = std.ArrayList(MessageAction).initBuffer(action_buf);

    var rp = try sip.ResponseParser.init(message);

    var to: ?[]const u8 = null;

    while (try rp.message_parser.nextHeader()) |h| {
        if (h.key == .to) {
            to = h.val;
        } else if (h.key == .content_type) {
            if (!std.mem.eql(u8, h.val, "application/sdp")) {
                return error.UnexpectedType;
            }
        }
    }

    const received_ok = rp.response_code == 200;

    std.debug.print("INVITE res\n{s}\n", .{message});

    if (received_ok) {
        var notify_accepted = false;
        switch (self.state) {
            .wait_ok => {
                self.state = .{ .received_ok = now };
                // RFC 3261 13.2.2.4 says that we need to keep responding for 64 * T1
                ret.appendBounded(.{ .schedule_timeout = .fromMilliseconds(t1_ms * 64) }) catch unreachable;
                self.negotiated_sdp = rp.message_parser.readBody();
                notify_accepted = true;
            },
            .received_ok => {},
        }

        var w = std.Io.Writer.fixed(out_buf);

        var cseq_buf: [1024]u8 = undefined;
        const cseq_s = std.fmt.bufPrint(&cseq_buf, "{d} ACK", .{self.cseq}) catch unreachable;

        // RFC 3261 17.1.1.3
        //   copy in Call-ID, From, top Via, and Request-URI from original req
        //   copy from response To
        //   copy cseq number from original req, but method ACK
        const req = try sip.ClientRequestWriter.init(.{
            .method = .ACK,
            .uri = self.request_uri,
            .call_id = self.call_id,
            .from = self.from,
            .via = .{
                .sent_by = self.sent_by,
                .branch = self.branch_id,
            },
            .to = to orelse return error.InvalidRequest,
            .cseq = cseq_s,
        }, &w);

        try req.writeHeader("Content-Length", "0");
        ret.appendBounded(.{ .send = try req.finish("") }) catch unreachable;

        if (notify_accepted) {
            ret.appendBounded(.accepted) catch unreachable;
        }
    }

    return ret.items;
}

pub fn onTimeout(
    self: *OutgoingInvite,
    now: std.Io.Timestamp,
) !TimeoutAction {
    switch (self.state) {
        .received_ok => |t| {
            if (t.durationTo(now).toMilliseconds() >= t1_ms * 64) {
                return .finish;
            }
        },
        else => return error.UnexpectedTimeout,
    }

    return .none;
}
