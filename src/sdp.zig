const std = @import("std");
const sdp_parse = @import("sdp/parse.zig");
const parse = @import("parse.zig");

pub const MediaField = struct {
    media: parse.Range,
    port: parse.Range,
    num_ports: ?parse.Range,
    protocol: parse.Range,
    formats: []parse.Range,

    pub fn portRange(self: MediaField, data: []const u8) ![2]u16 {
        const num_ports = if (self.num_ports) |num_ports_r|
            try std.fmt.parseInt(u16, num_ports_r.data(data), 10)
        else
            1;

        const start_port = try std.fmt.parseInt(u16, self.port.data(data), 10);

        return .{
            start_port,
            start_port + num_ports,
        };
    }
};

pub const MediaDescription = struct {
    media: MediaField,
    connections: []ConnectionField,
};

pub const Origin = struct {
    username: parse.Range,
    session_id: parse.Range,
    session_version: parse.Range,
    net_type: parse.Range,
    addr_type: parse.Range,
    unicast_addr: parse.Range,
};

pub const ConnectionField = struct {
    net_type: parse.Range,
    addr_type: parse.Range,
    connection_address: parse.Range,

    pub fn toIpAddress(self: ConnectionField, data: []const u8, port: u16) !std.Io.net.IpAddress {
        return .parse(self.connection_address.data(data), port);
    }
};

pub const SessionDescription = struct {
    version: parse.Range,
    origin: Origin,
    connection: ?ConnectionField,
    media_descriptions: []MediaDescription,
};

pub fn parseSessionDescription(alloc: std.mem.Allocator, data: []const u8) !SessionDescription {
    var tc = parse.TokenConsumer.init(data);

    return try sdp_parse.sessionDescription(alloc, &tc) orelse return error.ParseFailure;
}

test "sip received" {
    const data =
        "v=0\r\n" ++
        "o=- 3988897187 3988897188 IN IP4 192.168.1.105\r\n" ++
        "s=pjmedia\r\n" ++
        "b=AS:84\r\n" ++
        "t=0 0\r\n" ++
        "a=X-nat:0\r\n" ++
        "m=audio 4000 RTP/AVP 0\r\n" ++
        "c=IN IP4 192.168.1.105\r\n" ++
        "b=TIAS:64000\r\n" ++
        "a=rtcp:4001 IN IP4 192.168.1.105\r\n" ++
        "a=sendrecv\r\n" ++
        "a=rtpmap:0 PCMU/8000\r\n" ++
        "a=ssrc:2085747712 cname:579a09791ebe8142\r\n";

    var alloc_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
    const alloc = fba.allocator();

    const parsed = try parseSessionDescription(alloc, data);

    // There's more to test here, but for now I'm just looking at things that
    // are relevant for our RTP stream
    try std.testing.expectEqualStrings("4000", parsed.media_descriptions[0].media.port.data(data));
    try std.testing.expectEqualStrings("RTP/AVP", parsed.media_descriptions[0].media.protocol.data(data));
    try std.testing.expectEqualStrings("0", parsed.media_descriptions[0].media.formats[0].data(data));
    try std.testing.expectEqualStrings("192.168.1.105", parsed.media_descriptions[0].connections[0].connection_address.data(data));
}
