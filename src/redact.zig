//! Redaction for recorded corpora.
//!
//! A recording captures whatever the recorded program happened to print,
//! and agent CLIs print a startup banner. The first pair of corpora landed
//! in a public repository carrying live `claude.ai/code/session_…` remote
//! control links, because they were *scanned* for the problems someone
//! thought of rather than made incapable of carrying any.
//!
//! So this runs at capture time, in `record.zig`, before a corpus ever
//! exists on disk — and `check_corpora.zig` asserts in CI that running it
//! over a committed corpus changes nothing. One definition of "sensitive",
//! used by both, so the guard and the check cannot drift apart.
//!
//! **Replacements are the same length as what they replace.** Each corpus
//! has a `.timing` sidecar recording how many bytes arrived in each read;
//! a redaction that changed the length would silently invalidate it.
//!
//! This is a guard, not a guarantee. It knows the shapes it knows. A
//! recording still deserves reading before it is committed.

const std = @import("std");

/// A secret shape: a literal prefix followed by a run of secret-ish bytes.
const Shape = struct {
    prefix: []const u8,
    /// Minimum run length after the prefix before this is worth redacting,
    /// so that prose mentioning the prefix is left alone.
    min_run: usize,
    what: []const u8,
};

const shapes = [_]Shape{
    // Claude Code remote-control session links. The one that got out.
    .{ .prefix = "session_", .min_run = 12, .what = "session id" },
    // API keys, in the forms the common ones take.
    .{ .prefix = "sk-ant-", .min_run = 16, .what = "anthropic key" },
    .{ .prefix = "sk-", .min_run = 20, .what = "api key" },
    .{ .prefix = "ghp_", .min_run = 20, .what = "github token" },
    .{ .prefix = "gho_", .min_run = 20, .what = "github token" },
    .{ .prefix = "ghu_", .min_run = 20, .what = "github token" },
    .{ .prefix = "ghs_", .min_run = 20, .what = "github token" },
    .{ .prefix = "ghr_", .min_run = 20, .what = "github token" },
    .{ .prefix = "github_pat_", .min_run = 20, .what = "github token" },
    .{ .prefix = "xoxb-", .min_run = 16, .what = "slack token" },
    .{ .prefix = "xoxp-", .min_run = 16, .what = "slack token" },
    .{ .prefix = "AKIA", .min_run = 16, .what = "aws key id" },
    .{ .prefix = "Bearer ", .min_run = 16, .what = "bearer token" },
    .{ .prefix = "AIza", .min_run = 30, .what = "google key" },
};

/// Bytes that can appear inside a token. Deliberately narrow: stopping at
/// the first byte outside this set is what keeps a redaction from eating
/// the punctuation or escape sequence that follows it.
fn isTokenByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

pub const Finding = struct {
    offset: usize,
    len: usize,
    what: []const u8,
};

/// Redact every known shape in `buf`, in place and without changing its
/// length. Returns how many were found; `first` receives the first one, for
/// a caller that wants to say where.
pub fn scrub(buf: []u8, first: ?*Finding) usize {
    var found: usize = 0;
    var i: usize = 0;
    outer: while (i < buf.len) : (i += 1) {
        for (shapes) |shape| {
            if (i + shape.prefix.len > buf.len) continue;
            if (!std.mem.eql(u8, buf[i..][0..shape.prefix.len], shape.prefix)) continue;

            var end = i + shape.prefix.len;
            while (end < buf.len and isTokenByte(buf[end])) end += 1;
            const run = end - (i + shape.prefix.len);
            if (run < shape.min_run) continue;
            // Already redacted. Without this, redaction is not idempotent
            // -- the replacement matches its own shape -- and the CI check
            // below, which is "redacting this changes nothing", could never
            // pass on a file that had legitimately been scrubbed.
            if (std.mem.allEqual(u8, buf[i + shape.prefix.len .. end], 'x')) {
                i = end;
                continue :outer;
            }

            if (found == 0) if (first) |f| {
                f.* = .{ .offset = i, .len = end - i, .what = shape.what };
            };
            found += 1;
            // The prefix stays, so a reader can see what was removed and
            // the byte count is unchanged.
            @memset(buf[i + shape.prefix.len .. end], 'x');
            i = end;
            continue :outer;
        }
    }
    return found;
}

