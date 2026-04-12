const std = @import("std");

pub fn openUdpSocket() !std.posix.socket_t {
    //if ((sockfd = socket(AF_INET, SOCK_DGRAM, 0)) < 0) {
    //    perror("socket");
    //    return 1;
    //}

    //memset(&servaddr, 0, sizeof(servaddr));
    //servaddr.sin_family = AF_INET;
    //servaddr.sin_addr.s_addr = INADDR_ANY;
    //servaddr.sin_port = htons(PORT);

    //if (bind(sockfd, (struct sockaddr*)&servaddr, sizeof(servaddr)) < 0) {
    //    perror("bind");
    //    close(sockfd);
    //    return 1;
    //}

    const socket = try std.posix.socket(std.os.linux.AF.INET, std.os.linux.SOCK.DGRAM, 0);
    const addy = std.net.Ip4Address.init(.{ 127, 0, 0, 1 }, 5004);
    try std.posix.bind(socket, @ptrCast(&addy.sa), @sizeOf(@TypeOf(addy.sa)));

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

pub fn main() !void {
    const socket = try openUdpSocket();
    var buf: [1 * 1024 * 1024]u8 = undefined;

    const wav_f = try std.fs.cwd().createFile("wav.csv", .{});
    var writer_buf: [4096]u8 = undefined;
    var wav_writer_concrete = wav_f.writer(&writer_buf);
    var wav_writer = &wav_writer_concrete.interface;

    for (0..10) |_| {
        const recv_len = try std.posix.recvfrom(socket, &buf, 0, null, null);
        const received = buf[0..recv_len];

        var r = std.Io.Reader.fixed(received);
        const header = try RtpHeader.parse(&r);
        if (header.payload_type != 0) return error.UnknownPayload;

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
