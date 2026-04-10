const parse = @import("../parse.zig");
const std = @import("std");
const Range = parse.Range;
const Idx = parse.Idx;
const TokenConsumer = parse.TokenConsumer;

fn ipv4Digit(tc: *TokenConsumer) ?Range {
    var checkpoint = tc.checkpoint();
    defer checkpoint.restore();

    _ = parse.digit(tc) orelse return null;

    for (1..3) |_| {
        _ = parse.digit(tc) orelse break;
    }

    return checkpoint.commit();
}

pub fn ipv4Address(tc: *TokenConsumer) ?Range {
    var checkpoint = tc.checkpoint();
    defer checkpoint.restore();

    _ = ipv4Digit(tc) orelse return null;

    for (1..4) |_| {
        _ = tc.takeChar('.') orelse return null;
        _ = ipv4Digit(tc) orelse return null;
    }

    return checkpoint.commit();
}

pub fn hex4(tc: *TokenConsumer) ?Range {
    var checkpoint = tc.checkpoint();
    defer checkpoint.restore();

    _ = parse.hexdig(tc) orelse return null;
    for (1..4) |_| {
        _ = parse.hexdig(tc) orelse break;
    }

    return checkpoint.commit();
}

pub fn hexseq(tc: *TokenConsumer) ?Range {
    var checkpoint = tc.checkpoint();
    defer checkpoint.restore();

    _ = hex4(tc) orelse return null;

    while (true) {
        var iter_cp = tc.checkpoint();
        defer iter_cp.restore();

        _ = tc.takeChar(':') orelse break;
        _ = hex4(tc) orelse break;

        _ = iter_cp.commit();
    }

    return checkpoint.commit();
}

fn doubleColon(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    for (0..2) |_| {
        _ = tc.takeChar(':') orelse return null;
    }

    return cp.commit();
}

pub fn hexpart(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    const first = hexseq(tc); // optional if trailer is there
    const trailer = hexpartTrailer(tc);

    if (first != null or trailer) return cp.commit();
    return null;
}

fn hexpartTrailer(tc: *TokenConsumer) bool {
    _ = tc.takeChar(':') orelse return false;
    _ = tc.takeChar(':') orelse return false;
    _ = hexseq(tc); // Optional
    return true;
}

fn alphanum(tc: *TokenConsumer) ?Idx {
    if (parse.alpha(tc)) |r| return r;
    if (parse.digit(tc)) |r| return r;
    return null;
}

pub fn domainlabel(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = alphanum(tc) orelse return null;
    _ = domainlabelTrailer(tc); //optional

    return cp.commit();
}

// FIXME: Might want to take a look at this to see if there's some pattern to pull out
fn domainlabelTrailer(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    var last_alphanum = cp.start - 1;
    while (true) {
        if (alphanum(tc)) |idx| {
            last_alphanum = idx[0];
            continue;
        }

        if (tc.takeChar('-')) |_| continue;
        break;
    }

    tc.idx = last_alphanum + 1;

    return cp.commit();
}

test "domainLabel" {
    {
        const buf = "asdf-asdf asdflkj";
        var tc = TokenConsumer.init(buf);
        const range = domainlabel(&tc) orelse return error.ParseFailed;
        const text = range.data(buf);
        try std.testing.expectEqualStrings("asdf-asdf", text);
    }

    {
        const buf = "asdf-asdf- asdflkj";
        var tc = TokenConsumer.init(buf);
        const range = domainlabel(&tc) orelse return error.ParseFailed;
        const text = range.data(buf);
        try std.testing.expectEqualStrings("asdf-asdf", text);
    }

    {
        const buf = "a";
        var tc = TokenConsumer.init(buf);
        const range = domainlabel(&tc) orelse return error.ParseFailed;
        const text = range.data(buf);
        try std.testing.expectEqualStrings("a", text);
    }

    {
        const buf = "a-";
        var tc = TokenConsumer.init(buf);
        const range = domainlabel(&tc) orelse return error.ParseFailed;
        const text = range.data(buf);
        try std.testing.expectEqualStrings("a", text);
    }

    {
        const buf = "-asdf-asdf- asdflkj";
        var tc = TokenConsumer.init(buf);
        if (domainlabel(&tc)) |_| return error.UnexpectedParse;
    }
}

