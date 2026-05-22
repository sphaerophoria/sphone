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
