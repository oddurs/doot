//! Unit-test root.
//!
//! Zig only analyzes imports that something actually references, so a test
//! binary rooted at main.zig finds no tests at all -- `main` is never called
//! in a test build, so nothing below it is ever analyzed. Naming each module
//! here is what pulls their tests in.

test {
    _ = @import("vt.zig");
    _ = @import("grid.zig");
    _ = @import("terminal.zig");
    _ = @import("input.zig");
    _ = @import("theme.zig");
    _ = @import("font.zig");
    _ = @import("stats.zig");
    _ = @import("cli.zig");
    _ = @import("version.zig");
    _ = @import("png.zig");
    _ = @import("redact.zig");
}
