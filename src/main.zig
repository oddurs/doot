//! terminator -- a terminal emulator.
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
    rec_mutex: Mutex,
    rec: rec.Writer,

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
        "terminator",
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
        .term = try Terminal.init(alloc, size.cols, size.rows),
        .pty = try Pty.open(@intCast(size.cols), @intCast(size.rows), opts.shell),
    };
    defer app.mutex.deinit();
    defer app.rec_mutex.deinit();
    defer app.rec.deinit();
    defer app.term.deinit();
    defer app.pty.deinit();

    // Recording is on by default, and visible: the window title says so for
    // as long as it is happening. See docs/roadmap/record.md.
    var record_dir_buf: [std.c.PATH_MAX]u8 = undefined;
    if (opts.record) {
        const dir = if (opts.record_dir) |d|
            @as([]const u8, d)
        else
            rec.defaultDir(&record_dir_buf) orelse "";
        if (dir.len == 0) {
            std.debug.print("terminator: no place to keep recordings; not recording\n", .{});
        } else {
            // Swept before the new file exists, so this session's own
            // recording is never a candidate. By mtime, which is what makes
            // it safe to run while another instance has a session open --
            // that instance's flushes keep its file inside the window.
            _ = rec.sweep(dir, opts.record_retain_days, @divFloor(rec.wallNs(), std.time.ns_per_s));
            app.rec = rec.Writer.open(alloc, dir, .{
                .cols = @intCast(@min(size.cols, std.math.maxInt(u16))),
                .rows = @intCast(@min(size.rows, std.math.maxInt(u16))),
                .record_input = opts.record_input,
            }) catch |err| blk: {
                // A session that cannot be recorded is still a session.
                std.debug.print("terminator: not recording this session: {t}\n", .{err});
                break :blk rec.Writer.disabled(alloc);
            };
        }
    }

    app.wake_event = c.SDL_RegisterEvents(1);
    _ = c.SDL_StartTextInput(renderer.window);

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

    while (app.running.load(.acquire)) {
        var ev: c.SDL_Event = undefined;
        // Block until something happens. The reader thread's wake event and
        // the OS's input events both land here, so we never spin.
        if (!c.SDL_WaitEvent(&ev)) break;

        var redraw = false;
        var resized = false;
        while (true) {
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
                    if (try handleKey(&app, &renderer, &font_size, alloc, ev.key)) {
                        resized = true;
                    }
                    redraw = true;
                },
                c.SDL_EVENT_MOUSE_WHEEL => {
                    handleWheel(&app, ev.wheel);
                    redraw = true;
                },
                else => {},
            }
            if (!c.SDL_PollEvent(&ev)) break;
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
                    @intCast(@min(g.cols, std.math.maxInt(u16))),
                    @intCast(@min(g.rows, std.math.maxInt(u16))),
                    stats.nowNs(),
                );
                app.rec_mutex.unlock();
            } else |_| {}
            app.mutex.unlock();
            app.pty.resize(@intCast(g.cols), @intCast(g.rows));
            redraw = true;
        }

        // Read before the terminal mutex is taken, never inside it: the
        // lock order is terminal then recorder, so a read of the recorder's
        // state has to happen outside or not at all.
        const record_state = recordState(&app, opts);

        // Anything the terminal wants to tell the child (cursor reports,
        // device attributes) goes back down the PTY here.
        app.mutex.lock();
        const t_lock = stats.nowNs();
        if (app.term.replies.items.len > 0) {
            app.pty.writeAll(app.term.replies.items) catch {};
            app.term.replies.clearRetainingCapacity();
        }
        const dirty = app.term.dirty or redraw;
        app.term.dirty = false;

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
        var draw_frame = false;
        if (dirty) {
            draw_frame = true;
            renderer.snapshot(&app.term) catch {
                draw_frame = false;
                // `dirty` was consumed above. Dropping it here would lose
                // this content until some later event happened to set it
                // again -- on an idle terminal, the child's last line would
                // stay invisible until the user typed. Still under the lock.
                app.term.dirty = true;
            };
        }
        app.mutex.unlock();
        const lock_ns = stats.nowNs() - t_lock;

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
    if (renderer.screenshot_path != null) {
        renderer.screenshot_after_ns = 0;
        renderer.snapshot(&app.term) catch {};
        _ = renderer.draw();
    }

    app.pty.shutdown();
}

/// `--help` and `--version` are the program's output, not a diagnostic:
/// `std.debug.print` goes to stderr, which would hand `v=$(terminator
/// --version)` an empty string and write a zero-byte file for
/// `terminator --version > v.txt`. Answers to questions go to stdout.
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

/// Every byte the terminal sends the child goes through here, which is why
/// the input record is taken here: one call site, so `Writer.input`'s own
/// `record_input` check is the only gate and no future caller can miss it.
fn sendToPty(app: *App, bytes: []const u8) void {
    if (bytes.len == 0) return;
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
) !bool {
    const mods = key.mod;
    const cmd = mods & c.SDL_KMOD_GUI != 0;
    const ctrl = mods & c.SDL_KMOD_CTRL != 0;
    const alt = mods & c.SDL_KMOD_ALT != 0;
    const shift = mods & c.SDL_KMOD_SHIFT != 0;

    // Command-key shortcuts belong to the app, not the shell.
    if (cmd) {
        switch (key.key) {
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
            else => {},
        }
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

fn handleWheel(app: *App, wheel: c.SDL_MouseWheelEvent) void {
    const lines: isize = @intFromFloat(@trunc(wheel.y * 3));
    if (lines == 0) return;

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
