const std = @import("std");
const sip = @import("../sip.zig");
const sphtud = @import("sphtud");
const Transport = @import("Transport.zig");

const max_actions = 10;

const TransactionManager = @This();

alloc: *sphtud.alloc.Sphalloc,
by_branch: sphtud.util.hash_map.AutoHashMap(BranchId, Handle),
transactions: sphtud.util.ObjectPool(Transaction, Handle),
rand: std.Random,
action_buf: []ResponseAction,

pub const Handle = struct {
    id: usize,

    pub fn toIdx(self: Handle) usize {
        return self.id;
    }

    pub fn fromIdx(id: usize) Handle {
        return .{ .id = id };
    }
};
const Self = @This();

pub fn init(alloc: *sphtud.alloc.Sphalloc, rand: std.Random, typical_transactions: usize, max_transactions: usize) !TransactionManager {
    return .{
        .alloc = alloc,
        .by_branch = try .init(
            alloc.arena(),
            alloc.expansion(),
            typical_transactions,
            max_transactions,
        ),
        .transactions = try .init(
            alloc.arena(),
            alloc.expansion(),
            typical_transactions,
            max_transactions,
        ),
        .rand = rand,
        .action_buf = try alloc.arena().alloc(ResponseAction, max_actions),
    };
}

fn createRequest(self: *Self, branch_id: *const BranchId, transaction: Transaction) !Handle {
    const item = try self.transactions.acquire(self.alloc.expansion());
    errdefer self.transactions.release(self.alloc.expansion(), item.handle);

    item.val.* = transaction;
    try self.by_branch.putNoClobber(branch_id.*, item.handle);

    return item.handle;
}

// FIXME: Some requests have to stay tracked even after the caller is done with them
pub fn deinitRequest(self: *Self, handle: Handle) void {
    var it = self.by_branch.iter();
    while (it.next()) |item| {
        if (item.val.id == handle.id) {
            _ = self.by_branch.remove(item.key.*);
            break;
        }
    }

    self.transactions.release(self.alloc.expansion(), handle);
}

pub const ResponseAction = union(enum) {
    schedule_timeout: struct {
        handle: Handle,
        duration: std.Io.Duration,
    },
    send: Transport.Buffer,
    notify: Handle,
    finish: Handle,
};

pub fn onMessage(self: *Self, r: *std.Io.Reader, now: std.Io.Timestamp, out_buf: []u8) ![]const ResponseAction {
    while (true) {
        const header_end = try peekHeader(r);

        const header = try r.peek(header_end + 4);
        std.debug.print("Got some data {s}\n", .{header});

        // Check method as well
        const dispatch_data = try DispatchData.parse(header) orelse return error.Unimplemented;

        const message = try r.take(header_end + 4 + dispatch_data.content_len);

        const handle = self.by_branch.get(dispatch_data.branch.*) orelse return error.MissingTransaction;
        const tx = self.transactions.get(handle);

        std.debug.print("matched tx: {any}\n", .{tx});

        var action_buf: [max_actions]Transaction.Action = undefined;
        const res = try tx.onMessage(message, now, out_buf, &action_buf);

        const ret = self.convertActions(handle, res);

        if (ret.len > 0) return ret;
    }
}

fn convertActions(self: *Self, handle: Handle, actions: []const Transaction.Action) []const ResponseAction {
    var ret = std.ArrayList(ResponseAction).initBuffer(self.action_buf);
    for (actions) |action| switch (action) {
        .schedule_timeout => |t| {
            ret.appendBounded(.{
                .schedule_timeout = .{
                    .duration = t,
                    .handle = handle,
                },
            }) catch unreachable;
        },
        .notify => {
            ret.appendBounded(.{ .notify = handle }) catch unreachable;
        },
        .finish => {
            // We don't just release the handle now, because
            // technically we do not own the lifetime of the object.
            // The owner is the person who started the transaction, so
            // they get to finish it
            ret.appendBounded(.{ .finish = handle }) catch unreachable;
        },
        .send => |b| {
            ret.appendBounded(.{ .send = b }) catch unreachable;
        },
    };

    return ret.items;
}

const TimeoutAction = enum {
    none,
    finish,
};

pub fn onTimeout(self: *Self, handle: Handle, now: std.Io.Timestamp) !TimeoutAction {
    const tx = self.transactions.get(handle);
    return tx.onTimeout(now);
}

