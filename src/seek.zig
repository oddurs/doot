//! Seeking: the window looking at a moment in the log instead of at the live
//! terminal.
//!
//! L1 of [record.md](../docs/roadmap/record.md), and the half of it a person
//! can see. `ckpt.zig` makes any moment cheap to reach; this decides which
//! moment, owns the second `Terminal` the moment is materialized into, and
//! builds the status row that says where you are.
//!
//! ## What never happens here
//!
//! **The live terminal is not touched.** A seek decodes a checkpoint into a
//! *second* `Terminal` -- allocated on the first seek, kept for the window's
//! life -- and replays forward into that. `renderer.snapshot` already takes a
//! `*Terminal`, so seeking is a matter of pointing it at the other one. The
//! reader thread keeps feeding the live terminal the whole time, which is why
//! leaving seek mode is instant and why the child never notices.
//!
//! **The index is built off the main thread**, by a worker that opens the
//! `.trec` read-only and touches nothing else this process owns: no terminal
//! mutex, no recorder mutex, one file descriptor and its own memory. The one
//! place the recorder mutex is taken is on *entering* seek mode, to flush the
//! log to the present -- `rec.Writer.flushForSeek` -- because otherwise "seek
//! to now" and "the live screen" would differ by whatever is still buffered.
//!
//! **No file is opened at all when there is no log.** `--no-record` and
//! `--incognito` reach `unavailable`, the status row says so, and the seek
//! path never calls `open`. There is a test.
//!
//! std only: no SDL here. `main.zig` spawns the thread and pumps the events;
//! everything that decides anything is in this file, where it can be tested
//! without a window.

const std = @import("std");
const grid = @import("grid.zig");
const rec = @import("rec.zig");
const ckpt = @import("ckpt.zig");
const replay = @import("replay.zig");
const Terminal = @import("terminal.zig").Terminal;

/// Where the window is looking.
pub const Mode = enum {
    /// At the live terminal.
    live,
    /// The index is being built; the status row says so.
    building,
    /// At a moment in the log.
    seeking,
    /// There is no log to seek in -- an incognito or `--no-record` session,
    /// or a recording that could not be read.
    unavailable,
};

/// A step of the scrubber, in seconds.
pub const step_s: i64 = 1;
pub const big_step_s: i64 = 10;

// ---------------------------------------------------------------------------
// The worker
// ---------------------------------------------------------------------------

/// One index build. Handed to a thread, polled by the main loop, and read
/// only after `done` is true -- which is the whole of the synchronisation, and
/// is why nothing here needs a mutex.
pub const Build = struct {
    alloc: std.mem.Allocator,
    /// A copy: the writer owns its own path and may close at any moment.
    path: [:0]u8,
    /// The session already read, when this is a refresh rather than a first
    /// build. The worker reads only the bytes past `from_offset`.
    from_offset: u64 = 0,
    at_us_base: u64 = 0,
    /// The events an earlier build already produced, oldest first, and the
    /// header they came with.
    ///
    /// **Borrowed, and read on the worker thread.** That is safe for exactly
    /// one reason and it is worth naming: `State.events` is appended to only
    /// in `absorb`, and `absorb` runs on the main thread after `done` is set.
    /// While a build is in flight `seekAction` queues the key press instead
    /// of touching the state, so this slice cannot move under the worker.
    prior: []const rec.Event = &.{},
    prior_header: ?rec.Header = null,
    opts: ckpt.Options = .{},

    done: std.atomic.Value(bool) = .init(false),
    failed: ?anyerror = null,
    took_ns: u64 = 0,
    read_ns: u64 = 0,

    /// The file bytes this build read. Events point into it, so it outlives
    /// them; `State` keeps every one.
    bytes: []u8 = &.{},
    tail: rec.Tail = .{ .events = &.{}, .next_offset = 0, .last_at_us = 0 },
    header: ?rec.Header = null,
    /// The product. Ownership moves to `State` in `absorb`.
    index: ?ckpt.Index = null,

    pub fn deinit(self: *Build) void {
        self.alloc.free(self.path);
        if (self.bytes.len > 0) self.alloc.free(self.bytes);
        if (self.tail.events.len > 0) self.alloc.free(self.tail.events);
        if (self.index) |*i| i.deinit();
        self.* = undefined;
    }
};

