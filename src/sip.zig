const std = @import("std");
const transport = @import("sip/transport.zig");
const transaction_manager = @import("sip/transaction_manager.zig");

pub const Transport = transport.Transport;
pub const TransactionManager = transaction_manager.TransactionManager;

// * Messages
//   * Requests
//   * Responses
//

// "INVITE sip:mick-terminal@127.0.0.1:5062 SIP/2.0\r\n" ++
pub const RequestWriter = struct {
    w: *std.Io.Writer,

    pub fn init(method: []const u8, uri: []const u8, w: *std.Io.Writer) !RequestWriter {
        try w.writeAll(method);
        try w.writeByte(' ');
        try w.writeAll(uri);
        try w.writeByte(' ');
        try w.writeAll("SIP/2.0\r\n");

        return .{
            .w = w,
        };
    }

    pub fn writeHeader(self: RequestWriter, key: []const u8, val: []const u8) !void {
        try self.w.writeAll(key);
        try self.w.writeAll(": ");
        try self.w.writeAll(val);
        try self.w.writeAll("\r\n");
    }

    pub fn finish(self: RequestWriter, body: []const u8) !void {
        try self.w.writeAll("\r\n");
        try self.w.writeAll(body);
        // FIXME: Maybe this should go higher up
        try self.w.flush();
    }
};

pub const ClientRequestWriter = struct {
    rw: RequestWriter,

    pub const InitParams = struct {
        method: []const u8,
        uri: []const u8,
        to: []const u8,
        from: []const u8,
        cseq: []const u8,
        call_id: []const u8,
        max_forwards: []const u8,
        via: []const u8,
    };

    pub fn init(params: InitParams, w: *std.Io.Writer) !ClientRequestWriter {
        const rw = try RequestWriter.init(params.method, params.uri, w);

        try rw.writeHeader("To", params.to);
        try rw.writeHeader("From", params.from);
        try rw.writeHeader("CSeq", params.cseq);
        try rw.writeHeader("Call-ID", params.call_id);
        try rw.writeHeader("Max-Forwards", params.max_forwards);
        try rw.writeHeader("Via", params.via);

        return .{
            .rw = rw,
        };
    }

    pub fn writeHeader(self: ClientRequestWriter, key: []const u8, val: []const u8) !void {
        try self.rw.writeHeader(key, val);
    }

    pub fn finish(self: ClientRequestWriter, body: []const u8) !void {
        try self.rw.finish(body);
    }
};

const branch_prefix = "z9hG4bK";
const branch_id_len = branch_prefix.len + 32;

pub const BranchId = [branch_id_len]u8;

// pjsip uses a GUID which is 122 bits of random data 16 bytes is 128 bits of
// random data so our chances of colliding are astronomically low.
//
// Branch IDs are supposed to be globally unique, however we suspect that there
// are security concerns with using sequential IDs so we do what pjsip does,
// but a little different
pub fn genBranchId(rng: std.Random) BranchId {
    var ret: [branch_id_len]u8 = undefined;
    @memcpy(ret[0..branch_prefix.len], branch_prefix);

    var rand_buf: [16]u8 = undefined;
    rng.bytes(&rand_buf);

    for (0..rand_buf.len) |i| {
        const s = rand_buf[i];
        @memcpy(ret[branch_prefix.len + 2 * i..][0..2], &std.fmt.hex(s));
    }

    return ret;
}

pub const Method = enum {
    invite,
};


test {
    std.testing.refAllDeclsRecursive(@This());
}
