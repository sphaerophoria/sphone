const std = @import("std");
const sphtud = @import("sphtud");
const sip = @import("sip.zig");
const TransportService = @import("io/TransportService.zig");
const SipService = @import("io/SipService.zig");
const PlaybackRtpStream = @import("io/PlaybackRtpStream.zig");
const sphaudio = @import("sphaudio");
const rtp = @import("rtp.zig");
const io = @import("io.zig");

const max_dns_connections = 1024;
const rtp_port = 48102;

const GuiIds = struct {
    ignore: usize = 0,
    start_call: usize = 1,
};

const gui_ids = GuiIds{};

const Ids = struct {
    timer: usize,
    dns: sphtud.io.DnsService.Ids,
    tcp_spawner: sphtud.io.TcpSpawner.Ids,
    sip: SipService.Ids,
    invite_complete: usize,
    rtp: PlaybackRtpStream.Ids,
    audio: usize,
    service_ui: usize,

    pub fn init() Ids {
        var alloc = sphtud.io.IdAlloc{ .idx = 0 };

        return .{
            .timer = alloc.allocOne(),
            .dns = .init(&alloc, max_dns_connections),
            .tcp_spawner = .init(&alloc),
            .sip = .init(&alloc),
            .invite_complete = alloc.allocOne(),
            .rtp = .init(&alloc),
            .audio = alloc.allocOne(),
            .service_ui = alloc.allocOne(),
        };
    }
};

const ids = Ids.init();

// Gui request of gui thread
const GuiAction = union(enum) {
    start_call,
    edit_call_recipiant: sphtud.ui.textbox.TextboxNotifier,

    pub fn makeEditCallRecipiant(notifier: sphtud.ui.textbox.TextboxNotifier) GuiAction {
        return .{
            .edit_call_recipiant = notifier,
        };
    }
};

// Gui thread request of main thread
// FIXME: Surely needs a better name
const GuiThreadAction = union(enum) {
    start_call: struct {
        buf: [128]u8,
        len: usize,
    },
};

const GuiState = struct {
    mutex: std.Io.Mutex,
    io: std.Io.Threaded,

    shutdown: bool,
    protected: struct {
        state: enum {
            default,
            in_call,
        },

        action_queue: sphtud.util.CircularBuffer(GuiThreadAction),
    },

    pub fn popAction(self: *GuiState) !?GuiThreadAction {
        try self.mutex.lock(self.io.io());
        defer self.mutex.unlock(self.io.io());

        return self.protected.action_queue.pop();
    }
};

pub fn uiMain(gui_state: *GuiState) !void {
    var allocators: sphtud.render.AppAllocators = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    var window: sphtud.window.Window = undefined;
    try window.initPinned("sphui demo", 800, 600);
    defer window.deinit();

    try sphtud.render.initGl(window.glLoader());

    const gl = sphtud.render.gl;

    gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    const gui_alloc = try allocators.root_render.makeSubAlloc("gui");

    const widget_state = try sphtud.ui.WidgetState.init(
        gui_alloc,
        &allocators.scratch,
        &allocators.scratch_gl,
        .{},
    );

    const widget_factory = sphtud.ui.WidgetFactory {
        .alloc = gui_alloc,
        .state = widget_state,
    };

    const call_layout = try widget_factory.makeLayout();
    call_layout.cursor.direction = .left_to_right;

    const textbox = try widget_factory.makeTextbox(gui_ids.ignore);
    try textbox.setText("sip:mick@127.0.0.1:5062");

    try call_layout.append(&textbox.widget);

    const start_call_label = try widget_factory.makeLabel("call", .{});
    const start_call = try widget_factory.makeButton(&start_call_label.widget, gui_ids.start_call);
    try call_layout.append(&start_call.widget);

    const centered = try widget_factory.makeCentered(&call_layout.widget);
    var runner = try widget_factory.makeRunner(&centered.widget);

    const std_io = gui_state.io.io();

    while (!window.closed() and !gui_state.shutdown) {
        allocators.resetScratch();
        const width, const height = window.getWindowSize();

        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glScissor(0, 0, @intCast(width), @intCast(height));

        const background_color = sphtud.ui.WidgetState.StyleColors.background_color;
        gl.glClearColor(background_color.r, background_color.g, background_color.b, background_color.a);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        try runner.step(1.0, .{
            .width = @intCast(width),
            .height = @intCast(height),
        }, &window.queue);

        for (widget_state.event_queue.items) |event| switch (event) {
            gui_ids.start_call => {
                try gui_state.mutex.lock(std_io);
                defer gui_state.mutex.unlock(std_io);

                var thread_action = GuiThreadAction{
                    .start_call = undefined,
                };

                @memcpy(thread_action.start_call.buf[0..textbox.text.items.len], textbox.text.items);
                thread_action.start_call.len = textbox.text.items.len;

                try gui_state.protected.action_queue.pushNoClobber(thread_action);
            },
            gui_ids.ignore => {},
            else => unreachable,
        };

        window.swapBuffers();
    }
}