/// Read the log and build the index from it. **The whole of the work**, on
/// the worker thread.
///
/// Nothing here touches the terminal mutex, the recorder mutex, or the live
/// `Terminal`. It opens one descriptor, reads it, replays it into a
/// `Terminal` of its own that is freed before this returns, and leaves an
/// index of encoded blobs behind. That is the sprint's non-negotiable shape:
/// a checkpoint is derived from the *log*, because the log is the scrubbed
/// copy and the live terminal is not.
///
/// A first build reads the whole file; a refresh reads only past
/// `from_offset` and replays the events the state already holds in front of
/// the new ones. The replay is O(session) either way -- the index cannot be
/// extended in place, because a decimation may have thrown away the entry a
/// refresh would want to continue from -- and doing it here rather than in
/// `absorb` is what keeps a several-hundred-millisecond replay off the frame
/// loop.
pub fn runBuild(b: *Build) void {
    const t0 = rec.nowNs();
    defer {
        b.took_ns = rec.nowNs() -| t0;
        b.done.store(true, .release);
    }

    const whole = rec.readFile(b.alloc, b.path, 1 << 30) catch |err| {
        b.failed = err;
        return;
    };
    // A first build reads the header too; a refresh already has it.
    if (b.from_offset == 0) {
        b.header = rec.Header.decode(whole) catch |err| {
            b.alloc.free(whole);
            b.failed = err;
            return;
        };
    }
    const start = if (b.from_offset == 0) rec.header_len else b.from_offset;
    if (start > whole.len) {
        // The file shrank under us. Nothing sane to do but say so.
        b.alloc.free(whole);
        b.failed = error.RecordingShrank;
        return;
    }

    // Only the tail is kept: `parseFrom` points its payloads into this slice,
    // so a refresh allocates the new bytes and nothing else. The prefix has
    // already been read into a buffer the caller is holding.
    const keep = b.alloc.alloc(u8, whole.len - start) catch |err| {
        b.alloc.free(whole);
        b.failed = err;
        return;
    };
    @memcpy(keep, whole[start..]);
    b.alloc.free(whole);
    b.bytes = keep;

    b.tail = rec.parseFrom(b.alloc, keep, 0, b.at_us_base) catch |err| {
        b.failed = err;
        return;
    };
    // `parseFrom` was given a slice starting at `start`, so its offsets are
    // relative to that. Put them back in the file's frame.
    b.tail.next_offset += start;
    if (b.tail.truncated_at) |t| b.tail.truncated_at = t + start;
    b.read_ns = rec.nowNs() -| t0;

    // One contiguous view of the whole session, borrowed prefix and freshly
    // read tail. Temporary: the index holds encoded bytes and event
    // *indices*, never a pointer into an event.
    const all = b.alloc.alloc(rec.Event, b.prior.len + b.tail.events.len) catch |err| {
        b.failed = err;
        return;
    };
    defer b.alloc.free(all);
    @memset(all[0..b.prior.len], .{ .kind = .tick, .flags = 0, .at_us = 0, .payload = &.{} });
    @memcpy(all[b.prior.len..], b.tail.events);

    const session = rec.Session{
        .header = b.header orelse b.prior_header orelse {
            b.failed = error.NoHeader;
            return;
        },
        .events = all,
        .truncated_at = b.tail.truncated_at,
        .next_offset = b.tail.next_offset,
        .last_at_us = b.tail.last_at_us,
    };
    b.index = ckpt.build(b.alloc, session, b.opts) catch |err| {
        b.failed = err;
        return;
    };
}

