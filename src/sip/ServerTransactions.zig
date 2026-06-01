const sphtud = @import("sphtud");
const parse = @import("../parse.zig");
const std = @import("std");
const sip = @import("../sip.zig");
const sip_parse = @import("parse_utils.zig");
const Transport = @import("Transport.zig");

const Self = @This();

alloc: *sphtud.alloc.Sphalloc,
pool: sphtud.util.ObjectPool(Invite, Handle),

pub fn init(alloc: *sphtud.alloc.Sphalloc, typical: usize, max: usize) !Self {
    return .{
        .alloc = alloc,
        .pool = try .init(
            alloc.arena(),
            alloc.expansion(),
            typical,
            max,
        ),
    };
}

pub const Handle = struct {
    id: usize,

    pub fn toIdx(self: Handle) usize {
        return self.id;
    }

    pub fn fromIdx(idx: usize) Handle {
        return .{ .id = idx };
    }
};

pub const Invite = struct {
    alloc: *sphtud.alloc.Sphalloc,
    // Dodge 0 sized struct
    caller: []const u8,

    pub const AcceptResult = struct {
        to_send: Transport.Buffer,
        dest: []const u8,
    };

    pub fn accept(self: *Invite) !AcceptResult {
        _ = self;
        unreachable;
        //SIP/2.0 200 OK
        //Via: SIP/2.0/TCP 127.0.0.1:5060;received=127.0.0.1;branch=z9hG4bKee6030c935bf52f6a0dec70771121830
        //Call-ID: 51f4c980592b3e7aaca0581dcbe402c7
        //From: <sip:mick@127.0.0.1>
        //To: <sip:mick@127.0.0.1>;tag=rx6hYHKN.t7wQQA.bxV1O5t8qyOHivUs
        //CSeq: 47819 INVITE
        //Contact: <sip:mick-terminal@127.0.0.1:5062;transport=TCP>
        //Allow: PRACK, INVITE, ACK, BYE, CANCEL, UPDATE, INFO, SUBSCRIBE, NOTIFY, REFER, MESSAGE, OPTIONS
        //Supported: replaces, 100rel, timer, norefersub
        //Content-Type: application/sdp
        //Content-Length:   262
    }
};

pub const InviteHandle = struct {
    handle: Handle,
    invite: *Invite,
};

pub const MessageResponse = union(enum) {
    INVITE: InviteHandle,
};

pub fn onMessage(self: *Self, message: []const u8) !MessageResponse {
    var tc = parse.TokenConsumer.init(message);
    const request_line = sip_parse.requestLine(&tc) orelse return error.InvalidRequest;

    const method = std.meta.stringToEnum(sip.Method, request_line.method.data(message)) orelse return error.Unsupported;
    _ = parse.crlf(&tc);

    switch (method) {
        .INVITE => {
            const invite = try self.pool.acquire(self.alloc.expansion());

            const tx_alloc = try self.alloc.makeSubAlloc("server invite");
            errdefer tx_alloc.deinit();

            var message_parser = sip.MessageParser.init(tc.remaining());

            var from: []const u8 = &.{};

            while (try message_parser.nextHeader()) |h| {
                switch (h.key) {
                    .from => {
                        var tc2 = parse.TokenConsumer.init(h.val);
                        const from_spec = sip_parse.fromSpec(&tc2);
                        from = try tx_alloc.arena().dupe(u8, from_spec.from.data(h.val));
                    },
                    else => {},
                }
            }

            invite.val.* = .{
                .alloc = tx_alloc,
                .caller = from,
            };

            return .{
                .INVITE = .{
                    .handle = invite.handle,
                    .invite = invite.val,
                },
            };
        },
        else => return error.Unsupported,
    }
}
