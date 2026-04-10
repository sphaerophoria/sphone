const std = @import("std");
const sphtud = @import("sphtud");
const sip = @import("sip.zig");

const Events = struct {
    const accept = 1;
    const new_read = 3;
};

fn isWouldBlock(r: *std.net.Stream.Reader, e: anyerror) bool {
    if (e != error.ReadFailed) return false;
    const source_error = r.getError() orelse return false;
    return source_error == error.WouldBlock;
}

const MessageType = enum {
    ok,
    other
};

fn printWhatYouCan(sr: *std.net.Stream.Reader) !MessageType {
    const r: *std.Io.Reader = sr.interface();

    var message_type = MessageType.other;
    const first_line = r.takeDelimiterInclusive('\n') catch |e| {
        if (isWouldBlock(sr, e)) return message_type;
        return e;
    };
    std.debug.print("{s}", .{first_line});

    if (std.mem.containsAtLeast(u8, first_line, 1, "200 OK\r")) message_type = .ok;

    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch |e| {
            if (isWouldBlock(sr, e)) return message_type;
            return e;
        };

        std.debug.print("{s}", .{line});
    }
}

fn hexWhatYouCan(sr: *std.net.Stream.Reader) !void {
    const r: *std.Io.Reader = sr.interface();

    while (true) {
        const b = r.takeByte() catch |e| {
            if (isWouldBlock(sr, e)) {
                std.debug.print("\n", .{});
                return;
            }
            return e;
        };

        std.debug.print("{x:<02} ", .{b});
    }
}