pub fn toplabel(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = parse.alpha(tc) orelse return null;
    _ = domainlabelTrailer(tc); // optional

    return cp.commit();
}

pub fn hostname(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    while (true) {
        var iter_cp = tc.checkpoint();
        defer iter_cp.restore();

        _ = domainlabel(tc) orelse break;
        _ = tc.takeChar('.') orelse break;

        _ = iter_cp.commit();
    }

    _ = toplabel(tc) orelse return null;
    _ = tc.takeChar('.'); //optional

    return cp.commit();
}

test "hostname sanity" {
    const buf = "012ahg-sj27.sh.01-23-4.the-end";
    var tc = TokenConsumer.init(buf);

    const range = hostname(&tc) orelse return error.ParseFailed;
    const data = range.data(buf);
    try std.testing.expectEqualStrings(buf, data);
}

pub fn ipv6Address(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = hexpart(tc) orelse return null;

    ipv6Trailer(tc);

    return cp.commit();
}

fn ipv6Trailer(tc: *TokenConsumer) void {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeChar(':') orelse return;
    _ = ipv4Address(tc) orelse return;

    _ = cp.commit();
}

pub fn ipv6Reference(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeChar('[') orelse return null;
    _ = ipv6Address(tc) orelse return null;
    _ = tc.takeChar(']') orelse return null;

    return cp.commit();
}

pub fn host(tc: *TokenConsumer) ?Range {
    if (hostname(tc)) |r| return r;
    if (ipv4Address(tc)) |r| return r;
    if (ipv6Reference(tc)) |r| return r;

    return null;
}

pub fn utf8Cont(tc: *TokenConsumer) ?Idx {
    return tc.takeCharRange(0x80, 0xbf);
}

pub fn utf8NonAscii(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    if (tc.takeCharRange(0xc0, 0xdf)) |_| {
        _ = utf8Cont(tc) orelse return null;
        return cp.commit();
    }

    if (tc.takeCharRange(0xe0, 0xef)) |_| {
        for (0..2) |_| {
            _ = utf8Cont(tc) orelse return null;
        }
        return cp.commit();
    }

    if (tc.takeCharRange(0xf0, 0xf7)) |_| {
        for (0..3) |_| {
            _ = utf8Cont(tc) orelse return null;
        }
        return cp.commit();
    }

    if (tc.takeCharRange(0xf8, 0xfb)) |_| {
        for (0..4) |_| {
            _ = utf8Cont(tc) orelse return null;
        }
        return cp.commit();
    }

    if (tc.takeCharRange(0xfc, 0xfd)) |_| {
        for (0..5) |_| {
            _ = utf8Cont(tc) orelse return null;
        }
        return cp.commit();
    }

    return null;
}

pub fn lws(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    while (true) {
        _ = parse.wsp(tc) orelse break;
    }

    const leading_ws_range = cp.commit();

    _ = parse.crlfwsp(tc) orelse {
        if (leading_ws_range.start == leading_ws_range.end) return null;
        return leading_ws_range;
    };

    while (true) {
        _ = parse.wsp(tc) orelse break;
    }

    return cp.commit();
}

test "lws sanity" {
    {
        const buf = "  asdf";
        var tc = TokenConsumer.init(buf);
        const range = lws(&tc) orelse return error.ParseError;
        try std.testing.expectEqualStrings("  ", range.data(buf));
    }

    {
        const buf = "  \r\n";
        var tc = TokenConsumer.init(buf);
        const range = lws(&tc) orelse return error.ParseError;
        try std.testing.expectEqualStrings("  ", range.data(buf));
    }

    {
        const buf = "  \r\n ";
        var tc = TokenConsumer.init(buf);
        const range = lws(&tc) orelse return error.ParseError;
        try std.testing.expectEqualStrings("  \r\n ", range.data(buf));
    }

    {
        const buf = "\r\n ";
        var tc = TokenConsumer.init(buf);
        const range = lws(&tc) orelse return error.ParseError;
        try std.testing.expectEqualStrings("\r\n ", range.data(buf));
    }

    {
        const buf = "\r\n";
        var tc = TokenConsumer.init(buf);
        if (lws(&tc)) |_| return error.UnexpectedParse;
    }
}

