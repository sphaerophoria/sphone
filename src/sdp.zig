const parse = @import("parse.zig");
const std = @import("std");

// Returns range of version information
pub fn protoVersion(tc: *parse.TokenConsumer) ?parse.Range {
    //proto-version =       %x76 "=" 1*DIGIT CRLF
    //                      ;this memo describes version 0
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeChar('v') orelse return null;
    _ = tc.takeChar('=') orelse return null;

    var version_start = tc.checkpoint();

    _ = parse.digitRange(tc, 1, std.math.maxInt(usize)) orelse return null;

    const version = version_start.commit();

    _ = parse.crlf(tc) orelse return null;

    _ = cp.commit();

    return version;
}

fn nonWsStringChar(tc: *parse.TokenConsumer) ?parse.Idx {
    if (parse.vchar(tc)) |i| return i;
    if (tc.takeCharRange(0x80, 0xff)) |i| return i;
    return null;
}

fn nonWsString(tc: *parse.TokenConsumer) ?parse.Range {
    //non-ws-string =       1*(VCHAR/%x80-FF)
    //                      ;string of visible characters
    //

    var cp = tc.checkpoint();
    defer cp.restore();

    _ = nonWsStringChar(tc) orelse return null;

    while (true) {
        _ = nonWsStringChar(tc) orelse break;
    }

    return cp.commit();
}

fn username(tc: *parse.TokenConsumer) ?parse.Range {
    return nonWsString(tc);
}

fn tokenChar(tc: *parse.TokenConsumer) ?parse.Idx {
    //token-char =          %x21 / %x23-27 / %x2A-2B / %x2D-2E / %x30-39
    //                      / %x41-5A / %x5E-7E
    if (tc.takeChar(0x21)) |i| return i;
    if (tc.takeCharRange(0x23, 0x27)) |i| return i;
    if (tc.takeCharRange(0x2a, 0x2b)) |i| return i;
    if (tc.takeCharRange(0x2d, 0x2e)) |i| return i;
    if (tc.takeCharRange(0x30, 0x39)) |i| return i;
    if (tc.takeCharRange(0x41, 0x5a)) |i| return i;
    if (tc.takeCharRange(0x5e, 0x7e)) |i| return i;
    return null;
}

fn token(tc: *parse.TokenConsumer) ?parse.Range {
    //token =               1*(token-char)
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tokenChar(tc) orelse return null;

    while (true) {
        _ = tokenChar(tc) orelse break;
    }

    return cp.commit();
}

fn decimalUchar(tc: *parse.TokenConsumer) ?parse.Range {
    //POS-DIGIT =           %x31-39 ; 1 - 9
    //decimal-uchar =       DIGIT
    //                      / POS-DIGIT DIGIT
    //                      / ("1" 2*(DIGIT))
    //                      / ("2" ("0"/"1"/"2"/"3"/"4") DIGIT)
    //                      / ("2" "5" ("0"/"1"/"2"/"3"/"4"/"5"))

    // The above kinda just says "decimal values in the range 0-255"
    // It's easier for me to implement as "parse up to 3 digits and fail if
    // we're out of range :)"

    var cp = tc.checkpoint();
    defer cp.restore();

    const range = parse.digitRange(tc, 1, 3) orelse return null;

    const data = range.data(tc.buf);
    const parsed = std.fmt.parseInt(u8, data, 10) catch return null;
    if (parsed > 255) return null;

    return cp.commit();
}

fn ip4Address(tc: *parse.TokenConsumer) ?parse.Range {
    //IP4-address =         b1 3("." decimal-uchar)

    //b1 =                  decimal-uchar
    //                      ; less than "224"
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = decimalUchar(tc) orelse return null;

    for (0..3) |_| {
        _ = tc.takeChar('.') orelse return null;
        _ = decimalUchar(tc) orelse return null;
    }

    return cp.commit();
}

const Origin = struct {
    username: parse.Range,
    session_id: parse.Range,
    session_version: parse.Range,
    net_type: parse.Range,
    addr_type: parse.Range,
    unicast_addr: parse.Range,
};

