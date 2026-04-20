const std = @import("std");
const transport = @import("sip/transport.zig");
const transaction_manager = @import("sip/transaction_manager.zig");
const parse_utils = @import("sip/parse_utils.zig");
const parse = @import("parse.zig");

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
        @memcpy(ret[branch_prefix.len + 2 * i ..][0..2], &std.fmt.hex(s));
    }

    return ret;
}

pub const Method = enum {
    invite,
};

//pub const ViaParser = struct {
//    buf: []const u8,
//    idx: usize,
//    state: enum {
//        init,
//        sent_proto,
//        sent_by,
//        via_param,
//    },
//
//    const Output = union(enum) {
//        new_via,
//        protocol: []const u8,
//        sent_by: []const u8,
//        param: struct {
//            key: []const u8,
//            val: []const u8,
//        },
//    };
//
//    fn init(via: []const u8) ViaParser {
//        return .{
//            .buf = via,
//            .idx = 0,
//            .state = .init,
//        };
//    }
//
//    fn next(self: *ViaParser) !?Output {
//        if (self.idx >= self.buf.len) return null;
//
//        const start = self.idx;
//
//        switch (self.state) {
//            .init => {
//                self.state = .sent_proto;
//                // FIXME: split out a fn to consume LWS (linear whitespace)
//                // BNF for LSP says [*WSP CRLF] 1*WSP which i think means "any
//                // amount of WSP follows by a \r\n then 1 WSP"
//                //
//                // WSP is defined in rfc2234 as space (0x20) or htab (0x09)
//                self.idx = parse_utils.consumeSws(self.buf, self.idx);
//                return .new_via;
//            },
//            .sent_proto => {
//                self.idx = std.mem.indexOfAnyPos(u8, self.buf, self.idx, parse_utils.wsp_chars) orelse return error.Invalid;
//                const end = self.idx;
//                self.idx += 1; // consume wsp
//                self.state = .sent_by;
//                return .{ .protocol = self.buf[start..end] };
//            },
//            .sent_by => {
//                const end = self.advanceTillParamEnd();
//                return .{ .sent_by = self.buf[start..end] };
//            },
//            .via_param => {
//                const param_end = self.advanceTillParamEnd();
//
//                const param_buf = self.buf[start..param_end];
//
//                const eql_idx = std.mem.indexOfScalar(u8, param_buf, '=') orelse param_buf.len;
//
//                const key = param_buf[0..eql_idx];
//                const val = if (eql_idx + 1 < param_buf.len) param_buf[eql_idx + 1 ..] else "";
//                return .{ .param = .{ .key = key, .val = val } };
//            },
//        }
//    }
//
//    fn advanceTillParamEnd(self: *ViaParser) usize {
//        if (std.mem.indexOfScalarPos(u8, self.buf, self.idx, ';')) |pos| {
//            self.idx = pos + 1;
//            self.state = .via_param;
//            return pos;
//        } else if (std.mem.indexOfScalarPos(u8, self.buf, self.idx, ',')) |pos| {
//            self.idx = pos + 1;
//            self.state = .init;
//            return pos;
//        } else {
//            self.idx = self.buf.len;
//            return self.buf.len;
//        }
//    }
//};

test "ViaParser sanity" {
    const buf = "SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bK.641H~Jw20;rport";
    var tc = parse.TokenConsumer.init(buf);

    const header = parse_utils.viaParm(&tc) orelse return error.ParseFailure;

    try std.testing.expectEqualStrings("SIP/2.0/UDP", header.sent_protocol.data(buf));
    try std.testing.expectEqualStrings("127.0.0.1:5060", header.sent_by.data(buf));

    {
        const param = parse_utils.viaParams(&tc) orelse return error.ParseFailure;
        try std.testing.expectEqualStrings("z9hG4bK.641H~Jw20", param.branch.data(buf));
    }

    {
        const param = parse_utils.viaParams(&tc) orelse return error.ParseFailure;
        try std.testing.expectEqualStrings("rport", param.extension.key.data(buf));
    }

    try std.testing.expectEqual(null, parse_utils.viaParams(&tc));
}