fn peekHeader(r: *std.Io.Reader) !usize {
    while (true) {
        const buf = r.buffered();
        if (std.mem.find(u8, buf, "\r\n\r\n")) |end| return end;

        if (r.seek == 0 and r.end == r.buffer.len) return error.OutOfMemory;
        try r.fillMore();
    }
}

pub const InviteParams = struct {
    uri: []const u8,
    to: []const u8,
    from: []const u8,
    out_buf: []u8,
    sent_by: []const u8,
};

const InviteRes = struct {
    handle: InviteHandle,
    to_send: Transport.Buffer,
    dest: []const u8,
};

pub const InviteHandle = struct {
    handle: Handle,
    parent: *TransactionManager,

    // FIXME: This is a bad API for passing out of sip service
    pub fn get(self: InviteHandle) *InviteTransaction {
        return &self.parent.transactions.get(self.handle).INVITE;
    }
};

pub fn startInvite(self: *TransactionManager, params: InviteParams) !InviteRes {
    const branch_id = genBranchId(self.rand);

    var call_id: [globally_unique_hex_len]u8 = undefined;
    genRandHex(self.rand, &call_id);

    var message_w = std.Io.Writer.fixed(params.out_buf);

    const cseq = self.rand.int(u16);
    var cseq_buf: [1024]u8 = undefined;
    const cseq_s = std.fmt.bufPrint(&cseq_buf, "{d} INVITE", .{cseq}) catch unreachable;

    var req = try sip.ClientRequestWriter.init(.{
        .method = .INVITE,
        .uri = params.uri,
        .via = .{
            .sent_by = params.sent_by,
            .branch = &branch_id,
        },
        .to = params.to,
        .from = params.from,
        .call_id = &call_id,
        .cseq = cseq_s,
    }, &message_w);

    // SDP copied from linphone and stripped down until it looked about right
    const body = "v=0\r\n" ++
        "o=streamer 416 78 IN IP4 127.0.0.1\r\n" ++
        "s=Talk\r\n" ++
        "c=IN IP4 127.0.0.1\r\n" ++
        "t=0 0\r\n" ++
        "m=audio 48013 RTP/AVP 0\r\n";

    var body_len_buf: [4]u8 = undefined;
    const body_len = try std.fmt.bufPrint(&body_len_buf, "{d}", .{body.len});

    try req.writeHeader("Content-Type", "application/sdp");
    try req.writeHeader("Content-Length", body_len);
    try req.writeHeader("Contact", "<sip:streamer@127.0.0.1;transport=tcp>");
    const to_send = try req.finish(body);

    const tx_alloc = try self.alloc.makeSubAlloc("invite");
    errdefer tx_alloc.deinit();

    const tx_arena = tx_alloc.arena();

    const handle = try self.createRequest(&branch_id, .{
        .INVITE = .{
            .alloc = tx_alloc,
            .negotiated_sdp = &.{},
            .call_id = try tx_arena.dupe(u8, &call_id),
            .sent_by = try tx_arena.dupe(u8, params.sent_by),
            .branch_id = try tx_arena.dupe(u8, &branch_id),
            .request_uri = try tx_arena.dupe(u8, params.uri),
            .from = try tx_arena.dupe(u8, params.from),
            .cseq = cseq,
            .state = .wait_ok,
        },
    });

    return .{
        .handle = InviteHandle{ .handle = handle, .parent = self },
        .to_send = to_send,
        .dest = params.uri,
    };
}

const DispatchData = struct {
    response_code: u16,
    branch: *const BranchId,
    method: sip.Method,
    content_len: usize,

    // FIXME: Branch ID and method
    fn parse(message: []const u8) !?DispatchData {
        var rp = try sip.ResponseParser.init(message);

        var branch: ?*const BranchId = null;
        var method: ?sip.Method = null;
        var content_len: ?usize = null;

        std.debug.print("response code: {d}\n", .{rp.response_code});

        while (try rp.nextHeader()) |h| {
            var tc = sip.parse.TokenConsumer.init(h.val);

            if (branch == null and h.key == .via) {
                _ = sip.parse_utils.viaParm(&tc) orelse break;
                while (true) {
                    const param = sip.parse_utils.viaParams(&tc) orelse break;
                    switch (param) {
                        .branch => |br| {
                            const in_branch = br.data(h.val);
                            if (in_branch.len != branch_id_len) return error.UnexpectedBranchId;
                            branch = in_branch[0..branch_id_len];
                        },
                        else => {},
                    }
                }
            }

            if (method == null and h.key == .cseq) {
                const cseq = sip.parse_utils.cseq(&tc) orelse return error.InvalidCSeq;
                method = std.meta.stringToEnum(sip.Method, cseq.method.data(h.val)) orelse return null;
            }

            if (content_len == null and h.key == .content_length) {
                content_len = try std.fmt.parseInt(usize, h.val, 10);
            }
        }

        return .{
            .response_code = rp.response_code,
            .branch = branch orelse return null,
            .method = method orelse return null,
            .content_len = content_len orelse 0,
        };
    }
};

