const std = @import("std");

pub fn decodePcmu(b_in: u8) i16 {
    const b = ~b_in;
    const m: i16 = @as(u4, @truncate(b));
    const e: u3 = @truncate(b >> 4);
    const s: u1 = @truncate(b >> 7);

    const sign_multiplier: i14 = if (s == 0) 1 else -1;

    var val = 33 + 2 * m;
    val *= std.math.pow(i16, 2, e);
    val -= 33;
    val *= sign_multiplier;

    // 14 bit int, shift by 2 to get it in the right range
    return val << 2;
}

pub const Iter = struct {
    data: []const u8,
    idx: usize,

    pub fn init(data: []const u8) Iter {
        return .{
            .idx = 0,
            .data = data,
        };
    }

    pub fn next(self: *Iter) ?i16 {
        if (self.idx >= self.data.len) return null;
        defer self.idx += 1;

        return decodePcmu(self.data[self.idx]);
    }
};