pub fn sws(tc: *TokenConsumer) ?Range {
    if (lws(tc)) |r| return r;
    return .{ .start = tc.idx, .end = tc.idx };
}

pub fn hcolon(tc: *TokenConsumer) ?Range {
    // HCOLON  =  *( SP / HTAB ) ":" SWS
    const cp = tc.checkpoint();
    defer cp.restore();

    while (true) {
        if (parse.sp(tc)) |_| continue;
        if (parse.htab(tc)) |_| continue;
        break;
    }

    _ = tc.takeChar(':') orelse return null;

    sws(tc) orelse return null;

    return cp.commit();
}

pub fn qdtext(tc: *TokenConsumer) ?Range {
    if (lws(tc)) |r| return r;
    if (tc.takeChar(0x21)) |i| return .fromIdx(i);
    if (tc.takeCharRange(0x23, 0x5b)) |i| return .fromIdx(i);
    if (tc.takeCharRange(0x5d, 0x7e)) |i| return .fromIdx(i);
    if (utf8NonAscii(tc)) |r| return r;
    return null;
}

pub fn quotedPair(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeChar('\\') orelse return null;

    if (tc.takeCharRange(0x0, 0x9)) |_| return cp.commit();
    if (tc.takeCharRange(0x0b, 0x0c)) |_| return cp.commit();
    if (tc.takeCharRange(0x0e, 0x7f)) |_| return cp.commit();

    return null;
}

pub fn quotedString(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = sws(tc) orelse return null;
    _ = parse.dquote(tc) orelse return null;

    while (true) {
        if (qdtext(tc)) |_| continue;
        if (quotedPair(tc)) |_| continue;
        break;
    }

    _ = parse.dquote(tc) orelse return null;

    return cp.commit();
}

pub fn genValue(tc: *TokenConsumer) ?Range {
    if (token(tc)) |r| return r;
    if (host(tc)) |r| return r;
    if (quotedString(tc)) |r| return r;
    return null;
}

const GenericParam = struct {
    key: Range,
    val: ?Range,
};

pub fn genericParam(tc: *TokenConsumer) ?GenericParam {
    const key = token(tc) orelse return null;

    var cp = tc.checkpoint();
    defer cp.restore();

    const key_only = GenericParam{
        .key = key,
        .val = null,
    };

    _ = equal(tc) orelse return key_only;
    const val = genValue(tc) orelse return key_only;

    _ = cp.commit();

    return .{
        .key = key,
        .val = val,
    };
}

pub fn token(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tokenElem(tc) orelse return null;

    while (tokenElem(tc)) |_| {}

    return cp.commit();
}

fn tokenElem(tc: *TokenConsumer) ?Idx {
    if (alphanum(tc)) |i| return i;
    if (tc.takeChar('-')) |i| return i;
    if (tc.takeChar('.')) |i| return i;
    if (tc.takeChar('!')) |i| return i;
    if (tc.takeChar('%')) |i| return i;
    if (tc.takeChar('*')) |i| return i;
    if (tc.takeChar('_')) |i| return i;
    if (tc.takeChar('+')) |i| return i;
    if (tc.takeChar('`')) |i| return i;
    if (tc.takeChar('\'')) |i| return i;
    if (tc.takeChar('~')) |i| return i;
    return null;
}

fn swsWrapped(tc: *TokenConsumer, char: u8) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = sws(tc) orelse return null;
    _ = tc.takeChar(char) orelse return null;
    _ = sws(tc) orelse return null;

    return cp.commit();
}

pub fn equal(tc: *TokenConsumer) ?Range {
    return swsWrapped(tc, '=');
}

