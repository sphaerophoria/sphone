const std = @import("std");
const sip = @import("../sip.zig");

pub fn Transport(max_connections: usize, connection_buf_size: usize,) type {
    return struct {
        // FIXME: Find some allocation strategy
        connections: [max_connections]?Connection,

        const Self = @This();
        pub const Connection = struct {
            socket: std.net.Stream,
            read_buf: [connection_buf_size]u8,
            write_buf: [connection_buf_size]u8,
            reader: std.net.Stream.Reader,
            writer: std.net.Stream.Writer,

            fn initPinned(self: *Connection, scratch: std.mem.Allocator, params: ConnectionParams) !void {
                self.socket = try std.net.tcpConnectToHost(scratch, params.host, params.port);
                errdefer self.socket.close();

                self.reader = self.socket.reader(&self.read_buf);
                self.writer = self.socket.writer(&self.write_buf);
            }
        };

        pub fn initPinned(self: *Self) void {
            self.connections = @splat(null);
        }

        const Request = struct {
            conn_handle: usize,
            service_handle: usize,
            writer: sip.ClientRequestWriter,
        };

        pub fn readerFromServiceId(self: *Self, service_id: usize) !*std.Io.Reader {
            const connection = &(self.connections[service_id] orelse return error.InvalidId);
            return connection.reader.interface();
        }

        // FIXME: API does not provide a way to shut down a connection
        pub fn makeRequest(self: *Self, scratch: std.mem.Allocator, params: sip.ClientRequestWriter.InitParams) !Request {
            const connection_params = try ConnectionParams.fromUri(params.uri);

            // FIXME: Figure out if a valid connection for this URI exists
            const conn_id = self.findFreeConnection() orelse return error.NoConnectionsAvaialable;

            self.connections[conn_id] = @as(Connection, undefined);
            try self.connections[conn_id].?.initPinned(scratch, connection_params);

            return .{
                .conn_handle = conn_id,
                // FIXME: Strong type service handle
                .service_handle = conn_id,
                // FIXME: What is this line lol
                .writer = try sip.ClientRequestWriter.init(params, &self.connections[conn_id].?.writer.interface),
            };
        }

        // FIXME: Strong type handle
        pub fn connFd(self: *const Self, handle: usize) !std.posix.fd_t {
            const conn = &(self.connections[handle] orelse return error.InvalidHandle);
            return conn.socket.handle;
        }

        fn findFreeConnection(self: *Self) ?usize {
            // FIXME: Better strat
            for (&self.connections, 0..) |*c, i| {
                if (c.* == null) {
                    return i;
                }
            }

            return null;
        }
    };
}

fn indexOfScalarPosOffset(haystack: []const u8, pos: usize, needle: u8, offset: usize) ?usize {
    const needle_pos = std.mem.indexOfScalarPos(u8, haystack, pos, needle) orelse return null;
    const ret = needle_pos + offset;
    if (ret >= haystack.len) return null;
    return ret;
}


const ConnectionParams = struct {
    host: []const u8,
    port: u16,

    fn fromUri(uri: []const u8) !ConnectionParams {
        //example uri sip:mick-terminal@127.0.0.1:5062

        const host_start = indexOfScalarPosOffset(uri, 0, '@', 1) orelse return error.NoHost;
        var port: u16 = 5060;
        var host_end = uri.len;
        const port_start = indexOfScalarPosOffset(uri, host_start, ':', 1);
        if (port_start) |ps| {
            host_end = ps - 1;
            port = try std.fmt.parseInt(u16, uri[ps..], 10);
        }

        return .{
            .host = uri[host_start..host_end],
            .port = port,
        };

    }
};

test "uri parsing" {
    {
        const params = try ConnectionParams.fromUri("sip:mick-terminal@127.0.0.1:5062");
        try std.testing.expectEqualStrings("127.0.0.1", params.host);
        try std.testing.expectEqual(5062, params.port);
    }

    {
        const params = try ConnectionParams.fromUri("sip:mick-terminal@127.0.0.1");
        try std.testing.expectEqualStrings("127.0.0.1", params.host);
        try std.testing.expectEqual(5060, params.port);
    }
}


// FIXME: Remove
fn hexWhatYouCan(r: *std.Io.Reader) !void {
    while (true) {
        const b = try r.takeByte();
        std.debug.print("{x:<02} ", .{b});
    }
}
