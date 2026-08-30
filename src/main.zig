//! doot -- a terminal emulator.
//!
//! Threading model: one thread reads the PTY and feeds the parser; the main
//! thread owns the window and draws. A single mutex guards the terminal state
//! between them. The reader wakes the main thread with an SDL event rather
//! than having it poll, so an idle terminal uses no CPU at all.
//!
//! The main thread holds the mutex only long enough to copy the visible cells
//! out of the terminal. Drawing and presenting -- which includes the wait for
//! vblank -- happen after it lets go, so the reader keeps feeding while a
//! frame is on its way to the display. Wake-ups coalesce for free: the reader
//! queues at most one wake event, and everything it parses while a frame is
//! presenting lands in the next one.

const std = @import("std");
const vt = @import("vt.zig");
const grid = @import("grid.zig");
const input = @import("input.zig");
const render = @import("render.zig");
const stats = @import("stats.zig");
const cli = @import("cli.zig");
const rec = @import("rec.zig");
const sel = @import("sel.zig");
const seek = @import("seek.zig");
const ckpt = @import("ckpt.zig");
const version = @import("version.zig");
const Terminal = @import("terminal.zig").Terminal;
const Pty = @import("pty.zig").Pty;

const c = render.c;

const default_font_size = cli.default_font_size;

/// A mutex, borrowed from SDL. Zig 0.16's own mutex wants an `Io` instance
/// threaded through every call site; SDL is already our platform layer, so
/// this keeps the two-thread handoff to four obvious lines.
const Mutex = struct {
    handle: ?*c.SDL_Mutex,

    fn init() Mutex {
        return .{ .handle = c.SDL_CreateMutex() };
    }
    fn deinit(self: *Mutex) void {
        c.SDL_DestroyMutex(self.handle);
    }
    fn lock(self: *Mutex) void {
        c.SDL_LockMutex(self.handle);
    }
    fn unlock(self: *Mutex) void {
        c.SDL_UnlockMutex(self.handle);
    }
};

/// State shared between the reader thread and the main thread.
const App = struct {
    mutex: Mutex,
    term: Terminal,
    parser: vt.Parser = .{},
    pty: Pty,

    /// Guards the session recorder, which three writers reach: the reader
    /// thread (`output`), the main thread (`input`, `focus`), and the main
    /// thread again from inside the terminal mutex (`resize`, `control`).
    ///
    /// **Lock order, where both are held: terminal first, then recorder.**
    /// The two sites that nest are `resize` and `control`, and they nest
    /// because `Terminal.resize` and `Terminal.fullReset` run under the
    /// terminal mutex -- that mutex is what orders them against a concurrent
    /// `parser.feed`, so it is what decides where their records belong. The
    /// reader thread never nests: it records, releases this, and only then
    /// takes the terminal mutex, so the terminal mutex hold is byte for byte
    /// what it was before recording existed. That is the whole point of
    /// sprint 1, and the `lock` column in `--frame-stats` is what says so.
    ///
    /// The nested pair are only cheap because `resize`, `focus` and `control`
    /// are **out-of-band** records: `rec.zig` keeps a reserved tail of the
    /// write buffer for them, so appending one cannot trigger a `write(2)`.
    /// Without that reserve a resize that landed on a full buffer performed a
    /// 64 KiB write inside the terminal mutex -- 2,234-5,578 µs measured, and
    /// exactly the stall sprint 1 exists to prevent.
    rec_mutex: Mutex,
    rec: rec.Writer,

    /// L1: where the window is looking, and what it takes to get there.
    ///
    /// Owned by the **main thread outright**. The seek worker touches only
    /// `seek_build`, and only until it sets that build's `done` flag; nothing
    /// here is ever read from two threads at once, which is why none of it
    /// needs a mutex of its own.
    seek: seek.State,
    seek_build: ?*seek.Build = null,
    seek_thread: ?std.Thread = null,
    /// What to do once the index arrives, because the key that asked for it
    /// was pressed before the build existed.
    seek_pending: ?SeekAction = null,
    /// The live terminal said it changed while the window was showing
    /// history. Consumed under the terminal mutex either way -- see the main
    /// loop -- and remembered here, so the live screen repaints the moment
    /// the seek ends rather than waiting for the child to print again.
    live_dirty: bool = true,

    running: std.atomic.Value(bool) = .init(true),
    /// A wake event is already queued, so don't queue another. Without this,
    /// a command producing megabytes of output floods the SDL event queue
    /// with millions of redundant wakeups.
    wake_queued: std.atomic.Value(bool) = .init(false),
    wake_event: u32 = 0,
    /// Bytes the reader has pulled off the PTY, for `--frame-stats`.
    bytes_read: std.atomic.Value(u64) = .init(0),

    fn requestWake(self: *App) void {
        if (self.wake_queued.swap(true, .acq_rel)) return;
        var ev = std.mem.zeroes(c.SDL_Event);
        ev.type = self.wake_event;
        _ = c.SDL_PushEvent(&ev);
    }
};

/// What a drag knows between events.
///
/// Everything it decides is computed in `sel.zig`; this is the four values a
/// press has to remember until the release, and nothing here branches on
/// terminal state.
const Mouse = struct {
    /// The button is down and the selection is ours to paint.
    dragging: bool = false,
    /// The pointer has moved since the press. A press and release with no
    /// movement in between is a click, and a click clears the selection
    /// rather than making a one-cell one.
    moved: bool = false,
    anchor: ?sel.Point = null,
    mode: sel.Mode = .character,
    rect: bool = false,
    /// Rows to scroll per tick while dragging past the edge of the grid, as
    /// the argument to `scrollView`. **Zero whenever the pointer is over the
    /// grid**, which is what keeps an idle terminal on `SDL_WaitEvent` rather
    /// than a 16 ms poll -- the event loop only takes the timeout while this
    /// is non-zero.
    autoscroll: isize = 0,
    /// Where the pointer was last seen, in device pixels. An autoscroll tick
    /// has no event of its own, so it re-derives the head from this: the row
    /// under a stationary pointer is a different line once the view moves.
    px: struct { x: i32 = 0, y: i32 = 0 } = .{},
};

/// What a seek key asked for. Held rather than acted on when the index is
/// still being built, so a key press is never silently dropped.
const SeekAction = union(enum) {
    prev_span,
    next_span,
    step: i64,
    to_end,
    to_time_us: u64,
};

// ---------------------------------------------------------------------------
// Seeking: the glue
// ---------------------------------------------------------------------------
//
// Everything that decides anything is in `seek.zig`, which has no SDL in it
// and is unit-tested without a window. What is here is the thread, the file
// path, and the one place the recorder mutex is taken.

