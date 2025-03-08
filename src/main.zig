const std = @import("std");
const builtin = @import("builtin");
const lq = @import("liquorice");
const yaml = @import("yaml");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

// override the log level so that YAML doesn't pollute everything
pub const std_options: std.Options = .{ .log_level = .err };

// for the infinite loop
var mtx: std.Thread.Mutex = .{};
var cond: std.Thread.Condition = .{};
var alive: bool = true;

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    // mostly for YAML
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const config_file = try std.fs.cwd().readFileAlloc(gpa, "config.yaml", 1024);
    defer gpa.free(config_file);
    const config = try (try yaml.Yaml.load(arena.allocator(), config_file)).parse(arena.allocator(), lq.Config);
    var liquorice = try lq.LiquoriceClient.init(gpa, config);
    std.debug.print("Starting!\n", .{});
    try liquorice.start();
    std.posix.sigaction(std.posix.SIG.INT, &std.posix.Sigaction{
        .handler = .{
            .handler = struct {
                pub fn handler(_: c_int) callconv(.C) void {
                    mtx.lock();
                    alive = false;
                    mtx.unlock();
                    cond.signal();
                }
            }.handler,
        },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);
    // wait forever
    while (alive) {
        mtx.lock();
        defer mtx.unlock();
        cond.wait(&mtx);
    }
    std.debug.print("Shutting down...\n", .{});
    liquorice.deinit();
    std.debug.print("shut down\n", .{});
}