const ActiveConnection = struct {
    stream: std.net.Stream,
    reader: std.net.Stream.Reader,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const in_addr = std.net.Address.initIp4(.{127, 0, 0, 1}, 5060);
    var in_socket = try in_addr.listen(.{
        .reuse_address = true,
    });

    // FIXME: Maybe 1 MTU is good enough?
    var transport: sip.Transport(100, 4096) = undefined;
    transport.initPinned();

    var transaction_manager: sip.TransactionManager(100) = undefined;
    transaction_manager.initPinned();

    // IO subsystem
    // when there is data available on connection X call me with number 50

    // FIXME: Req needs to come from the transaction manager
    // Transaction manager needs to generate branch param and tie it back??
    // OR at least mark the branch parameter

    var rng = blk: {
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        try std.posix.getrandom(&seed);
        break :blk std.Random.DefaultCsprng.init(seed);
    };

    // Transaction
    //   * transaction state
    //   * transaction ID -- branch + cseq method
    //
    const branch_id = sip.genBranchId(rng.random());
    std.debug.print("branch_id: {s}\n", .{branch_id});

    // FIXME: Wrap invite creation somewhere? Maybe a higher level Sip
    try transaction_manager.createRequest(&branch_id, .invite);

    // FIXME: Do something else
    var via_buf: [4096]u8 = undefined;
    const via = try std.fmt.bufPrint(&via_buf, "SIP/2.0/TCP 127.0.0.1:5060;branch={s}", .{&branch_id});

    var req = try transport.makeRequest(alloc, .{
        .method = "INVITE",
        .uri = "sip:mick-terminal@127.0.0.1:5062",
        .via = via,
        .to = "mick-terminal <sip:mick-terminal@127.0.0.1:5062>",
        .from = "mick <sip:mick@127.0.0.1>;tag=1928301774",
        .call_id = "3YhCFaopvB",
        .cseq = "314159 INVITE",
        // FIXME: max forwards is claimed to be reuqired, but our linphone invite does not have it
        .max_forwards = "70",
    });

    // Genreate branch id + method
    // Feed to transaction manager
    // Send via transport

    const body = "v=0\r\n" ++
        "o=streamer 416 78 IN IP4 127.0.0.1\r\n" ++
        "s=Talk\r\n" ++
        "c=IN IP4 127.0.0.1\r\n" ++
        "t=0 0\r\n" ++
        "a=rtcp-xr:rcvr-rtt=all:10000 stat-summary=loss,dup,jitt,TTL voip-metrics\r\n" ++
        "a=record:off\r\n" ++
        "m=audio 48013 RTP/AVP 96 97 98 0 8 101 99 100\r\n" ++
        "a=rtpmap:96 opus/48000/2\r\n" ++
        "a=fmtp:96 useinbandfec=1\r\n" ++
        "a=rtpmap:97 speex/16000\r\n" ++
        "a=fmtp:97 vbr=on\r\n" ++
        "a=rtpmap:98 speex/8000\r\n" ++
        "a=fmtp:98 vbr=on\r\n" ++
        "a=rtpmap:101 telephone-event/48000\r\n" ++
        "a=rtpmap:99 telephone-event/16000\r\n" ++
        "a=rtpmap:100 telephone-event/8000\r\n" ++
        "a=rtcp:56541\r\n" ++
        "a=rtcp-fb:* trr-int 5000\r\n" ++
        "a=rtcp-fb:* ccm tmmbr\r\n";

    // FIXME: Ew
    var body_len_buf: [4]u8 = undefined;
    const body_len = try std.fmt.bufPrint(&body_len_buf, "{d}", .{body.len});

    try req.writer.writeHeader("Content-Type", "application/sdp");
    try req.writer.writeHeader("Content-Length", body_len);
    try req.writer.writeHeader("Contact", "<sip:streamer@127.0.0.1;transport=tcp>;+org.linphone.specs=\"lime\"");
    try req.writer.finish(body);

    var loop = try sphtud.event.Loop2.init();

    try loop.register(.{
        .handle = in_socket.stream.handle,
        .id = Events.accept,
        .read = true,
        .write = false
    });

    const base_transport_id = 100;
    try loop.register(.{
        .handle = try transport.connFd(req.conn_handle),
        .id = base_transport_id + req.service_handle,
        .read = true,
        .write = false
    });

    //var ack_sent = false;

    var active_reader_buf: [4096]u8 = undefined;
    var active_connection: ?ActiveConnection = null;
    while (true) {
        const event = (try loop.poll(-1)) orelse continue;
        switch (event) {
            Events.accept => {
                if (active_connection) |*a| {
                    a.stream.close();
                    active_connection = null;
                }

                const stream = try in_socket.accept();
                const reader = stream.stream.reader(&active_reader_buf);
                active_connection = .{
                    .stream = stream.stream,
                    .reader = reader,
                };

                try sphtud.event.setNonblock(stream.stream.handle);

                try loop.register(.{
                    .handle = stream.stream.handle,
                    .id = Events.new_read,
                    .read = true,
                    .write = false
                });
            },
            //Events.source_read => {
            //    std.debug.print("Got message on source\n-----\n", .{});
            //    const message_type = try printWhatYouCan(&source_reader);
            //    std.debug.print("\n-----\n", .{});

            //    if (message_type == .ok and !ack_sent) {

            //        std.debug.print("SENDING ACK\n", .{});
            //        ack_sent = true;
            //        try w.writeAll(
            //            "ACK sip:mick-terminal@127.0.0.1:5062 SIP/2.0\r\n" ++
            //            "Via: SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bK.641H~Jw20;rport\r\n" ++
            //            "From: <sip:streamer@192.168.1.105>;tag=WcPQUVPZf\r\n" ++
            //            "To: <sip:mick-terminal@127.0.0.1>;tag=Wt4PGNRJAwvmPzREtTmL7o8kocfXWmqX\r\n" ++
            //            "CSeq: 20 ACK\r\n" ++
            //            "Call-ID: QUjvnPXpCj\r\n" ++
            //            "Max-Forwards: 70\r\n" ++
            //            "User-Agent: Linphone-Desktop/5.3.3 (cavetroll-linux-nixos) nixos/25.11 Qt/5.15.18 LinphoneSDK/5.4.0\r\n\r\n"
            //        );

            //        try w.flush();
            //    }
            //},
            //Events.new_read => {
            //    std.debug.print("Got message on connection\n-----\n", .{});
            //    try hexWhatYouCan(&active_connection.?.reader);
            //    std.debug.print("\n-----\n", .{});
            //},
            else => {
                if (event >= base_transport_id) {
                    const reader = try transport.readerFromServiceId(event - base_transport_id);
                    transaction_manager.processResponse(reader);
                }
            },
        }
    }
}
