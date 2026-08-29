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

/// The shapes whose prefix starts with each byte, built at compile time.
///
/// Why this exists: L0 of docs/roadmap/record.md scrubs every byte off the
/// pty on its way into a recording, so this scan is in the drain path of the
/// running terminal rather than in a capture tool nobody is waiting for.
/// Trying all fourteen prefixes at every offset -- fourteen
/// runtime-length `std.mem.eql` calls per byte -- measured **67 MiB/s** on
/// the `zig build bench` `redact` rows, against a pty that
/// `bench/dump.sh` drains at about 48 MiB/s. That is a 1.4x margin over the
/// thing it has to keep up with, which is not a margin.
///
/// The shapes have five distinct first bytes, so almost every byte of real
/// output can be rejected with one array lookup instead of fourteen string
/// compares. `shapes` stays the single definition; this is derived from it,
/// and the test below asserts the derivation covers all of it so the two
/// cannot drift.
const by_first: [256][]const Shape = blk: {
    @setEvalBranchQuota(256 * (shapes.len + 4));
    var table: [256][]const Shape = @splat(&[_]Shape{});
    for (0..256) |b| {
        // Order is preserved from `shapes`, which matters: `sk-ant-` has to
        // be tried before `sk-`, or an Anthropic key is redacted as the
        // shorter shape and the reader is told the wrong thing about it.
        var bucket: [shapes.len]Shape = undefined;
        var n: usize = 0;
        for (shapes) |s| if (s.prefix[0] == b) {
            bucket[n] = s;
            n += 1;
        };
        if (n == 0) continue;
        const final = bucket[0..n].*;
        table[b] = &final;
    }
    break :blk table;
};

/// The distinct two-byte openings any shape can start with.
///
/// Derived from `shapes`, so there is still one definition of what a secret
/// looks like; the tests below assert the derivation is complete in both
/// directions. Pairs rather than single bytes because `s` alone is one of
/// the commonest bytes in English prose and in source code, so a first-byte
/// filter rejects almost nothing on the `ascii` corpus -- measured, it was
/// worth only 1.3x. `se`, `sk`, `gh`, `gi`, `xo`, `AK`, `AI` and `Be` are
/// rare, and rejecting on the pair is what makes this scan cost nothing
/// next to the pty it sits in front of.
const Pair = struct { a: u8, b: u8 };

const lead_pairs: []const Pair = blk: {
    var buf: [shapes.len]Pair = undefined;
    var n: usize = 0;
    for (shapes) |s| {
        // Every shape is at least two bytes long, which the test below
        // asserts rather than assumes.
        var seen = false;
        for (buf[0..n]) |p| {
            if (p.a == s.prefix[0] and p.b == s.prefix[1]) seen = true;
        }
        if (!seen) {
            buf[n] = .{ .a = s.prefix[0], .b = s.prefix[1] };
            n += 1;
        }
    }
    const final = buf[0..n].*;
    break :blk &final;
};