// ---------------------------------------------------------------------------
// The state
// ---------------------------------------------------------------------------

pub const State = struct {
    alloc: std.mem.Allocator,
    mode: Mode = .live,

    /// Every file buffer read so far, oldest first. Event payloads point into
    /// these, so none of them may be freed while the session is alive.
    buffers: std.ArrayList([]u8) = .empty,
    events: std.ArrayList(rec.Event) = .empty,
    header: ?rec.Header = null,
    next_offset: u64 = 0,
    last_at_us: u64 = 0,
    truncated_at: ?u64 = null,

    index: ?ckpt.Index = null,
    /// The second terminal. Allocated on the first seek and kept: rebuilding
    /// it per seek would allocate two screens and a 10,000-line ring every
    /// time the user pressed a key.
    view: ?Terminal = null,

    /// Where the view is, as an event index: events `[0, target)` applied.
    target: usize = 0,
    /// Which alt-screen span the last jump landed on, so ⇧↑ walks back
    /// through them rather than re-landing on the same one.
    span_cursor: ?usize = null,

    /// The last seek's cost, end to end, for `--frame-stats` and the gate.
    last_seek_ns: u64 = 0,
    last_replayed: usize = 0,
    /// Why there is nothing to seek in, when there is not.
    reason: []const u8 = "",

    pub fn deinit(self: *State) void {
        if (self.index) |*i| i.deinit();
        if (self.view) |*v| v.deinit();
        for (self.buffers.items) |b| self.alloc.free(b);
        self.buffers.deinit(self.alloc);
        self.events.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn active(self: *const State) bool {
        return self.mode == .seeking;
    }

    /// Take a finished build. The state owns everything in it afterwards.
    ///
    /// Cheap by construction: the worker did the reading and the replaying,
    /// so this is two appends and a move. Anything expensive here would be
    /// expensive *on the frame loop*, which is the thing the worker exists
    /// to avoid.
    pub fn absorb(self: *State, b: *Build) !void {
        if (b.failed) |err| {
            self.mode = .unavailable;
            self.reason = switch (err) {
                error.FileNotFound => "no recording for this session",
                else => "this session's recording could not be read",
            };
            return;
        }
        if (b.header) |h| self.header = h;
        // Room first, so a failure here leaves the state exactly as it was
        // rather than holding a buffer whose events never arrived.
        try self.buffers.ensureUnusedCapacity(self.alloc, 1);
        try self.events.ensureUnusedCapacity(self.alloc, b.tail.events.len);
        self.buffers.appendAssumeCapacity(b.bytes);
        b.bytes = &.{};
        self.events.appendSliceAssumeCapacity(b.tail.events);
        self.next_offset = b.tail.next_offset;
        self.last_at_us = b.tail.last_at_us;
        self.truncated_at = b.tail.truncated_at;

        // Moved out, *then* freed. `self.index = null` overwrites the
        // optional's payload, so a `*Index` into it is dangling the moment
        // the field is cleared -- and `deinit` through that pointer frees a
        // zeroed struct and leaks the whole index. Caught by the refresh
        // test's leak check, which is what a leak check is for.
        if (self.index) |old| {
            var stale = old;
            self.index = null;
            stale.deinit();
        }
        self.index = b.index;
        b.index = null;
        if (self.index == null) return error.NoIndex;
    }

    pub fn session(self: *const State) rec.Session {
        return .{
            .header = self.header orelse .{
                .cols = 80,
                .rows = 24,
                .wall_start_ns = 0,
                .session_id = @splat(0),
            },
            .events = self.events.items,
            .truncated_at = self.truncated_at,
            .next_offset = self.next_offset,
            .last_at_us = self.last_at_us,
        };
    }

    /// Materialize event index `target` into the view terminal.
    ///
    /// The greatest checkpoint at or before `target`, decoded, then
    /// `materializeInto` for the rest. Both halves are timed together,
    /// because "seek p95 ≤ 150 ms" is a claim about the key press, not about
    /// either half of it.
    pub fn seekTo(self: *State, target: usize) !void {
        const idx = &(self.index orelse return error.NoIndex);
        const s = self.session();
        const t = @min(target, s.events.len);
        const t0 = rec.nowNs();

        if (self.view == null) {
            self.view = try Terminal.init(self.alloc, s.header.cols, s.header.rows);
        }
        const view = &self.view.?;

        const at = idx.before(t) orelse return error.NoIndex;
        const meta = try idx.restore(at, view);
        const from: usize = @intCast(meta.event_index);
        try replay.materializeInto(view, s, from, t);
        // A replay has nobody to answer, and the *live* terminal is what
        // owes the child its cursor reports. Dropping these here is what
        // stops a seek putting a second CPR answer down the pty.
        view.replies.clearRetainingCapacity();

        self.target = t;
        self.last_replayed = t -| from;
        self.last_seek_ns = rec.nowNs() -| t0;
        self.mode = .seeking;
    }

    /// Wall-clock microseconds of the current target, from the head's clock.
    pub fn atUs(self: *const State) u64 {
        const s = self.session();
        if (self.target == 0 or s.events.len == 0) return 0;
        return s.events[@min(self.target, s.events.len) - 1].at_us;
    }

    pub fn durationUs(self: *const State) u64 {
        return self.last_at_us;
    }

    /// Move ±`seconds` and seek there.
    pub fn stepSeconds(self: *State, seconds: i64) !void {
        const now = @as(i64, @intCast(self.atUs()));
        const want = std.math.clamp(
            now + seconds * std.time.us_per_s,
            0,
            @as(i64, @intCast(self.durationUs())),
        );
        const ev = ckpt.eventAtTime(self.events.items, @intCast(want));
        self.span_cursor = null;
        try self.seekTo(ev);
    }

    /// The last frame of the previous closed full-screen program.
    ///
    /// A decode and no forward replay at all, because the index forces an
    /// entry at exactly this boundary. That is the whole demo.
    pub fn prevSpan(self: *State) !bool {
        const idx = &(self.index orelse return error.NoIndex);
        if (idx.spans.items.len == 0) return false;
        var i = self.span_cursor orelse idx.spans.items.len;
        if (i == 0) return false;
        i -= 1;
        try self.seekTo(idx.spans.items[i].exit_event);
        self.span_cursor = i;
        return true;
    }

    pub fn nextSpan(self: *State) !bool {
        const idx = &(self.index orelse return error.NoIndex);
        if (idx.spans.items.len == 0) return false;
        const cur = self.span_cursor orelse return false;
        if (cur + 1 >= idx.spans.items.len) return false;
        try self.seekTo(idx.spans.items[cur + 1].exit_event);
        self.span_cursor = cur + 1;
        return true;
    }

    /// Seek to the end of the log, which is the live screen.
    pub fn toEnd(self: *State) !void {
        self.span_cursor = null;
        try self.seekTo(self.events.items.len);
    }

    /// Back to the live terminal. The index and the view terminal are kept:
    /// the next seek is then a decode rather than a rebuild.
    pub fn toLive(self: *State) void {
        if (self.mode == .seeking) self.mode = .live;
    }

    /// How far behind the end of the log the view is.
    pub fn behindSeconds(self: *const State) u64 {
        return (self.durationUs() -| self.atUs()) / std.time.us_per_s;
    }

    /// Everything the status row needs, gathered in one place so `main.zig`
    /// stays glue.
    pub fn status(self: *const State) Status {
        const at = self.atUs();
        const total = self.durationUs();
        const start_s: i64 = if (self.header) |h|
            @divFloor(h.wall_start_ns, std.time.ns_per_s)
        else
            0;
        return .{
            .mode = self.mode,
            .wall_s = start_s + @as(i64, @intCast(at / std.time.us_per_s)),
            .behind_s = self.behindSeconds(),
            .frac = if (total == 0)
                1
            else
                @as(f64, @floatFromInt(at)) / @as(f64, @floatFromInt(total)),
            // The child's own title at that moment, which is the whole
            // reason a checkpoint carries one.
            .title = if (self.view) |*v| v.title.items else "",
            .reason = self.reason,
        };
    }
};

// ---------------------------------------------------------------------------
// The status row
// ---------------------------------------------------------------------------
//
// Drawn as the **bottom grid row**, not as an overlay: the main thread builds
// a row of `grid.Cell` and the renderer paints it exactly as it paints every
// other row. That reuses the whole draw path -- runs, colours, the atlas --
// and means the status row cannot render differently from the terminal it is
// describing. An overlay would have been a second text renderer.

pub const bar_width = 12;

pub const Status = struct {
    mode: Mode,
    /// Seconds since the Unix epoch at the moment being shown.
    wall_s: i64,
    /// How far behind the end of the log that moment is.
    behind_s: u64,
    /// Position in the session, 0..1.
    frac: f64,
    /// What the child called itself at that moment -- from the view
    /// terminal's `title`, which is why a checkpoint carries one.
    title: []const u8,
    /// What to say when there is nothing to seek in.
    reason: []const u8 = "",
};

/// `< 12:03:11  -4:32  [######------]  vim  esc: live`
///
/// ASCII throughout. The bar is a bar because a number alone does not say
/// "there is a lot more behind you"; the clock is there because "-4:32" is
/// only useful next to something absolute.
pub fn statusText(buf: []u8, st: Status) []const u8 {
    switch (st.mode) {
        .building => return copy(buf, "< building the index ...   esc: live"),
        .unavailable => {
            var tmp: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "< {s}   esc: live", .{st.reason}) catch
                return copy(buf, "< nothing to seek in   esc: live");
            return copy(buf, s);
        },
        .live => return buf[0..0],
        .seeking => {},
    }

    var bar: [bar_width]u8 = @splat('-');
    const filled: usize = @intFromFloat(@round(
        std.math.clamp(st.frac, 0, 1) * @as(f64, @floatFromInt(bar_width)),
    ));
    for (bar[0..@min(filled, bar_width)]) |*c| c.* = '#';

    const secs: u64 = @intCast(@max(st.wall_s, 0));
    const ds = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = ds.getDaySeconds();

    var tmp: [256]u8 = undefined;
    const text = std.fmt.bufPrint(
        &tmp,
        "< {d:0>2}:{d:0>2}:{d:0>2}  -{d}:{d:0>2}  [{s}]  {s}  esc: live",
        .{
            day.getHoursIntoDay(),
            day.getMinutesIntoHour(),
            day.getSecondsIntoMinute(),
            st.behind_s / 60,
            st.behind_s % 60,
            &bar,
            trimTitle(st.title),
        },
    ) catch return copy(buf, "< seeking   esc: live");
    return copy(buf, text);
}

