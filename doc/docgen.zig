const std = @import("std");
const io = std.io;
const os = std.os;

pub fn main() -> %void {
    // TODO use a more general purpose allocator here
    var inc_allocator = %%std.heap.IncrementingAllocator.init(5 * 1024 * 1024);
    defer inc_allocator.deinit();
    const allocator = &inc_allocator.allocator;

    var args_it = os.args();

    if (!args_it.skip()) @panic("expected self arg");

    const in_file_name = %%(args_it.next(allocator) ?? @panic("expected input arg"));
    defer allocator.free(in_file_name);

    const out_file_name = %%(args_it.next(allocator) ?? @panic("expected output arg"));
    defer allocator.free(out_file_name);

    var in_file = %%io.File.openRead(in_file_name, allocator);
    defer in_file.close();

    var out_file = %%io.File.openWrite(out_file_name, allocator);
    defer out_file.close();

    var file_in_stream = io.FileInStream.init(&in_file);
    var buffered_in_stream = io.BufferedInStream.init(&file_in_stream.stream);

    var file_out_stream = io.FileOutStream.init(&out_file);
    var buffered_out_stream = io.BufferedOutStream.init(&file_out_stream.stream);

    gen(&buffered_in_stream.stream, &buffered_out_stream.stream);
    %%buffered_out_stream.flush();

}

const State = enum {
    Start,
    LessThan,
    BeginTagName,
};

const Context = struct {
    line: usize,
    column: usize,
};

fn gen(in: &io.InStream, out: &const io.OutStream) {
    var state = State.Start;
    var context = Context {
        .line = 0,
        .column = 0,
    };
    while (true) {
        const byte = in.readByte() %% |err| {
            if (err == error.EndOfStream) {
                return;
            }
            std.debug.panic("{}", err)
        };
        switch (state) {
            State.Start => switch (byte) {
                '<' => {
                    state = State.LessThan;
                },
                else => {
                    %%out.writeByte(byte);
                },
            },
            State.LessThan => switch (byte) {
                '%' => {
                    state = State.BeginTagName,
                },
                else => {
                    %%out.writeByte('<');
                    %%out.writeByte(byte);
                    state = State.Start;
                },
            },
            State.BeginTagName => switch (byte) {
                'h' => {
                    state = State.ExpectHeaderBeginQuote,
                },
                else => {
                    reportError(context, "unrecognized tag character: '{}'", byte);
                },
            },
        }
        if (byte == '\n') {
            context.line += 1;
            context.column = 0;
        } else {
            context.column += 1;
        }
    }
}

fn reportError(context: Context, comptime format: []const u8, args: ...) -> noreturn {
    std.debug.panic("{}:{}: " ++ format, context.line + 1, context.column + 1, args);
}
