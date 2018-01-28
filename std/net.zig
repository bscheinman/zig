const linux = @import("os/linux.zig");
const cstr = @import("cstr.zig");
const assert = @import("debug.zig").assert;
const warn = @import("debug.zig").warn;
const endian = @import("endian.zig");
const mem = @import("mem.zig");

error SigInterrupt;
error Io;
error TimedOut;
error ConnectionReset;
error ConnectionRefused;
error OutOfMemory;
error NotSocket;
error BadFd;
error UnsupportedOption;
error AddressInUse;
error AccessDenied;

pub const ControlProtocol = enum {
    TCP,
    UDP
};

const Connection = struct {
    socket_fd: i32,

    pub fn send(c: Connection, buf: []const u8) %usize {
        const send_ret = linux.sendto(c.socket_fd, buf.ptr, buf.len, 0, null, 0);
        const send_err = linux.getErrno(send_ret);
        switch (send_err) {
            0 => return send_ret,
            linux.EINVAL => unreachable,
            linux.EFAULT => unreachable,
            linux.ECONNRESET => return error.ConnectionReset,
            linux.EINTR => return error.SigInterrupt,
            // TODO there are more possible errors
            else => return error.Unexpected,
        }
    }

    pub fn recv(c: Connection, buf: []u8) %[]u8 {
        const recv_ret = linux.recvfrom(c.socket_fd, buf.ptr, buf.len, 0, null, null);
        const recv_err = linux.getErrno(recv_ret);
        switch (recv_err) {
            0 => return buf[0..recv_ret],
            linux.EINVAL => unreachable,
            linux.EFAULT => unreachable,
            linux.ENOTSOCK => return error.NotSocket,
            linux.EINTR => return error.SigInterrupt,
            linux.ENOMEM => return error.OutOfMemory,
            linux.ECONNREFUSED => return error.ConnectionRefused,
            linux.EBADF => return error.BadFd,
            // TODO more error values
            else => return error.Unexpected,
        }
    }

    pub fn close(c: Connection) %void {
        while (true) {
            switch (linux.getErrno(linux.close(c.socket_fd))) {
                0 => return,
                linux.EBADF => unreachable,
                linux.EINTR => continue,
                linux.EIO => return error.Io,
                else => return error.Unexpected,
            }
        }
    }
};

const Address = struct {
    family: u16,
    scope_id: u32,
    addr: [16]u8,
    sort_key: i32,
};

pub fn lookup(hostname: []const u8) %Address {
    // TODO: support other address names
    // TODO: support ipv6
    // TODO: support multiple output values
    if (mem.cmp(u8, hostname, "localhost") != mem.Cmp.Equal) {
        warn("cannot interpret hostname {}\n", hostname);
        return error.UnsupportedOption;
    }

    const addr_bytes = []u8{127, 0, 0, 1};

    var addr = Address {
        .family = linux.AF_INET,
        .scope_id = 0,
        .addr = []u8{0} ** 16,
        .sort_key = 0
    };

    @memcpy(@ptrCast(&u8, &addr.addr), &addr_bytes[0], 4);

    return addr;
}

fn createSocket(addr: &const Address, protocol: ControlProtocol) %i32 {
    const type_arg = switch (protocol) {
        ControlProtocol.TCP => i32(linux.SOCK_STREAM),
        ControlProtocol.UDP => i32(linux.SOCK_DGRAM),
    };
    const protocol_arg = switch (protocol) {
        ControlProtocol.TCP => i32(linux.PROTO_tcp),
        ControlProtocol.UDP => i32(linux.PROTO_udp),
    };

    const socket_ret = linux.socket(addr.family, type_arg, protocol_arg);
    const socket_err = linux.getErrno(socket_ret);
    if (socket_err > 0) {
        // TODO figure out possible errors from socket()
        return error.Unexpected;
    }

    return i32(socket_ret);
}

pub fn connectAddr(addr: &const Address, port: u16, protocol: ControlProtocol) %Connection {
    const socket_fd = try createSocket(addr, protocol);

    const connect_ret = if (addr.family == linux.AF_INET) x: {
        var os_addr: linux.sockaddr_in = undefined;
        os_addr.family = addr.family;
        os_addr.port = endian.swapIfLe(u16, port);
        @memcpy((&u8)(&os_addr.addr), &addr.addr[0], 4);
        @memset(&os_addr.zero[0], 0, @sizeOf(@typeOf(os_addr.zero)));
        break :x linux.connect(socket_fd, (&linux.sockaddr)(&os_addr), @sizeOf(linux.sockaddr_in));
    } else if (addr.family == linux.AF_INET6) x: {
        var os_addr: linux.sockaddr_in6 = undefined;
        os_addr.family = addr.family;
        os_addr.port = endian.swapIfLe(u16, port);
        os_addr.flowinfo = 0;
        os_addr.scope_id = addr.scope_id;
        @memcpy(&os_addr.addr[0], &addr.addr[0], 16);
        break :x linux.connect(socket_fd, (&linux.sockaddr)(&os_addr), @sizeOf(linux.sockaddr_in6));
    } else {
        return error.UnsupportedOption;
    };
    const connect_err = linux.getErrno(connect_ret);
    if (connect_err > 0) {
        switch (connect_err) {
            linux.ETIMEDOUT => return error.TimedOut,
            else => {
                // TODO figure out possible errors from connect()
                return error.Unexpected;
            },
        }
    }

    return Connection {
        .socket_fd = socket_fd,
    };
}

