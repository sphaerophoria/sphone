const std = @import("std");
const sip = @import("../sip.zig");
const sphtud = @import("sphtud");

const Self = @This();

pub fn init() Self {
    return .{};
}

pub const Connection = union(enum) {
    new_tcp: ConnectionParams,
    existing: usize,
};

pub const Buffer = struct {
    buf: []u8,
    proto_offs: usize,

    pub fn withProto(self: Buffer, p: Proto) []u8 {
        const proto_string = p.toSipString();
        std.debug.assert(proto_string.len == 3);
        @memcpy(self.buf[self.proto_offs..][0..3], proto_string);
        return self.buf;
    }
};

pub const WriteParams = struct {
    connection: Connection,
    data: []const u8,
};

pub fn getWriteParams(self: *Self, sip_uri: []const u8, buffer: Buffer) !WriteParams {
    _ = self;
    const connection_params = try ConnectionParams.fromUri(sip_uri);

    // FIXME: Lookup based off params to see if we have a connection we can
    // re-use. (spec says it's fine, recommended even, in 18.1.1)

    // FIXME: MTU tracking to figure out if we are allowed to use udp

    return .{
        .connection = .{
            .new_tcp = connection_params,
        },
        .data = buffer.withProto(.tcp),
    };
}

const ConnectionId = struct {
    inner: usize,

    pub fn fromIdx(idx: usize) ConnectionId {
        return .{ .inner = idx };
    }

    pub fn toIdx(self: ConnectionId) usize {
        return self.inner;
    }
};

const Proto = enum {
    tcp,
    udp,

    fn toSipString(self: Proto) []const u8 {
        switch (self) {
            .tcp => return "TCP",
            .udp => return "UDP",
        }
    }
};

fn indexOfScalarPosOffset(haystack: []const u8, pos: usize, needle: u8, offset: usize) ?usize {
    const needle_pos = std.mem.indexOfScalarPos(u8, haystack, pos, needle) orelse return null;
    const ret = needle_pos + offset;
    if (ret >= haystack.len) return null;
    return ret;
}

const ConnectionParams = struct {
    host: []const u8,
    port: u16,

    fn fromUri(uri: []const u8) !ConnectionParams {
        //example uri sip:mick-terminal@127.0.0.1:5062

        const host_start = indexOfScalarPosOffset(uri, 0, '@', 1) orelse return error.NoHost;
        var port: u16 = 5060;
        var host_end = uri.len;
        const port_start = indexOfScalarPosOffset(uri, host_start, ':', 1);
        if (port_start) |ps| {
            host_end = ps - 1;
            port = try std.fmt.parseInt(u16, uri[ps..], 10);
        }

        return .{
            .host = uri[host_start..host_end],
            .port = port,
        };
    }
};

test "uri parsing" {
    {
        const params = try ConnectionParams.fromUri("sip:mick-terminal@127.0.0.1:5062");
        try std.testing.expectEqualStrings("127.0.0.1", params.host);
        try std.testing.expectEqual(5062, params.port);
    }

    {
        const params = try ConnectionParams.fromUri("sip:mick-terminal@127.0.0.1");
        try std.testing.expectEqualStrings("127.0.0.1", params.host);
        try std.testing.expectEqual(5060, params.port);
    }
}