/// A copy of the recording's path, with the log flushed to the present.
///
/// The **one** time L1 takes `rec_mutex`, and it is taken on its own: never
/// inside the terminal mutex, so the `lock` column cannot see it. The flush
/// can cost a 64 KiB `write(2)` -- L0 measured 1,002-2,760 µs -- and it is
/// paid once per entry into seek mode, on the main thread, because without it
/// the log stops short of the present and "seek to now == live" is false.
fn seekPath(app: *App, alloc: std.mem.Allocator) ?[:0]u8 {
    app.rec_mutex.lock();
    defer app.rec_mutex.unlock();
    if (!app.rec.recording or app.rec.path.len == 0) return null;
    app.rec.flushForSeek(stats.nowNs());
    return alloc.dupeZ(u8, app.rec.path) catch null;
}

fn seekWorker(app: *App) void {
    seek.runBuild(app.seek_build.?);
    // The main thread may be parked in `SDL_WaitEvent`; without this an idle
    // session would sit on "building the index ..." until something else
    // happened to wake it.
    app.requestWake();
}

/// A seek key was pressed. Start (or refresh) the index, then act.
fn seekAction(app: *App, alloc: std.mem.Allocator, action: SeekAction, report: bool) void {
    if (app.seek.mode == .unavailable) return;
    // Already seeking with an index in hand: this is the interactive path,
    // and it is a decode plus a bounded replay. No file, no thread, no lock.
    if (app.seek.mode == .seeking and app.seek_build == null) {
        applySeek(app, action, report);
        return;
    }
    if (app.seek_build != null) {
        app.seek_pending = action; // a build is already in flight
        return;
    }

    const path = seekPath(app, alloc) orelse {
        app.seek.mode = .unavailable;
        if (app.seek.reason.len == 0) {
            app.seek.reason = "this session is not being recorded";
        }
        return;
    };
    const build = alloc.create(seek.Build) catch {
        alloc.free(path);
        return;
    };
    build.* = .{
        .alloc = alloc,
        .path = path,
        .from_offset = app.seek.next_offset,
        .at_us_base = app.seek.last_at_us,
        // Borrowed for the worker's lifetime. Safe because a build is in
        // flight for exactly as long as `app.seek_build` is non-null, and
        // every path that would append to `events` returns early on that.
        .prior = app.seek.events.items,
        .prior_header = app.seek.header,
    };
    app.seek_build = build;
    app.seek_pending = action;
    app.seek.mode = .building;
    app.seek_thread = std.Thread.spawn(.{}, seekWorker, .{app}) catch {
        build.deinit();
        alloc.destroy(build);
        app.seek_build = null;
        app.seek.mode = .unavailable;
        app.seek.reason = "could not start the seek worker";
        return;
    };
}

/// Has the worker finished? Returns whether anything changed.
fn pollSeekBuild(app: *App, alloc: std.mem.Allocator, report: bool) bool {
    const build = app.seek_build orelse return false;
    if (!build.done.load(.acquire)) return false;

    if (app.seek_thread) |t| t.join();
    app.seek_thread = null;
    app.seek_build = null;

    const took_ns = build.took_ns;
    const read_ns = build.read_ns;
    app.seek.absorb(build) catch {
        app.seek.mode = .unavailable;
        app.seek.reason = "the index could not be built";
    };
    build.deinit();
    alloc.destroy(build);

    if (report) {
        if (app.seek.index) |idx| {
            // `read` against `total` is the split that says whether the
            // worker is I/O-bound or replay-bound, which is the number that
            // decides whether a lazier build is worth building.
            std.debug.print(
                "seek: index {d} entries, {d} spans, {d} KiB, {d} events, worker {d} ms ({d} ms read)\n",
                .{
                    idx.entries.items.len,
                    idx.spans.items.len,
                    idx.bytes / 1024,
                    idx.events,
                    took_ns / std.time.ns_per_ms,
                    read_ns / std.time.ns_per_ms,
                },
            );
        }
    }

    if (app.seek_pending) |action| {
        app.seek_pending = null;
        if (app.seek.mode != .unavailable) applySeek(app, action, report);
    }
    return true;
}

fn seekOnce(app: *App, action: SeekAction) !void {
    switch (action) {
        .prev_span => {
            // Nothing to jump to -- a session with no full-screen program in
            // it -- lands at the end of the log instead of doing nothing, so
            // the key always says something and the status row explains why.
            if (!try app.seek.prevSpan() and app.seek.mode != .seeking) {
                try app.seek.toEnd();
            }
        },
        .next_span => {
            if (!try app.seek.nextSpan() and app.seek.mode == .seeking) {
                try app.seek.toEnd();
            }
        },
        .step => |d| {
            // Stepping from live starts at the end of the log, which is the
            // screen you are already looking at.
            if (app.seek.mode != .seeking) try app.seek.toEnd();
            try app.seek.stepSeconds(d);
        },
        .to_end => try app.seek.toEnd(),
        .to_time_us => |us| try app.seek.seekTo(
            ckpt.eventAtTime(app.seek.events.items, us),
        ),
    }
}

fn applySeek(app: *App, action: SeekAction, report: bool) void {
    seekOnce(app, action) catch {
        app.seek.mode = .unavailable;
        app.seek.reason = "nothing recorded yet";
        return;
    };
    if (report) {
        std.debug.print("seek: {d} ms end to end, {d} events replayed forward\n", .{
            app.seek.last_seek_ns / std.time.ns_per_ms,
            app.seek.last_replayed,
        });
    }
}

/// Back to the live terminal. Cheap: the index and the view terminal stay,
/// so the next seek is a decode rather than a rebuild.
fn exitSeek(app: *App) void {
    if (app.seek.mode == .live) return;
    app.seek.mode = .live;
    app.seek_pending = null;
    // The live screen has been changing behind the seek and its `dirty` flag
    // was consumed every frame. Without this it would come back stale.
    app.live_dirty = true;
}

