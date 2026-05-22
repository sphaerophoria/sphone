const std = @import("std");
const sphtud = @import("sphtud");
const sdpm = @import("sdp.zig");
const parse = @import("parse.zig");

pub fn openUdpSocket(io: std.Io, addr: std.Io.net.IpAddress) !std.Io.net.Socket {
    const socket = try addr.bind(io, .{
        .mode = .dgram,
        .protocol = .udp,
    });

    return socket;
}

const RtpHeader = struct {
    version: u2,
    extension: bool,
    cc: u4,
    marker: bool,
    payload_type: u7,
    sequence_number: u16,
    timestamp: u32,
    ssrc: u32,
    csrc_data: []const u8,

    fn parse(r: *std.Io.Reader) !RtpHeader {
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
        };
    }
};

fn anyFormatsArePcmu(buf: []const u8, formats: []const parse.Range) bool {
    for (formats) |fmt| {
        if (std.mem.eql(u8, "0", fmt.data(buf))) return true;
    }

    return false;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arg_it = init.args.iterate();
    _ = arg_it.next();

    const sdp_path = arg_it.next().?;

    const sdp_fd = try sphtud.io.open(sdp_path, .{
        .ACCMODE = .RDONLY,
    }, 0);
    defer sphtud.io.close(sdp_fd);

    var alloc_buf: [1 * 1024 * 1024]u8 = undefined;
    var buf_alloc = sphtud.alloc.BufAllocator.init(&alloc_buf);
    const alloc = buf_alloc.allocator();

    var sdp_reader_buf: [4096]u8 = undefined;
    var sdp_r = sphtud.io.Reader.init(sdp_fd, &sdp_reader_buf);
    const sdp = try sdp_r.interface.allocRemaining(alloc, .unlimited);
    std.debug.print("sdp: {s}\n", .{sdp});

    var tc = parse.TokenConsumer.init(sdp);
    const parsed = try sdpm.sessionDescription(alloc, &tc) orelse return error.InvalidSdp;

    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();

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

    const socket = try openUdpSocket(io, ip);
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

    const wav_f = try std.Io.Dir.cwd().createFile(io, "wav.csv", .{});
    var writer_buf: [4096]u8 = undefined;
    var wav_writer_concrete = wav_f.writer(io, &writer_buf);
    var wav_writer = &wav_writer_concrete.interface;

    for (0..10) |_| {
        const recv_len: usize = while (true) {
            const rc = std.posix.system.recvfrom(socket.handle, &buf, buf.len, 0, null, null);
            switch (std.posix.errno(rc)) {
                .SUCCESS => break @intCast(rc),
                .INTR => continue,
                else => return error.RecvFailed,
            }
        };
        const received = buf[0..recv_len];

        var r = std.Io.Reader.fixed(received);
        const header = try RtpHeader.parse(&r);
        if (header.payload_type != 0) continue;

        std.debug.print("{any}\n\n", .{header});

        // -1^s * ((33 + 2m) * 2^e - 33)

        // Guaranteed PCMU
        //
        while (true) {
            const b = ~(r.takeByte() catch break);

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
