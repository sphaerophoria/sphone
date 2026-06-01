const std = @import("std");
pub const Transport = @import("sip/Transport.zig");
pub const Transactions = @import("sip/Transactions.zig");
pub const ServerTransactions = @import("sip/ServerTransactions.zig");
pub const parse_utils = @import("sip/parse_utils.zig");
pub const parse = @import("parse.zig");

pub const RequestWriter = struct {
    w: *std.Io.Writer,

    pub fn init(method: Method, uri: []const u8, w: *std.Io.Writer) !RequestWriter {
        try w.writeAll(@tagName(method));
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
    via_start: usize,

    pub const InitParams = struct {
        method: Method,
        uri: []const u8,
        to: []const u8,
        from: []const u8,
        cseq: []const u8,
        call_id: []const u8,
        via: struct {
            sent_by: []const u8,
            branch: []const u8,
        },
    };

    pub fn init(params: InitParams, w: *std.Io.Writer) !ClientRequestWriter {
        const rw = try RequestWriter.init(params.method, params.uri, w);

        try rw.writeHeader("To", params.to);
        try rw.writeHeader("From", params.from);
        try rw.writeHeader("CSeq", params.cseq);
        try rw.writeHeader("Call-ID", params.call_id);

        // RFC 3261 8.1.1.6 says we should just hardcode a 70 here
        try rw.writeHeader("Max-Forwards", "70");

        std.debug.assert(w.vtable == std.Io.Writer.fixed(&.{}).vtable);
        const via_start = w.end;

        var via_buf: [4096]u8 = undefined;
        const via = try std.fmt.bufPrint(&via_buf, "SIP/2.0/XXX {s};branch={s}", .{ params.via.sent_by, params.via.branch });
        try rw.writeHeader("Via", via);

        return .{
            .rw = rw,
            .via_start = via_start,
        };
    }

    pub fn writeHeader(self: ClientRequestWriter, key: []const u8, val: []const u8) !void {
        try self.rw.writeHeader(key, val);
    }

    pub fn finish(self: ClientRequestWriter, body: []const u8) !Transport.Buffer {
        try self.rw.finish(body);
        return .{
            .buf = self.rw.w.buffered(),
            .proto_offs = self.via_start + 13,
        };
    }
};

pub const MessageParser = struct {
    line_reader: std.mem.SplitIterator(u8, .sequence),

    pub fn init(buf: []const u8) MessageParser {
        return .{
            .line_reader = std.mem.splitSequence(u8, buf, "\r\n"),
        };
    }

    pub const Header = struct {
        key: Key,
        val: []const u8,

        pub const Key = union(enum) {
            via,
            to,
            from,
            cseq,
            content_length,
            content_type,
            unknown: []const u8,
        };
    };

    fn parseKey(s: []const u8) Header.Key {
        const Keys = enum {
            Via,
            v,
            CSeq,
            @"Content-Length",
            l,
            @"Content-Type",
            c,
            To,
            t,
            From,
            f,
        };

        const parsed = std.meta.stringToEnum(Keys, s) orelse return .{ .unknown = s };

        switch (parsed) {
            .Via, .v => return .via,
            .To, .t => return .to,
            .CSeq => return .cseq,
            .@"Content-Length", .l => return .content_length,
            .@"Content-Type", .c => return .content_type,
            .From, .f => return .from,
        }
    }

    pub fn nextHeader(self: *MessageParser) !?Header {
        const line = self.line_reader.next() orelse return null;
        if (line.len == 0) return null;

        const key, const val = std.mem.cutScalar(u8, line, ':') orelse return error.InvalidHeader;

        return .{
            .key = parseKey(key),
            .val = std.mem.trimStart(u8, val, &std.ascii.whitespace),
        };
    }

    pub fn readBody(self: *MessageParser) []const u8 {
        const idx = self.line_reader.index orelse return &.{};
        if (idx >= self.line_reader.buffer.len) return &.{};
        return self.line_reader.buffer[idx..];
    }
};

pub const ResponseParser = struct {
    response_code: u16,
    message_parser: MessageParser,

    pub fn init(buf: []const u8) !ResponseParser {
        var tc = parse.TokenConsumer.init(buf);
        const status_line = parse_utils.statusLine(&tc) orelse return error.InvalidMessage;

        const code_s = status_line.status_code.data(buf);
        const response_code = try std.fmt.parseInt(u16, code_s, 10);

        _ = parse.crlf(&tc);

        const headers_buf = tc.remaining();

        return .{
            .response_code = response_code,
            .message_parser = .init(headers_buf),
        };
    }
};

pub const Method = enum {
    INVITE,
    ACK,
};
