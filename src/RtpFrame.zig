const std = @import("std");

version: u2,
extension: bool,
cc: u4,
marker: bool,
payload_type: u7,
sequence_number: u16,
timestamp: u32,
ssrc: u32,
csrc_data: []const u8,
payload: []const u8,

pub fn parse(frame_data: []const u8) !@This() {
    var r = std.Io.Reader.fixed(frame_data);

    const b1 = try r.takeByte();
    const version: u2 = @truncate(b1 >> 6);
    const extension: u1 = @truncate(b1 >> 4);
    const cc: u4 = @truncate(b1);

    const b2 = try r.takeByte();
    const marker: u1 = @truncate(b2 >> 7);
    const payload_type: u7 = @truncate(b2);

    const sequence_number = try r.takeInt(u16, .big);
    const timestamp = try r.takeInt(u32, .big);
    const ssrc = try r.takeInt(u32, .big);
    const csrc_data = try r.take(cc * 4);

    const payload = try r.take(r.bufferedLen());

    return .{
        .version = version,
        .extension = extension > 0,
        .cc = cc,
        .marker = marker > 0,
        .payload_type = payload_type,
        .sequence_number = sequence_number,
        .timestamp = timestamp,
        .ssrc = ssrc,
        .csrc_data = csrc_data,
        .payload = payload,
    };
}
