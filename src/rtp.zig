pub const Frame = @import("rtp/Frame.zig");
pub const Stream = @import("rtp/Stream.zig");

const std = @import("std");
const sphtud = @import("sphtud");
const sdpm = @import("sdp.zig");
const parse = @import("parse.zig");

pub const StreamInfo = struct {
    ip: std.Io.net.IpAddress,

    pub fn fromSdp(scratch: sphtud.alloc.LinearAllocator, sdp: []const u8) !StreamInfo {
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const parsed = try sdpm.parseSessionDescription(scratch.allocator(), sdp);

        if (parsed.media_descriptions.len < 1) return error.NoMedia;
        if (parsed.media_descriptions.len > 1) {
            std.log.warn("Unimplemented handling of multiple media descriptions\n", .{});
        }

        const media_description = parsed.media_descriptions[0];
        const port_range = try media_description.media.portRange(sdp);

        const ip = if (media_description.connections.len > 0)
            try media_description.connections[0].toIpAddress(sdp, port_range[0])
        else if (parsed.connection) |c|
            try c.toIpAddress(sdp, port_range[0])
        else
            return error.NoConnection;

        // I think multiple formats probably means you will receive all of them,
        // and you should pick which one you want to use. I haven't checked that, I
        // just made it up, but like, what else would it mean?
        if (!anyFormatsArePcmu(sdp, media_description.media.formats)) return error.UnhandledFormat;

        if (!std.mem.eql(u8, "audio", media_description.media.media.data(sdp))) return error.UnhandledMedia;
        if (!std.mem.eql(u8, "RTP/AVP", media_description.media.protocol.data(sdp))) return error.UnhandledProto;

        return .{
            .ip = ip,
        };
    }

    fn anyFormatsArePcmu(buf: []const u8, formats: []const parse.Range) bool {
        for (formats) |fmt| {
            if (std.mem.eql(u8, "0", fmt.data(buf))) return true;
        }

        return false;
    }
};
