const std = @import("std");
const sphtud = @import("sphtud");
const sdpm = @import("sdp.zig");
const parse = @import("parse.zig");
const sphaudio = @import("sphaudio");
const rtp = @import("rtp.zig");
const g711 = @import("g711.zig");
const PlaybackRtpStream = @import("io/PlaybackRtpStream.zig");

fn allocFile(alloc: std.mem.Allocator, path: [:0]const u8) ![]const u8 {
    const fd = try sphtud.io.open(path, .{
        .ACCMODE = .RDONLY,
    }, 0);
    defer sphtud.io.close(fd);

    var reader_buf: [4096]u8 = undefined;
    var r = sphtud.io.Reader.init(fd, &reader_buf);

    return try r.interface.allocRemaining(alloc, .unlimited);
}

const Ids = struct {
    audio: usize,
    rtp: PlaybackRtpStream.Ids,
    timer: usize,

    fn init() Ids {
        var alloc = sphtud.io.IdAlloc.init;
        return .{
            .audio = alloc.allocOne(),
            .rtp = .init(&alloc),
            .timer = alloc.allocOne(),
        };
    }
};

const ids = Ids.init();

pub fn main(init: std.process.Init.Minimal) !void {
    var arg_it = init.args.iterate();
    _ = arg_it.next();

    const sdp_path = arg_it.next().?;

    var alloc_buf: [1 * 1024 * 1024]u8 = undefined;
    var buf_alloc = sphtud.alloc.BufAllocator.init(&alloc_buf);
    const alloc = buf_alloc.allocator();

    var pw = try sphaudio.Pipewire.init();
    defer pw.deinit();

    var chain_buf: [100]usize = undefined;
    var loop = try sphtud.io.Loop.init(&chain_buf);

    try loop.register(.{
        .handle = pw.pollFd(),
        .id = ids.audio,
        .read = true,
        .write = false,
    });

    var timer_service = try sphtud.io.TimerService.init(
        alloc,
        buf_alloc.expansion(),
        &loop,
        ids.timer,
    );

    const sdp = try allocFile(alloc, sdp_path);

    const stream_info = try rtp.StreamInfo.fromSdp(buf_alloc.linear(), sdp);

    var rtp_stream: PlaybackRtpStream = undefined;
    try rtp_stream.initPinned(stream_info.ip, &pw, &loop, &timer_service, ids.rtp);
    defer rtp_stream.deinit(&timer_service);

    while (true) {
        const ev = try loop.poll(-1) orelse continue;

        switch (ev) {
            ids.audio => {
                try pw.service();
            },
            ids.rtp.total.start...ids.rtp.total.end => {
                try rtp_stream.service(ev, &timer_service, ids.rtp);
            },
            ids.timer => {
                try timer_service.service(&loop);
            },
            else => unreachable,
        }
    }
}
