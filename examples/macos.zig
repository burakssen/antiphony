const std = @import("std");
const rpc = @import("antiphony");

const CreateError = error{ OutOfMemory, UnknownCounter };
const UsageError = error{ OutOfMemory, UnknownCounter };

// Define our RPC service via function signatures.
const RcpDefinition = rpc.CreateDefinition(.{
    .host = .{
        .createCounter = fn () CreateError!u32,
        .destroyCounter = fn (u32) void,
        .increment = fn (u32, u32) UsageError!u32,
        .getCount = fn (u32) UsageError!u32,
    },
    .client = .{
        .signalError = fn (msg: []const u8) void,
    },
});

fn clientImplementation(file: std.fs.File) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const ClientImpl = struct {
        pub fn signalError(msg: []const u8) void {
            std.log.err("remote error: {s}", .{msg});
        }
    };

    const EndPoint = RcpDefinition.ClientEndPoint(ClientImpl);

    var reader_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(&reader_buffer);

    var writer_buffer: [1024]u8 = undefined;
    var file_writer = file.writer(&writer_buffer);

    var end_point = EndPoint.init(
        gpa.allocator(),
        &file_reader.interface,
        &file_writer.interface,
    );
    defer end_point.destroy();

    var impl = ClientImpl{};
    std.debug.print("Client connecting to host\n", .{});
    try end_point.connect(&impl); // establish RPC handshake
    std.debug.print("Client connected to host\n", .{});
    const handle = try end_point.invoke("createCounter", .{});

    std.log.info("first increment:  {}", .{try end_point.invoke("increment", .{ handle, 5 })});
    std.log.info("second increment: {}", .{try end_point.invoke("increment", .{ handle, 3 })});
    std.log.info("third increment:  {}", .{try end_point.invoke("increment", .{ handle, 7 })});
    std.log.info("final count:      {}", .{try end_point.invoke("getCount", .{handle})});

    try end_point.invoke("destroyCounter", .{handle});

    _ = end_point.invoke("getCount", .{handle}) catch |err| std.log.info("error while calling getCount()  with invalid handle: {s}", .{@errorName(err)});

    try end_point.shutdown();
}

fn hostImplementation(file: std.fs.File) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const HostImpl = struct {
        const Self = @This();

        const EndPoint = RcpDefinition.HostEndPoint(Self);

        allocator: std.mem.Allocator,
        counters: std.ArrayList(?u32),
        end_point: *EndPoint,

        fn sendErrorMessage(self: Self, msg: []const u8) void {
            self.end_point.invoke("signalError", .{msg}) catch |err| std.log.err("failed to send error message: {s}", .{@errorName(err)});
        }

        pub fn createCounter(self: *Self) CreateError!u32 {
            const index: u32 = @truncate(self.counters.items.len);
            try self.counters.append(self.allocator, 0);
            return index;
        }
        pub fn destroyCounter(self: *Self, handle: u32) void {
            if (handle >= self.counters.items.len) {
                self.sendErrorMessage("unknown counter");
                return;
            }
            self.counters.items[handle] = null;
        }
        pub fn increment(self: *Self, handle: u32, count: u32) UsageError!u32 {
            if (handle >= self.counters.items.len) {
                self.sendErrorMessage("This counter does not exist!");
                return error.UnknownCounter;
            }
            if (self.counters.items[handle]) |*counter| {
                const previous = counter.*;
                counter.* +%= count;
                return previous;
            } else {
                self.sendErrorMessage("This counter was already deleted!");
                return error.UnknownCounter;
            }
        }
        pub fn getCount(self: *Self, handle: u32) UsageError!u32 {
            if (handle >= self.counters.items.len) {
                self.sendErrorMessage("This counter does not exist!");
                return error.UnknownCounter;
            }
            if (self.counters.items[handle]) |value| {
                return value;
            } else {
                self.sendErrorMessage("This counter was already deleted!");
                return error.UnknownCounter;
            }
        }
    };

    var reader_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(&reader_buffer);

    var writer_buffer: [1024]u8 = undefined;
    var file_writer = file.writer(&writer_buffer);

    var end_point = HostImpl.EndPoint.init(
        gpa.allocator(), // we need some basic session management
        &file_reader.interface, // data input
        &file_writer.interface, // data output
    );
    defer end_point.destroy();

    var impl = HostImpl{
        .allocator = gpa.allocator(),
        .counters = .empty,
        .end_point = &end_point,
    };
    defer impl.counters.deinit(gpa.allocator());

    try end_point.connect(&impl); // establish RPC handshake

    try end_point.acceptCalls(); // blocks until client exits.
}

// This main function just creates a socket pair and hands them off to two threads that perform some RPC calls.
pub fn main() !void {
    const c = std.c;
    var sockets: [2]c.fd_t = undefined;

    // Use C socketpair which works on macOS
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairError;
    }

    var socket_a = std.fs.File{ .handle = sockets[0] };
    defer socket_a.close();

    var socket_b = std.fs.File{ .handle = sockets[1] };
    defer socket_b.close();

    {
        var client_thread = try std.Thread.spawn(.{}, clientImplementation, .{socket_a});
        defer client_thread.join();

        var host_thread = try std.Thread.spawn(.{}, hostImplementation, .{socket_b});
        defer host_thread.join();
    }
}
