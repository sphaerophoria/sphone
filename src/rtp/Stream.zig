const std = @import("std");
const sphtud = @import("sphtud");
const RtpFrame = @import("Frame.zig");
const g711 = @import("../g711.zig");

inner: union(enum) {
    pending: std.Io.Duration, // Initial buffer period
    initialized: Initialized,
},

const Initialized = struct {
    head_timestamp: u32,
    last_tail_update: std.Io.Timestamp,
};

const RtpStream = @This();

pub fn init(init_bufer_period: std.Io.Duration) RtpStream {
    return .{
        .inner = .{
            .pending = init_bufer_period,
        },
    };
}

const FrameAction = union(enum) {
    write: struct {
        offset: usize, // Offset in samples relative to last commit time
        it: g711.Iter,
    },
    skip,
};

const sample_rate = 8000;

pub fn onFrame(self: *RtpStream, frame_data: []const u8) !FrameAction {
    const frame = try RtpFrame.parse(frame_data);

    // For now we only support PCMU
    switch (frame.payload_type) {
        .pcmu => {},
        else => return .skip,
    }
    std.debug.assert(sample_rate == 8000);

    const inner = try self.ensureInnerInitialized(frame.timestamp);

    if (frame.timestamp < inner.head_timestamp) {
        // Not much of an algo right now, just buffer such that we never miss
        // anything :)
        const increase_amount_samples = inner.head_timestamp - frame.timestamp;
        const increase_amount_ns = @as(u63, std.time.ns_per_s) * increase_amount_samples / sample_rate;
        inner.last_tail_update = inner.last_tail_update.addDuration(.fromNanoseconds(increase_amount_ns));
    }

    return .{
        .write = .{
            .offset = frame.timestamp - inner.head_timestamp,
            .it = g711.Iter.init(frame.payload),
        },
    };
}

fn ensureInnerInitialized(self: *RtpStream, timestamp: u32) !*Initialized {
    const initial_buffer_period = switch (self.inner) {
        .pending => |d| d,
        .initialized => |*i| return i,
    };

    const now = try sphtud.io.clock_gettime(.BOOTTIME);
    self.inner = .{
        .initialized = .{
            .head_timestamp = timestamp,
            .last_tail_update = now.addDuration(initial_buffer_period),
        },
    };

    return &self.inner.initialized;
}

pub fn onTimeout(self: *RtpStream) !usize {
    const now = try sphtud.io.clock_gettime(.BOOTTIME);

    const inner = switch (self.inner) {
        .initialized => |*i| i,
        .pending => return 0,
    };

    const elapsed_since_update_ns = inner.last_tail_update.durationTo(now).toNanoseconds();
    if (elapsed_since_update_ns < 0) {
        return 0;
    }

    const elapsed_since_update_samples: usize = @intCast(@divTrunc(elapsed_since_update_ns * sample_rate, std.time.ns_per_s));

    // Anything above u32 max behaves as if it didn't happen, truncate should
    // be correct
    inner.head_timestamp +%= @truncate(elapsed_since_update_samples);
    inner.last_tail_update = now;

    return elapsed_since_update_samples;
}
