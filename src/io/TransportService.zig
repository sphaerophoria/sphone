const std = @import("std");
const sphtud = @import("sphtud");
const Transport = @import("../sip/Transport.zig");

const Self = @This();

// FIXME: We should have our incoming TCP/UDP ports allocated here
gpa: std.mem.Allocator,
transport: Transport,
pool: sphtud.util.ObjectPool(Storage, Handle),
spawner: *sphtud.io.TcpSpawner,
loop: *sphtud.io.Loop,

udp_recv_buf: []u8,
udp_listener: std.posix.fd_t,
tcp_listener: std.posix.fd_t,

data_received_start: usize,
connection_ready_start: usize,

// This is an absurd number of concurrent connections for a SIP
// client, in reality I'd expect like... 4? Maybe 2 to a proxy, 2
// to an endpoint
pub const max_connections = 1024;

pub const Ids = struct {
    connection_ready: sphtud.io.IdAlloc.Range,
    data_received: sphtud.io.IdAlloc.Range,
    udp_listener: usize,
    tcp_listener: usize,
    total: sphtud.io.IdAlloc.Range,

    pub fn init(alloc: *sphtud.io.IdAlloc) Ids {
        const start = alloc.mark();
        return .{
            .connection_ready = alloc.allocMany(max_connections),
            .data_received = alloc.allocMany(max_connections),
            .udp_listener = alloc.allocOne(),
            .tcp_listener = alloc.allocOne(),
            .total = start.range(),
        };
    }
};

pub fn init(
    gpa: std.mem.Allocator,
    spawner: *sphtud.io.TcpSpawner,
    loop: *sphtud.io.Loop,
    comptime ids: Ids,
) !Self {
    const system = sphtud.io.system;

    const ip: std.Io.net.IpAddress = .{
        .ip4 = .{
            .bytes = .{ 0, 0, 0, 0 },
            .port = 5060,
        },
    };

    const udp_listener = try sphtud.io.socket(system.AF.INET, system.SOCK.DGRAM, 0);
    try sphtud.io.bind(udp_listener, ip);

    const tcp_listener = try sphtud.io.createTcpListener(ip, 32);

    try loop.register(.{
        .handle = tcp_listener,
        .id = ids.tcp_listener,
        .read = true,
        .write = false,
    });

    try loop.register(.{
        .handle = udp_listener,
        .id = ids.udp_listener,
        .read = true,
        .write = false,
    });

    return .{
        .gpa = gpa,
        .transport = .init(),
        .data_received_start = ids.data_received.start,
        .connection_ready_start = ids.connection_ready.start,
        .udp_recv_buf = try gpa.alloc(u8, 4096),
        .udp_listener = udp_listener,
        .tcp_listener = tcp_listener,
        .pool = try .init(
            gpa,
            .general(gpa),
            16,
            max_connections,
        ),
        .spawner = spawner,
        .loop = loop,
    };
}

pub fn sendMessage(self: *Self, sip_uri: []const u8, message: Transport.Buffer) !void {
    const res = try self.transport.getWriteParams(sip_uri, message);

    switch (res.connection) {
        .new_tcp => |params| {
            // FIXME: Surely we should close these at some point
            const storage = try self.pool.acquire(.general(self.gpa));
            const spawn_handle = self.spawner.spawn(params.host, params.port, self.connection_ready_start + storage.handle.toIdx()) catch |e| {
                self.pool.release(.general(self.gpa), storage.handle);
                return e;
            };

            storage.val.initPinned(spawn_handle);
            errdefer self.close(storage.handle);

            try storage.val.writeMessage(self.gpa, res.data);
        },
        .existing => |idx| {
            const storage = self.pool.get(.fromIdx(idx));
            try storage.writeMessage(self.gpa, res.data);
        },
    }
}

pub fn sendResponse(self: *Self, handle: Handle, buf: Transport.Buffer) !void {
    const storage = self.pool.get(handle);
    _ = try sphtud.io.write(buf.withProto(.tcp), storage.socket.ready);
}

fn close(self: *Self, handle: Handle) void {
    const storage = self.pool.get(handle);
    switch (storage.socket) {
        .ready => |s| sphtud.io.close(s),
        // FIXME: TCP spawner has no way to cancel a spawn
        .initializing => @panic("unimplemented"),
    }

    self.loop.clearEvents(self.data_received_start + handle.toIdx());
    self.loop.clearEvents(self.connection_ready_start + handle.toIdx());

    self.pool.release(.general(self.gpa), handle);
}

pub const Event = union(enum) {
    udp: UdpMessage,
    tcp: TcpMessage,
};

pub const UdpMessage = struct {
    data: []const u8,
};

pub const TcpMessage = struct {
    r: *std.Io.Reader,
    handle: Handle,
};

// one connection to send back to
//
// If we get UDP -> send UDP + IP
// If we get TCP -> respond over same connection

