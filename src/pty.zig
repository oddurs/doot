//! The pseudoterminal: a bidirectional pipe with a kernel line discipline on
//! it, which is what makes a shell believe it's talking to a real terminal.
//!
//! `forkpty` does three things at once that are easy to get subtly wrong by
//! hand: allocate the master/slave pair, put the child in a new session, and
//! make the slave its controlling terminal. Without that last part the shell
//! can't deliver Ctrl-C, and job control silently doesn't work.

const std = @import("std");
const posix = std.posix;
const version = @import("version.zig");

const c = @cImport({
    @cInclude("util.h");
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("signal.h");
    @cInclude("fcntl.h");
});

pub const Pty = struct {
    master: posix.fd_t,
    pid: posix.pid_t,
    closed: bool = false,

    pub const Error = error{ ForkFailed, WriteFailed, EmptyCommand, TooManyArgs };

    /// As many arguments as `openCommand` will pass on. The copy has to
    /// live on the child's stack, because allocating after fork is not
    /// safe, so it is bounded -- generously, for a command line.
    pub const max_argv = 64;

    /// Open a pty running the user's shell as a login shell.
    pub fn open(cols: u16, rows: u16, shell_override: ?[:0]const u8) !Pty {
        const shell = shell_override orelse defaultShell();
        return openCommand(cols, rows, &.{ shell, "-l" });
    }

    /// Open a pty running an arbitrary command. `argv[0]` is the program.
    ///
    /// The recorder needs this to run an agent CLI rather than a shell; the
    /// terminal itself only ever wants `open`.
    ///
    /// Both bounds are checked here rather than in the child: after fork
    /// there is nothing useful to do with an error, and a truncated argv
    /// would exec a command nobody asked for.
    pub fn openCommand(cols: u16, rows: u16, argv_slice: []const [*:0]const u8) !Pty {
        if (argv_slice.len == 0) return Error.EmptyCommand;
        if (argv_slice.len > max_argv) return Error.TooManyArgs;
        var ws = c.winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        var master: c_int = -1;
        const pid = c.forkpty(&master, null, null, &ws);
        if (pid < 0) return Error.ForkFailed;

        if (pid == 0) {
            // -- child --------------------------------------------------
            // Restore default signal handling; SDL installs handlers we do
            // not want the shell to inherit.
            // SIG_DFL is a null handler pointer; macOS spells it as a cast
            // that Zig's C translator can't chew on, so we pass null.
            const sig_dfl: c.sig_t = null;
            _ = c.signal(c.SIGPIPE, sig_dfl);
            _ = c.signal(c.SIGINT, sig_dfl);
            _ = c.signal(c.SIGTERM, sig_dfl);
            _ = c.signal(c.SIGCHLD, sig_dfl);

            // TERM decides which capabilities every curses app will use.
            // xterm-256color is the safe lingua franca; COLORTERM is the
            // de-facto flag for 24-bit color.
            _ = c.setenv("TERM", "xterm-256color", 1);
            _ = c.setenv("COLORTERM", "truecolor", 1);
            // Identify ourselves the way iTerm, Apple Terminal and Ghostty
            // do, so shell config can special-case this terminal.
            _ = c.setenv("TERM_PROGRAM", "doot", 1);
            _ = c.setenv("TERM_PROGRAM_VERSION", version.string, 1);
            _ = c.unsetenv("LINES");
            _ = c.unsetenv("COLUMNS");

            // A null-terminated copy of argv on the child's stack. Bounded
            // rather than allocated: this runs after fork, where allocating
            // is not safe.
            var argv_buf: [max_argv:null]?[*:0]const u8 = @splat(null);
            for (argv_slice, 0..) |a, i| argv_buf[i] = a;
            argv_buf[argv_slice.len] = null;
            _ = c.execvp(argv_slice[0], @ptrCast(@constCast(&argv_buf)));

            // execvp only returns on failure. _exit, not exit: we must not
            // run atexit handlers or flush the parent's buffers.
            c._exit(127);
        }

        // -- parent -----------------------------------------------------
        return .{ .master = @intCast(master), .pid = @intCast(pid) };
    }

    fn defaultShell() [:0]const u8 {
        if (c.getenv("SHELL")) |s| {
            return std.mem.span(@as([*:0]const u8, @ptrCast(s)));
        }
        return "/bin/zsh";
    }

    /// Tell the kernel the window changed size. This is what makes the child
    /// receive SIGWINCH, which is how vim et al learn to repaint.
    pub fn resize(self: Pty, cols: u16, rows: u16) void {
        var ws = c.winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = c.ioctl(self.master, c.TIOCSWINSZ, &ws);
    }

    /// Put the master end in non-blocking mode, so reads return EAGAIN
    /// instead of parking the caller. The app doesn't need this -- its reader
    /// thread wants to block -- but anything single-threaded does.
    pub fn setNonBlocking(self: Pty) void {
        const flags = c.fcntl(self.master, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(self.master, c.F_SETFL, flags | c.O_NONBLOCK);
    }

    /// Wait up to `timeout_ms` for readable data. Returns false on timeout.
    pub fn waitReadable(self: Pty, timeout_ms: i32) bool {
        var fds = [_]std.c.pollfd{.{
            .fd = self.master,
            .events = std.c.POLL.IN,
            .revents = 0,
        }};
        return std.c.poll(&fds, 1, timeout_ms) > 0;
    }

    pub fn read(self: Pty, buf: []u8) !usize {
        return posix.read(self.master, buf);
    }

    /// Write every byte, retrying short writes and EINTR. A dropped keystroke
    /// is a bug the user feels immediately, so this loop matters.
    pub fn writeAll(self: Pty, bytes: []const u8) Error!void {
        var n: usize = 0;
        while (n < bytes.len) {
            const rc = std.c.write(self.master, bytes.ptr + n, bytes.len - n);
            if (rc < 0) {
                switch (posix.errno(rc)) {
                    .INTR, .AGAIN => continue,
                    else => return Error.WriteFailed,
                }
            }
            if (rc == 0) return Error.WriteFailed;
            n += @intCast(rc);
        }
    }

    /// True once the child has exited.
    pub fn exited(self: Pty) bool {
        var status: c_int = 0;
        const r = c.waitpid(self.pid, &status, c.WNOHANG);
        return r == self.pid;
    }

    /// Hang up the child and close our end. Idempotent, so it's safe to call
    /// on the way out of an error path and again from `deinit`.
    pub fn shutdown(self: *Pty) void {
        if (self.closed) return;
        self.closed = true;
        _ = c.kill(self.pid, c.SIGHUP);
        _ = std.c.close(self.master);
        // Reap the child so it doesn't linger as a zombie.
        var status: c_int = 0;
        _ = c.waitpid(self.pid, &status, 0);
    }

    pub fn deinit(self: *Pty) void {
        self.shutdown();
    }
};