/// `--seek N` / `--seek-span N`, applied on the way out so the screenshot
/// shows a moment rather than the end. Errors are reported and not fatal: a
/// capture that could not seek should still capture something.
fn captureSeek(app: *App, alloc: std.mem.Allocator, opts: cli.Options) void {
    if (!app.rec.recording and app.rec.path.len == 0) {
        std.debug.print("doot: --seek: this session was not recorded\n", .{});
        return;
    }
    const path = alloc.dupeZ(u8, app.rec.path) catch return;
    var build = seek.Build{ .alloc = alloc, .path = path };
    seek.runBuild(&build);
    defer build.deinit();

    app.seek.absorb(&build) catch {
        std.debug.print("doot: --seek: the index could not be built\n", .{});
        return;
    };
    if (app.seek.mode == .unavailable) {
        std.debug.print("doot: --seek: {s}\n", .{app.seek.reason});
        return;
    }
    // The same line the interactive path prints, so `--frame-stats --seek 0`
    // is a way to get the index's real size and build cost out of a headless
    // run. It is how the sprint's memory figure was measured.
    if (opts.frame_stats) {
        if (app.seek.index) |idx| std.debug.print(
            "seek: index {d} entries, {d} spans, {d} KiB, {d} events, worker {d} ms ({d} ms read)\n",
            .{
                idx.entries.items.len,
                idx.spans.items.len,
                idx.bytes / 1024,
                idx.events,
                build.took_ns / std.time.ns_per_ms,
                build.read_ns / std.time.ns_per_ms,
            },
        );
    }

    if (opts.seek_sweep > 0) {
        seekSweep(app, opts.seek_sweep);
        return;
    }

    if (opts.seek_span) |n| {
        // Counting back from the end: 1 is the most recent closed
        // full-screen program, which is what `Cmd ⇧ ↑` lands on.
        var left = @max(n, 1);
        while (left > 0) : (left -= 1) {
            const found = app.seek.prevSpan() catch false;
            if (!found) {
                std.debug.print("doot: --seek-span: only {d} span(s) in this session\n", .{
                    @max(n, 1) - left,
                });
                break;
            }
        }
    } else if (opts.seek) |s| {
        const total_us = app.seek.durationUs();
        const want_us: u64 = if (s < 0)
            total_us -| @as(u64, @intFromFloat(@min(-s, 1e12) * 1e6))
        else
            @min(@as(u64, @intFromFloat(@min(s, 1e12) * 1e6)), total_us);
        app.seek.seekTo(ckpt.eventAtTime(app.seek.events.items, want_us)) catch {
            std.debug.print("doot: --seek: nothing recorded yet\n", .{});
        };
    }
}

/// `--seek-sweep N`: seek to N evenly spaced moments and report what each
/// one cost, end to end.
///
/// The gate's latency criterion is a p95, and a p95 needs a sample. Every
/// seek here goes through the same `State.seekTo` a key press calls -- the
/// same decode, the same bounded forward replay, into the same reused view
/// terminal -- so the distribution is the distribution of the key press.
fn seekSweep(app: *App, n: u32) void {
    const total_us = app.seek.durationUs();
    var samples: [cli.max_seek_sweep]u64 = undefined;
    var replayed: u64 = 0;
    var worst_replayed: usize = 0;
    var taken: usize = 0;

    for (0..n) |i| {
        // Inclusive of both ends, so the first sample is the empty terminal
        // and the last is "seek to now".
        const want_us = if (n <= 1) total_us else total_us * i / (n - 1);
        const ev = ckpt.eventAtTime(app.seek.events.items, want_us);
        app.seek.seekTo(ev) catch continue;
        samples[taken] = app.seek.last_seek_ns;
        taken += 1;
        replayed += app.seek.last_replayed;
        worst_replayed = @max(worst_replayed, app.seek.last_replayed);
    }
    if (taken == 0) {
        std.debug.print("doot: --seek-sweep: nothing to seek in\n", .{});
        return;
    }

    const s = samples[0..taken];
    std.mem.sort(u64, s, {}, std.sort.asc(u64));
    const us = struct {
        fn f(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1e6;
        }
    }.f;
    std.debug.print(
        "seek-sweep: {d} seeks over {d} events, {d:.1} ms median, {d:.1} ms p95, " ++
            "{d:.1} ms worst, {d:.1} ms best; {d} events replayed on average, {d} worst\n",
        .{
            taken,
            app.seek.events.items.len,
            us(s[taken / 2]),
            us(s[(taken * 95) / 100]),
            us(s[taken - 1]),
            us(s[0]),
            replayed / taken,
            worst_replayed,
        },
    );
}

/// The status row's contents, with `--seek-status` applied.
///
/// One place, because the row is composed at three call sites and a pinned
/// clock that reached two of them would produce a capture whose bar and
/// clock disagreed about which frame it was.
fn seekStatus(app: *App, opts: cli.Options) seek.Status {
    var st = app.seek.status();
    if (opts.seek_status) |fixed| {
        st.wall_s = fixed.wall_s;
        st.behind_s = fixed.behind_s;
        st.frac = @as(f64, @floatFromInt(fixed.percent)) / 100.0;
    }
    return st;
}

/// A thread that does nothing but parse, so the claim L0's record makes --
/// that an extra busy thread makes the main thread likelier to be descheduled
/// while it holds the terminal mutex -- can be measured rather than assumed.
///
/// It is deliberately *worse* than the seek worker it stands in for: the
/// worker reads a file and replays a session once, in a few hundred
/// milliseconds; this never stops. A `lock` column that does not move under
/// this will not move under the worker. See `--busy-threads`.
fn busyThread(app: *App) void {
    const alloc = std.heap.page_allocator;
    var term = Terminal.init(alloc, 80, 24) catch return;
    defer term.deinit();
    var parser: vt.Parser = .{};

    // Colour, wrapping and line feeds, so this exercises the parser rather
    // than a memcpy.
    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (n + 64 < buf.len) : (i += 1) {
        const s = std.fmt.bufPrint(
            buf[n..],
            "\x1b[{d}m{d:0>5} the quick brown fox jumps over the lazy dog\r\n",
            .{ 30 + (i % 8), i },
        ) catch break;
        n += s.len;
    }

    while (app.running.load(.acquire)) {
        parser.feed(&term, buf[0..n]);
        term.replies.clearRetainingCapacity();
    }
}

fn readerThread(app: *App) void {
    // Poll with a timeout rather than blocking in read(). A blocking read
    // would keep this thread parked in the kernel after the window closes,
    // and join() would then wait for a child that has nothing left to say.
    app.pty.setNonBlocking();

    var buf: [65536]u8 = undefined;
    while (app.running.load(.acquire)) {
        // The recorder's flush timer, and it costs nothing to have: the
        // wait below already returns every 100 ms when the pty is quiet, so
        // the 250 ms flush needs no timer thread and no clock syscall of
        // its own.
        app.rec_mutex.lock();
        app.rec.maybeFlush(stats.nowNs());
        app.rec_mutex.unlock();

        if (!app.pty.waitReadable(100)) continue;
        const n = app.pty.read(&buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => break,
        };
        if (n == 0) break; // child closed the terminal

        // Recorded before it is parsed, so a crash between the two loses
        // nothing that was already on the wire. Under the recorder mutex
        // only -- never nested with the terminal mutex, which is what keeps
        // the lock column where sprint 1 left it.
        app.rec_mutex.lock();
        app.rec.output(buf[0..n], stats.nowNs());
        app.rec_mutex.unlock();

        app.mutex.lock();
        app.parser.feed(&app.term, buf[0..n]);
        app.mutex.unlock();

        _ = app.bytes_read.fetchAdd(n, .monotonic);
        app.requestWake();
    }
    app.running.store(false, .release);
    app.requestWake();
}

