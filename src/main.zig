const std = @import("std");
const sphtud = @import("sphtud");
const sip = @import("sip.zig");
const TransportService = @import("io/TransportService.zig");
const SipService = @import("io/SipService.zig");

const max_dns_connections = 1024;

const Ids = struct {
    timer: usize,
    dns: sphtud.io.DnsService.Ids,
    tcp_spawner: sphtud.io.TcpSpawner.Ids,
    sip: SipService.Ids,
    invite_complete: usize,

    pub fn init() Ids {
        var alloc = sphtud.io.IdAlloc{ .idx = 0 };

        return .{
            .timer = alloc.allocOne(),
            .dns = .init(&alloc, max_dns_connections),
            .tcp_spawner = .init(&alloc),
            .sip = .init(&alloc),
            .invite_complete = alloc.allocOne(),
        };
    }
};

const ids = Ids.init();

pub fn main(init: std.process.Init.Minimal) !void {
    var tpa: sphtud.alloc.TinyPageAllocator = undefined;
    try tpa.initPinned();

    var root_alloc: sphtud.alloc.Sphalloc = undefined;
    try root_alloc.initPinned(tpa.allocator(), "root");

    var args = try init.args.iterateAllocator(root_alloc.general());

    _ = args.next();
    const callee = args.next() orelse return error.NoCallee;
    const caller = "sip:mick@127.0.0.1";

    var rng = blk: {
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        try sphtud.io.getrandom(&seed);
        break :blk std.Random.DefaultCsprng.init(seed);
    };

    var chain_buf: [256]usize = undefined;
    var loop = try sphtud.io.Loop.init(&chain_buf);
    var timer = try sphtud.io.TimerService.init(root_alloc.general(), &loop, ids.timer);
    var dns_service = try sphtud.io.DnsService.init(&root_alloc, &loop, &timer, ids.dns);
    var spawner = try sphtud.io.TcpSpawner.init(root_alloc.arena(), root_alloc.expansion(), &dns_service, &loop, ids.tcp_spawner);

    var sip_service = try SipService.init(
        try root_alloc.makeSubAlloc("sip"),
        &timer,
        rng.random(),
        &spawner,
        &loop,
        ids.sip,
    );

    var message_buf: [4096]u8 = undefined;
    const invite_res = try sip_service.startInvite(.{
        .uri = callee,
        .to = callee,
        .from = caller,
        // FIXME: This feels like a lower level detail
        .out_buf = &message_buf,
        // This should probably be resolved by transport
        .sent_by = "127.0.0.1:5060",
    }, ids.invite_complete);

    while (true) {
        const event = (try loop.poll(-1)) orelse continue;
        switch (event) {
            ids.timer => {
                try timer.service(&loop);
            },
            ids.dns.total.start...ids.dns.total.end => {
                try dns_service.service(event, ids.dns);
            },
            ids.tcp_spawner.total.start...ids.tcp_spawner.total.end => {
                try spawner.service(event, ids.tcp_spawner);
            },
            ids.sip.total.start...ids.sip.total.end => {
                try sip_service.service(event, ids.sip);
            },
            ids.invite_complete => {
                std.debug.print("Invite complete!\n", .{});
                sip_service.release(invite_res.handle);
            },
            else => unreachable,
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