pub fn origin(tc: *parse.TokenConsumer) !?Origin {
    //origin-field =        %x6f "=" username SP sess-id SP sess-version SP
    //                      nettype SP addrtype SP unicast-address CRLF

    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeChar('o') orelse return null;
    _ = tc.takeChar('=') orelse return null;

    const u = username(tc) orelse return null;
    _ = parse.sp(tc) orelse return null;
    const id = parse.digitRange(tc, 1, std.math.maxInt(usize)) orelse return null;
    _ = parse.sp(tc) orelse return null;
    const version = parse.digitRange(tc, 1, std.math.maxInt(usize)) orelse return null;
    _ = parse.sp(tc) orelse return null;
    const net_type = token(tc) orelse return null;
    _ = parse.sp(tc) orelse return null;
    const addr_type = token(tc) orelse return null;
    _ = parse.sp(tc) orelse return null;

    if (!std.mem.eql(u8, "IP4", addr_type.data(tc.buf))) {
        return error.Unimplemented;
    }

    const unicast_addr = ip4Address(tc) orelse return null;

    _ = parse.crlf(tc) orelse return null;

    _ = cp.commit();

    return .{
        .username = u,
        .session_id = id,
        .session_version = version,
        .net_type = net_type,
        .addr_type = addr_type,
        .unicast_addr = unicast_addr,
    };
}

fn byteStringChar(tc: *parse.TokenConsumer) ?parse.Idx {
    //byte-string =         1*(%x01-09/%x0B-0C/%x0E-FF)
    //                      ;any byte except NUL, CR, or LF
    if (tc.takeCharRange(0x1, 0x9)) |i| return i;
    if (tc.takeCharRange(0xb, 0xc)) |i| return i;
    if (tc.takeCharRange(0xe, 0xff)) |i| return i;

    return null;
}

fn byteString(tc: *parse.TokenConsumer) ?parse.Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = byteStringChar(tc) orelse return null;

    while (true) {
        _ = byteStringChar(tc) orelse break;
    }

    return cp.commit();
}

fn sessionNameField(tc: *parse.TokenConsumer) ?parse.Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeString("s=") orelse return null;
    const ret = byteString(tc) orelse return null;
    _ = parse.crlf(tc) orelse return null;
    _ = cp.commit();

    return ret;
}

fn informationField(tc: *parse.TokenConsumer) ?parse.Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeString("i=") orelse return null;
    const ret = byteString(tc) orelse return null;
    _ = parse.crlf(tc) orelse return null;
    _ = cp.commit();

    return ret;
}

fn uriField(tc: *parse.TokenConsumer) ?parse.Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeString("u=") orelse return null;

    // Note that this is technically wrong, I don't want to parse a URI right
    // now, we can leave that up to the caller :)
    const ret = byteString(tc);

    _ = cp.commit();

    return ret;
}

fn ignoreSdpLine(tc: *parse.TokenConsumer, c: u8) bool {
    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeChar(c) orelse return false;
    _ = tc.takeChar('=') orelse return false;
    _ = byteString(tc) orelse return false;

    _ = parse.crlf(tc) orelse return false;

    _ = cp.commit();

    return true;
}

const ConnectionField = struct {
    net_type: parse.Range,
    addr_type: parse.Range,
    connection_address: parse.Range,
};

fn connectionField(tc: *parse.TokenConsumer) !?ConnectionField {
    //connection-field =    [%x63 "=" nettype SP addrtype SP
    //                      connection-address CRLF]
    //                      ;a connection field must be present
    //                      ;in every media description or at the
    //                      ;session-level

    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeString("c=") orelse return null;

    const net_type = token(tc) orelse return null;
    _ = parse.sp(tc) orelse return null;
    const addr_type = token(tc) orelse return null;
    _ = parse.sp(tc) orelse return null;

    if (!std.mem.eql(u8, "IP4", addr_type.data(tc.buf))) {
        return error.Unimplemented;
    }

    const addr = ip4Address(tc) orelse return null;

    _ = parse.crlf(tc) orelse return null;

    _ = cp.commit();

    return .{
        .net_type = net_type,
        .addr_type = addr_type,
        .connection_address = addr,
    };
}

