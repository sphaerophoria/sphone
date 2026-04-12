const std = @import("std");

pub const wsp_chars = " \t";

pub fn consumeSws(buf: []const u8, pos: usize) usize {
    for (wsp_chars) |c| {
        if (buf[pos] == c) return pos + 1;
    }

    return pos;
}
