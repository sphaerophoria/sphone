const std = @import("std");
const sphtud = @import("sphtud");
const sip = @import("../sip.zig");
const Transactions = sip.Transactions;
const ServerTransactions = sip.ServerTransactions;
const TransportService = @import("TransportService.zig");
const parse = @import("../parse.zig");
const sip_parse = @import("../sip/parse_utils.zig");

const SipService = @This();

expansion: sphtud.util.ExpansionAlloc,
transactions: Transactions,
server_transactions: ServerTransactions,
transport: TransportService,
timer: *sphtud.io.TimerService,
loop: *sphtud.io.Loop,
start_timeout_id: usize,
incoming_call: ?ServerTransactions.InviteHandle,
incoming_call_event: usize,

extra: sphtud.util.LinearMap(Extra),

const Extra = struct {
    timer_handle: ?sphtud.io.TimerService.TimerHandle,
    callback_id: usize,
    completion: CompletionStatus,
};

const CompletionStatus = struct {
    val: u8,

    const io_finished = 1;
    const user_finished = 2;
    const can_be_freed = 3;

    pub const init = CompletionStatus{ .val = 0 };

    fn finishUser(self: *CompletionStatus) void {
        self.val |= user_finished;
    }

    fn finishIo(self: *CompletionStatus) void {
        self.val |= io_finished;
    }

    fn isFullyComplete(self: *CompletionStatus) bool {
        return self.val == can_be_freed;
    }
};
pub const Handle = Transactions.Handle;

const typical_transactions = 32;
// In what world is a single guy sending 1024 messages at once... then 8x for safety
const max_transactions = 1024;

pub fn init(
    alloc: *sphtud.alloc.Sphalloc,
    timer: *sphtud.io.TimerService,
    rand: std.Random,
    spawner: *sphtud.io.TcpSpawner,
    loop: *sphtud.io.Loop,
    incoming_call_event: usize,
    comptime ids: Ids,
) !SipService {
    const transactions = try Transactions.init(
        try alloc.makeSubAlloc("transaction manager"),
        rand,
        typical_transactions,
        max_transactions,
    );

    const server_tx_alloc = try alloc.makeSubAlloc("server transaction manager");

    const server_transactions = try ServerTransactions.init(
        server_tx_alloc,
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
        .expansion = alloc.expansion(),
        .transactions = transactions,
        .server_transactions = server_transactions,
        .transport = transport,
        .loop = loop,
        .timer = timer,
        .extra = try .init(
            alloc.arena(),
            alloc.expansion(),
            typical_transactions,
            max_transactions,
        ),
        .start_timeout_id = ids.timeout.start,
        .incoming_call = null,
        .incoming_call_event = incoming_call_event,
    };
}

pub fn startInvite(self: *SipService, params: Transactions.InviteParams, callback_id: usize) !Transactions.InviteHandle {
    var message_buf: [4096]u8 = undefined;
    const res = try self.transactions.startInvite(params, &message_buf);
    const extra = try self.extra.acquire(self.expansion, res.handle.handle.id);
    extra.* = .{
        .timer_handle = null,
        .callback_id = callback_id,
        .completion = .init,
    };

    try self.transport.sendMessage(res.dest, res.to_send);

    return res.handle;
}

pub fn acceptIncoming(self: *SipService) !void {
    const incoming_call = self.incoming_call orelse return;
    const res = try incoming_call.invite.accept();

    try self.transport.sendMessage(res.dest, res.to_send);
}

pub fn release(self: *SipService, handle: Transactions.Handle) void {
    const extra = self.extra.getPtr(handle.id);
    extra.completion.finishUser();
    if (extra.completion.isFullyComplete()) {
        self.deinitItem(handle);
    }
}

fn deinitItem(self: *SipService, handle: Transactions.Handle) void {
    const extra = self.extra.getPtr(handle.id);
    if (extra.timer_handle) |h| {
        self.timer.remove(h);
    }

    self.loop.clearEvents(self.start_timeout_id + handle.id);

    self.extra.release(handle.id);
    self.transactions.deinitRequest(handle);
}

pub fn service(self: *SipService, id: usize, comptime ids: Ids) !void {
    std.debug.print("sip service\n", .{});
    switch (id) {
        ids.timeout.start...ids.timeout.end => {
            const handle = Handle.fromIdx(id - ids.timeout.start);
            const now = try sphtud.io.clock_gettime(.BOOTTIME);
            const action = try self.transactions.onTimeout(handle, now);
            switch (action) {
                .finish => {
                    self.handleTxFinish(handle);
                },
                .none => {},
            }
        },
        ids.transport.total.start...ids.transport.total.end => {
            while (true) {
                std.debug.print("transport service\n", .{});
                const te = try self.transport.service(id, ids.transport) orelse break;
                std.debug.print("transport service return\n", .{});



                // Want guy who
                //  * Parses any sip message
                //  * breaks into request/response
                //  * frames the data

                switch (te) {
                    .tcp => |tcp_e| while (true) {
                        const frame = frameTcp(tcp_e.r) catch |e| {
                            // FIXME: Check if this is cause the socket closed or cause of blocking io
                            if (e == error.ReadFailed) return;
                            return e;
                        };
                        try self.dispatchMessage(frame, tcp_e.handle, ids);
                    },
                    .udp => |udp_e| {
                        try self.dispatchMessage(udp_e.data, null, ids);
                    },
                }
            }
        },
        else => unreachable,
    }
}

fn dispatchMessage(self: *SipService, message: []const u8, transport_handle: ?TransportService.Handle, comptime ids: Ids) !void {
    var tc = parse.TokenConsumer.init(message);

    const now = try sphtud.io.clock_gettime(.BOOTTIME);
    var response_buf: [4096]u8 = undefined;

    if (sip_parse.statusLine(&tc)) |_| {
        const actions = try self.transactions.onMessage(message, now, &response_buf);
        try self.handleTransactionActions(actions, transport_handle, ids);
    } else if (sip_parse.requestLine(&tc)) |_| {

        // FIXME: do new things
        std.debug.print("Got request: {s}\n", .{message});
        const res = try self.server_transactions.onMessage(message);
        switch (res) {
            .INVITE => |call| {
                self.incoming_call = call;
                try self.loop.pushEvent(self.incoming_call_event);
            },
        }
    }
    else {
        return error.InvalidMessage;
    }
}

fn handleTransactionActions(self: *SipService, actions: []const sip.Transactions.ResponseAction, tx_handle: ?TransportService.Handle, comptime ids: Ids) !void {
    for (actions) |action| switch (action) {
        .schedule_timeout => |t| {
            const extra = self.extra.getPtr(t.handle.id);
            extra.timer_handle = try self.timer.add(t.duration, ids.timeout.start + t.handle.id);
        },
        .send => |buf| {
            try self.transport.sendResponse(tx_handle.?, buf);
        },
        .notify => |handle| {
            const extra = self.extra.getPtr(handle.id);
            try self.loop.pushEvent(extra.callback_id);
        },
        .finish => |handle| {
            self.handleTxFinish(handle);
        },
    };
}
fn handleTxFinish(self: *SipService, handle: Transactions.Handle) void {
    const extra = self.extra.getPtr(handle.id);
    extra.completion.finishIo();

    if (extra.completion.isFullyComplete()) {
        self.deinitItem(handle);
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
        if (sip_parse.statusLine(&tc)) |_| {}
        else if ( sip_parse.requestLine(&tc)) |_| {}
        else {
            return error.InvalidMessage;
        }


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
