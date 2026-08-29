//! Frame timing for the running app: the numbers `zig build bench` cannot
//! produce.
//!
//! The bench is headless, so the mutex is never contended there and no frame
//! is ever presented. Whether the reader thread is starved by the display,
//! and how long a frame takes to build against how long it waits for vblank,
//! can only be measured with a window open. This is that measurement, printed
//! to stderr once a second while `--frame-stats` is on, with a totals line at
//! exit.
//!
//! Per frame, three intervals:
//!
//!   lock      how long the main thread held the terminal mutex. The reader
//!             cannot feed a byte while this is non-zero, so it is the number
//!             that decides bulk-output throughput.
//!   build     from the lock being released to the frame being submitted --
//!             vertex generation and draw calls.
//!   drawable  the wait for the GPU to finish plus the wait for a drawable.
//!
//! Before Sprint 1 of docs/roadmap/performance.md, that wait happened inside
//! `lock`, and the lock column was the whole frame. It was called `present`
//! until D0, when the wait stopped being SDL's and became ours.

const std = @import("std");

pub fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const report_every_ns: u64 = 1_000_000_000;

/// Sum and max over a window, reported as average and worst case. The
/// average says what a frame usually costs; the max is the stall a user
/// would notice.
const Interval = struct {
    sum: u64 = 0,
    max: u64 = 0,

    fn add(self: *Interval, ns: u64) void {
        self.sum += ns;
        self.max = @max(self.max, ns);
    }

    fn avgUs(self: Interval, n: u64) f64 {
        if (n == 0) return 0;
        return @as(f64, @floatFromInt(self.sum / n)) / 1000.0;
    }

    fn maxUs(self: Interval) f64 {
        return @as(f64, @floatFromInt(self.max)) / 1000.0;
    }
};

pub const FrameTimes = struct {
    lock: u64 = 0,
    build: u64 = 0,
    /// The wait for the GPU to finish the frame, plus the wait for a
    /// drawable to present it to.
    drawable: u64 = 0,
    /// GPU submission calls the frame made. Not a time, but it is the number
    /// Sprint 2 existed to change.
    calls: u64 = 0,
};

pub const FrameStats = struct {
    enabled: bool = false,

    started: u64 = 0,
    window_start: u64 = 0,
    window_bytes_start: u64 = 0,

    frames: u64 = 0,
    lock: Interval = .{},
    build: Interval = .{},
    drawable: Interval = .{},
    calls: Interval = .{},

    total_frames: u64 = 0,
    /// Worst lock hold over the whole run, not just the last window.
    total_lock_max: u64 = 0,

    pub fn init(enabled: bool) FrameStats {
        const now = nowNs();
        return .{ .enabled = enabled, .started = now, .window_start = now };
    }

    pub fn record(self: *FrameStats, t: FrameTimes) void {
        if (!self.enabled) return;
        self.frames += 1;
        self.lock.add(t.lock);
        self.build.add(t.build);
        self.drawable.add(t.drawable);
        self.calls.add(t.calls);
        self.total_lock_max = @max(self.total_lock_max, t.lock);
    }

    /// Print a line if a second has passed. `bytes_read` is the reader
    /// thread's running total, so the line can say how fast the PTY is
    /// actually being drained -- the throughput figure the sprint is about.
    pub fn maybeReport(self: *FrameStats, bytes_read: u64) void {
        if (!self.enabled) return;
        const now = nowNs();
        const elapsed = now - self.window_start;
        if (elapsed < report_every_ns) return;

        const n = self.frames;
        if (n == 0) {
            // A window can elapse without a single frame being drawn: an
            // event that wakes the loop without dirtying the screen -- a
            // mouse move over an idle window -- does exactly that. There
            // is nothing to average, so start a new window rather than
            // dividing by it.
            self.window_start = now;
            self.window_bytes_start = bytes_read;
            return;
        }
        std.debug.print(
            "frame-stats  {d:>4} fps  lock {d:>7.0}/{d:<7.0}  build {d:>6.0}/{d:<6.0}  drawable {d:>7.0}/{d:<7.0} us  calls {d:>5}/{d:<5}  pty {d:>7.2} MiB/s\n",
            .{
                n * 1_000_000_000 / elapsed,
                self.lock.avgUs(n),
                self.lock.maxUs(),
                self.build.avgUs(n),
                self.build.maxUs(),
                self.drawable.avgUs(n),
                self.drawable.maxUs(),
                self.calls.sum / n,
                self.calls.max,
                mibPerSec(bytes_read - self.window_bytes_start, elapsed),
            },
        );

        self.total_frames += n;
        self.frames = 0;
        self.lock = .{};
        self.build = .{};
        self.drawable = .{};
        self.calls = .{};
        self.window_start = now;
        self.window_bytes_start = bytes_read;
    }

    /// The whole-run figures. Printed once, at exit, so a scripted run
    /// (`--shell` pointing at something that dumps output and quits) leaves
    /// one line that says what happened.
    pub fn reportTotals(self: *FrameStats, bytes_read: u64) void {
        if (!self.enabled) return;
        const elapsed = nowNs() - self.started;
        const frames = self.total_frames + self.frames;
        std.debug.print(
            "frame-stats  total: {d} frames in {d:.2} s, {d} bytes from the pty at {d:.2} MiB/s, worst lock hold {d:.0} us\n",
            .{
                frames,
                @as(f64, @floatFromInt(elapsed)) / 1e9,
                bytes_read,
                mibPerSec(bytes_read, elapsed),
                @as(f64, @floatFromInt(self.total_lock_max)) / 1000.0,
            },
        );
    }
};

