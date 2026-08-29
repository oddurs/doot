//! Fail the build if a committed corpus carries a secret.
//!
//!   zig build check-corpora
//!
//! The check is exactly "redacting this file changes nothing", using the
//! same `redact.zig` the recorder applies at capture time. One definition,
//! so the guard at the door and the check on the shelf cannot drift.
//!
//! This is the half that does not depend on anyone remembering. A recording
//! is still worth reading before it is committed — `redact` knows the
//! shapes it knows — but nothing with a shape it knows can reach `main`.

const std = @import("std");
const redact = @import("redact.zig");

const dir_path = "bench/corpus";

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var checked: usize = 0;
    var dirty: usize = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // Recordings and their sidecars both come from the recorded
        // program, so both are checked.
        const is_corpus = std.mem.endsWith(u8, entry.name, ".bin") or
            std.mem.endsWith(u8, entry.name, ".timing");
        if (!is_corpus) continue;

        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.name });
        defer gpa.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
        defer gpa.free(bytes);

        checked += 1;
        var first: redact.Finding = undefined;
        if (!try redact.isClean(gpa, bytes, &first)) {
            dirty += 1;
            std.debug.print(
                "{s}: {s} at byte {d}, {d} bytes long\n",
                .{ path, first.what, first.offset, first.len },
            );
        }
    }

    if (dirty > 0) {
        std.debug.print(
            \\
            \\{d} of {d} corpora carry something that looks like a secret.
            \\
            \\Re-record them, or scrub in place -- replacements must be the
            \\same length, because each .timing sidecar records how many
            \\bytes arrived in each read and would otherwise stop matching.
            \\
        , .{ dirty, checked });
        std.process.exit(1);
    }
    std.debug.print("{d} corpora checked, none carry a known secret shape\n", .{checked});
}
