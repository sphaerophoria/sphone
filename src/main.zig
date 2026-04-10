const std = @import("std");
const sphtud = @import("sphtud");

const Events = struct {
    const accept = 1;
    const source_read = 2;
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
    //var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //const alloc = gpa.allocator();


    const addr = std.net.Address.initIp4(.{127, 0, 0, 1}, 5062);
    const s = try std.net.tcpConnectToAddress(addr);

    try sphtud.event.setNonblock(s.handle);

    var w_buf: [4096]u8 = undefined;
    var sw = s.writer(&w_buf);
    const w = &sw.interface;

    const in_addr = std.net.Address.initIp4(.{127, 0, 0, 1}, 5060);
    var in_socket = try in_addr.listen(.{
        .reuse_address = true,
    });

    try w.writeAll(
        "INVITE sip:mick-terminal@127.0.0.1:5062 SIP/2.0\r\n" ++
        "Via: SIP/2.0/TCP 127.0.0.1:5060;branch=z9hG4bK776asdhds\r\n" ++
        "To: mick-terminal <sip:mick-terminal@127.0.0.1:5062>\r\n" ++
        "From: mick <sip:mick@127.0.0.1>;tag=1928301774\r\n" ++
        "Call-ID: 3YhCFaopvB\r\n" ++
        "CSeq: 314159 INVITE\r\n" ++
        "Content-Type: application/sdp\r\n" ++
        "Content-Length: 517\r\n" ++
        "Contact: <sip:streamer@127.0.0.1;transport=tcp>;+org.linphone.specs=\"lime\"\r\n" ++
        "\r\n" ++
        "v=0\r\n" ++
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
        "a=rtcp-fb:* ccm tmmbr\r\n"
    );

    try w.flush();

    var loop = try sphtud.event.Loop2.init();

    try loop.register(.{
        .handle = in_socket.stream.handle,
        .id = Events.accept,
        .read = true,
        .write = false
    });

    try loop.register(.{
        .handle = s.handle,
        .id = Events.source_read,
        .read = true,
        .write = false
    });

    var source_reader_buf: [4096]u8 = undefined;
    var source_reader = s.reader(&source_reader_buf);
    var ack_sent = false;

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
            Events.source_read => {
                std.debug.print("Got message on source\n-----\n", .{});
                const message_type = try printWhatYouCan(&source_reader);
                std.debug.print("\n-----\n", .{});

                if (message_type == .ok and !ack_sent) {

                    std.debug.print("SENDING ACK\n", .{});
                    ack_sent = true;
                    try w.writeAll(
                        "ACK sip:mick-terminal@127.0.0.1:5062 SIP/2.0\r\n" ++
                        "Via: SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bK.641H~Jw20;rport\r\n" ++
                        "From: <sip:streamer@192.168.1.105>;tag=WcPQUVPZf\r\n" ++
                        "To: <sip:mick-terminal@127.0.0.1>;tag=Wt4PGNRJAwvmPzREtTmL7o8kocfXWmqX\r\n" ++
                        "CSeq: 20 ACK\r\n" ++
                        "Call-ID: QUjvnPXpCj\r\n" ++
                        "Max-Forwards: 70\r\n" ++
                        "User-Agent: Linphone-Desktop/5.3.3 (cavetroll-linux-nixos) nixos/25.11 Qt/5.15.18 LinphoneSDK/5.4.0\r\n\r\n"
                    );

                    try w.flush();
                }
            },
            Events.new_read => {
                std.debug.print("Got message on connection\n-----\n", .{});
                try hexWhatYouCan(&active_connection.?.reader);
                std.debug.print("\n-----\n", .{});
            },
            else => {},
        }
    }
}