/// Whether `buf` contains anything `scrub` would change. Non-destructive,
/// for the CI check.
pub fn isClean(alloc: std.mem.Allocator, buf: []const u8, first: ?*Finding) !bool {
    const copy = try alloc.dupe(u8, buf);
    defer alloc.free(copy);
    return scrub(copy, first) == 0;
}

const testing = std.testing;

test "a session link is redacted and the length is preserved" {
    var buf = "see https://claude.ai/code/session_015fCwM6faCRNYfgauovyEUw now".*;
    const before = buf.len;
    var first: Finding = undefined;
    try testing.expectEqual(@as(usize, 1), scrub(&buf, &first));
    try testing.expectEqual(before, buf.len);
    try testing.expectEqualStrings("session id", first.what);
    try testing.expect(std.mem.indexOf(u8, &buf, "015fCwM6") == null);
    // The prefix survives, so the reader can tell what was taken out, and
    // the text around it is untouched.
    try testing.expect(std.mem.indexOf(u8, &buf, "session_xxx") != null);
    try testing.expect(std.mem.endsWith(u8, &buf, " now"));
}

test "redaction stops at the first byte that cannot be in a token" {
    // The escape sequence after the token must survive intact, or the
    // corpus stops being a faithful recording of everything else.
    var buf = "session_0123456789abcdef\x1b[1mbold\x1b[0m".*;
    _ = scrub(&buf, null);
    try testing.expect(std.mem.indexOf(u8, &buf, "\x1b[1mbold\x1b[0m") != null);
}

test "several secrets in one buffer are all found" {
    var buf = "a sk-abcdefghijklmnopqrstuvwxyz b ghp_ABCDEFGHIJKLMNOPQRSTUV c".*;
    try testing.expectEqual(@as(usize, 2), scrub(&buf, null));
    try testing.expect(std.mem.indexOf(u8, &buf, "abcdefghij") == null);
    try testing.expect(std.mem.indexOf(u8, &buf, "ABCDEFGHIJ") == null);
}

test "prose mentioning a prefix is left alone" {
    // `min_run` is what keeps this from redacting documentation, log lines
    // and this repository's own source.
    const cases = [_][]const u8{
        "the session_id column",
        "a Bearer token, generically",
        "sk-short",
        "resume a session_1 quickly",
    };
    for (cases) |case| {
        const buf = try testing.allocator.dupe(u8, case);
        defer testing.allocator.free(buf);
        try testing.expectEqual(@as(usize, 0), scrub(buf, null));
        try testing.expectEqualStrings(case, buf);
    }
}

test "scrubbing an already-scrubbed buffer changes nothing" {
    // The property the CI check relies on: clean means redaction is a no-op.
    var buf = "session_015fCwM6faCRNYfgauovyEUw and sk-abcdefghijklmnopqrstuvwxyz".*;
    _ = scrub(&buf, null);
    const once = try testing.allocator.dupe(u8, &buf);
    defer testing.allocator.free(once);
    try testing.expectEqual(@as(usize, 0), scrub(&buf, null));
    try testing.expectEqualSlices(u8, once, &buf);
    try testing.expect(try isClean(testing.allocator, &buf, null));
}

test "an empty or tiny buffer is not a special case" {
    var empty: [0]u8 = .{};
    try testing.expectEqual(@as(usize, 0), scrub(&empty, null));
    var tiny = "sk-".*;
    try testing.expectEqual(@as(usize, 0), scrub(&tiny, null));
}
