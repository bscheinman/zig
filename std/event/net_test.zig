const std = @import("std");
const assert = std.debug.assert;
const event = @import("event.zig");
//const net = @import("event_net.zig");

const TestContext = struct {
    value: usize
};

const ContextAllocator = struct {
    contexts: [16]TestContext,
    index: usize,

    const Self = this;

    fn init() -> ContextAllocator {
        const read_context = TestContext { .value = 42 };
        ContextAllocator {
            .contexts = []TestContext { read_context } ** 16,
            .index = 0
        }
    }

    fn alloc(allocator: &Self) -> %&TestContext {
        std.debug.warn("index {} / length {}\n", allocator.index,
            allocator.contexts.len);
        if (allocator.index >= allocator.contexts.len) {
            std.debug.warn("out of context memory\n");
            return error.OutOfMemory;
        }

        const res = &allocator.contexts[allocator.index];
        allocator.index += 1;
        res
    }
};

const ListenerContext = struct {
    server_id: usize,
    loop: &event.Loop,
    context_alloc: &ContextAllocator
};

fn read_handler(bytes: &const []u8, context: &TestContext) -> void {
    std.debug.warn("reading {} bytes from context {}\n", bytes.len, context.value);
}

fn conn_handler(md: &const event.EventMd, context: &ListenerContext) -> %void {
    std.debug.warn("registering event for new connection {}\n", md.fd);
    std.debug.warn("using context {}\n", @ptrToInt(context));
    var event_closure = %return context.context_alloc.alloc();
    std.debug.warn("created context {}\n", @ptrToInt(event_closure));
    var ev = %return event.NetworkEvent.init(md, event_closure, &read_handler);
    std.debug.warn("created event\n");
    ev.register(context.loop)
}

test "listen" {
    var loop = %%event.Loop.init();

    var allocator = ContextAllocator.init();

    var listener_context = ListenerContext {
        .server_id = 1,
        .loop = &loop,
        .context_alloc = &allocator
    };

    std.debug.warn("created context at {}\n", @ptrToInt(&listener_context));

    var listener = event.StreamListener.init(&listener_context, &conn_handler);
    %%listener.listen_tcp("localhost", 12345);
    %%listener.register(&loop);

    %%loop.run();
}
