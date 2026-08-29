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
const Terminal = @import("terminal.zig").Terminal;
const Pty = @import("pty.zig").Pty;

const c = render.c;

const default_font_size = 14;
const default_cols = 100;
const default_rows = 30;

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
        if (!app.pty.waitReadable(100)) continue;
        const n = app.pty.read(&buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => break,
        };
        if (n == 0) break; // child closed the terminal

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

    const opts = parseArgs(init.args.vector);

    var renderer = try render.Renderer.init(
        alloc,
        "terminator",
        opts.font_size,
        opts.cols,
        opts.rows,
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
        .term = try Terminal.init(alloc, size.cols, size.rows),
        .pty = try Pty.open(@intCast(size.cols), @intCast(size.rows), opts.shell),
    };
    defer app.mutex.deinit();
    defer app.term.deinit();
    defer app.pty.deinit();

    app.wake_event = c.SDL_RegisterEvents(1);
    _ = c.SDL_StartTextInput(renderer.window);

    const reader = try std.Thread.spawn(.{}, readerThread, .{&app});
    defer {
        // Order matters: tell the reader to stop and hang up the child
        // before joining, or we wait on a thread that isn't coming back.
        app.running.store(false, .release);
        app.pty.shutdown();
        reader.join();
    }

    var title_buf: [256:0]u8 = undefined;
    var last_title_len: usize = std.math.maxInt(usize);
    var font_size = opts.font_size;

    var frame_stats = stats.FrameStats.init(opts.frame_stats);
    defer frame_stats.reportTotals(app.bytes_read.load(.monotonic));

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
                    redraw = true;
                },
                c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                    renderer.focused = false;
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
            app.term.resize(g.cols, g.rows) catch {};
            app.mutex.unlock();
            app.pty.resize(@intCast(g.cols), @intCast(g.rows));
            redraw = true;
        }

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

        if (app.term.title.items.len != last_title_len and
            app.term.title.items.len < title_buf.len)
        {
            last_title_len = app.term.title.items.len;
            @memcpy(title_buf[0..last_title_len], app.term.title.items);
            title_buf[last_title_len] = 0;
            renderer.setTitle(title_buf[0..last_title_len :0]);
        }

        // Copy the frame out under the lock; draw and present it after. The
        // present waits for vblank, and with it inside the lock the reader
        // could not feed a byte for the whole of every frame.
        var draw_frame = false;
        if (dirty) {
            draw_frame = true;
            renderer.snapshot(&app.term) catch {
                draw_frame = false;
            };
        }
        app.mutex.unlock();
        const lock_ns = stats.nowNs() - t_lock;

        if (draw_frame) {
            var times = renderer.draw();
            times.lock = lock_ns;
            frame_stats.record(times);
        }
        frame_stats.maybeReport(app.bytes_read.load(.monotonic));

        if (app.pty.exited()) app.running.store(false, .release);
    }

    app.running.store(false, .release);
}

fn sendToPty(app: *App, bytes: []const u8) void {
    if (bytes.len == 0) return;
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
                app.mutex.unlock();
                sendToPty(app, "\x0c"); // Ctrl-L, so the shell redraws its prompt
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
    defer app.mutex.unlock();

    if (app.term.on_alt) {
        // Full-screen apps have no scrollback of ours to show, so translate
        // the wheel into arrow keys the way xterm does. That makes less,
        // man and vim scroll as expected.
        const key: input.Key = if (lines > 0) .up else .down;
        const count: usize = @abs(lines);
        var buf: [32]u8 = undefined;
        const bytes = input.encode(&buf, key, .{}, app.term.modes.app_cursor) orelse return;
        for (0..count) |_| app.pty.writeAll(bytes) catch return;
    } else {
        app.term.scrollView(lines);
    }
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

const Options = struct {
    font_size: u32 = default_font_size,
    shell: ?[:0]const u8 = null,
    frame_stats: bool = false,
    screenshot: ?[:0]const u8 = null,
    cols: u32 = default_cols,
    rows: u32 = default_rows,
};

fn parseArgs(argv: []const [*:0]const u8) Options {
    var opts = Options{};
    var i: usize = 1; // skip argv[0]

    while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--font-size")) {
            i += 1;
            if (i >= argv.len) break;
            opts.font_size = std.fmt.parseInt(u32, std.mem.span(argv[i]), 10) catch
                default_font_size;
        } else if (std.mem.eql(u8, arg, "--shell")) {
            i += 1;
            if (i >= argv.len) break;
            opts.shell = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--frame-stats")) {
            opts.frame_stats = true;
        } else if (std.mem.eql(u8, arg, "--screenshot")) {
            i += 1;
            if (i >= argv.len) break;
            opts.screenshot = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i >= argv.len) break;
            const spec = std.mem.span(argv[i]);
            if (std.mem.indexOfScalar(u8, spec, 'x')) |x| {
                opts.cols = std.fmt.parseInt(u32, spec[0..x], 10) catch default_cols;
                opts.rows = std.fmt.parseInt(u32, spec[x + 1 ..], 10) catch default_rows;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\terminator -- a terminal emulator
                \\
                \\  --font-size N   point size (default {d})
                \\  --size CxR      initial grid, e.g. 200x60 (default {d}x{d})
                \\  --shell PATH    shell to run (default $SHELL)
                \\  --frame-stats   print frame timing to stderr once a second
                \\  -h, --help      this message
                \\
                \\Keys:
                \\  Cmd +/-/0       font size
                \\  Cmd V           paste
                \\  Cmd K           clear
                \\  Wheel           scroll history
                \\
            , .{ default_font_size, default_cols, default_rows });
            std.process.exit(0);
        }
    }
    return opts;
}