fn copy(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

/// A child's title is arbitrary bytes and can be as long as it likes. Take
/// the first word, up to sixteen bytes, on a codepoint boundary.
fn trimTitle(title: []const u8) []const u8 {
    var end = @min(title.len, 16);
    while (end > 0 and (title[end - 1] & 0xc0) == 0x80) end -= 1;
    if (end > 0 and end < title.len and title[end - 1] >= 0x80) end -= 1;
    const cut = title[0..end];
    // Control bytes in a status row would be a child painting our chrome.
    for (cut, 0..) |c, i| {
        if (c < 0x20 or c == 0x7f) return cut[0..i];
    }
    return cut;
}

/// Paint `text` into a row of cells, reverse video, padded to `cells.len`.
pub fn paintStatus(cells: []grid.Cell, text: []const u8) void {
    const template = grid.Cell{ .attrs = .{ .reverse = true } };
    @memset(cells, template);
    var x: usize = 0;
    // One byte per cell: `statusText` is ASCII by construction, and a title
    // that was not has already been cut to one by `trimTitle`.
    for (text) |b| {
        if (x >= cells.len) break;
        if (b < 0x20 or b >= 0x7f) continue;
        cells[x] = .{ .cp = b, .attrs = .{ .reverse = true } };
        x += 1;
    }
}

/// `⏮ −4:32`, for the window title.
pub fn titleMarker(buf: []u8, behind_s: u64) []const u8 {
    const s = std.fmt.bufPrint(buf, "\u{23ee} \u{2212}{d}:{d:0>2}", .{
        behind_s / 60,
        behind_s % 60,
    }) catch return buf[0..0];
    return s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the status row says where you are" {
    var buf: [128]u8 = undefined;
    const got = statusText(&buf, .{
        .mode = .seeking,
        .wall_s = 12 * 3600 + 3 * 60 + 11,
        .behind_s = 4 * 60 + 32,
        .frac = 0.5,
        .title = "vim",
    });
    try testing.expectEqualStrings("< 12:03:11  -4:32  [######------]  vim  esc: live", got);
}

test "the bar fills with the position and never overruns" {
    var buf: [128]u8 = undefined;
    for ([_]f64{ -1, 0, 0.25, 0.999, 1, 2 }) |f| {
        const got = statusText(&buf, .{
            .mode = .seeking,
            .wall_s = 0,
            .behind_s = 0,
            .frac = f,
            .title = "",
        });
        const open = std.mem.indexOfScalar(u8, got, '[').?;
        const close = std.mem.indexOfScalar(u8, got, ']').?;
        try testing.expectEqual(bar_width, close - open - 1);
        for (got[open + 1 .. close]) |c| try testing.expect(c == '#' or c == '-');
    }
}

test "a hostile title cannot paint the status row" {
    // The title is whatever the child sent. A control byte in it would be a
    // program writing our chrome, and a truncation mid-codepoint would be a
    // replacement glyph that reads as our bug.
    var buf: [128]u8 = undefined;
    const got = statusText(&buf, .{
        .mode = .seeking,
        .wall_s = 0,
        .behind_s = 0,
        .frac = 0,
        .title = "ok\x1b[31mred",
    });
    try testing.expect(std.mem.indexOfScalar(u8, got, 0x1b) == null);
    try testing.expect(std.mem.indexOf(u8, got, "  ok  ") != null);

    const long = statusText(&buf, .{
        .mode = .seeking,
        .wall_s = 0,
        .behind_s = 0,
        .frac = 0,
        .title = "\u{1f680}\u{1f680}\u{1f680}\u{1f680}\u{1f680}\u{1f680}",
    });
    try testing.expect(std.unicode.utf8ValidateSlice(long));
}

test "painting the status row fills exactly the row" {
    var cells: [20]grid.Cell = undefined;
    paintStatus(&cells, "abc");
    try testing.expectEqual(@as(u21, 'a'), cells[0].cp);
    try testing.expectEqual(@as(u21, 'c'), cells[2].cp);
    for (cells) |c| try testing.expect(c.attrs.reverse);
    // Past the text, blanks -- still reverse, so the bar runs the full width.
    try testing.expectEqual(@as(u21, ' '), cells[19].cp);

    // And text longer than the row is cut rather than written past it.
    var narrow: [4]grid.Cell = undefined;
    paintStatus(&narrow, "abcdefghij");
    try testing.expectEqual(@as(u21, 'd'), narrow[3].cp);
}

test "the title marker reads as time behind live" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\u{23ee} \u{2212}4:32", titleMarker(&buf, 272));
    try testing.expectEqualStrings("\u{23ee} \u{2212}0:07", titleMarker(&buf, 7));
}

