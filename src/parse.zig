
// Something that holds an index + buffer, and gives us utilities to check and
// consume the next pieces
//
// Handle rollback
//
// Something that makes loops easier to manage [N,M] <some complex thing>
pub const TokenConsumer = struct {
    buf: []const u8,
    idx: usize,

    pub fn init(buf: []const u8) TokenConsumer {
        return .{ .buf = buf, .idx = 0 };
    }

    pub const Checkpoint = struct {
        tc: *TokenConsumer,
        start: usize,
        committed: usize,

        pub fn restore(self: *Checkpoint) void {
            self.tc.idx = self.committed;
        }

        pub fn commit(self: *Checkpoint) Range {
            self.committed = self.tc.idx;
            return .{ .start = self.start, .end = self.tc.idx };
        }
    };

    pub fn checkpoint(self: *TokenConsumer) Checkpoint {
        return .{
            .tc = self,
            .start = self.idx,
            .committed = self.idx,
        };
    }

    pub fn takeChar(self: *TokenConsumer, expected: u8) ?Idx {
        const c = self.currentChar() orelse return null;

        if (c != expected) return null;

        defer self.idx += 1;
        return Idx { self.idx };
    }

    // inclusive range
    pub fn takeCharRange(self: *TokenConsumer, start: u8, end: u8) ?Idx {
        const c = self.currentChar() orelse return null;
        if (c < start or c > end) return null;

        defer self.idx += 1;
        return Idx { self.idx };
    }

    pub fn takeString(self: *TokenConsumer, s: []const u8) ?Range {
        var cp = self.checkpoint();
        defer cp.restore();

        for (s) |c| {
            _ = self.takeChar(c) orelse return null;
        }

        return cp.commit();
    }

    fn currentChar(self: *TokenConsumer) ?u8 {
        if (self.idx >= self.buf.len) return null;
        return self.buf[self.idx];
    }
};

pub const Range = struct {
    start: usize,
    // Exclusive
    end: usize,

    pub fn fromIdx(idx: Idx) Range {
        return .{ .start = idx[0], .end = idx[0] + 1 };
    }

    pub fn data(self: Range, buf: []const u8) []const u8 {
        return buf[self.start..self.end];
    }
};

pub const Idx = struct { usize };

pub fn alpha(tc: *TokenConsumer) ?Idx {
    if (tc.takeCharRange('a', 'z')) |idx| return idx;
    if (tc.takeCharRange('A', 'Z')) |idx| return idx;
    return null;
}

pub fn bit(tc: *TokenConsumer) ?Idx {
    if (tc.takeChar('0')) |idx| return idx;
    if (tc.takeChar('1')) |idx| return idx;
    return null;
}

pub fn char(tc: *TokenConsumer) ?Idx {
    return tc.takeCharRange(0x01, 0x7f);
}

pub fn cr(tc: *TokenConsumer) ?Idx {
    return tc.takeChar('\r');
}

pub fn crlf(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = cr(tc);
    _ = lf(tc);

    return cp.commit();
}

pub fn ctl(tc: *TokenConsumer) ?Idx {
    if (tc.takeCharRange(0x00, 0x1f)) |idx| return idx;
    if (tc.takeChar(0x7f)) |idx| return idx;
    return null;
}

pub fn digit(tc: *TokenConsumer) ?Idx {
    return tc.takeCharRange('0', '9');
}

pub fn dquote(tc: *TokenConsumer) ?Idx {
    return tc.takeChar('"');
}

pub fn hexdig(tc: *TokenConsumer) ?Idx {
    if (digit(tc)) |idx| return idx;
    if (tc.takeCharRange('A', 'F')) |idx| return idx;
    return null;
}

pub fn htab(tc: *TokenConsumer) ?Idx {
    return tc.takeChar(0x09);
}

pub fn lf(tc: *TokenConsumer) ?Idx {
    return tc.takeChar('\n');
}

pub fn lwsp(tc: *TokenConsumer) ?Range {
    const checkpoint = tc.checkpoint();
    defer checkpoint.restore();

    while (lwsp_helper.iter()) |_| {}

    return checkpoint.commit();
}

pub fn crlfwsp(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = crlf(tc) orelse return null;
    _ = wsp(tc) orelse return null;

    return cp.commit();
}

const lwsp_helper = struct {
    fn iter(tc: *TokenConsumer) ?Range {
        const cp = tc.checkpoint();
        defer cp.restore();

        if (wsp(tc)) |_| return cp.commit();
        if (crlfwsp(tc)) |_| return cp.commit();

        return null;
    }
};

pub fn octet(tc: *TokenConsumer) ?Idx {
    // FIXME: What a silly checked range
    return tc.takeCharRange(0x00, 0xff);
}
pub fn sp(tc: *TokenConsumer) ?Idx {
    return tc.takeChar(' ');
}

pub fn vchar(tc: *TokenConsumer) ?Idx {
    return tc.takeCharRange(0x21, 0x7e);
}

pub fn wsp(tc: *TokenConsumer) ?Idx {
    if (sp(tc)) |idx| return idx;
    if (htab(tc)) |idx| return idx;
    return null;
}
