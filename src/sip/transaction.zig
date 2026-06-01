const std = @import("std");
const sphtud = @import("sphtud");
const Transport = @import("Transport.zig");

pub const OutgoingInvite = @import("transaction/OutgoingInvite.zig");
pub const IncomingInvite = @import("transaction/IncomingInvite.zig");

const sip = @import("../sip.zig");

pub const OutgoingInviteParams = struct {
    uri: []const u8,
    to: []const u8,
    from: []const u8,
    sent_by: []const u8,
    rtp_port: u16,
};

pub const OutgoingInviteReq = struct {
    invite: OutgoingInvite,
    to_send: Transport.Buffer,
};

pub fn makeOutgoingInviteReq(
    arena: std.mem.Allocator,
    out_buf: []u8,
    rand: std.Random,
    params: OutgoingInviteParams,
) !OutgoingInviteReq {
    const branch_id = sip.genBranchId(rand);

    var call_id: [sip.globally_unique_hex_len]u8 = undefined;
    sip.genRandHex(rand, &call_id);

    var message_w = std.Io.Writer.fixed(out_buf);

    const cseq = rand.int(u16);
    var cseq_buf: [1024]u8 = undefined;
    const cseq_s = std.fmt.bufPrint(&cseq_buf, "{d} INVITE", .{cseq}) catch unreachable;

    var req = try sip.ClientRequestWriter.init(.{
        .method = .INVITE,
        .uri = params.uri,
        .via = .{
            .sent_by = params.sent_by,
            .branch = &branch_id,
        },
        .to = params.to,
        .from = params.from,
        .call_id = &call_id,
        .cseq = cseq_s,
    }, &message_w);

    // SDP copied from linphone and stripped down until it looked about right
    var body_buf: [1024]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "v=0\r\n" ++
        "o=streamer 416 78 IN IP4 127.0.0.1\r\n" ++
        "s=Talk\r\n" ++
        "c=IN IP4 127.0.0.1\r\n" ++
        "t=0 0\r\n" ++
        "m=audio {d} RTP/AVP 0\r\n", .{params.rtp_port});

    var body_len_buf: [4]u8 = undefined;
    const body_len = try std.fmt.bufPrint(&body_len_buf, "{d}", .{body.len});

    try req.writeHeader("Content-Type", "application/sdp");
    try req.writeHeader("Content-Length", body_len);
    try req.writeHeader("Contact", "<sip:streamer@127.0.0.1;transport=tcp>");
    const to_send = try req.finish(body);

    const invite = OutgoingInvite{
        .negotiated_sdp = &.{},
        .call_id = try arena.dupe(u8, &call_id),
        .sent_by = try arena.dupe(u8, params.sent_by),
        .branch_id = try arena.dupe(u8, &branch_id),
        .request_uri = try arena.dupe(u8, params.uri),
        .from = try arena.dupe(u8, params.from),
        .cseq = cseq,
        .state = .wait_ok,
    };

    return .{
        .invite = invite,
        .to_send = to_send,
    };
}