pub fn main(init: std.process.Init.Minimal) !void {
    // DebugAllocator catches leaks and use-after-free in debug builds; the
    // release build gets the fast SMP allocator instead.
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const alloc = if (@import("builtin").mode == .Debug)
        debug_alloc.allocator()
    else
        std.heap.smp_allocator;

    const opts = switch (cli.parseArgs(init.args.vector)) {
        .run => |o| o,
        .help => {
            stdout(cli.help, .{
                cli.min_font_size,       cli.max_font_size, cli.default_font_size,
                cli.default_cols,        cli.default_rows,  cli.max_dim,
                cli.default_retain_days,
            });
            std.process.exit(0);
        },
        .version => {
            stdout("{s}\n", .{version.line});
            std.process.exit(0);
        },
    };

    var renderer = try render.Renderer.init(
        alloc,
        "doot",
        opts.font_size,
        opts.cols,
        opts.rows,
        opts.scale,
    );
    defer renderer.deinit();
    if (opts.screenshot) |path| {
        // A second in, so the shell has had time to draw something.
        renderer.screenshot_path = path;
        renderer.screenshot_after_ns = stats.nowNs() + 1_000_000_000;
    }

    const size = renderer.gridSize();

    var app = App{
        .mutex = .init(),
        .rec_mutex = .init(),
        // Replaced below when this session is being recorded. A disabled
        // recorder owns nothing and every method on it is a no-op, so
        // `--no-record` and `--incognito` need no branch at any call site.
        .rec = rec.Writer.disabled(alloc),
        .seek = .{ .alloc = alloc },
        .term = try Terminal.init(alloc, size.cols, size.rows),
        .pty = try Pty.open(@intCast(size.cols), @intCast(size.rows), opts.shell),
    };
    defer app.mutex.deinit();
    defer app.rec_mutex.deinit();
    defer app.rec.deinit();
    defer app.seek.deinit();
    defer app.term.deinit();
    defer app.pty.deinit();
    // A seek worker still in flight at exit is joined before anything it
    // points at is freed. It takes no lock, so it cannot be waiting on us.
    defer if (app.seek_thread) |t| {
        t.join();
        if (app.seek_build) |b| {
            b.deinit();
            alloc.destroy(b);
        }
    };

    // `--no-record` and `--incognito`: there is no log, so the seek keys have
    // nothing to open. The *mode* is not set here -- the status row must not
    // appear until somebody asks to seek -- only what it will say when they
    // do. `seekPath` returns null without touching a descriptor when the
    // recorder is disabled, which is what makes "the seek path opens no file"
    // a testable claim rather than a hopeful one.
    if (!opts.record) {
        app.seek.reason = if (opts.incognito)
            "this window is incognito -- nothing is recorded"
        else
            "this session is not being recorded";
    }

    // Recording is on by default, and visible: the window title says so for
    // as long as it is happening. See docs/roadmap/record.md.
    var record_dir_buf: [std.c.PATH_MAX]u8 = undefined;
    if (opts.record) {
        const dir = if (opts.record_dir) |d|
            @as([]const u8, d)
        else
            rec.defaultDir(&record_dir_buf) orelse "";
        if (dir.len == 0) {
            std.debug.print("doot: no place to keep recordings; not recording\n", .{});
        } else {
            // Swept before the new file exists, so this session's own
            // recording is never a candidate. By mtime, which is what makes
            // it safe to run while another instance has a session open --
            // that instance's flushes keep its file inside the window.
            _ = rec.sweep(dir, opts.record_retain_days, @divFloor(rec.wallNs(), std.time.ns_per_s));
            // Clamped to `cli.max_dim`, which is the bound the reader
            // enforces: a `.trec` claiming a bigger grid is four bytes of
            // allocation request nothing checked, so neither end will carry
            // one. `--size` already refuses more, and a window is measured in
            // cells, so this is not a geometry the renderer can reach.
            app.rec = rec.Writer.open(alloc, dir, .{
                .cols = @intCast(@min(size.cols, cli.max_dim)),
                .rows = @intCast(@min(size.rows, cli.max_dim)),
                .record_input = opts.record_input,
            }) catch |err| blk: {
                // A session that cannot be recorded is still a session.
                std.debug.print("doot: not recording this session: {t}\n", .{err});
                break :blk rec.Writer.disabled(alloc);
            };
        }
    }

    app.wake_event = c.SDL_RegisterEvents(1);
    _ = c.SDL_StartTextInput(renderer.window);

    // The L1 lock experiment. Zero unless asked for, so the ordinary run is
    // one branch at startup and nothing else.
    var busy: [cli.max_busy_threads]std.Thread = undefined;
    var busy_n: usize = 0;
    while (busy_n < opts.busy_threads) : (busy_n += 1) {
        busy[busy_n] = std.Thread.spawn(.{}, busyThread, .{&app}) catch break;
    }
    defer for (busy[0..busy_n]) |t| t.join();

    const reader = try std.Thread.spawn(.{}, readerThread, .{&app});
    var reader_joined = false;
    defer if (!reader_joined) {
        // Order matters: tell the reader to stop and hang up the child
        // before joining, or we wait on a thread that isn't coming back.
        // Skipped when the normal exit path below already joined it.
        app.running.store(false, .release);
        app.pty.shutdown();
        reader.join();
    };

    // The composed title -- the child's, plus the recording indicator --
    // and the last one actually handed to the window. Compared as bytes
    // rather than by length: the indicator can change while the child's
    // title does not, and a child can change its title without changing its
    // length, which the old length-only check missed.
    var title_buf: [512:0]u8 = undefined;
    var last_title: [512]u8 = undefined;
    var last_title_len: usize = std.math.maxInt(usize);
    var font_size = opts.font_size;

    // Why the loop ended. Draining the pty only makes sense when the child
    // is already gone; quitting the window while something is still writing
    // must hang up on it, not wait for it to finish.
    var child_exited = false;

    var frame_stats = stats.FrameStats.init(opts.frame_stats);
    // Runs before the recorder is freed: this defer is registered after the
    // one that frees it, and defers run in reverse.
    defer frame_stats.reportTotals(app.bytes_read.load(.monotonic), recordTotals(&app));

    var mouse: Mouse = .{};

    while (app.running.load(.acquire)) {
        var ev: c.SDL_Event = undefined;
        // Block until something happens. The reader thread's wake event and
        // the OS's input events both land here, so we never spin.
        //
        // The one exception is a drag that has left the grid: autoscroll has
        // no event source of its own, so it needs a clock. The timeout is
        // taken *only* while `mouse.autoscroll` is non-zero, which is only
        // while a button is held outside the grid -- an idle terminal, and a
        // drag inside the grid, still wake exactly as often as before.
        var have_event = true;
        if (mouse.autoscroll != 0) {
            have_event = c.SDL_WaitEventTimeout(&ev, 16);
        } else if (!c.SDL_WaitEvent(&ev)) break;

        var redraw = false;
        var resized = false;
        while (have_event) {
            if (ev.type == app.wake_event) {
                app.wake_queued.store(false, .release);
                redraw = true;
            } else switch (ev.type) {
                c.SDL_EVENT_QUIT => app.running.store(false, .release),
                c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
                c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED,
                => resized = true,
                c.SDL_EVENT_WINDOW_FOCUS_GAINED => {
                    renderer.focused = true;
                    recordFocus(&app, true);
                    redraw = true;
                },
                c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                    renderer.focused = false;
                    recordFocus(&app, false);
                    redraw = true;
                },
                c.SDL_EVENT_WINDOW_EXPOSED => redraw = true,
                c.SDL_EVENT_TEXT_INPUT => {
                    const text = std.mem.span(ev.text.text);
                    sendToPty(&app, text);
                    redraw = true;
                },
                c.SDL_EVENT_KEY_DOWN => {
                    if (try handleKey(&app, &renderer, &font_size, alloc, ev.key, opts.frame_stats)) {
                        resized = true;
                    }
                    redraw = true;
                },
                c.SDL_EVENT_MOUSE_WHEEL => {
                    handleWheel(&app, ev.wheel);
                    redraw = true;
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    handleMouseDown(&app, &renderer, &mouse, ev.button);
                    redraw = true;
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    if (handleMouseMotion(&app, &renderer, &mouse, ev.motion)) redraw = true;
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    handleMouseUp(&app, &mouse, opts, alloc, ev.button);
                    redraw = true;
                },
                else => {},
            }
            if (!c.SDL_PollEvent(&ev)) break;
        }

        // An autoscroll tick: move the view one step and re-derive the head
        // from where the pointer is, because the row under it is a different
        // line now.
        if (mouse.autoscroll != 0 and mouse.dragging) {
            autoscrollStep(&app, &renderer, &mouse);
            redraw = true;
        }

        if (resized) {
            renderer.updateSize();
            const g = renderer.gridSize();
            app.mutex.lock();
            if (app.term.resize(g.cols, g.rows)) |_| {
                // Inside the terminal mutex, which is the one nesting rule
                // documented on `rec_mutex`: that mutex is what orders this
                // resize against a concurrent `parser.feed`, so it is what
                // decides where the record belongs in the file. Recorded
                // only when the resize took, so a failed allocation does not
                // leave the recording claiming a geometry the screen never
                // had.
                app.rec_mutex.lock();
                app.rec.resize(
                    @intCast(@min(g.cols, cli.max_dim)),
                    @intCast(@min(g.rows, cli.max_dim)),
                    stats.nowNs(),
                );
                app.rec_mutex.unlock();
            } else |_| {}
            app.mutex.unlock();
            app.pty.resize(@intCast(g.cols), @intCast(g.rows));
            redraw = true;
        }

        // The seek worker wakes the main thread when it finishes, so this
        // costs one branch per iteration and never blocks.
        if (pollSeekBuild(&app, alloc, opts.frame_stats)) redraw = true;

        // Read before the terminal mutex is taken, never inside it: the
        // lock order is terminal then recorder, so a read of the recorder's
        // state has to happen outside or not at all.
        const record_state = recordState(&app, opts);

        // The window is showing history (or is about to). The live terminal
        // is still being fed by the reader thread the whole time.
        const showing_view = app.seek.mode == .seeking and app.seek.view != null;
        const status = app.seek.mode != .live;
        var marker_buf: [32]u8 = undefined;
        const seek_marker: ?[]const u8 = if (app.seek.mode == .seeking)
            seek.titleMarker(&marker_buf, app.seek.behindSeconds())
        else
            null;

        // Anything the terminal wants to tell the child (cursor reports,
        // device attributes) goes back down the PTY here. **Also while
        // seeking**: those are the emulator answering the child, the child is
        // still running, and a program waiting on a CPR that never arrives
        // hangs for as long as the window is looking at history.
        app.mutex.lock();
        const t_lock = stats.nowNs();
        if (app.term.replies.items.len > 0) {
            app.pty.writeAll(app.term.replies.items) catch {};
            app.term.replies.clearRetainingCapacity();
        }
        // Consumed every frame, seeking or not, and *remembered*. Left set,
        // it would pile up; consumed and forgotten, the live screen would
        // come back blank on the way out of seek mode and stay that way until
        // the child next printed something.
        if (app.term.dirty) {
            app.term.dirty = false;
            app.live_dirty = true;
        }

        // The composition is a pure function in cli.zig, tested without a
        // window. It happens here because it reads `term.title`, which the
        // reader thread writes; the `setTitle` call that follows from it is
        // a platform call and happens *after* the mutex is dropped. Sprint 1
        // took the vblank wait out of this lock and it is not getting a
        // window-server round trip back.
        const composed = cli.windowTitle(
            title_buf[0 .. title_buf.len - 1],
            app.term.title.items,
            record_state,
            seek_marker,
        );
        var title_changed = false;
        if (composed.len != last_title_len or
            !std.mem.eql(u8, composed, last_title[0..composed.len]))
        {
            @memcpy(last_title[0..composed.len], composed);
            last_title_len = composed.len;
            title_buf[composed.len] = 0;
            title_changed = true;
        }

        // Copy the frame out under the lock; draw and present it after. The
        // present waits for vblank, and with it inside the lock the reader
        // could not feed a byte for the whole of every frame.
        // `--select`, re-applied every frame so it survives the shell's
        // output arriving underneath it. Under the lock, immediately before
        // the snapshot that photographs it.
        var draw_frame = false;
        if (!showing_view) {
            if (opts.select) |spec| applySelect(&app.term, spec, opts.select_rect);
            if (app.live_dirty or redraw) {
                app.live_dirty = false;
                draw_frame = true;
                renderer.snapshot(&app.term) catch {
                    draw_frame = false;
                    // Dropping this would lose the content until some later
                    // event happened to set it again -- on an idle terminal,
                    // the child's last line would stay invisible until the
                    // user typed.
                    app.live_dirty = true;
                };
            }
        }
        app.mutex.unlock();
        const lock_ns = stats.nowNs() - t_lock;

        // The view terminal is the main thread's outright, so it is
        // photographed **outside** the lock. Sprint 1's rule is that the
        // critical section holds one memcpy of the live grid and nothing
        // else; a seek must not add a second one to it.
        if (showing_view) {
            renderer.snapshot(&app.seek.view.?) catch {
                draw_frame = false;
            };
            draw_frame = true;
        }
        if (status and draw_frame) {
            var text_buf: [512]u8 = undefined;
            renderer.setStatus(seek.statusText(&text_buf, seekStatus(&app, opts)));
        }

        if (title_changed) renderer.setTitle(title_buf[0..last_title_len :0]);

        if (draw_frame) {
            var times = renderer.draw();
            times.lock = lock_ns;
            frame_stats.record(times);
        }
        frame_stats.maybeReport(app.bytes_read.load(.monotonic));

        if (app.pty.exited()) {
            child_exited = true;
            app.running.store(false, .release);
        }
    }

    // The loop can end because `pty.exited()` noticed the child was gone
    // while bytes it had already written were still in the pty buffer, so
    // stop the reader and drain the rest here rather than losing the tail
    // of a program's last output. Joining first means nothing else is
    // reading the pty, so this needs no lock.
    app.running.store(false, .release);
    reader.join();
    reader_joined = true;

    // Both guards matter. Without `child_exited`, closing the window while
    // a command is producing output waits for the pty to go quiet, which a
    // busy child never allows -- the app would hang until killed. The
    // deadline covers the rest: the child is gone but something it left
    // behind still holds the pty open and is writing.
    if (child_exited) {
        const deadline = stats.nowNs() + 250 * std.time.ns_per_ms;
        var tail: [65536]u8 = undefined;
        while (stats.nowNs() < deadline and app.pty.waitReadable(20)) {
            const n = app.pty.read(&tail) catch break;
            if (n == 0) break;
            // Recorded, not just parsed. A replay that stopped at the join
            // would be missing a program's last output and would diverge
            // from the screen the user was looking at -- which is exactly
            // the thing the checksum test is for.
            app.rec.output(tail[0..n], stats.nowNs());
            app.parser.feed(&app.term, tail[0..n]);
        }
    }

    // Closed here rather than left to `deinit`, so the last flush lands
    // before `--frame-stats` reports what was written.
    app.rec.close(.clean);

    // A `--shell` that prints and exits never reaches the one-second
    // timer, so the last frame is captured on the way out instead. The
    // gallery depends on this: its scenes are a few lines of printf and
    // are gone in milliseconds.
    // `--seek` / `--seek-span`: photograph a moment in this session's own
    // recording rather than its last frame.
    //
    // Synchronous, and only here: the child is gone, the reader is joined and
    // the recorder is closed, so nothing is racing and the worker thread
    // would buy nothing. It exists so the gallery can carry a seeked frame --
    // the arbiter for anything visible is a picture, and a feature no picture
    // can show is a feature nothing is watching.
    if (opts.seek != null or opts.seek_span != null) {
        captureSeek(&app, alloc, opts);
    }

    if (renderer.screenshot_path != null) {
        renderer.screenshot_after_ns = 0;
        if (app.seek.mode != .live and app.seek.view != null) {
            renderer.snapshot(&app.seek.view.?) catch {};
            var text_buf: [512]u8 = undefined;
            renderer.setStatus(seek.statusText(&text_buf, seekStatus(&app, opts)));
        } else {
            if (opts.select) |spec| applySelect(&app.term, spec, opts.select_rect);
            renderer.snapshot(&app.term) catch {};
            if (app.seek.mode != .live) {
                var text_buf: [512]u8 = undefined;
                renderer.setStatus(seek.statusText(&text_buf, seekStatus(&app, opts)));
            }
        }
        _ = renderer.draw();
    }

    app.pty.shutdown();
}

