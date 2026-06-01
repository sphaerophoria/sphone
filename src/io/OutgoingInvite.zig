const sip = @import("../sip.zig");
const sphtud = @import("sphtud");
const DualCompletion = @import("DualCompletion.zig");
const SipService = @import("SipService.zig");
const TransportService = @import("TransportService.zig");
const Impl = sip.transaction.OutgoingInvite;

alloc: *sphtud.alloc.Sphalloc,
tx_handle: SipService.TransactionHandle,
timer_handle: ?sphtud.io.TimerService.TimerHandle,
callback_id: usize,
completion: DualCompletion,
invite: Impl,

const OutgoingInvite = @This();

pub fn deinit(self: *OutgoingInvite, parent: *SipService) void {
    self.completion.finishUser();
    self.destroyIfFullyComplete(parent);
}

pub fn onMessage(
    self: *OutgoingInvite,
    parent: *SipService,
    message: []const u8,
    sender: ?TransportService.Handle,
    on_timeout: usize,
) !void {
    var action_buf: [16]sip.transaction.OutgoingInvite.MessageAction = undefined;
    var out_buf: [4096]u8 = undefined;

    const actions = try self.invite.onMessage(
        message,
        try sphtud.io.clock_gettime(.BOOTTIME),
        &out_buf,
        &action_buf,
    );

    for (actions) |action| switch (action) {
        .schedule_timeout => |duration| {
            if (self.timer_handle) |h| try parent.timer.rearm(h, duration) else self.timer_handle = try parent.timer.add(duration, on_timeout);
        },
        .send => |buf| try parent.transport.sendResponse(sender.?, buf),
        .notify => try parent.loop.pushEvent(self.callback_id),
    };
}

pub fn onTimeout(self: *OutgoingInvite, parent: *SipService) !void {
    const now = try sphtud.io.clock_gettime(.BOOTTIME);

    switch (try self.invite.onTimeout(now)) {
        .finish => {
            self.completion.finishUser();
            self.destroyIfFullyComplete(parent);
        },
        .none => {},
    }
}

fn destroyIfFullyComplete(self: *OutgoingInvite, parent: *SipService) void {
    if (!self.completion.isFullyComplete()) {
        return;
    }

    parent.tx_lookup.remove(self.invite.branch_id);
    if (self.timer_handle) |h| parent.timer.remove(h);
    parent.loop.clearEvents(self.callback_id);

    self.alloc.deinit();
    parent.transactions.release(parent.alloc.expansion(), self.tx_handle);
}
