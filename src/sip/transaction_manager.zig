const std = @import("std");
const sip = @import("../sip.zig");

pub fn TransactionManager(comptime max_transactions: usize) type {
    return struct {
        transactions: [max_transactions]?Transaction,

        const Self = @This();

        pub fn initPinned(self: *Self) void {
            self.transactions = @splat(null);
        }

        pub fn createRequest(self: *Self, branch_id: *const sip.BranchId, method: sip.Method) !void {
            const transaction_id = self.findFreeTransaction() orelse return error.TooManyTransactions;
            self.transactions[transaction_id] = @as(Transaction, undefined);

            const transaction = &self.transactions[transaction_id].?;
            transaction.branch = branch_id.*;
            transaction.state = .init(method);
        }

        pub fn processResponse(self: *Self, response: []const u8, w: *std.Io.Writer) !void {
            var r = std.Io.Reader.fixed(response);
            const rp = sip.ResponseParser.init(r);

            var branch_id: ?sip.Method = null;
            var method: ?sip.Method = null;

            while (rp.readHeader()) |header| {
                if (std.mem.eql(u8, header.key, "Via")) {
                    // First via is the only one where branch matters

                }

                if (std.mem.eql(u8, header.key, "CSeq")) {
                    method = sip.Method.fromString(header.val) orelse return error.UnknownMethod;
                    // Extract method here
                }
            }

            var transaction = self.findTransaction(branch_id, method);
            transaction.service(response);
        }

        fn findFreeTransaction(self: *Self) ?usize {
            // FIXME: Maybe need better allocation scheme
            for (&self.transactions, 0..) |*t, i| {
                if (t.* == null) return i;
            }

            return null;
        }
    };
}

pub const TransactionState = union(sip.Method) {
    invite: void, // have i acked yet

    pub fn init(method: sip.Method) TransactionState {
        switch (method) {
            .invite => return .invite,
        }
    }
};

pub const Transaction = struct {
    // Branch ID is sized according to our generation. AFAICT, all correlation
    // is done from the UAC role. When we are working as a UAS, requests come
    // in with new branch IDs, and we just have to copy paste them out. The
    // only time we need to actually correlate responses is when we are GETTING
    // the response, not GIVING the response
    branch: sip.BranchId,
    state: TransactionState,

    const ServiceResponse = enum {
        in_progress,
        complete,
    };

    fn service(self: *Transaction, messsage: []const u8, w: *std.Io.Writer) !ServiceResponse {
        switch (self.state) {
            .invite => |is| {
                // Send ack
            },
        }
    }
};
