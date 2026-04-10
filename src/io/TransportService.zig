const std = @import("std");
const sphtud = @import("sphtud");
const Transport = @import("../sip/Transport.zig");

const Self = @This();

// FIXME: We should have our incoming TCP/UDP ports allocated here
expansion: sphtud.util.ExpansionAlloc,
transport: Transport,
pool: sphtud.util.ObjectPool(Storage, Handle),
spawner: *sphtud.io.TcpSpawner,
loop: *sphtud.io.Loop,

data_received_start: usize,
connection_ready_start: usize,

// This is an absurd number of concurrent connections for a SIP
// client, in reality I'd expect like... 4? Maybe 2 to a proxy, 2
// to an endpoint
pub const max_connections = 1024;

pub const Ids = struct {
    connection_ready: sphtud.io.IdAlloc.Range,
    data_received: sphtud.io.IdAlloc.Range,
    total: sphtud.io.IdAlloc.Range,

    pub fn init(alloc: *sphtud.io.IdAlloc) Ids {
        const start = alloc.mark();
        return .{
            .connection_ready = alloc.allocMany(max_connections),
            .data_received = alloc.allocMany(max_connections),
            .total = start.range(),
        };
    }
};

pub fn init(
    arena: std.mem.Allocator,
    expansion: sphtud.util.ExpansionAlloc,
    spawner: *sphtud.io.TcpSpawner,
    loop: *sphtud.io.Loop,
    comptime ids: Ids,
) !Self {
    return .{
        .expansion = expansion,
        .transport = .init(),
        .data_received_start = ids.data_received.start,
        .connection_ready_start = ids.connection_ready.start,
        .pool = try .init(
            arena,
            expansion,
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
            const storage = try self.pool.acquire(self.expansion);
            const spawn_handle = self.spawner.spawn(params.host, params.port, self.connection_ready_start + storage.handle.toIdx()) catch |e| {
                self.pool.release(self.expansion, storage.handle);
                return e;
            };

            storage.val.initPinned(spawn_handle);
            errdefer self.close(storage.handle);

            try storage.val.writeMessage(self.expansion.alloc, res.data);
        },
        .existing => |idx| {
            const storage = self.pool.get(.fromIdx(idx));
            try storage.writeMessage(self.expansion.alloc, res.data);
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

    self.pool.release(self.expansion, handle);
}

pub const Event = struct {
    r: *std.Io.Reader,
    handle: Handle,
};

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

pub fn service(self: *Self, service_id: usize, comptime ids: Ids) !Event {
    switch (service_id) {
        ids.connection_ready.start...ids.connection_ready.end => {
            const idx = service_id - ids.connection_ready.start;
            const storage = self.pool.get(.fromIdx(idx));

            try storage.onConnectionReady(self.spawner);

            switch (storage.socket) {
                .ready => {
                    try self.loop.register(.{
                        .handle = storage.socket.ready,
                        .id = ids.data_received.start + idx,
                        .read = true,
                        .write = false,
                    });

                    return .{
                        .handle = .fromIdx(idx),
                        .r = &storage.reader.interface,
                    };
                },
                else => {
                    // Return a failing reader to immediately trigger "no data
                    // available" case in next section. The other option was
                    // ?*std.Io.Reader but there's no point in making the
                    // caller check for failure twice
                    return .{
                        .handle = .invalid,
                        // I swear this const cast is fine. We know that the
                        // failing reader has no internal state to modify, so the
                        // pointer to the reader does not actually have to be
                        // mutable
                        .r = @constCast(&std.Io.Reader.failing),
                    };
                },
            }
        },
        ids.data_received.start...ids.data_received.end => {
            const idx = service_id - ids.data_received.start;
            const storage = self.pool.get(.fromIdx(idx));
            return .{
                .handle = .fromIdx(idx),
                .r = &storage.reader.interface,
            };
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

    pub fn writeMessage(self: *Storage, alloc: std.mem.Allocator, message: []const u8) !void {
        switch (self.socket) {
            .initializing => {
                errdefer alloc.free(message);

                try self.messages.appendBounded(message);
                return;
            },
            .ready => |fd| {
                try sphtud.io.writeAll(message, fd);
            },
        }
    }

    pub fn onConnectionReady(self: *Storage, tcp_spawner: *sphtud.io.TcpSpawner) !void {
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
            try sphtud.io.writeAll(message, self.socket.ready);
        }
        self.messages.clearRetainingCapacity();
    }
};
