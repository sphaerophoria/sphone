const std = @import("std");
const sphtud = @import("sphtud");
const sdpm = @import("sdp.zig");
const parse = @import("parse.zig");
const RtpFrame = @import("RtpFrame.zig");

pub fn openUdpSocket(addr: std.Io.net.IpAddress) !std.posix.fd_t {
    const system = sphtud.io.system;
    const socket = try sphtud.io.socket(system.AF.INET, system.SOCK.DGRAM, 0);
    try sphtud.io.bind(socket, addr);

    return socket;
}

fn anyFormatsArePcmu(buf: []const u8, formats: []const parse.Range) bool {
    for (formats) |fmt| {
        if (std.mem.eql(u8, "0", fmt.data(buf))) return true;
    }

    return false;
}

fn allocFile(alloc: std.mem.Allocator, path: [:0]const u8) ![]const u8 {
    const fd = try sphtud.io.open(path, .{
        .ACCMODE = .RDONLY,
    }, 0);
    defer sphtud.io.close(fd);

    var reader_buf: [4096]u8 = undefined;
    var r = sphtud.io.Reader.init(fd, &reader_buf);

    return try r.interface.allocRemaining(alloc, .unlimited);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arg_it = init.args.iterate();
    _ = arg_it.next();

    const sdp_path = arg_it.next().?;

    var alloc_buf: [1 * 1024 * 1024]u8 = undefined;
    var buf_alloc = sphtud.alloc.BufAllocator.init(&alloc_buf);
    const alloc = buf_alloc.allocator();

    const sdp = try allocFile(alloc, sdp_path);
    const parsed = try sdpm.parseSessionDescription(alloc, sdp);

    const media_description = parsed.media_descriptions[0];
    // FIXME: Media description might contain the connection, need to support that override
    const port = try std.fmt.parseInt(u16, media_description.media.port.data(sdp), 10);
    const ip = try std.Io.net.IpAddress.parse(parsed.connection.?.connection_address.data(sdp), port);

    // I think multiple formats probably means you will receive all of them,
    // and you should pick which one you want to use. I haven't checked that, I
    // just made it up, but like, what else would it mean?
    if (!anyFormatsArePcmu(sdp, media_description.media.formats)) return error.UnhandledFormat;

    if (!std.mem.eql(u8, "audio", media_description.media.media.data(sdp))) return error.UnhandledMedia;
    if (!std.mem.eql(u8, "RTP/AVP", media_description.media.protocol.data(sdp))) return error.UnhandledProto;

    const socket = try openUdpSocket(ip);
    var buf: [1 * 1024 * 1024]u8 = undefined;

    // I THINK this is supposed to just be 0, otherwise the spec we are reading
    // doesn't know about it :)
    std.debug.print("version: {s}\n", .{parsed.version.data(sdp)});
    std.debug.print("origin username: {s}\n", .{parsed.origin.username.data(sdp)});
    std.debug.print("origin session id: {s}\n", .{parsed.origin.session_id.data(sdp)});
    std.debug.print("origin session version: {s}\n", .{parsed.origin.session_version.data(sdp)});
    std.debug.print("origin net type: {s}\n", .{parsed.origin.net_type.data(sdp)});
    std.debug.print("origin addr type: {s}\n", .{parsed.origin.addr_type.data(sdp)});
    std.debug.print("origin addr : {s}\n", .{parsed.origin.unicast_addr.data(sdp)});

    if (parsed.connection) |c| {
        std.debug.print("connection net type: {s}\n", .{c.net_type.data(sdp)});
        std.debug.print("connection addr type: {s}\n", .{c.addr_type.data(sdp)});
        std.debug.print("connection addr : {s}\n", .{c.connection_address.data(sdp)});
    }

    for (parsed.media_descriptions) |md| {
        std.debug.print("media {s}\n", .{md.media.media.data(sdp)});
        std.debug.print("port {s}\n", .{md.media.port.data(sdp)});
        if (md.media.num_ports) |np| {
            std.debug.print("num_ports {s}\n", .{np.data(sdp)});
        }
        std.debug.print("protocol {s}\n", .{md.media.protocol.data(sdp)});
        for (md.media.formats) |fmt| {
            std.debug.print("fmt {s}\n", .{fmt.data(sdp)});
        }
    }

    const wav_fd = try sphtud.io.open("wav.csv", .{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
        .CREAT = true,
        .TRUNC = true,
    }, 0);
    var writer_buf: [4096]u8 = undefined;
    var wav_writer_concrete = sphtud.io.Writer.init(wav_fd, &writer_buf);
    var wav_writer = &wav_writer_concrete.interface;

    for (0..10) |_| {
        const recv_len = try sphtud.io.recvfrom(socket, &buf, 0, null, null);
        const received = buf[0..recv_len];

        const frame = try RtpFrame.parse(received);
        if (frame.payload_type != 0) continue;

        std.debug.print("{any}\n\n", .{frame});

        // -1^s * ((33 + 2m) * 2^e - 33)

        // Guaranteed PCMU
        //
        for (frame.payload) |b| {
            const m: i16 = @as(u4, @truncate(b));
            const e: u3 = @truncate(b >> 4);
            const s: u1 = @truncate(b >> 7);

            const sign_multiplier: i14 = if (s == 0) 1 else -1;

            var val = 33 + 2 * m;
            val *= std.math.pow(i16, 2, e);
            val -= 33;
            val *= sign_multiplier;

            std.debug.print("{d} ", .{val});
            try wav_writer.print("{d}\n", .{val});
        }
        std.debug.print("\n\n", .{});
    }
    try wav_writer.flush();
}