test "a refresh reads only the new bytes and still indexes the whole session" {
    // The path a second `Cmd ⇧ ↑` takes while the child is still printing:
    // the worker reads past `next_offset` only, and replays the events the
    // state already holds in front of the ones it just read. Getting that
    // wrong gives an index over the tail alone, which seeks correctly to
    // recent moments and silently cannot reach anything older.
    const alloc = testing.allocator;
    var dir_buf: [128]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "/tmp/doot-seek-refresh-{d}", .{std.c.getpid()}) catch
        unreachable;
    try testing.expect(rec.makeDir(dir));
    defer {
        var z: [std.c.PATH_MAX]u8 = undefined;
        const p = std.fmt.bufPrintZ(&z, "{s}", .{dir}) catch unreachable;
        _ = std.c.rmdir(p.ptr);
    }

    var w = try rec.Writer.open(alloc, dir, .{ .cols = 40, .rows = 8 });
    defer w.deinit();
    const path = try alloc.dupeZ(u8, w.path);
    defer alloc.free(path);
    defer {
        var z: [std.c.PATH_MAX]u8 = undefined;
        const p = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch unreachable;
        _ = std.c.unlink(p.ptr);
    }

    var t = rec.nowNs();
    var buf: [64]u8 = undefined;
    for (0..30) |i| {
        t += std.time.ns_per_ms;
        w.output(try std.fmt.bufPrint(&buf, "FIRST-HALF-{d:0>3}\r\n", .{i}), t);
    }
    w.flushForSeek(t);

    var st = State{ .alloc = alloc };
    defer st.deinit();
    {
        var b = Build{ .alloc = alloc, .path = try alloc.dupeZ(u8, path) };
        runBuild(&b);
        defer b.deinit();
        try testing.expectEqual(@as(?anyerror, null), b.failed);
        try st.absorb(&b);
    }
    const first_events = st.events.items.len;
    const first_offset = st.next_offset;
    try testing.expect(first_events > 0);

    for (30..60) |i| {
        t += std.time.ns_per_ms;
        w.output(try std.fmt.bufPrint(&buf, "SECOND-HALF-{d:0>3}\r\n", .{i}), t);
    }
    w.close(.clean);

    {
        var b = Build{
            .alloc = alloc,
            .path = try alloc.dupeZ(u8, path),
            .from_offset = first_offset,
            .at_us_base = st.last_at_us,
            .prior = st.events.items,
            .prior_header = st.header,
        };
        runBuild(&b);
        defer b.deinit();
        try testing.expectEqual(@as(?anyerror, null), b.failed);
        // The tail only: the prefix was not read a second time.
        try testing.expect(b.bytes.len < first_offset);
        try st.absorb(&b);
    }
    try testing.expect(st.events.items.len > first_events);

    // The index covers the whole session, not just the tail: a seek back to
    // the very first event has a checkpoint at or before it.
    const idx = &st.index.?;
    try testing.expectEqual(st.events.items.len, idx.events);
    try testing.expect(idx.before(0) != null);
    try testing.expect(idx.before(first_events / 2) != null);

    // And seeking to the end is the same terminal a replay from scratch
    // builds -- which is the whole identity, checked across a refresh.
    try st.toEnd();
    var whole = try replay.materialize(alloc, st.session());
    defer whole.deinit();
    whole.replies.clearRetainingCapacity();
    try testing.expectEqual(
        @import("check.zig").checksum(&whole),
        @import("check.zig").checksum(&st.view.?),
    );
    try testing.expectEqual(whole.next_line_id, st.view.?.next_line_id);
}

test "there is nothing to seek in, and the row says so" {
    var buf: [128]u8 = undefined;
    const got = statusText(&buf, .{
        .mode = .unavailable,
        .wall_s = 0,
        .behind_s = 0,
        .frac = 0,
        .title = "",
        .reason = "this session is not being recorded",
    });
    try testing.expectEqualStrings(
        "< this session is not being recorded   esc: live",
        got,
    );
}