/// `--help` and `--version` are the program's output, not a diagnostic:
/// `std.debug.print` goes to stderr, which would hand `v=$(doot
/// --version)` an empty string and write a zero-byte file for
/// `doot --version > v.txt`. Answers to questions go to stdout.
fn stdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var written: usize = 0;
    while (written < text.len) {
        const rc = std.c.write(1, text.ptr + written, text.len - written);
        if (rc <= 0) return;
        written += @intCast(rc);
    }
}

/// Every byte the terminal sends the child **on the user's behalf** goes
/// through here, which is why the input record is taken here: one call site,
/// so `Writer.input`'s own `record_input` check is the only gate and no
/// future caller can miss it.
///
/// Not every byte that goes down the pty. The event loop writes
/// `term.replies` -- cursor position reports, device attributes -- straight
/// at the pty, because those are the emulator answering the child, not the
/// user typing, and recording them as `input` would put bytes the user never
/// pressed in a file whose whole promise is that keystrokes are opt-in. They
/// are also already derivable: every one of them is a reply to an `output`
/// record that is in the file.
fn sendToPty(app: *App, bytes: []const u8) void {
    if (bytes.len == 0) return;
    // A printable key exits seek mode and is then delivered, mirroring the
    // view snap-back below: you scroll back to read, then type, and you are
    // back. Keystrokes must never reach the child *while* the window is
    // showing history -- a `q` meant for a status row would be a `q` typed
    // into whatever is running now.
    exitSeek(app);

    app.rec_mutex.lock();
    app.rec.input(bytes, stats.nowNs());
    app.rec_mutex.unlock();

    app.mutex.lock();
    // Typing snaps the view back to the live screen, like every other
    // terminal: you scroll up to read, then hit a key and you're back.
    app.term.scrollView(-@as(isize, @intCast(app.term.view_offset)));
    app.mutex.unlock();
    app.pty.writeAll(bytes) catch {};
}