pub fn semi(tc: *TokenConsumer) ?Range {
    return swsWrapped(tc, ';');
}

pub fn ttl(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = parse.digit(tc) orelse return null;
    for (1..3) |_| {
        _ = parse.digit(tc) orelse break;
    }

    return cp.commit();
}

pub fn port(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = parse.digit(tc) orelse return null;
    while (true) {
        _ = parse.digit(tc) orelse break;
    }

    return cp.commit();
}

pub fn sentBy(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = host(tc) orelse return null;

    const host_only = cp.commit();

    _ = colon(tc) orelse return host_only;
    _ = port(tc) orelse return host_only;

    return cp.commit();
}

pub fn colon(tc: *TokenConsumer) ?Range {
    return swsWrapped(tc, ':');
}

pub fn slash(tc: *TokenConsumer) ?Range {
    return swsWrapped(tc, '/');
}

pub fn otherTransport(tc: *TokenConsumer) ?Range {
    return token(tc);
}

pub fn transport(tc: *TokenConsumer) ?Range {
    // spec specificallky calls out UDP/TCP/TLS/SCTP, but these are a subset of otherTransport
    return otherTransport(tc);
}

pub fn protocolName(tc: *TokenConsumer) ?Range {
    // Spec calls out SIP, but this is a subset of token
    return token(tc);
}

pub fn protocolVersion(tc: *TokenConsumer) ?Range {
    return token(tc);
}

pub fn sentProtocol(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = protocolName(tc) orelse return null;
    _ = slash(tc) orelse return null;
    _ = protocolVersion(tc) orelse return null;
    _ = slash(tc) orelse return null;
    _ = transport(tc) orelse return null;

    return cp.commit();
}

// Returns ttl, not entire ttl=ttl string
pub fn viaTtl(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeString("ttl") orelse return null;
    _ = equal(tc) orelse return null;
    const ret = ttl(tc) orelse return null;

    _ = cp.commit();

    return ret;
}

// Returns host
pub fn viaMaddr(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeString("maddr") orelse return null;
    _ = equal(tc) orelse return null;
    const ret = host(tc) orelse return null;

    _ = cp.commit();

    return ret;
}

// Returns branch param
pub fn viaBranch(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeString("branch") orelse return null;
    _ = equal(tc) orelse return null;
    const ret = token(tc) orelse return null;

    _ = cp.commit();

    return ret;
}

pub fn viaExtension(tc: *TokenConsumer) ?GenericParam {
    return genericParam(tc);
}

pub fn viaReceived(tc: *TokenConsumer) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeString("received") orelse return null;
    _ = equal(tc) orelse return null;

    const ret = if (ipv4Address(tc)) |r| r else if (ipv6Address(tc)) |r| r else return null;

    _ = cp.commit();

    return ret;
}

pub const ViaParams = union(enum) {
    ttl: Range,
    maddr: Range,
    received: Range,
    branch: Range,
    extension: GenericParam,
};

pub fn viaParams(tc: *TokenConsumer) ?ViaParams {
    _ = semi(tc) orelse return null;

    var cp = tc.checkpoint();

    if (viaTtl(tc)) |r| return .{ .ttl = r };
    if (viaMaddr(tc)) |r| return .{ .maddr = r };
    if (viaReceived(tc)) |r| return .{ .received = r };
    if (viaBranch(tc)) |r| return .{ .branch = r };
    if (viaExtension(tc)) |p| return .{ .extension = p };

    cp.restore();
    return null;
}

pub const ViaParm = struct {
    sent_protocol: Range,
    sent_by: Range,
};

pub fn viaParm(tc: *TokenConsumer) ?ViaParm {
    const sent_protocol = sentProtocol(tc) orelse return null;
    _ = lws(tc) orelse return null;
    const sent_by = sentBy(tc) orelse return null;

    return .{
        .sent_protocol = sent_protocol,
        .sent_by = sent_by,
    };
}