pub const Handle = struct {
    id: usize,

    pub const invalid: Handle = .{ .id = std.math.maxInt(usize) };

    pub fn toIdx(self: Handle) usize {
        return self.id;
    }

    pub fn fromIdx(idx: usize) Handle {
        return .{ .id = idx };
    }
};

pub fn service(self: *Self, service_id: usize, comptime ids: Ids) !?Event {
    switch (service_id) {
        ids.connection_ready.start...ids.connection_ready.end => {
            const idx = service_id - ids.connection_ready.start;
            const storage = self.pool.get(.fromIdx(idx));

            if (storage.socket == .ready) return null;

            try storage.onConnectionReady(self.gpa, self.spawner);

            switch (storage.socket) {
                .ready => {
                    std.debug.print("Ready called with {d}\n", .{storage.socket.ready});
                    try self.loop.register(.{
                        .handle = storage.socket.ready,
                        .id = ids.data_received.start + idx,
                        .read = true,
                        .write = false,
                    });

                    return .{
                        .tcp = .{
                            .handle = .fromIdx(idx),
                            .r = &storage.reader.interface,
                        },
                    };
                },
                else => {
                    // Return a failing reader to immediately trigger "no data
                    // available" case in next section. The other option was
                    // ?*std.Io.Reader but there's no point in making the
                    // caller check for failure twice
                    return .{
                        .tcp = .{
                            .handle = .invalid,
                            // I swear this const cast is fine. We know that the
                            // failing reader has no internal state to modify, so the
                            // pointer to the reader does not actually have to be
                            // mutable
                            .r = @constCast(&std.Io.Reader.failing),
                        },
                    };
                },
            }
        },
        ids.data_received.start...ids.data_received.end => {
            const idx = service_id - ids.data_received.start;
            const storage = self.pool.get(.fromIdx(idx));
            return .{
                .tcp = .{
                    .handle = .fromIdx(idx),
                    .r = &storage.reader.interface,
                },
            };
        },
        ids.udp_listener => {
            std.debug.print("UDP listener triggered\n", .{});
            const len = sphtud.io.recvfrom(self.udp_listener, self.udp_recv_buf, 0, null, null) catch |e| {
                if (e == error.WouldBlock) return null;
                return e;
            };
            return .{
                .udp = .{
                    .data = self.udp_recv_buf[0..len],
                },
            };
        },
        ids.tcp_listener => {
            std.debug.print("TCP listener triggered\n", .{});

            while (true) {
                const new_connection = sphtud.io.accept(self.tcp_listener) catch |e| {
                    if (e == error.WouldBlock) return null;
                    return e;
                };

                const storage = try self.pool.acquire(.general(self.gpa));
                storage.val.* = .{
                    .socket = .{
                        .ready = new_connection,
                    },
                    .reader_buf = undefined,
                    .reader = .init(new_connection, &storage.val.reader_buf),
                    .messages_buf = undefined,
                    .messages = .empty,
                };

                try self.loop.pushEvent(ids.data_received.start + storage.handle.id);
            }
        },
        else => return error.InvalidId,
    }
}

const Storage = struct {
    socket: union(enum) {
        initializing: sphtud.io.TcpSpawner.SpawnHandle,
        ready: std.posix.fd_t,
    },
    reader_buf: [4096]u8 = undefined,
    reader: sphtud.io.Reader,

    // This is pretty app specific, but surely we aren't ripping 10 messages to
    // the same guy before we even initialize
    messages_buf: [10][]const u8,
    messages: std.ArrayList([]const u8),

    pub fn initPinned(self: *Storage, spawn_handle: sphtud.io.TcpSpawner.SpawnHandle) void {
        self.socket = .{ .initializing = spawn_handle };
        self.messages_buf = undefined;
        self.messages = .initBuffer(&self.messages_buf);
        self.reader = .invalid;
    }

    pub fn writeMessage(self: *Storage, alloc: std.mem.Allocator, tmp_message: []const u8) !void {
        switch (self.socket) {
            .initializing => {
                const message = try alloc.dupe(u8, tmp_message);
                errdefer alloc.free(message);

                try self.messages.appendBounded(message);
                return;
            },
            .ready => |fd| {
                try sphtud.io.writeAll(tmp_message, fd);
            },
        }
    }

    pub fn onConnectionReady(self: *Storage, alloc: std.mem.Allocator, tcp_spawner: *sphtud.io.TcpSpawner) !void {
        const handle = switch (self.socket) {
            .initializing => |h| h,
            else => {
                std.log.err("Notification on connection ready when already initialized", .{});
                return;
            },
        };

        const conn_spawner = tcp_spawner.get(handle);
        const result = conn_spawner.result orelse return;

        if (result) |r| {
            self.socket = .{ .ready = r };
        } else |e| return e;

        self.reader = .init(self.socket.ready, &self.reader_buf);
        for (self.messages.items) |message| {
            defer alloc.free(message);
            try sphtud.io.writeAll(message, self.socket.ready);
        }
        self.messages.clearRetainingCapacity();
    }
};
