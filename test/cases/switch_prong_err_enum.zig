const assert = @import("std").debug.assert;

var read_count: u64 = 0;

fn readOnce() -> %u64 {
    read_count += 1;
    return read_count;
}

error InvalidDebugInfo;

const FormValue = enum {
    Address: u64,
    Other: bool,
};

fn doThing(form_id: u64) -> %FormValue {
    return switch (form_id) {
        17 => FormValue.Address { %return readOnce() },
        else => error.InvalidDebugInfo,
    }
}

test "switch prong returns error enum" {
    switch (%%doThing(17)) {
        FormValue.Address => |payload| { assert(payload == 1); },
        else => unreachable,
    }
    assert(read_count == 1);
}