/// Returns true if the window needs re-measuring (font size changed).
fn handleKey(
    app: *App,
    renderer: *render.Renderer,
    font_size: *u32,
    alloc: std.mem.Allocator,
    key: c.SDL_KeyboardEvent,
    report: bool,
) !bool {
    const mods = key.mod;
    const cmd = mods & c.SDL_KMOD_GUI != 0;
    const ctrl = mods & c.SDL_KMOD_CTRL != 0;
    const alt = mods & c.SDL_KMOD_ALT != 0;
    const shift = mods & c.SDL_KMOD_SHIFT != 0;

    // Command-key shortcuts belong to the app, not the shell.
    if (cmd) {
        switch (key.key) {
            c.SDLK_C => {
                // With no selection this does nothing at all -- deliberately
                // not "copy the screen" or "send SIGINT", both of which have
                // been someone's idea of what an empty Cmd C should do.
                copySelection(app, alloc);
            },
            c.SDLK_V => {
                if (c.SDL_GetClipboardText()) |text| {
                    defer c.SDL_free(text);
                    const slice = std.mem.span(text);
                    app.mutex.lock();
                    const bracketed = app.term.modes.bracketed_paste;
                    app.mutex.unlock();
                    if (bracketed) {
                        const wrapped = try input.bracketPaste(alloc, slice);
                        defer alloc.free(wrapped);
                        sendToPty(app, wrapped);
                    } else {
                        sendToPty(app, slice);
                    }
                }
            },
            c.SDLK_EQUALS, c.SDLK_PLUS => {
                font_size.* = @min(font_size.* + 1, 72);
                try renderer.setFontSize(font_size.*);
                return true;
            },
            c.SDLK_MINUS => {
                font_size.* = @max(font_size.* -| 1, 6);
                try renderer.setFontSize(font_size.*);
                return true;
            },
            c.SDLK_0 => {
                font_size.* = default_font_size;
                try renderer.setFontSize(font_size.*);
                return true;
            },
            c.SDLK_K => {
                app.mutex.lock();
                app.term.fullReset();
                // A reset with no bytes behind it. Without a record, every
                // session in which this was pressed replays to a different
                // screen than it showed. Nested inside the terminal mutex
                // for the same reason `resize` is.
                app.rec_mutex.lock();
                app.rec.control(.full_reset, stats.nowNs());
                app.rec_mutex.unlock();
                app.mutex.unlock();
                sendToPty(app, "\x0c"); // Ctrl-L, so the shell redraws its prompt
            },
            // Cmd Shift R: start or stop recording keystrokes, now. The
            // title moves with it in the same frame, which is what makes
            // the indicator mean something rather than decorate something.
            //
            // Both spellings, because SDL3 reports the shifted keycode on
            // some layouts and the unshifted one on others, and a shortcut
            // that works on one keyboard is a bug on the other.
            c.SDLK_R, 'R' => {
                if (shift) toggleInputRecording(app);
            },
            // L1: the window looks into the session's own recording.
            //
            // `Cmd ⇧ ↑` is the sprint's whole claim in one key -- the last
            // frame of the most recently closed full-screen program, which
            // every other terminal throws away the instant it exits.
            c.SDLK_UP => if (shift) seekAction(app, alloc, .prev_span, report),
            c.SDLK_DOWN => if (shift) seekAction(app, alloc, .next_span, report),
            c.SDLK_LEFT => if (shift) seekAction(app, alloc, .{
                .step = -(if (alt) seek.big_step_s else seek.step_s),
            }, report),
            c.SDLK_RIGHT => if (shift) seekAction(app, alloc, .{
                .step = if (alt) seek.big_step_s else seek.step_s,
            }, report),
            else => {},
        }
        return false;
    }

    // Esc leaves seek mode rather than reaching the child. It is the only
    // key that means "back to live" and nothing else, and while the window
    // is showing history the child has no business hearing it.
    if (key.key == c.SDLK_ESCAPE and app.seek.mode != .live) {
        exitSeek(app);
        return false;
    }

    const m = input.Mods{ .ctrl = ctrl, .alt = alt, .shift = shift };
    const mapped = mapKey(key.key) orelse return false;

    // Printable characters without Ctrl/Alt arrive as TEXT_INPUT instead,
    // which handles dead keys and IME correctly. Don't double-send them.
    if (mapped == .char and !ctrl and !alt) return false;

    app.mutex.lock();
    const app_cursor = app.term.modes.app_cursor;
    app.mutex.unlock();

    var buf: [32]u8 = undefined;
    if (input.encode(&buf, mapped, m, app_cursor)) |bytes| sendToPty(app, bytes);
    return false;
}