fn proto(tc: *parse.TokenConsumer) ?parse.Range {
    var cp = tc.checkpoint();
    defer cp.restore();

    //proto  =              token *("/" token)
    //                      ;typically "RTP/AVP" or "udp"
    _ = token(tc) orelse return null;

    while (true) {
        var loop_cp = tc.checkpoint();
        defer loop_cp.restore();

        _ = tc.takeChar('/') orelse break;
        _ = token(tc) orelse break;

        _ = loop_cp.commit();
    }

    return cp.commit();
}

const MediaField = struct {
    media: parse.Range,
    port: parse.Range,
    num_ports: ?parse.Range,
    protocol: parse.Range,
    formats: []parse.Range,
};

fn mediaField(alloc: std.mem.Allocator, tc: *parse.TokenConsumer) !?MediaField {
    //media-field =         %x6d "=" media SP port ["/" integer]
    //                      SP proto 1*(SP fmt) CRLF

    var cp = tc.checkpoint();
    defer cp.restore();

    _ = tc.takeString("m=") orelse return null;
    const m = token(tc) orelse return null;
    _ = parse.sp(tc) orelse return null;
    const port = parse.digitRange(tc, 1, std.math.maxInt(usize)) orelse return null;

    var num_ports: ?parse.Range = null;

    if (tc.takeChar('/')) |_| {
        num_ports = parse.digitRange(tc, 1, std.math.maxInt(usize)) orelse return null;
    }

    _ = parse.sp(tc) orelse return null;
    const p = proto(tc) orelse return null;

    _ = parse.sp(tc) orelse return null;

    var fmts = std.ArrayList(parse.Range).empty;
    try fmts.append(alloc, token(tc) orelse return null);

    while (token(tc)) |r| {
        try fmts.append(alloc, r);
    }

    _ = cp.commit();

    return .{
        .media = m,
        .port = port,
        .num_ports = num_ports,
        .protocol = p,
        .formats = fmts.items,
    };
}

const MediaDescription = struct {
    media: MediaField,

    // Other fields are ignored for now, but are relevant. Single field struct
    // makes more sense for future code
};

pub fn mediaDescription(alloc: std.mem.Allocator, tc: *parse.TokenConsumer) !?MediaDescription {
    const media = try mediaField(alloc, tc) orelse return null;

    _ = ignoreSdpLine(tc, 'i');
    while (ignoreSdpLine(tc, 'c')) {}
    while (ignoreSdpLine(tc, 'b')) {}
    _ = ignoreSdpLine(tc, 'k');
    while (ignoreSdpLine(tc, 'a')) {}

    return .{
        .media = media,
    };
}

const SessionDescription = struct {
    version: parse.Range,
    origin: Origin,
    connection: ?ConnectionField,
    media_descriptions: []MediaDescription,
};

pub fn sessionDescription(alloc: std.mem.Allocator, tc: *parse.TokenConsumer) !?SessionDescription {
    // I THINK this is supposed to just be 0, otherwise the spec we are reading
    // doesn't know about it :)
    const v = protoVersion(tc) orelse return null;
    const o = try origin(tc) orelse return null;

    _ = ignoreSdpLine(tc, 's');
    _ = ignoreSdpLine(tc, 'i');
    _ = ignoreSdpLine(tc, 'u');
    while (ignoreSdpLine(tc, 'e')) {}
    while (ignoreSdpLine(tc, 'p')) {}

    const c = try connectionField(tc);

    while (ignoreSdpLine(tc, 'b')) {}
    while (ignoreSdpLine(tc, 't')) {}
    _ = ignoreSdpLine(tc, 'k');
    while (ignoreSdpLine(tc, 'a')) {}

    var media_descriptions = std.ArrayList(MediaDescription).empty;

    while (try mediaDescription(alloc, tc)) |md| {
        try media_descriptions.append(alloc, md);
    }

    return .{
        .version = v,
        .origin = o,
        .connection = c,
        .media_descriptions = media_descriptions.items,
    };
}
