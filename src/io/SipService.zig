const std = @import("std");
const sphtud = @import("sphtud");
const sip = @import("../sip.zig");
const Transactions = sip.Transactions;
const TransportService = @import("TransportService.zig");
const parse = @import("../parse.zig");
const sip_parse = @import("../sip/parse_utils.zig");

const SipService = @This();
const OutgoingInvite = @import("OutgoingInvite.zig");

alloc: *sphtud.alloc.Sphalloc,
rand: std.Random,
tx_lookup: Transactions,
transactions: sphtud.util.ObjectPool(Transaction, usize),
transport: TransportService,
timer: *sphtud.io.TimerService,
loop: *sphtud.io.Loop,
start_timeout_id: usize,

pub const IncomingInvite = struct {
    alloc: *sphtud.alloc.Sphalloc,
    invite: sip.transaction.IncomingInvite,

    pub fn accept(self: *IncomingInvite, parent: *SipService) !void {
        _ = self;
        _ = parent;
    }
};
const Transaction = union(enum) {
    outgoing_invite: OutgoingInvite,
    incoming_invite: IncomingInvite,
};

pub const TransactionHandle = usize;

const typical_transactions = 32;
// In what world is a single guy sending 1024 messages at once... then 8x for safety
const max_transactions = 1024;

pub fn init(
    alloc: *sphtud.alloc.Sphalloc,
    timer: *sphtud.io.TimerService,
    rand: std.Random,
    spawner: *sphtud.io.TcpSpawner,
    loop: *sphtud.io.Loop,
    comptime ids: Ids,
) !SipService {
    const tx_lookup = try Transactions.init(
        alloc.arena(),
        alloc.expansion(),
        typical_transactions,
        max_transactions,
    );

    const transport_alloc = try alloc.makeSubAlloc("transport service");
    const transport = try TransportService.init(
        transport_alloc.general(),
        spawner,
        loop,
        ids.transport,
    );

    return .{
        .alloc = alloc,
        .rand = rand,
        .tx_lookup = tx_lookup,
        .transactions = try .init(
            alloc.arena(),
            alloc.expansion(),
            typical_transactions,
            max_transactions,
        ),
        .transport = transport,
        .loop = loop,
        .timer = timer,
        .start_timeout_id = ids.timeout.start,
    };
}

pub fn startInvite(self: *SipService, params: sip.transaction.OutgoingInviteParams) !void {
    var message_buf: [4096]u8 = undefined;

    const tx_alloc = try self.alloc.makeSubAlloc("invite");
    errdefer tx_alloc.deinit();

    const res = try sip.transaction.makeOutgoingInviteReq(
        tx_alloc.arena(),
        &message_buf,
        self.rand,
        params,
    );

    const transaction = try self.transactions.acquire(self.alloc.expansion());
    transaction.val.* = .{
        .outgoing_invite = .{
            .alloc = tx_alloc,
            .tx_handle = transaction.handle,
            .timer_handle = null,
            .invite = res.invite,
        },
    };

    const storage = &transaction.val.outgoing_invite;
    try self.tx_lookup.register(storage.invite.branch_id, transaction.handle);
    try self.transport.sendMessage(params.uri, res.to_send);
}

pub const ServiceResult = union(enum) {
    invite_accepted: *OutgoingInvite,
    invite: *IncomingInvite,
};

pub fn service(self: *SipService, id: usize, comptime ids: Ids) !?ServiceResult {
    std.debug.print("sip service\n", .{});
    switch (id) {
        ids.timeout.start...ids.timeout.end => {
            const handle = id - ids.timeout.start;
            const tx = self.transactions.get(handle);
            switch (tx.*) {
                .outgoing_invite => |*invite| try invite.onTimeout(self),
                .incoming_invite => unreachable,
            }
            return null;
        },
        ids.transport.total.start...ids.transport.total.end => {
            while (true) {
                std.debug.print("transport service\n", .{});
                const te = try self.transport.service(id, ids.transport) orelse return null;
                std.debug.print("transport service return\n", .{});

                // Want guy who
                //  * Parses any sip message
                //  * breaks into request/response
                //  * frames the data

                switch (te) {
                    .tcp => |tcp_e| while (true) {
                        const frame = frameTcp(tcp_e.r) catch |e| {
                            // FIXME: Check if this is cause the socket closed or cause of blocking io
                            if (e == error.ReadFailed) return null;
                            return e;
                        };
                        if (try self.dispatchMessage(frame, tcp_e.handle, ids)) |r| return r;
                    },
                    .udp => |udp_e| {
                        if (try self.dispatchMessage(udp_e.data, null, ids)) |r| return r;
                    },
                }
            }
        },
        else => unreachable,
    }
}

fn dispatchMessage(self: *SipService, message: []const u8, transport_handle: ?TransportService.Handle, comptime ids: Ids) !?ServiceResult {
    var tc = parse.TokenConsumer.init(message);

    if (try self.tx_lookup.resolve(message)) |transaction_id| {
        const transaction = self.transactions.get(transaction_id);

        switch (transaction.*) {
            .outgoing_invite => |*invite| {
                const result = try invite.onMessage(self, message, transport_handle, transaction_id + ids.timeout.start);
                switch (result) {
                    .accepted => return .{
                        .invite_accepted = invite,
                    },
                    .none => return null,
                }
            },
            .incoming_invite => unreachable,
        }
    } else {
        const start_line = sip_parse.startLine(&tc) orelse return error.InvalidMessage;

        const request_line = switch (start_line) {
            .request => |r| r,
            .status => return error.MissingTransaction,
        };

        // FIXME: We're probably supposed to do something interesting here
        const method = std.meta.stringToEnum(sip.Method, request_line.method.data(message)) orelse return error.UnsupportedMethod;

        switch (method) {
            .INVITE => {
                const tx = try self.transactions.acquire(self.alloc.expansion());
                errdefer self.transactions.release(self.alloc.expansion(), tx.handle);

                const alloc = try self.alloc.makeSubAlloc("incoming invite");
                errdefer alloc.deinit();

                tx.val.* = .{
                    .incoming_invite = .{
                        .alloc = alloc,
                        .invite = try sip.transaction.IncomingInvite.init(alloc.arena(), message),
                    },
                };

                return .{
                    .invite = &tx.val.incoming_invite,
                };
            },
            .ACK => {
                return error.InvalidAck;
            },
        }
    }
}

pub const Ids = struct {
    timeout: sphtud.io.IdAlloc.Range,
    transport: TransportService.Ids,
    total: sphtud.io.IdAlloc.Range,

    pub fn init(alloc: *sphtud.io.IdAlloc) Ids {
        const start = alloc.mark();

        return .{
            .timeout = alloc.allocMany(max_transactions),
            .transport = .init(alloc),
            .total = start.range(),
        };
    }
};

fn frameTcp(r: *std.Io.Reader) ![]const u8 {
    // consume until \r\n\r\n
    while (true) {
        const idx = std.mem.find(u8, r.buffered(), "\r\n\r\n") orelse {
            if (r.bufferedLen() == r.buffer.len) {
                return error.OutOfMemory;
            }
            try r.fillMore();
            continue;
        };

        const header = r.buffered()[0..idx];
        var tc = parse.TokenConsumer.init(header);
        _ = sip_parse.startLine(&tc) orelse return error.InvalidMessage;

        var mp = sip.MessageParser.init(tc.remaining());
        while (try mp.nextHeader()) |h| switch (h.key) {
            .content_length => {
                const len = try std.fmt.parseInt(usize, h.val, 10);
                return r.take(idx + 4 + len);
            },
            else => {},
        };

        return r.take(idx + 4);
    }
}