fn mibPerSec(bytes: u64, ns: u64) f64 {
    if (ns == 0) return 0;
    const b: f64 = @floatFromInt(bytes);
    const s: f64 = @as(f64, @floatFromInt(ns)) / 1e9;
    return b / s / (1024.0 * 1024.0);
}

const testing = std.testing;

test "intervals report average and worst case" {
    var iv = Interval{};
    iv.add(1_000);
    iv.add(3_000);
    try testing.expectEqual(@as(f64, 2.0), iv.avgUs(2));
    try testing.expectEqual(@as(f64, 3.0), iv.maxUs());
}

test "a disabled timer records nothing" {
    var s = FrameStats.init(false);
    s.record(.{ .lock = 1, .build = 1, .drawable = 1 });
    try testing.expectEqual(@as(u64, 0), s.frames);
}

test "a window that elapses with no frames starts a new one instead of dividing by zero" {
    var s = FrameStats.init(true);
    // Backdate the window so a report is due, and record nothing -- what
    // the event loop does when it wakes for an event that sets neither
    // `redraw` nor `term.dirty`. Every column here is a per-frame average.
    s.window_start -= 2 * report_every_ns;
    s.maybeReport(0);

    // The window moved on, and no frame was invented to fill it.
    try testing.expectEqual(@as(u64, 0), s.frames);
    try testing.expectEqual(@as(u64, 0), s.total_frames);
    try testing.expect(nowNs() - s.window_start < report_every_ns);
}

test "a window with frames in it reports and resets" {
    var s = FrameStats.init(true);
    s.record(.{ .lock = 1_000, .build = 2_000, .drawable = 3_000, .calls = 2 });
    s.record(.{ .lock = 3_000, .build = 4_000, .drawable = 5_000, .calls = 4 });
    try testing.expectEqual(@as(u64, 2), s.frames);
    try testing.expectEqual(@as(u64, 6), s.calls.sum);

    s.window_start -= 2 * report_every_ns;
    s.maybeReport(4096);

    // The two frames are retired into the run total, not lost.
    try testing.expectEqual(@as(u64, 2), s.total_frames);
    try testing.expectEqual(@as(u64, 0), s.frames);
    try testing.expectEqual(@as(u64, 0), s.calls.sum);
    // The worst lock hold is a whole-run figure and outlives the window.
    try testing.expectEqual(@as(u64, 3_000), s.total_lock_max);
    try testing.expectEqual(@as(u64, 4096), s.window_bytes_start);
}
