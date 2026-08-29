//! The version, in one place.
//!
//! `build.zig.zon`'s `.version` is the source of truth; `build.zig` hands
//! it here as a build option along with the short commit. Nothing else in
//! the tree spells the number out. `pty.zig` used to, and a constant that
//! has to be kept in step with the changelog by hand is a constant that
//! eventually is not -- the repository shipped a `CHANGELOG.md` entry for
//! a `v0.1.0` that was never tagged.

const std = @import("std");
const build_options = @import("build_options");

/// Sentinel-terminated because `setenv` needs a C string, and a build
/// option's `[]const u8` does not carry the sentinel in its type.
pub const string: [:0]const u8 = std.fmt.comptimePrint("{s}", .{build_options.version});

/// The short commit, or empty when this was not built from a checkout.
pub const commit: [:0]const u8 = std.fmt.comptimePrint("{s}", .{build_options.commit});

/// What `--version` prints: `terminator 0.1.0 (faac302)`. The commit is
/// what turns "it does this on my machine" into a build someone can check
/// out, so it is worth the seven characters.
pub const line: [:0]const u8 = if (commit.len == 0)
    std.fmt.comptimePrint("terminator {s}", .{string})
else
    std.fmt.comptimePrint("terminator {s} ({s})", .{ string, commit });

const testing = std.testing;

test "the version is a semantic version and matches build.zig.zon" {
    const parsed = try std.SemanticVersion.parse(string);
    // Nothing here should ever be zero-length or a placeholder.
    try testing.expect(parsed.major > 0 or parsed.minor > 0 or parsed.patch > 0);
    try testing.expect(std.mem.startsWith(u8, line, "terminator " ++ string));
}

test "a commit, when there is one, is a short hash" {
    if (commit.len == 0) return; // built outside a checkout
    try testing.expectEqual(@as(usize, 7), commit.len);
    for (commit) |ch| try testing.expect(std.ascii.isHex(ch));
}