test "ViaParser sanity" {
    const buf = "SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bK.641H~Jw20;rport";
    var tc = parse.TokenConsumer.init(buf);

    const header = viaParm(&tc) orelse return error.ParseFailure;

    try std.testing.expectEqualStrings("SIP/2.0/UDP", header.sent_protocol.data(buf));
    try std.testing.expectEqualStrings("127.0.0.1:5060", header.sent_by.data(buf));

    {
        const param = viaParams(&tc) orelse return error.ParseFailure;
        try std.testing.expectEqualStrings("z9hG4bK.641H~Jw20", param.branch.data(buf));
    }

    {
        const param = viaParams(&tc) orelse return error.ParseFailure;
        try std.testing.expectEqualStrings("rport", param.extension.key.data(buf));
    }

    try std.testing.expectEqual(null, viaParams(&tc));
}

pub const StatusLine = struct {
    version: SipVersion,
    status_code: Range,
    reason: Range,
};

pub fn statusLine(tc: *TokenConsumer) ?StatusLine {
    var cp = tc.checkpoint();
    defer cp.restore();

    const version = sipVersion(tc) orelse return null;
    _ = parse.sp(tc) orelse return null;
    const status_code = statusCode(tc) orelse return null;
    _ = parse.sp(tc) orelse return null;

    // Lazy, and possibly incorrect, but just take till the end of the line
    const eol = std.mem.findPos(u8, tc.buf, tc.idx, "\r\n") orelse tc.buf.len;
    const reason = Range{
        .start = tc.idx,
        .end = eol,
    };
    tc.idx = eol;

    _ = cp.commit();

    return .{
        .version = version,
        .status_code = status_code,
        .reason = reason,
    };
}

test "statusLine" {
    const line = "SIP/2.0 100 Trying";
    var tc = TokenConsumer.init(line);

    const status_line = statusLine(&tc) orelse return error.StatusParseFailed;

    try std.testing.expectEqualStrings("100", status_line.status_code.data(line));
    try std.testing.expectEqualStrings("2", status_line.version.major.data(line));
    try std.testing.expectEqualStrings("0", status_line.version.minor.data(line));
    try std.testing.expectEqualStrings("Trying", status_line.reason.data(line));
}

fn digitRange(tc: *TokenConsumer, min: usize, max: usize) ?Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    for (0..min) |_| {
        _ = parse.digit(tc) orelse return null;
    }

    for (min..max) |_| {
        _ = parse.digit(tc) orelse break;
    }

    return cp.commit();
}

const SipVersion = struct {
    major: Range,
    minor: Range,
};

pub fn sipVersion(tc: *TokenConsumer) ?SipVersion {
    //SIP-Version    =  "SIP" "/" 1*DIGIT "." 1*DIGIT
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeString("SIP/") orelse return null;

    const major = digitRange(tc, 1, std.math.maxInt(usize)) orelse return null;
    _ = tc.takeChar('.') orelse return null;
    const minor = digitRange(tc, 1, std.math.maxInt(usize)) orelse return null;

    _ = cp.commit();

    return .{
        .major = major,
        .minor = minor,
    };
}

pub fn statusCode(tc: *TokenConsumer) ?Range {
    return digitRange(tc, 3, 3);
}

pub const CSeq = struct {
    seq: Range,
    method: Range,
};

pub fn cseq(tc: *TokenConsumer) ?CSeq {
    //CSeq  =  1*DIGIT LWS Method
    var cp = tc.checkpoint();
    defer cp.restore();

    const seq = digitRange(tc, 1, std.math.maxInt(usize)) orelse return null;
    _ = lws(tc) orelse return null;
    const methodr = method(tc) orelse return null;

    _ = cp.commit();

    return .{
        .seq = seq,
        .method = methodr,
    };
}

pub fn method(tc: *TokenConsumer) ?Range {
    // Spec has specific callouts for INVITE/ACK/OPTIONS/etc./etc., along with
    // an extension method which is just any valid token. All options are
    // subsets of token, so there is no point in doing them separately. Parsing
    // into a nice enum will be done at a higher layer
    return token(tc);
}