// ---------------------------------------------------------------------------
// The mouse
// ---------------------------------------------------------------------------
//
// Glue only. Everything below hands numbers to `sel.zig` and puts the answer
// back: the pixel arithmetic, the word boundaries, the wide-character
// snapping and the extraction rules are all there, where they are unit-tested
// without a window. If a function here grows a decision, it is in the wrong
// file.

/// The grid geometry `sel` needs. Call with the terminal mutex held.
fn metricsOf(app: *App, renderer: *const render.Renderer) sel.Metrics {
    return renderer.cellMetrics(app.term.cols, app.term.rows);
}

fn handleMouseDown(
    app: *App,
    renderer: *render.Renderer,
    mouse: *Mouse,
    ev: c.SDL_MouseButtonEvent,
) void {
    if (ev.button != c.SDL_BUTTON_LEFT) return;
    // `SDL_MouseButtonEvent` carries no modifier field, so the keyboard has
    // to be asked directly.
    const mods = c.SDL_GetModState();
    const shift = mods & c.SDL_KMOD_SHIFT != 0;
    const option = mods & c.SDL_KMOD_ALT != 0;
    const px = renderer.toPixels(ev.x, ev.y);
    mouse.px = .{ .x = px.x, .y = px.y };

    app.mutex.lock();
    defer app.mutex.unlock();

    // The application owns the mouse. E2 fills this branch in; until it does,
    // the only thing that matters is that we do **not** start a selection --
    // otherwise the day a drag inside vim starts being forwarded, it will
    // both scroll vim and paint a highlight over it.
    if (sel.mouseOwner(&app.term, shift) == .child) return;

    const coord = sel.cellAt(metricsOf(app, renderer), px.x, px.y);
    const point = sel.pointAt(&app.term, coord) orelse return;

    // Shift-click extends the existing selection from its anchor rather than
    // starting a new one.
    if (shift) {
        if (app.term.selection) |existing| {
            var next = existing;
            next.head = point;
            app.term.setSelection(next);
            mouse.* = .{
                .dragging = true,
                .moved = true,
                .anchor = next.anchor,
                .mode = next.mode,
                .rect = next.rect,
                .px = mouse.px,
            };
            return;
        }
    }

    const mode = sel.modeForClicks(ev.clicks);
    mouse.* = .{
        .dragging = true,
        // A double or triple click selects on the press: there is no drag to
        // wait for, and waiting would make the word flash and vanish.
        .moved = mode != .character,
        .anchor = point,
        .mode = mode,
        .rect = option,
        .px = mouse.px,
    };
    if (mode == .character) {
        // A press replaces whatever was selected. Whether it produces a new
        // selection is decided by whether the pointer moves before the
        // release -- a click with no drag selects nothing.
        app.term.clearSelection();
    } else {
        app.term.setSelection(.{
            .anchor = point,
            .head = point,
            .mode = mode,
            .rect = option,
        });
    }
}

/// Returns whether the frame needs redrawing. Motion with no button down is
/// the most frequent event a window gets, so it must cost nothing.
fn handleMouseMotion(
    app: *App,
    renderer: *render.Renderer,
    mouse: *Mouse,
    ev: c.SDL_MouseMotionEvent,
) bool {
    if (!mouse.dragging) return false;
    const anchor = mouse.anchor orelse return false;
    const px = renderer.toPixels(ev.x, ev.y);
    mouse.px = .{ .x = px.x, .y = px.y };

    app.mutex.lock();
    defer app.mutex.unlock();
    const m = metricsOf(app, renderer);
    mouse.autoscroll = sel.autoscroll(m, px.y);
    const head = sel.pointAt(&app.term, sel.cellAt(m, px.x, px.y)) orelse return false;
    mouse.moved = true;
    app.term.setSelection(.{
        .anchor = anchor,
        .head = head,
        .mode = mouse.mode,
        .rect = mouse.rect,
    });
    return true;
}

fn handleMouseUp(
    app: *App,
    mouse: *Mouse,
    opts: cli.Options,
    alloc: std.mem.Allocator,
    ev: c.SDL_MouseButtonEvent,
) void {
    if (ev.button != c.SDL_BUTTON_LEFT) return;
    const was_dragging = mouse.dragging;
    const moved = mouse.moved;
    mouse.* = .{};
    // Copy-on-select does **not** clear the selection: it is a convenience
    // for pasting elsewhere, not a different way of ending a drag.
    if (was_dragging and moved and opts.copy_on_select) copySelection(app, alloc);
}

