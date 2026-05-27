const std = @import("std");
const sdp_parse = @import("sdp/parse.zig");
const parse = @import("parse.zig");

pub const MediaField = struct {
    media: parse.Range,
    port: parse.Range,
    num_ports: ?parse.Range,
    protocol: parse.Range,
    formats: []parse.Range,
};

pub const MediaDescription = struct {
    media: MediaField,

    // Other fields are ignored for now, but are relevant. Single field struct
    // makes more sense for future code
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