/// The next offset at or after `from` whose two bytes could open a shape.
///
/// Why this is vectorised: the scan runs on the thread that drains the pty,
/// once over every byte the terminal is handed. The first-byte table below
/// already cut it from fourteen `std.mem.eql` per byte to one array lookup
/// -- 67 MiB/s to about 1,000 -- and at that speed it still cost 13% of the
/// pty rate in the running app, measured with `--frame-stats`, which is more
/// than L0's gate allows. Thirty-two bytes compared against eight pairs at a
/// time is the difference between a per-byte cost and one that rounds to
/// nothing.
fn nextCandidate(buf: []const u8, from: usize) ?usize {
    const lanes = 32;
    const V = @Vector(lanes, u8);
    const M = @Vector(lanes, bool);
    const yes: M = @splat(true);

    var i = from;
    // `+ 1` because the second byte of the last lane's pair has to be in
    // the buffer too.
    while (i + lanes + 1 <= buf.len) : (i += lanes) {
        const cur: V = buf[i..][0..lanes].*;
        const nxt: V = buf[i + 1 ..][0..lanes].*;
        var hit: M = @splat(false);
        inline for (lead_pairs) |p| {
            const both = @select(bool, cur == @as(V, @splat(p.a)), nxt == @as(V, @splat(p.b)), @as(M, @splat(false)));
            hit = @select(bool, both, yes, hit);
        }
        const mask: std.meta.Int(.unsigned, lanes) = @bitCast(hit);
        if (mask != 0) return i + @ctz(mask);
    }
    while (i + 1 < buf.len) : (i += 1) {
        for (by_first[buf[i]]) |shape| {
            if (shape.prefix[1] == buf[i + 1]) return i;
        }
    }
    // A single byte at the end cannot open anything: every shape is longer.
    return null;
}

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
    outer: while (i < buf.len) {
        // Skip straight to the next byte that could begin a shape. On real
        // terminal output that steps over almost the whole buffer.
        i = nextCandidate(buf, i) orelse break;
        for (by_first[buf[i]]) |shape| {
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
        i += 1;
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

test "the first-byte table covers every shape and invents none" {
    // `by_first` is derived from `shapes`, and a derivation that silently
    // dropped a row would turn a redaction off with nothing to notice it.
    // The check is set equality in both directions.
    var seen: usize = 0;
    for (by_first, 0..) |bucket, b| {
        for (bucket) |shape| {
            seen += 1;
            // Every shape is filed under its own first byte...
            try testing.expectEqual(@as(u8, @intCast(b)), shape.prefix[0]);
            // ...and is one of the shapes, not something invented.
            var known = false;
            for (shapes) |s| {
                if (std.mem.eql(u8, s.prefix, shape.prefix)) known = true;
            }
            try testing.expect(known);
        }
    }
    try testing.expectEqual(shapes.len, seen);

    // And the reverse: every shape is reachable through the table.
    for (shapes) |s| {
        var reachable = false;
        for (by_first[s.prefix[0]]) |candidate| {
            if (std.mem.eql(u8, candidate.prefix, s.prefix)) reachable = true;
        }
        try testing.expect(reachable);
    }
}

test "the lead-pair set covers every shape and nothing else" {
    // The vectorised skip is only correct if `lead_pairs` contains every
    // two-byte opening a shape can have. A shape whose pair fell out of
    // this set would simply never be found, silently.
    for (shapes) |s| {
        try testing.expect(s.prefix.len >= 2);
        var covered = false;
        for (lead_pairs) |p| {
            if (p.a == s.prefix[0] and p.b == s.prefix[1]) covered = true;
        }
        try testing.expect(covered);
    }
    for (lead_pairs) |p| {
        var used = false;
        for (by_first[p.a]) |shape| {
            if (shape.prefix[1] == p.b) used = true;
        }
        try testing.expect(used);
    }
    // No duplicates: only a waste of a compare, but it says the derivation
    // is doing what it claims.
    for (lead_pairs, 0..) |p, i| {
        for (lead_pairs[i + 1 ..]) |q| {
            try testing.expect(!(p.a == q.a and p.b == q.b));
        }
    }
}

test "the vector scan finds a secret at every alignment" {
    // Thirty-two bytes at a time, so a secret that begins in the tail of one
    // vector, in the scalar remainder, or exactly on a lane boundary must
    // all be found. Off-by-one here is invisible until it is a leak.
    const secret = "ghp_ABCDEFGHIJKLMNOPQRSTUV";
    for (0..96) |pad| {
        const buf = try testing.allocator.alloc(u8, pad + secret.len + 7);
        defer testing.allocator.free(buf);
        @memset(buf, '.');
        @memcpy(buf[pad..][0..secret.len], secret);
        try testing.expectEqual(@as(usize, 1), scrub(buf, null));
        try testing.expect(std.mem.indexOf(u8, buf, "ABCDEFGHIJ") == null);
        try testing.expect(std.mem.indexOf(u8, buf, "ghp_x") != null);
    }
}

test "a longer prefix still wins over the shorter one that contains it" {
    // `sk-ant-` and `sk-` share a bucket, and the bucket keeps the order
    // `shapes` declares. Reversing it would report an Anthropic key as a
    // generic api key -- same redaction, wrong label.
    var buf = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz".*;
    var first: Finding = undefined;
    try testing.expectEqual(@as(usize, 1), scrub(&buf, &first));
    try testing.expectEqualStrings("anthropic key", first.what);
}

test "an empty or tiny buffer is not a special case" {
    var empty: [0]u8 = .{};
    try testing.expectEqual(@as(usize, 0), scrub(&empty, null));
    var tiny = "sk-".*;
    try testing.expectEqual(@as(usize, 0), scrub(&tiny, null));
}