const InviteTransaction = struct {
    // copy in Call-ID, From, top Via, and Request-URI from original req
    // copy from response To
    // copy cseq number from original req, but method ACK
    alloc: *sphtud.alloc.Sphalloc,
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

    // This is supposed to be an estimate of the RTT, but for now we just
    // hardcode the default
    //
    // RFC 3261 17.1.1.1
    const t1_ms = 500;

    fn onMessage(
        self: *InviteTransaction,
        message: []const u8,
        now: std.Io.Timestamp,
        out_buf: []u8,
        action_buf: []Transaction.Action,
    ) ![]const Transaction.Action {
        // Parse
        // Check if we are finished
        var ret = std.ArrayList(Transaction.Action).initBuffer(action_buf);

        var rp = try sip.ResponseParser.init(message);

        var to: ?[]const u8 = null;

        while (try rp.nextHeader()) |h| {
            if (h.key == .to) {
                to = h.val;
            } else if (h.key == .content_type) {
                if (!std.mem.eql(u8, h.val, "application/sdp")) {
                    return error.UnexpectedType;
                }
            }
        }

        const received_ok = rp.response_code == 200;

        if (received_ok) {
            var notify = false;
            switch (self.state) {
                .wait_ok => {
                    self.state = .{ .received_ok = now };
                    // RFC 3261 13.2.2.4 says that we need to keep responding for 64 * T1
                    ret.appendBounded(.{ .schedule_timeout = .fromMilliseconds(t1_ms * 64) }) catch unreachable;
                    self.negotiated_sdp = rp.readBody();
                    notify = true;
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

            if (notify) {
                ret.appendBounded(.notify) catch unreachable;
            }
        }

        return ret.items;
    }

    fn onTimeout(
        self: *InviteTransaction,
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
};

const Transaction = union(sip.Method) {
    INVITE: InviteTransaction,
    ACK,

    const Action = union(enum) {
        schedule_timeout: std.Io.Duration,
        send: Transport.Buffer,
        // Tell the caller to look at us
        notify,
        // We can be marked as complete from an IO perspective
        finish,
    };

    fn onMessage(self: *Transaction, message: []const u8, now: std.Io.Timestamp, out_buf: []u8, action_buf: []Action) ![]const Action {
        switch (self.*) {
            .INVITE => |*i| return i.onMessage(message, now, out_buf, action_buf),
            .ACK => unreachable,
        }
    }

    fn onTimeout(self: *Transaction, now: std.Io.Timestamp) !TimeoutAction {
        switch (self.*) {
            .INVITE => |*i| return i.onTimeout(now),
            .ACK => unreachable,
        }
    }
};

const branch_prefix = "z9hG4bK";
pub const globally_unique_hex_len = 32;
pub const branch_id_len = branch_prefix.len + globally_unique_hex_len;

// Branch ID is sized according to our generation. AFAICT, all correlation
// is done from the UAC role. When we are working as a UAS, requests come
// in with new branch IDs, and we just have to copy paste them out. The
// only time we need to actually correlate responses is when we are GETTING
// the response, not GIVING the response
pub const BranchId = [branch_id_len]u8;

// pjsip uses a GUID which is 122 bits of random data 16 bytes is 128 bits of
// random data so our chances of colliding are astronomically low.
//
// Branch IDs are supposed to be globally unique, however we suspect that there
// are security concerns with using sequential IDs so we do what pjsip does,
// but a little different
fn genBranchId(rng: std.Random) BranchId {
    var ret: [branch_id_len]u8 = undefined;
    @memcpy(ret[0..branch_prefix.len], branch_prefix);

    genRandHex(rng, ret[branch_prefix.len..]);

    return ret;
}

fn genRandHex(rng: std.Random, buf: []u8) void {
    std.debug.assert(buf.len % 2 == 0);

    const rand_start = buf.len / 2;
    const rand_len = buf.len / 2;
    rng.bytes(buf[rand_start..]);

    for (0..rand_len) |i| {
        const s = buf[rand_start + i];
        @memcpy(buf[2 * i ..][0..2], &std.fmt.hex(s));
    }
}