/// One autoscroll tick: move the view, then re-derive the head, because the
/// line under a stationary pointer changed when the view did.
fn autoscrollStep(app: *App, renderer: *render.Renderer, mouse: *Mouse) void {
    const anchor = mouse.anchor orelse return;
    app.mutex.lock();
    defer app.mutex.unlock();
    app.term.scrollView(mouse.autoscroll);
    const m = metricsOf(app, renderer);
    const head = sel.pointAt(&app.term, sel.cellAt(m, mouse.px.x, mouse.px.y)) orelse return;
    app.term.setSelection(.{
        .anchor = anchor,
        .head = head,
        .mode = mouse.mode,
        .rect = mouse.rect,
    });
}

/// The selection onto the system pasteboard. Does nothing when there is no
/// selection, or when what it covers is empty.
fn copySelection(app: *App, alloc: std.mem.Allocator) void {
    app.mutex.lock();
    const text: ?[:0]u8 = if (app.term.selection) |s|
        sel.extract(alloc, &app.term, s) catch null
    else
        null;
    app.mutex.unlock();

    const t = text orelse return;
    defer alloc.free(t);
    if (t.len == 0) return;
    _ = c.SDL_SetClipboardText(t.ptr);
}

/// `--select R,C,R,C`. Call with the terminal mutex held.
///
/// Re-applied every frame rather than once, so it still describes the same
/// cells after the scene's own output has arrived. `setSelection` normalizes
/// and only marks the terminal dirty when the result actually moved, so this
/// does not turn into a repaint loop.
fn applySelect(term: *Terminal, spec: cli.Select, rect: bool) void {
    if (term.rows == 0 or term.cols == 0) return;
    const at = struct {
        fn f(t: *Terminal, r: u32, col: u32) ?sel.Point {
            return sel.pointAt(t, .{
                .x = @min(@as(usize, col), t.cols - 1),
                .y = @min(@as(usize, r), t.rows - 1),
            });
        }
    }.f;
    const a = at(term, spec.r0, spec.c0) orelse return;
    const h = at(term, spec.r1, spec.c1) orelse return;
    term.setSelection(.{ .anchor = a, .head = h, .rect = rect });
}

fn handleWheel(app: *App, wheel: c.SDL_MouseWheelEvent) void {
    const lines: isize = @intFromFloat(@trunc(wheel.y * 3));
    if (lines == 0) return;
    // Inert while the window is showing history. Scrolling the *live*
    // terminal's viewport under a historical frame would move something the
    // user cannot see, and translating the wheel into arrow keys for the
    // child would be sending it input from a screen it is not showing.
    // Scrolling the seeked view's own history is E7's job, not this sprint's.
    if (app.seek.mode != .live) return;

    app.mutex.lock();
    const on_alt = app.term.on_alt;
    const app_cursor = app.term.modes.app_cursor;
    if (!on_alt) app.term.scrollView(lines);
    app.mutex.unlock();
    if (!on_alt) return;

    // Full-screen apps have no scrollback of ours to show, so translate the
    // wheel into arrow keys the way xterm does. That makes less, man and vim
    // scroll as expected.
    //
    // Through `sendToPty` rather than straight at the pty: that was the
    // second place in this file that wrote to the child, and a second place
    // is a place the input record would have been missing from. It also
    // picks up the view snap-back every other keystroke gets -- inert here,
    // because `scrollView` is a no-op on the alt screen, but the shape is
    // now the same one everywhere.
    const key: input.Key = if (lines > 0) .up else .down;
    const count: usize = @abs(lines);
    var buf: [32]u8 = undefined;
    const bytes = input.encode(&buf, key, .{}, app_cursor) orelse return;
    for (0..count) |_| sendToPty(app, bytes);
}

/// What the title should say about this session right now.
fn recordState(app: *App, opts: cli.Options) cli.RecordState {
    if (opts.incognito) return .incognito;
    app.rec_mutex.lock();
    defer app.rec_mutex.unlock();
    if (!app.rec.recording) return .off;
    return if (app.rec.record_input) .output_and_input else .output;
}

fn recordFocus(app: *App, focused: bool) void {
    app.rec_mutex.lock();
    defer app.rec_mutex.unlock();
    app.rec.focus(focused, stats.nowNs());
}

/// `Cmd ⇧ R`. Does nothing when the session is not being recorded at all:
/// an incognito window cannot be talked into recording keystrokes by a
/// keystroke.
fn toggleInputRecording(app: *App) void {
    app.rec_mutex.lock();
    defer app.rec_mutex.unlock();
    if (!app.rec.recording) return;
    app.rec.record_input = !app.rec.record_input;
}

fn recordTotals(app: *App) ?stats.RecordTotals {
    app.rec_mutex.lock();
    defer app.rec_mutex.unlock();
    if (app.rec.stats.records == 0 and app.rec.stats.bytes == 0) return null;
    return .{
        .bytes = app.rec.stats.bytes,
        .records = app.rec.stats.records,
        .redactions = app.rec.stats.redactions,
        .flushes = app.rec.stats.flushes,
        .worst_flush_ns = app.rec.stats.worst_flush_ns,
    };
}

/// SDL keycode -> our platform-independent key.
fn mapKey(k: c.SDL_Keycode) ?input.Key {
    return switch (k) {
        c.SDLK_UP => .up,
        c.SDLK_DOWN => .down,
        c.SDLK_LEFT => .left,
        c.SDLK_RIGHT => .right,
        c.SDLK_HOME => .home,
        c.SDLK_END => .end,
        c.SDLK_PAGEUP => .page_up,
        c.SDLK_PAGEDOWN => .page_down,
        c.SDLK_INSERT => .insert,
        c.SDLK_DELETE => .delete,
        c.SDLK_BACKSPACE => .backspace,
        c.SDLK_TAB => .tab,
        c.SDLK_RETURN, c.SDLK_KP_ENTER => .enter,
        c.SDLK_ESCAPE => .escape,
        c.SDLK_F1 => .{ .f = 1 },
        c.SDLK_F2 => .{ .f = 2 },
        c.SDLK_F3 => .{ .f = 3 },
        c.SDLK_F4 => .{ .f = 4 },
        c.SDLK_F5 => .{ .f = 5 },
        c.SDLK_F6 => .{ .f = 6 },
        c.SDLK_F7 => .{ .f = 7 },
        c.SDLK_F8 => .{ .f = 8 },
        c.SDLK_F9 => .{ .f = 9 },
        c.SDLK_F10 => .{ .f = 10 },
        c.SDLK_F11 => .{ .f = 11 },
        c.SDLK_F12 => .{ .f = 12 },
        else => if (k > 0 and k < 0x110000)
            .{ .char = @intCast(k) }
        else
            null,
    };
}
