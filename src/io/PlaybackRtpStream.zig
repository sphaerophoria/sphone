const std = @import("std");
const sphtud = @import("sphtud");
const sphaudio = @import("sphaudio");
const rtp = @import("../rtp.zig");
const Impl = rtp.Stream;

socket: std.posix.fd_t,
audio_buf: [1 * 1024 * 1024 / 4]i16,
audio_stream: sphaudio.Pipewire.AudioStream,

impl: Impl,

timer_handle: sphtud.io.TimerService.TimerHandle,

const PlaybackRtpStream = @This();

pub const Ids = struct {
    udp_recv: usize,
    timeout: usize,
    total: sphtud.io.IdAlloc.Range,

    pub fn init(alloc: *sphtud.io.IdAlloc) Ids {
        const start = alloc.mark();
        return .{
            .udp_recv = alloc.allocOne(),
            .timeout = alloc.allocOne(),
            .total = start.range(),
        };
    }
};

const timeout_service_ms = 10;

pub fn initPinned(self: *PlaybackRtpStream, ip: std.Io.net.IpAddress, pw: *sphaudio.Pipewire, loop: *sphtud.io.Loop, timer: *sphtud.io.TimerService, ids: Ids) !void {
    self.socket = try openUdpSocket(ip);
    errdefer sphtud.io.close(self.socket);

    try self.audio_stream.initPinned(pw, .{
        .num_channels = 1,
        .sample_rate = 8000,
        .buf = &self.audio_buf,
    });
    errdefer self.audio_stream.deinit();

    try loop.register(.{
        .handle = self.socket,
        .id = ids.udp_recv,
        .read = true,
        .write = false,
    });

    self.impl = .init(.fromMilliseconds(timeout_service_ms));

    self.timer_handle = try timer.add(.fromMilliseconds(timeout_service_ms), ids.timeout);
}

pub fn deinit(self: *PlaybackRtpStream, timer: *sphtud.io.TimerService) void {
    sphtud.io.close(self.socket);
    self.audio_stream.deinit();
    timer.remove(self.timer_handle);
}

pub fn service(self: *PlaybackRtpStream, id: usize, timer_service: *sphtud.io.TimerService, comptime ids: Ids) !void {
    switch (id) {
        ids.udp_recv => {
            self.serviceUdp() catch |e| {
                if (e == error.WouldBlock) return;
                return e;
            };
        },
        ids.timeout => {
            try self.onTimeout(timer_service);
        },
        else => unreachable,
    }
}

fn serviceUdp(self: *PlaybackRtpStream) !void {
    while (true) {
        // MTU 1600
        var buf: [4096]u8 = undefined;
        const recv_len = try sphtud.io.recvfrom(self.socket, &buf, 0, null, null);

        var params = switch (try self.impl.onFrame(buf[0..recv_len])) {
            .write => |params| params,
            .skip => continue,
        };

        var sample_idx: usize = 0;
        while (params.it.next()) |sample| {
            defer sample_idx += 1;

            for (0..self.audio_stream.num_channels) |i| {
                const write_idx = sample_idx * self.audio_stream.num_channels + i + params.offset;

                // FIXME: Silence handling + stream reset handling + out of bounds handling
                try self.audio_stream.sb.writePastHead(write_idx, sample);
            }
        }
    }
}

fn onTimeout(self: *PlaybackRtpStream, timer_service: *sphtud.io.TimerService) !void {
    try timer_service.rearm(self.timer_handle, .fromMilliseconds(timeout_service_ms));

    const samples_to_commit = try self.impl.onTimeout();
    self.audio_stream.sb.markWritten(samples_to_commit);
}

fn openUdpSocket(addr: std.Io.net.IpAddress) !std.posix.fd_t {
    const system = sphtud.io.system;
    const socket = try sphtud.io.socket(system.AF.INET, system.SOCK.DGRAM, 0);
    try sphtud.io.bind(socket, addr);

    return socket;
}
