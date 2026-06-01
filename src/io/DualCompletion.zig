const DualCompletion = @This();
val: u8,

const io_finished = 1;
const user_finished = 2;
const can_be_freed = 3;

pub const init = DualCompletion{ .val = 0 };

pub fn finishUser(self: *DualCompletion) void {
    self.val |= user_finished;
}

pub fn finishIo(self: *DualCompletion) void {
    self.val |= io_finished;
}

pub fn isFullyComplete(self: *DualCompletion) bool {
    return self.val == can_be_freed;
}