pub fn connect(hostname: []const u8, port: u16, protocol: ControlProtocol) %Connection {
    const addr = try lookup(hostname);
    return connectAddr(&addr, port, protocol);
}

pub fn bindAddr(addr: &const Address, port: u16, protocol: ControlProtocol) %Connection {
    const socket_fd = try createSocket(addr, protocol);

    const bind_ret = if (addr.family == linux.AF_INET) val: {
        var os_addr: linux.sockaddr_in = undefined;
        os_addr.family = addr.family;
        os_addr.port = endian.swapIfLe(u16, port);
        //@memcpy((&u8)(&os_addr.addr), &addr.addr[0], 4);
        @memcpy(@ptrCast(&u8, &os_addr.addr), &addr.addr[0], 4);
        @memset(&os_addr.zero[0], 0, @sizeOf(@typeOf(os_addr.zero)));
        //linux.bind(socket_fd, (&linux.sockaddr)(&os_addr), @sizeOf(linux.sockaddr_in))
        break :val linux.bind(socket_fd, @ptrCast(&linux.sockaddr, &os_addr), @sizeOf(linux.sockaddr_in));
    } else {
        return error.UnsupportedOption;
    };

    const bind_err = linux.getErrno(bind_ret);
    if (bind_err != 0) {
        return switch (bind_err) {
            linux.EACCES => error.AccessDenied,
            linux.EADDRINUSE => error.AddressInUse,
            linux.EBADF => error.BadFd,
            else => error.Unexpected
        };
    }

    return Connection {
        .socket_fd = socket_fd
    };
}

pub fn bind(hostname: []const u8, port: u16, protocol: ControlProtocol) %Connection {
    const addr = try lookup(hostname);
    return bindAddr(&addr, port, protocol);
}

error InvalidIpLiteral;

pub fn parseIpLiteral(buf: []const u8) %Address {
    return error.InvalidIpLiteral;
}

fn hexDigit(c: u8) u8 {
    // TODO use switch with range
    if ('0' <= c and c <= '9') {
        return c - '0';
    } else if ('A' <= c and c <= 'Z') {
        return c - 'A' + 10;
    } else if ('a' <= c and c <= 'z') {
        return c - 'a' + 10;
    } else {
        return @maxValue(u8);
    }
}

error InvalidChar;
error Overflow;
error JunkAtEnd;
error Incomplete;

fn parseIp6(buf: []const u8) %Address {
    var result: Address = undefined;
    result.family = linux.AF_INET6;
    result.scope_id = 0;
    const ip_slice = result.addr[0..];

    var x: u16 = 0;
    var saw_any_digits = false;
    var index: u8 = 0;
    var scope_id = false;
    for (buf) |c| {
        if (scope_id) {
            if (c >= '0' and c <= '9') {
                const digit = c - '0';
                if (@mulWithOverflow(u32, result.scope_id, 10, &result.scope_id)) {
                    return error.Overflow;
                }
                if (@addWithOverflow(u32, result.scope_id, digit, &result.scope_id)) {
                    return error.Overflow;
                }
            } else {
                return error.InvalidChar;
            }
        } else if (c == ':') {
            if (!saw_any_digits) {
                return error.InvalidChar;
            }
            if (index == 14) {
                return error.JunkAtEnd;
            }
            ip_slice[index] = @truncate(u8, x >> 8);
            index += 1;
            ip_slice[index] = @truncate(u8, x);
            index += 1;

            x = 0;
            saw_any_digits = false;
        } else if (c == '%') {
            if (!saw_any_digits) {
                return error.InvalidChar;
            }
            if (index == 14) {
                ip_slice[index] = @truncate(u8, x >> 8);
                index += 1;
                ip_slice[index] = @truncate(u8, x);
                index += 1;
            }
            scope_id = true;
            saw_any_digits = false;
        } else {
            const digit = hexDigit(c);
            if (digit == @maxValue(u8)) {
                return error.InvalidChar;
            }
            if (@mulWithOverflow(u16, x, 16, &x)) {
                return error.Overflow;
            }
            if (@addWithOverflow(u16, x, digit, &x)) {
                return error.Overflow;
            }
            saw_any_digits = true;
        }
    }

    if (!saw_any_digits) {
        return error.Incomplete;
    }

    if (scope_id) {
        return result;
    }

    if (index == 14) {
        ip_slice[14] = @truncate(u8, x >> 8);
        ip_slice[15] = @truncate(u8, x);
        return result;
    }

    return error.Incomplete;
}

fn parseIp4(buf: []const u8) %u32 {
    var result: u32 = undefined;
    const out_ptr = ([]u8)((&result)[0..1]);

    var x: u8 = 0;
    var index: u8 = 0;
    var saw_any_digits = false;
    for (buf) |c| {
        if (c == '.') {
            if (!saw_any_digits) {
                return error.InvalidChar;
            }
            if (index == 3) {
                return error.JunkAtEnd;
            }
            out_ptr[index] = x;
            index += 1;
            x = 0;
            saw_any_digits = false;
        } else if (c >= '0' and c <= '9') {
            saw_any_digits = true;
            const digit = c - '0';
            if (@mulWithOverflow(u8, x, 10, &x)) {
                return error.Overflow;
            }
            if (@addWithOverflow(u8, x, digit, &x)) {
                return error.Overflow;
            }
        } else {
            return error.InvalidChar;
        } 
    }
    if (index == 3 and saw_any_digits) {
        out_ptr[index] = x;
        return result;
    }

    return error.Incomplete;
}