pub fn main() !void {
    var tpa: sphtud.alloc.TinyPageAllocator = undefined;
    try tpa.initPinned();

    var root_alloc: sphtud.alloc.Sphalloc = undefined;
    try root_alloc.initPinned(tpa.allocator(), "root");

    const caller = "sip:mick@127.0.0.1";

    var rng = blk: {
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        try sphtud.io.getrandom(&seed);
        break :blk std.Random.DefaultCsprng.init(seed);
    };

    var chain_buf: [256]usize = undefined;
    var loop = try sphtud.io.Loop.init(&chain_buf);
    var timer = try sphtud.io.TimerService.init(root_alloc.arena(), root_alloc.expansion(), &loop, ids.timer);
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

    var pw = try sphaudio.Pipewire.init();
    defer pw.deinit();

    try loop.register(.{
        .id = ids.audio,
        .handle = pw.pollFd(),
        .read = true,
        .write = false,
    });

    var playback_stream: PlaybackRtpStream = undefined;
    try playback_stream.initPinned(
        .{
            .ip4 = .{
                .bytes = .{ 0, 0, 0, 0 },
                .port = rtp_port,
            },
        },
        &pw,
        &loop,
        &timer,
        ids.rtp,
    );

    var gui_action_queue_buf: [32]GuiThreadAction = undefined;
    var gui_state = GuiState{
        .mutex = .init,
        .io = .init_single_threaded,
        .protected = .{
            .state = .default,
            .action_queue = .{ .items = &gui_action_queue_buf },
        },
        .shutdown = false,
    };

    const ui_thread_handle = try std.Thread.spawn(.{}, uiMain, .{&gui_state});
    defer {
        gui_state.shutdown = true;
        ui_thread_handle.join();
    }

    const service_ui_timer = try timer.add(.fromMilliseconds(16), ids.service_ui);

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
                while (try sip_service.service(event, ids.sip)) |result| switch (result) {
                    .invite => |invite| {
                        std.debug.print("RING RING {s} is calling\n", .{invite.invite.from});

                        try invite.accept(&sip_service);
                    },
                    .invite_accepted => |invite| {
                        _ = invite;
                        std.debug.print("Invite complete!\n", .{});
                    },
                };
            },
            ids.rtp.total.start...ids.rtp.total.end => {
                try playback_stream.service(event, &timer, ids.rtp);
            },
            ids.audio => {
                try pw.service();
            },
            ids.service_ui => {
                try timer.rearm(service_ui_timer, .fromMilliseconds(16));

                while (try gui_state.popAction()) |action| switch (action) {
                    .start_call => |params| {
                        const recipient = params.buf[0..params.len];
                        std.debug.print("Call {s} please\n", .{recipient});

                        try sip_service.startInvite(.{
                            .uri = recipient,
                            .to = recipient,
                            .from = caller,
                            // This should probably be resolved by transport
                            .sent_by = "127.0.0.1:5060",
                            .rtp_port = rtp_port,
                        });
                    },
                };
            },
            else => unreachable,
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
