//! Session recording: the `.trec` file, the writer that appends to it, and
//! the reader that takes one apart again.
//!
//! L0 of [record.md](../docs/roadmap/record.md). The claim that page makes is
//! that the terminal is not a screen but an append-only, time-indexed log of
//! every byte in and out of every session, and that the screen is a view of
//! it. This file is the log. `src/replay.zig` is the view, and
//! `src/check.zig` is what decides whether the two agree.
//!
//! ## The file
//!
//! One file per session, append-only, uncompressed, opened
//! `O_WRONLY|O_CREAT|O_EXCL|O_APPEND` with mode `0600` inside a `0700`
//! directory. `O_EXCL` because a filename collision must fail rather than
//! append this session onto somebody else's; `O_APPEND` because every write
//! is at the end by definition and nothing here ever seeks.
//!
//! A 48-byte header, then a stream of records:
//!
//! ```
//! header  magic "TRMREC\x1a\n"  8   version u16   header_len u16
//!         cols u16  rows u16    wall_start_ns i64
//!         session_id [16]u8     flags u32         crc32 of bytes 0..44
//!
//! record  type u8   flags u8    len u16           dt_us u32   payload[len]
//! ```
//!
//! `wall_start_ns` is **the only wall clock in the file**. Everything after
//! it is a delta in microseconds from the record before, so a recording says
//! when it started and how long everything took, and nothing else about when
//! the machine thought it was.
//!
//! `len` is a `u16` because the kernel caps a read off a pty at 1,024 bytes
//! -- measured, not assumed -- so 64 KiB of headroom per record is already
//! sixty times what one ever carries. `dt_us` is a `u32`, which runs out at
//! about 71 minutes; a longer gap emits `tick` records to bridge it.
//!
//! Integers are little-endian. A recording is a local artifact of a local
//! session; byte-swapping it for a machine that will never read it is cost
//! with no reader.
//!
//! ## Timing without drift
//!
//! The naive delta -- `(now - last) / 1000` -- throws away the sub-microsecond
//! remainder on **every** record. At the write rates a terminal actually sees
//! that compounds into about 4% of the session's length going missing. So the
//! nanosecond base is kept, and each record's delta is
//! `(now - base) / 1000 - everything emitted so far`. The error is bounded at
//! one microsecond for the whole file rather than accumulating per record.
//!
//! ## The one-read delay
//!
//! `redact.scrub` runs over every byte before it is recorded -- see
//! `redact.zig` for why, and for the dispatch table that makes it fast enough
//! to sit here. Scrubbing each read on its own leaks any secret that straddles
//! a read boundary, and the motivating incident was a *startup banner*, which
//! arrives in the very first read. Two failure modes, and the second is worse
//! than the first: the prefix can be split across the boundary, or the whole
//! prefix can land in read N with the run continuing into N+1, where `scrub`
//! sees a run shorter than `min_run` and skips it entirely.
//!
//! So a read is held rather than emitted. On the next read, `prev ++ new` is
//! scrubbed as one contiguous buffer, the scrubbed `prev` is emitted carrying
//! `prev`'s own timestamp, and the scrubbed `new` becomes the next held read.
//! Re-scrubbing the held bytes is free of consequence because `scrub` is
//! idempotent, which `redact.zig` has a test for.
//!
//! **The limit, stated rather than hidden:** a token spanning more than two
//! reads has its tail unredacted. `redact.zig`'s `min_run` means the *start*
//! is still caught, so what escapes is the far end of a very long token split
//! across three reads. The test below asserts that behaviour so a change to
//! it is deliberate.
//!
//! ## Failure policy: never write a hole
//!
//! Any write error closes the fd, sets `recording = false`, makes one
//! best-effort attempt at an `end` record, and never retries. A recorder that
//! retried would produce a file with a gap in the middle that reads as
//! continuous, which is worse than a file that stops. The terminal keeps
//! running either way: a session that cannot be recorded is still a session.
//!
//! **The `end(write_error)` attempt usually fails, and is not the signal.**
//! On the failure it exists for -- a full disk -- the disk that refused the
//! buffered flush refuses nine more bytes too, so no `end` record reaches the
//! file and `flushNow`'s partial-write path may already have left a torn
//! record in front of it. The attempt is kept because it *is* correct for the
//! errors that are not about space (a descriptor pulled out from under us, a
//! device that went away and came back), but nothing here should be read as a
//! promise that a write error is recorded in the file. What a reader sees on
//! a full disk is a recording with **no `end` record at all**, which
//! `Session.closed_cleanly` reports as false -- and that is the signal: the
//! writer did not get to finish. `end_reason == .write_error` is the lucky
//! case, not the expected one. Both are pinned by tests below.
//!
//! There is no `fsync` anywhere in this file, on purpose. The durability
//! being bought is against *our own* crash, which the OS's page cache already
//! provides; `fsync` buys durability against power loss, and it is the one
//! call guaranteed to block for milliseconds on the thread that is draining
//! the pty.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const redact = @import("redact.zig");

// ---------------------------------------------------------------------------
// The format
// ---------------------------------------------------------------------------

pub const magic = "TRMREC\x1a\n";
pub const format_version: u16 = 1;
pub const header_len: usize = 48;
pub const extension = ".trec";

/// What a record is.
///
/// `mark` and `checkpoint` are reserved for L1 and L3 and are **never
/// written** by L0. They are numbered here so that a file written then and a
/// reader written now disagree about content rather than about framing.
pub const Type = enum(u8) {
    /// Nothing happened; carries time only. Emitted to bridge a gap longer
    /// than `dt_us` can express.
    tick = 0,
    /// Bytes the child wrote to the terminal.
    output = 1,
    /// Bytes the terminal wrote to the child. Never recorded unless asked.
    input = 2,
    /// The grid was resized: `cols u16, rows u16`.
    resize = 3,
    /// The window gained (1) or lost (0) focus.
    focus = 4,
    /// A terminal mutation with no bytes behind it: see `Control`.
    control = 5,
    /// Free text about the session. Reserved: L0 has nothing to say in one,
    /// so nothing writes it. Numbered here for the same reason `mark` and
    /// `checkpoint` are -- so a later writer and this reader disagree about
    /// content rather than about framing.
    meta = 6,
    /// The session ended: see `EndReason`.
    end = 7,
    /// Reserved for L1/L3. Not written.
    mark = 8,
    /// Reserved for L1. Not written.
    checkpoint = 9,
    _,
};

/// Set on a record whose payload had something replaced by `redact.scrub`.
pub const flag_redacted: u8 = 1;

/// A change to the terminal that no bytes went through the parser for.
///
/// This list is closed, and knowing that it is closed is what makes the
/// checksum test meaningful. The complete set of ways `main.zig` mutates the
/// terminal outside `parser.feed` is `resize`, `fullReset`, `scrollView` and
/// `setSelection`; `resize` has a record type of its own, and `fullReset` is
/// this.
///
/// `scrollView` and `setSelection` are both excluded, and for the same
/// reason: they move only what the window is showing and what the user has
/// picked out of it, and `check.zig` excludes both by construction. A record
/// for either would put events in the file that no replay could act on and
/// no checksum could see -- which is how a closed list stops being one.
pub const Control = enum(u8) { full_reset = 0, _ };

pub const EndReason = enum(u8) {
    /// The session ended and the recorder was closed on the way out.
    clean = 0,
    /// The per-session size cap was reached.
    size_cap = 1,
    /// A write failed. The bytes before this point are still good.
    ///
    /// Best-effort: see the failure policy at the top of this file. On a full
    /// disk this record does not reach the file and the recording reads as
    /// not closed cleanly instead.
    write_error = 2,
    // 3 was `disabled`, for switching recording off while the session
    // continued. Nothing can do that -- `Cmd ⇧ R` toggles keystroke
    // recording, not recording -- so it was a reason no file could carry.
    // The number is not reused: a file written by something that did have it
    // must read as a reason this build does not know, not as a wrong one.
    _,
};

/// The bytes before a record's payload.
pub const record_header_len: usize = 8;

/// The largest payload one record carries. Well above a pty read, and small
/// enough that a record always fits in the buffer with room to spare -- which
/// is what lets `put` promise that no record is ever split across two
/// `write` calls.
pub const max_payload: usize = 32 * 1024;

/// The largest chunk `output` accepts in one piece, and therefore the size of
/// the held read. Matches `main.zig`'s pty read buffer.
pub const max_read: usize = 64 * 1024;

/// How much of the buffer ordinary records -- `output`, `input`, `tick`,
/// `end` -- may fill before a flush. 64 KiB, which is what the flush size was
/// before the reserve below existed, so the gate's numbers stay comparable.
const buf_usable: usize = 64 * 1024;

/// A tail of the buffer that only an **out-of-band** record may touch, so
/// that one never triggers a `write(2)`.
///
/// `resize`, `focus` and `control` are emitted from the *main* thread, and
/// `resize` and `control` are emitted with the terminal mutex held. A flush
/// on that path is a 64 KiB `write(2)` inside the critical section sprint 1
/// exists to keep empty -- measured at 2,234-5,578 µs, which is four orders
/// of magnitude above the 12-byte append it is supposed to be. Keeping a tail
/// free means the append always fits and the reader thread's next
/// `maybeFlush` is what writes it.
///
/// The record itself is at most 12 bytes. The reserve is large because an
/// out-of-band record must first `drainHold`, and the held read can be a
/// whole `max_read`, which `emit` splits into two `max_payload` records. So
/// the reserve is sized for the worst drain plus a run of small records, and
/// the guarantee is unconditional rather than "unless the hold was big".
const oob_reserve: usize = 2 * (record_header_len + max_payload) + 512;

const buf_capacity: usize = buf_usable + oob_reserve;

/// Flush on fill, or after this long. The timer is free: the reader thread's
/// `waitReadable(100)` already returns every 100 ms when the pty is quiet, so
/// there is no timer thread and no timer syscall.
pub const flush_after_ns: u64 = 250 * std.time.ns_per_ms;

/// How long a silent session may go without a `write(2)` before one is made
/// anyway, as a `tick`.
///
/// The retention sweep goes by mtime because mtime is self-protecting -- an
/// open session's writes keep its file inside the window, so another instance
/// cannot delete a file this one still holds open. That only holds if an open
/// session keeps writing. A window left at a prompt buffers nothing, so
/// `flushNow` returned without a `write(2)` and the mtime froze; fourteen days
/// later the file was swept out from under its own writer, which went on
/// appending to a nameless inode. A `tick` a minute costs 8 bytes and 1,440
/// writes a day, and the format already has ticks for gaps.
pub const idle_tick_ns: u64 = 60 * std.time.ns_per_s;

/// The largest grid a recording may claim, in either direction.
///
/// A record carries no CRC, so a flipped byte in a `resize` payload is a
/// `u16` the reader hands straight to `Terminal.resize`. At `65535 x 65535`
/// that is 4.3 billion cells -- about 68 GB -- of allocation request from
/// four bytes nothing checked. The header's geometry *is* inside its CRC, but
/// a CRC only says the file is the one somebody wrote; it does not say the
/// writer was this one. The writer refuses anything above this bound, so the
/// reader refusing it too costs no readable file.
pub const max_dim: u16 = cli.max_dim;

/// One session cannot grow past this. A terminal left open for a month
/// against a program that never stops printing is not a reason to fill a
/// disk.
pub const default_size_cap: u64 = 256 * 1024 * 1024;

/// How long a recording is kept, unless asked otherwise. Days, not forever.
pub const default_retain_days: u32 = 14;

const Crc32 = std.hash.crc.Crc32;

pub const Header = struct {
    version: u16 = format_version,
    cols: u16,
    rows: u16,
    /// Nanoseconds since the Unix epoch when the session started. The only
    /// wall clock in the file.
    wall_start_ns: i64,
    session_id: [16]u8,
    flags: u32 = 0,

    pub fn encode(self: Header) [header_len]u8 {
        var b: [header_len]u8 = @splat(0);
        @memcpy(b[0..8], magic);
        std.mem.writeInt(u16, b[8..10], self.version, .little);
        std.mem.writeInt(u16, b[10..12], @intCast(header_len), .little);
        std.mem.writeInt(u16, b[12..14], self.cols, .little);
        std.mem.writeInt(u16, b[14..16], self.rows, .little);
        std.mem.writeInt(i64, b[16..24], self.wall_start_ns, .little);
        @memcpy(b[24..40], &self.session_id);
        std.mem.writeInt(u32, b[40..44], self.flags, .little);
        std.mem.writeInt(u32, b[44..48], Crc32.hash(b[0..44]), .little);
        return b;
    }

    pub fn decode(b: []const u8) Error!Header {
        if (b.len < header_len) return Error.ShortHeader;
        if (!std.mem.eql(u8, b[0..8], magic)) return Error.NotARecording;
        if (Crc32.hash(b[0..44]) != std.mem.readInt(u32, b[44..48], .little)) {
            return Error.BadHeaderChecksum;
        }
        const v = std.mem.readInt(u16, b[8..10], .little);
        if (v != format_version) return Error.UnsupportedVersion;
        // A future version may make the header longer. Refusing a header
        // longer than we know how to read is the honest answer; refusing a
        // *shorter* one is refusing a file that cannot be this format.
        if (std.mem.readInt(u16, b[10..12], .little) != header_len) {
            return Error.UnsupportedVersion;
        }
        // Before anything allocates from it. The CRC covers this field, so a
        // header that gets here is one somebody wrote on purpose -- and the
        // writer will not write a geometry past `max_dim`, so a file that
        // claims one is not a file this reader should build a grid from.
        const cols = std.mem.readInt(u16, b[12..14], .little);
        const rows = std.mem.readInt(u16, b[14..16], .little);
        if (cols > max_dim or rows > max_dim) return Error.GeometryOutOfRange;
        return .{
            .version = v,
            .cols = cols,
            .rows = rows,
            .wall_start_ns = std.mem.readInt(i64, b[16..24], .little),
            .session_id = b[24..40].*,
            .flags = std.mem.readInt(u32, b[40..44], .little),
        };
    }
};

pub const Error = error{
    ShortHeader,
    NotARecording,
    BadHeaderChecksum,
    UnsupportedVersion,
    /// A geometry no writer here produces and no reader should allocate from.
    GeometryOutOfRange,
};

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

pub fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn wallNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
}

/// `2026-08-29T14-03-11Z`, UTC, colons replaced by hyphens so the name is a
/// filename on every filesystem anyone will put this on.
pub fn stampUtc(buf: *[20]u8, epoch_s: i64) []const u8 {
    const secs: u64 = if (epoch_s < 0) 0 else @intCast(epoch_s);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}-{d:0>2}-{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// Sixteen bytes nobody can guess, for the session id.
///
/// `/dev/urandom` rather than `arc4random_buf` or `getrandom`, because those
/// two are spelled differently on every platform this is meant to keep
/// building for and the file is opened once per session. The fallback is
/// weaker and says so: it is there so a session still records on a machine
/// with no `/dev/urandom` rather than refusing to.
pub fn randomId() [16]u8 {
    var id: [16]u8 = undefined;
    const fd = std.c.open("/dev/urandom", .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd >= 0) {
        defer _ = std.c.close(fd);
        var got: usize = 0;
        while (got < id.len) {
            const rc = std.c.read(fd, id[got..].ptr, id.len - got);
            if (rc <= 0) break;
            got += @intCast(rc);
        }
        if (got == id.len) return id;
    }
    var h = std.hash.Wyhash.init(@bitCast(wallNs()));
    h.update(std.mem.asBytes(&nowNs()));
    const pid = std.c.getpid();
    h.update(std.mem.asBytes(&pid));
    std.mem.writeInt(u64, id[0..8], h.final(), .little);
    h.update(std.mem.asBytes(&id));
    std.mem.writeInt(u64, id[8..16], h.final(), .little);
    return id;
}

// ---------------------------------------------------------------------------
// Where recordings live
// ---------------------------------------------------------------------------

/// The default sessions directory, written into `buf`.
///
/// `~/Library/Application Support/doot/sessions` on macOS, and the XDG
/// data directory elsewhere -- the core is kept portable on every PR
/// (docs/roadmap/compatibility.md's M0) and a hardcoded Apple path is exactly
/// the kind of thing that quietly stops being true.
pub fn defaultDir(buf: []u8) ?[]const u8 {
    const home_z = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(@as([*:0]const u8, home_z));
    if (home.len == 0) return null;

    if (builtin.os.tag.isDarwin()) {
        return std.fmt.bufPrint(
            buf,
            "{s}/Library/Application Support/doot/sessions",
            .{home},
        ) catch null;
    }
    if (std.c.getenv("XDG_DATA_HOME")) |xdg_z| {
        const xdg = std.mem.span(@as([*:0]const u8, xdg_z));
        if (xdg.len > 0) {
            return std.fmt.bufPrint(buf, "{s}/doot/sessions", .{xdg}) catch null;
        }
    }
    return std.fmt.bufPrint(buf, "{s}/.local/share/doot/sessions", .{home}) catch null;
}

/// Create `path` and any missing parent, each `0700`.
///
/// `0700` rather than `0755` for the parents too: every component created
/// here is a component of a path that exists to hold recordings, and a
/// directory nobody else can list is the cheapest half of "files are 0600".
/// The mode is passed to `mkdir`, so a directory this call *creates* is never
/// readable for an instant.
///
/// **A directory that already exists is `chmod`ed to `0700`.** `EEXIST` used
/// to count as success and the mode went unchecked, so `chmod 0777` on an
/// existing sessions directory left it world-listable for good -- start
/// times, session-id prefixes, sizes and counts, which is exactly what the
/// directory mode is here to keep. The "never `chmod` after" rule is about
/// *files*, where the risk is the window between `create` and `chmod`; there
/// is no such window here, because the directory already exists and
/// tightening one we own only ever removes access.
///
/// Only the last component. Walking up `~/Library/Application Support` and
/// `chmod 0700`ing every parent that happened to exist would be a far worse
/// bug than the one being fixed.
pub fn makeDir(path: []const u8) bool {
    var buf: [std.c.PATH_MAX]u8 = undefined;
    if (path.len == 0 or path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and buf[i] != '/') continue;
        const saved = buf[i];
        buf[i] = 0;
        const rc = std.c.mkdir(@ptrCast(&buf), 0o700);
        if (rc != 0) {
            const existed = std.posix.errno(rc) == .EXIST;
            // A missing intermediate on some other error is still worth
            // trying to push through -- the final component is the one that
            // has to exist -- so only the last failure decides.
            if (!existed and i == path.len) return false;
            if (existed and i == path.len) _ = std.c.chmod(@ptrCast(&buf), 0o700);
        }
        buf[i] = saved;
    }
    return true;
}

/// Delete every `.trec` in `dir_path` whose mtime is older than
/// `retain_days`. Returns how many went. `retain_days == 0` keeps everything.
///
/// **By mtime, not by the header's start time**, and the difference matters:
/// mtime is self-protecting. A session that is still open has its mtime
/// pushed forward by every write, so it stays inside the window and a second
/// instance sweeping at startup cannot delete a file the first instance is
/// still writing to. A header timestamp has no such property -- a session
/// open for longer than the retention period would delete itself.
///
/// That argument only holds because of `idle_tick_ns`: a window sitting at a
/// prompt has nothing to flush, so without a periodic `tick` its mtime would
/// freeze and this sweep would unlink a file its own writer still had open.
pub fn sweep(dir_path: []const u8, retain_days: u32, now_epoch_s: i64) usize {
    if (retain_days == 0) return 0;
    const cutoff = now_epoch_s - @as(i64, retain_days) * 24 * 60 * 60;

    var dir_z: [std.c.PATH_MAX]u8 = undefined;
    if (dir_path.len >= dir_z.len) return 0;
    @memcpy(dir_z[0..dir_path.len], dir_path);
    dir_z[dir_path.len] = 0;

    const dp = std.c.opendir(@ptrCast(&dir_z)) orelse return 0;
    defer _ = std.c.closedir(dp);

    var removed: usize = 0;
    while (std.c.readdir(dp)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (!std.mem.endsWith(u8, name, extension)) continue;

        var path: [std.c.PATH_MAX]u8 = undefined;
        const full = std.fmt.bufPrintZ(&path, "{s}/{s}", .{ dir_path, name }) catch continue;

        const fd = std.c.open(full.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) continue;
        var st: std.c.Stat = undefined;
        const ok = std.c.fstat(fd, &st) == 0;
        _ = std.c.close(fd);
        if (!ok) continue;

        if (st.mtime().sec >= cutoff) continue;
        if (std.c.unlink(full.ptr) == 0) removed += 1;
    }
    return removed;
}

// ---------------------------------------------------------------------------
// The writer
// ---------------------------------------------------------------------------

/// What `--frame-stats` reports about the recorder at exit.
pub const Stats = struct {
    /// Bytes actually written to the file, header included.
    bytes: u64 = 0,
    records: u64 = 0,
    redactions: u64 = 0,
    flushes: u64 = 0,
    /// The direct measurement of whether writing stalls the reader thread.
    worst_flush_ns: u64 = 0,
};

pub const Options = struct {
    cols: u16,
    rows: u16,
    /// Keystrokes are recorded only when this is true, and it is never true
    /// unless someone asked for it on the command line or pressed the key.
    record_input: bool = false,
    size_cap: u64 = default_size_cap,
};

/// The path of a `Writer.disabled`, which owns no allocation to free.
var empty_path: [0:0]u8 = .{};

pub const Writer = struct {
    alloc: std.mem.Allocator,

    fd: i32 = -1,
    /// False once the file is closed, for any reason. Every entry point
    /// returns immediately when it is false, so a recorder that has given up
    /// costs one predictable branch per call and nothing else.
    recording: bool = false,
    /// **The one place input recording is decided.** `input()` checks this
    /// and no call site does, so no call site can get it wrong.
    record_input: bool = false,

    header: Header,
    path: [:0]u8,

    buf: []u8,
    used: usize = 0,

    /// The previous read, scrubbed, waiting for its successor so the two can
    /// be scrubbed as one contiguous buffer. See the module comment.
    hold: []u8,
    hold_len: usize = 0,
    hold_ns: u64 = 0,
    hold_redacted: bool = false,
    scratch: []u8,

    base_ns: u64,
    /// The sum of every `dt_us` written so far. The delta for the next record
    /// is computed against this rather than against the last timestamp, which
    /// is what keeps truncation from accumulating.
    emitted_us: u64 = 0,
    last_flush_ns: u64,
    /// When bytes last actually reached the file. **Not** `last_flush_ns`: a
    /// flush with nothing buffered moves that one and touches no inode, which
    /// is how an idle session's mtime used to freeze. See `idle_tick_ns`.
    last_write_ns: u64,
    size_cap: u64,
    /// Set while `finish` is running, so the size-cap check does not fire
    /// again on the records `finish` itself writes.
    closing: bool = false,
    /// Set while an out-of-band record is being emitted from the main thread,
    /// which lets `put` spend the reserved tail of the buffer rather than
    /// flush. See `oob_reserve`.
    oob: bool = false,

    stats: Stats = .{},

    /// Open a recording in `dir`, creating the directory if it is not there.
    ///
    /// The filename is the UTC start time and eight hex digits of the session
    /// id: sortable, unique, and readable without a tool.
    pub fn open(alloc: std.mem.Allocator, dir: []const u8, opts: Options) !Writer {
        if (!makeDir(dir)) return error.RecordDirUnavailable;

        const wall = wallNs();
        const id = randomId();
        var stamp: [20]u8 = undefined;
        const when = stampUtc(&stamp, @divFloor(wall, std.time.ns_per_s));

        const path = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{s}", .{
            dir, when, id[0], id[1], id[2], id[3], extension,
        }, 0);

        // `openPathWithId` owns `path` from here, on success and on failure.
        return openPathWithId(alloc, path, opts, wall, id);
    }

    /// Open a recording at exactly this path. The path must not already
    /// exist: `O_EXCL` is the point, not an accident.
    pub fn openPath(alloc: std.mem.Allocator, path: []const u8, opts: Options) !Writer {
        const owned = try alloc.allocSentinel(u8, path.len, 0);
        @memcpy(owned, path);
        // `openPathWithId` owns `owned` from here, on success and on failure.
        return openPathWithId(alloc, owned, opts, wallNs(), randomId());
    }

    /// Takes ownership of `path` -- it is freed here on every failure path,
    /// so no caller carries an `errdefer` for it.
    fn openPathWithId(
        alloc: std.mem.Allocator,
        path: [:0]u8,
        opts: Options,
        wall: i64,
        id: [16]u8,
    ) !Writer {
        // Refused here rather than clamped, so that no file this writer
        // produces carries a geometry `Header.decode` will refuse to read.
        if (opts.cols > max_dim or opts.rows > max_dim) {
            alloc.free(path);
            return Error.GeometryOutOfRange;
        }
        // O_EXCL: a name collision is a bug, and appending this session onto
        // another one would hide it. O_APPEND: nothing here ever seeks, and
        // it makes a torn write impossible to interleave with anything else.
        // 0600 passed to open, never chmod'd afterwards.
        const fd = std.c.open(path.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .APPEND = true,
        }, @as(std.c.mode_t, 0o600));
        if (fd < 0) {
            alloc.free(path);
            return error.RecordFileUnavailable;
        }
        errdefer {
            _ = std.c.close(fd);
            alloc.free(path);
        }

        const buf = try alloc.alloc(u8, buf_capacity);
        errdefer alloc.free(buf);
        const hold = try alloc.alloc(u8, max_read);
        errdefer alloc.free(hold);
        const scratch = try alloc.alloc(u8, max_read * 2);
        errdefer alloc.free(scratch);

        const now = nowNs();
        var self = Writer{
            .alloc = alloc,
            .fd = fd,
            .recording = true,
            .record_input = opts.record_input,
            .header = .{
                .cols = opts.cols,
                .rows = opts.rows,
                .wall_start_ns = wall,
                .session_id = id,
            },
            .path = path,
            .buf = buf,
            .hold = hold,
            .scratch = scratch,
            .base_ns = now,
            .last_flush_ns = now,
            .last_write_ns = now,
            .size_cap = opts.size_cap,
        };

        const head = self.header.encode();
        @memcpy(self.buf[0..head.len], &head);
        self.used = head.len;
        return self;
    }

    /// A recorder that is switched off. Every method is a no-op on it, so
    /// `--no-record` and `--incognito` need no branches at any call site.
    pub fn disabled(alloc: std.mem.Allocator) Writer {
        return .{
            .alloc = alloc,
            .header = .{ .cols = 0, .rows = 0, .wall_start_ns = 0, .session_id = @splat(0) },
            .path = &empty_path,
            .buf = &.{},
            .hold = &.{},
            .scratch = &.{},
            .base_ns = 0,
            .last_flush_ns = 0,
            .last_write_ns = 0,
            .size_cap = 0,
        };
    }

    pub fn deinit(self: *Writer) void {
        if (self.recording) self.finish(.clean);
        if (self.path.len > 0) self.alloc.free(self.path);
        if (self.buf.len > 0) self.alloc.free(self.buf);
        if (self.hold.len > 0) self.alloc.free(self.hold);
        if (self.scratch.len > 0) self.alloc.free(self.scratch);
        self.* = undefined;
    }

    pub fn sessionId(self: *const Writer) [16]u8 {
        return self.header.session_id;
    }

    // -- what a caller records ------------------------------------------

    /// Bytes the child wrote. Held for one read before being emitted, so a
    /// secret straddling the boundary is still caught.
    pub fn output(self: *Writer, bytes: []const u8, now_ns: u64) void {
        if (!self.recording) return;
        var rest = bytes;
        while (rest.len > max_read) {
            self.outputChunk(rest[0..max_read], now_ns);
            rest = rest[max_read..];
        }
        if (rest.len > 0) self.outputChunk(rest, now_ns);
    }

    /// Bytes the terminal wrote to the child.
    ///
    /// The gate is here and nowhere else. Every call site -- typing, paste,
    /// the wheel translated into arrow keys -- goes through `sendToPty`, and
    /// `sendToPty` calls this; if the check lived at the call sites, the
    /// next call site added would be the one that forgot it.
    ///
    /// Input is not held the way output is. A keystroke arrives on its own,
    /// so a hold would delay each one behind the next rather than joining two
    /// halves of anything, and the two streams share a file: holding one of
    /// them would put the file's records out of order.
    pub fn input(self: *Writer, bytes: []const u8, now_ns: u64) void {
        if (!self.recording) return;
        if (!self.record_input) return;
        if (bytes.len == 0) return;
        self.drainHold();
        self.scrubbed(.input, bytes, now_ns);
    }

    /// The grid was resized.
    ///
    /// One of three records `main.zig` writes from the main thread, and one of
    /// two it writes with the terminal mutex held -- because `Terminal.resize`
    /// runs under that mutex and it is the mutex that decides the true order
    /// against a concurrent `parser.feed`. Out-of-band, so it cannot flush:
    /// see `oob_reserve`.
    pub fn resize(self: *Writer, cols: u16, rows: u16, now_ns: u64) void {
        if (!self.recording) return;
        // The writer's half of the bound `Header.decode` and `replay.zig`
        // enforce, so nothing here can produce a record they will refuse.
        // `main.zig` already clamps; this is the last place that can, and a
        // bound held at only one end is a bound the other end cannot rely on.
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], @min(cols, max_dim), .little);
        std.mem.writeInt(u16, payload[2..4], @min(rows, max_dim), .little);
        self.emitOutOfBand(.resize, &payload, now_ns);
    }

    pub fn focus(self: *Writer, focused: bool, now_ns: u64) void {
        if (!self.recording) return;
        self.emitOutOfBand(.focus, &[_]u8{@intFromBool(focused)}, now_ns);
    }

    /// A terminal mutation with no bytes behind it.
    ///
    /// Without this, `Cmd K` -- which calls `Terminal.fullReset` directly and
    /// sends nothing through the parser -- would make every session in which
    /// it was pressed replay to a different screen than it showed.
    pub fn control(self: *Writer, what: Control, now_ns: u64) void {
        if (!self.recording) return;
        self.emitOutOfBand(.control, &[_]u8{@intFromEnum(what)}, now_ns);
    }

    /// Push everything held or buffered to the file, now.
    ///
    /// L1 calls this once on entering seek mode, on the main thread, under the
    /// recorder mutex and **never** under the terminal mutex. Without it the
    /// log stops a held read and a flush interval short of the present, and
    /// "seek to now == the live screen" -- the one identity a seek has to have
    /// -- would be false by up to 250 ms of output.
    ///
    /// It can cost a whole 64 KiB `write(2)`: 1,002-2,760 µs on the machine
    /// L0 measured. That is a real main-thread stall, it happens once per
    /// entry into seek mode rather than per frame, and it is outside the
    /// critical section the `lock` column measures. Stated rather than hidden.
    pub fn flushForSeek(self: *Writer, now_ns: u64) void {
        if (!self.recording) return;
        self.drainHold();
        self.flushNow(now_ns);
    }

    /// Called at the top of the reader loop, where `waitReadable` already
    /// returns every 100 ms when the pty is quiet. Costs one comparison per
    /// wake-up and needs no timer of its own.
    ///
    /// Also the one thing that keeps an idle session's mtime moving, which is
    /// what stops another instance's retention sweep deleting a file this one
    /// still has open. See `idle_tick_ns`.
    pub fn maybeFlush(self: *Writer, now_ns: u64) void {
        if (!self.recording) return;
        const idle = self.used == 0 and self.hold_len == 0 and
            now_ns -| self.last_write_ns >= idle_tick_ns;
        if (!idle and now_ns -| self.last_flush_ns < flush_after_ns) return;
        // Nothing to say, so say nothing -- with a timestamp, which is what a
        // `tick` is for, and which puts a `write(2)` on the file.
        if (idle) self.emit(.tick, 0, &.{}, now_ns);
        self.drainHold();
        self.flushNow(now_ns);
    }

    /// Stop recording and close the file. Idempotent.
    pub fn close(self: *Writer, reason: EndReason) void {
        self.finish(reason);
    }

    // -- the machinery ---------------------------------------------------

    fn outputChunk(self: *Writer, new: []const u8, now_ns: u64) void {
        std.debug.assert(new.len <= max_read);
        const held = self.hold_len;
        const total = held + new.len;

        @memcpy(self.scratch[0..held], self.hold[0..held]);
        @memcpy(self.scratch[held..total], new);

        // One scan over both reads together. The held bytes have already
        // been scrubbed once; `scrub` is idempotent, so doing it again costs
        // a pass and changes nothing unless the run continues into `new`.
        const found = redact.scrub(self.scratch[0..total], null);
        var emit_redacted = self.hold_redacted;
        var next_redacted = false;
        if (found > 0) {
            self.stats.redactions += found;
            // Which half moved decides which record carries the flag. Only
            // computed when something was found, so the common path pays
            // nothing for it.
            emit_redacted = emit_redacted or
                !std.mem.eql(u8, self.scratch[0..held], self.hold[0..held]);
            next_redacted = !std.mem.eql(u8, self.scratch[held..total], new);
        }

        if (held > 0) {
            // The held read carries its own timestamp, not this one.
            self.emit(.output, if (emit_redacted) flag_redacted else 0, self.scratch[0..held], self.hold_ns);
        }

        @memcpy(self.hold[0..new.len], self.scratch[held..total]);
        self.hold_len = new.len;
        self.hold_ns = now_ns;
        self.hold_redacted = next_redacted;
    }

    /// Emit the held read as it stands. Called before every non-output
    /// record, so the file's order is the order events happened in, and by
    /// the flush timer, so a held read is never sitting in memory for longer
    /// than the flush interval.
    fn drainHold(self: *Writer) void {
        if (self.hold_len == 0) return;
        const n = self.hold_len;
        const flags: u8 = if (self.hold_redacted) flag_redacted else 0;
        const at = self.hold_ns;
        // Cleared first: `emit` can reach `finish`, which drains again.
        self.hold_len = 0;
        self.hold_redacted = false;
        self.emit(.output, flags, self.hold[0..n], at);
    }

    /// A record from the main thread: drain the hold so the file's order is
    /// the order events happened in, then append -- all of it inside the
    /// reserved tail, so not one byte of it can reach `write(2)`.
    ///
    /// The whole operation is marked, not just the record: `drainHold` emits
    /// the held read, and *that* was the call that flushed. `oob_reserve` is
    /// sized for the worst drain plus the record, so the pair always fits.
    fn emitOutOfBand(self: *Writer, t: Type, payload: []const u8, now_ns: u64) void {
        self.oob = true;
        defer self.oob = false;
        self.drainHold();
        self.emit(t, 0, payload, now_ns);
    }

    /// Scrub a copy and emit it. Never the caller's bytes: what reaches the
    /// screen must be exactly what the program printed, so redaction happens
    /// to the recording and to nothing else.
    fn scrubbed(self: *Writer, t: Type, bytes: []const u8, now_ns: u64) void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = @min(rest.len, self.scratch.len);
            @memcpy(self.scratch[0..n], rest[0..n]);
            const found = redact.scrub(self.scratch[0..n], null);
            self.stats.redactions += found;
            self.emit(t, if (found > 0) flag_redacted else 0, self.scratch[0..n], now_ns);
            rest = rest[n..];
        }
    }

    fn emit(self: *Writer, t: Type, flags: u8, payload: []const u8, at_ns: u64) void {
        if (!self.recording) return;
        if (!self.closing and self.stats.bytes + self.used >= self.size_cap) {
            self.finish(.size_cap);
            return;
        }

        var rest = payload;
        var first = true;
        while (true) {
            const n = @min(rest.len, max_payload);
            // Only the first piece of a split payload carries the time; the
            // rest arrived in the same instant and say so.
            const dt = if (first) self.advance(at_ns) else 0;
            self.put(t, flags, rest[0..n], dt);
            first = false;
            rest = rest[n..];
            if (rest.len == 0) break;
        }
    }

    /// The delta from the last record to `at_ns`, in microseconds, emitting
    /// `tick` records first if the gap is longer than a `u32` can hold.
    fn advance(self: *Writer, at_ns: u64) u32 {
        const total_us = (at_ns -| self.base_ns) / 1000;
        // Saturating: a record emitted with an earlier timestamp than one
        // already written would otherwise wrap. Draining the hold before
        // every other record is what stops that happening, and this is the
        // belt to that pair of braces.
        var d = total_us -| self.emitted_us;
        const cap = std.math.maxInt(u32);
        while (d > cap) {
            self.put(.tick, 0, &.{}, cap);
            d -= cap;
        }
        return @intCast(d);
    }

    fn put(self: *Writer, t: Type, flags: u8, payload: []const u8, dt_us: u32) void {
        if (!self.recording) return;
        const need = record_header_len + payload.len;
        std.debug.assert(need <= buf_usable);
        // An out-of-band record may spend the reserved tail; an ordinary one
        // may not, which is what keeps the tail there for it.
        const limit = if (self.oob) self.buf.len else buf_usable;
        if (self.used + need > limit) {
            self.flushNow(nowNs());
            if (!self.recording) return;
        }

        const at = self.buf[self.used..];
        at[0] = @intFromEnum(t);
        at[1] = flags;
        std.mem.writeInt(u16, at[2..4], @intCast(payload.len), .little);
        std.mem.writeInt(u32, at[4..8], dt_us, .little);
        @memcpy(at[record_header_len..][0..payload.len], payload);

        self.used += need;
        self.emitted_us += dt_us;
        self.stats.records += 1;
    }

    fn flushNow(self: *Writer, now_ns: u64) void {
        if (self.used == 0) {
            self.last_flush_ns = now_ns;
            return;
        }
        const t0 = nowNs();
        var off: usize = 0;
        while (off < self.used) {
            const rc = std.c.write(self.fd, self.buf.ptr + off, self.used - off);
            if (rc < 0) {
                if (std.posix.errno(rc) == .INTR) continue;
                self.fail();
                return;
            }
            if (rc == 0) {
                self.fail();
                return;
            }
            off += @intCast(rc);
        }
        const took = nowNs() -| t0;
        self.stats.worst_flush_ns = @max(self.stats.worst_flush_ns, took);
        self.stats.flushes += 1;
        self.stats.bytes += self.used;
        self.used = 0;
        self.last_flush_ns = now_ns;
        // Only here, where bytes really reached the file and the inode's
        // mtime really moved. The early return above deliberately does not
        // touch it. See `idle_tick_ns`.
        self.last_write_ns = now_ns;
    }

    /// A write failed. Close, once, and never come back.
    ///
    /// The buffered bytes are dropped rather than retried: they are what the
    /// failed write was trying to place, and writing them later would leave
    /// the file's timeline with a hole in it that reads as continuous.
    fn fail(self: *Writer) void {
        self.used = 0;
        self.recording = false;
        // One attempt at an end record, straight to the fd, unbuffered and
        // unretried. dt is zero: the clock is not the interesting part of a
        // recording that just lost its disk.
        //
        // It is best-effort in the strong sense: on the failure it is named
        // for -- a disk with no space -- the write that follows a refused
        // flush is refused too, and the file ends with no `end` record.
        // "Not closed cleanly" is what a reader sees, and that is the honest
        // signal. This attempt earns its keep on the other write errors,
        // where the fd is still usable. Do not read it as a guarantee; the
        // tests below pin both outcomes.
        var tail: [record_header_len + 1]u8 = @splat(0);
        tail[0] = @intFromEnum(Type.end);
        std.mem.writeInt(u16, tail[2..4], 1, .little);
        tail[record_header_len] = @intFromEnum(EndReason.write_error);
        _ = std.c.write(self.fd, &tail, tail.len);
        self.closeFd();
    }

    fn finish(self: *Writer, reason: EndReason) void {
        if (!self.recording or self.closing) return;
        self.closing = true;
        defer self.closing = false;

        self.drainHold();
        if (self.recording) {
            self.emit(.end, 0, &[_]u8{@intFromEnum(reason)}, nowNs());
            self.flushNow(nowNs());
        }
        if (self.recording) {
            self.recording = false;
            self.closeFd();
        }
    }

    fn closeFd(self: *Writer) void {
        if (self.fd >= 0) {
            _ = std.c.close(self.fd);
            self.fd = -1;
        }
    }
};

// ---------------------------------------------------------------------------
// The reader
// ---------------------------------------------------------------------------

pub const Event = struct {
    kind: Type,
    flags: u8,
    /// Microseconds from the start of the session.
    at_us: u64,
    /// Points into the caller's buffer; it must outlive the `Session`.
    payload: []const u8,
};

pub const Session = struct {
    header: Header,
    events: []Event,
    /// The offset at which the records stopped making sense, if they did.
    ///
    /// A recording is a file that a process was appending to when something
    /// stopped it, so a torn tail is a normal outcome, not a corruption. What
    /// is *not* done here is resynchronisation: a reader that went looking
    /// for the next plausible record header would find one in the payload of
    /// a truncated record roughly whenever it looked, and would then report
    /// invented events with confidence. Stopping is the honest answer.
    truncated_at: ?u64 = null,
    /// An `end` record was seen. Its absence means the writer never got to
    /// close the file -- a crash, a kill, a full disk.
    closed_cleanly: bool = false,
    end_reason: ?EndReason = null,
    /// The byte offset one past the last record read, and the timestamp it
    /// left off at. A live file grows while the window is open, and L1 reads
    /// the tail with `parseFrom` rather than parsing the whole thing again
    /// every time the user seeks.
    next_offset: u64 = 0,
    last_at_us: u64 = 0,

    pub fn deinit(self: *Session, alloc: std.mem.Allocator) void {
        alloc.free(self.events);
        self.* = undefined;
    }

    pub fn count(self: Session, kind: Type) usize {
        var n: usize = 0;
        for (self.events) |e| {
            if (e.kind == kind) n += 1;
        }
        return n;
    }

    pub fn redactions(self: Session) usize {
        var n: usize = 0;
        for (self.events) |e| {
            if (e.flags & flag_redacted != 0) n += 1;
        }
        return n;
    }
};

/// Records only, from `start`. What `parse` uses, and what L1 uses to extend a
/// session it has already read.
///
/// The caller says where the record stream begins and what the clock had
/// reached there -- `Session.next_offset` and `Session.last_at_us` from the
/// previous read, or `header_len` and 0 for a fresh file. Getting `at_us_base`
/// wrong makes every timestamp in the tail wrong, which is why it is a
/// parameter rather than something guessed from the bytes.
///
/// Payloads point into `bytes`, which must outlive the events. Extending a
/// session therefore appends events pointing into a *second* buffer, and both
/// have to be kept: nothing here copies a payload.
pub const Tail = struct {
    events: []Event,
    next_offset: u64,
    last_at_us: u64,
    truncated_at: ?u64 = null,
    closed_cleanly: bool = false,
    end_reason: ?EndReason = null,
};

pub fn parseFrom(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    start: usize,
    at_us_base: u64,
) !Tail {
    var events: std.ArrayList(Event) = .empty;
    errdefer events.deinit(alloc);

    var out = Tail{ .events = &.{}, .next_offset = start, .last_at_us = at_us_base };
    var off: usize = start;
    var at_us: u64 = at_us_base;

    while (off < bytes.len) {
        // Fewer than eight bytes left is a torn header, not a short record.
        if (bytes.len - off < record_header_len) {
            out.truncated_at = off;
            break;
        }
        const kind: Type = @enumFromInt(bytes[off]);
        const flags = bytes[off + 1];
        const len = std.mem.readInt(u16, bytes[off + 2 ..][0..2], .little);
        const dt = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little);
        const body = off + record_header_len;
        if (body + len > bytes.len) {
            out.truncated_at = off;
            break;
        }

        at_us += dt;
        try events.append(alloc, .{
            .kind = kind,
            .flags = flags,
            .at_us = at_us,
            .payload = bytes[body..][0..len],
        });
        off = body + len;
        out.next_offset = off;

        if (kind == .end) {
            out.closed_cleanly = true;
            if (len >= 1) out.end_reason = @enumFromInt(bytes[body]);
            // Nothing follows an end record. If something does, this file is
            // two recordings in a trench coat and the rest is not ours.
            if (off < bytes.len) out.truncated_at = off;
            break;
        }
    }

    out.last_at_us = at_us;
    out.events = try events.toOwnedSlice(alloc);
    return out;
}

/// Take a `.trec` apart. `bytes` must outlive the returned `Session`, whose
/// payloads point into it.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !Session {
    const header = try Header.decode(bytes);
    const tail = try parseFrom(alloc, bytes, header_len, 0);
    return .{
        .header = header,
        .events = tail.events,
        .truncated_at = tail.truncated_at,
        .closed_cleanly = tail.closed_cleanly,
        .end_reason = tail.end_reason,
        .next_offset = tail.next_offset,
        .last_at_us = tail.last_at_us,
    };
}

/// Read a whole `.trec` into memory. The caller frees the slice.
pub fn readFile(alloc: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var path_z: [std.c.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path_z, "{s}", .{path}) catch return error.PathTooLong;

    const fd = std.c.open(p.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return error.StatFailed;
    const size: usize = @intCast(@max(st.size, 0));
    if (size > limit) return error.FileTooBig;

    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    var got: usize = 0;
    while (got < size) {
        const rc = std.c.read(fd, buf[got..].ptr, size - got);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return error.ReadFailed;
        }
        if (rc == 0) break;
        got += @intCast(rc);
    }
    return alloc.realloc(buf, got) catch buf[0..got];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A scratch directory under the system temp dir, removed by the caller.
fn tempDir(buf: []u8, tag: []const u8) []const u8 {
    const pid = std.c.getpid();
    return std.fmt.bufPrint(buf, "/tmp/doot-rec-test-{s}-{d}-{d}", .{
        tag, pid, nowNs() % 1_000_000,
    }) catch unreachable;
}

fn removeTree(dir: []const u8) void {
    var dir_z: [std.c.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrintZ(&dir_z, "{s}", .{dir}) catch return;
    if (std.c.opendir(p.ptr)) |dp| {
        while (std.c.readdir(dp)) |ent| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var child: [std.c.PATH_MAX]u8 = undefined;
            const c = std.fmt.bufPrintZ(&child, "{s}/{s}", .{ dir, name }) catch continue;
            _ = std.c.unlink(c.ptr);
        }
        _ = std.c.closedir(dp);
    }
    _ = std.c.rmdir(p.ptr);
}

fn readBack(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return readFile(alloc, path, 64 << 20);
}

/// A file's mtime in nanoseconds, so "did the mtime move" is answerable
/// without waiting a second for a coarser clock to tick.
fn mtimeNs(path: []const u8) !i128 {
    var path_z: [std.c.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path_z, "{s}", .{path}) catch return error.PathTooLong;
    const fd = std.c.open(p.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return error.StatFailed;
    const ts = st.mtime();
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn dirMode(path: []const u8) !u32 {
    var path_z: [std.c.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path_z, "{s}", .{path}) catch return error.PathTooLong;
    const fd = std.c.open(p.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return error.StatFailed;
    return st.mode & 0o777;
}

/// Burn `ms` of wall clock. Used where a test needs two filesystem
/// timestamps to be distinguishable and nothing else has to happen in
/// between; a sleep would be politer, and `std.Thread.sleep` is not
/// something this file should reach for to wait twenty milliseconds.
fn spin(ms: u64) void {
    const until = nowNs() + ms * std.time.ns_per_ms;
    while (nowNs() < until) {}
}

test "a recording round-trips through the reader" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "round");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 100, .rows = 30 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);

    const t0 = nowNs();
    w.output("hello ", t0);
    w.output("world", t0 + 1000);
    w.resize(80, 24, t0 + 2000);
    w.focus(false, t0 + 3000);
    w.control(.full_reset, t0 + 4000);
    w.close(.clean);
    w.deinit();

    const bytes = try readBack(testing.allocator, path);
    defer testing.allocator.free(bytes);
    var s = try parse(testing.allocator, bytes);
    defer s.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 100), s.header.cols);
    try testing.expectEqual(@as(u16, 30), s.header.rows);
    try testing.expect(s.closed_cleanly);
    try testing.expectEqual(EndReason.clean, s.end_reason.?);
    try testing.expectEqual(@as(?u64, null), s.truncated_at);

    // Both reads come back, in order, with nothing lost to the hold.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    for (s.events) |e| {
        if (e.kind == .output) try out.appendSlice(testing.allocator, e.payload);
    }
    try testing.expectEqualStrings("hello world", out.items);

    try testing.expectEqual(@as(usize, 1), s.count(.resize));
    try testing.expectEqual(@as(usize, 1), s.count(.focus));
    try testing.expectEqual(@as(usize, 1), s.count(.control));
    try testing.expectEqual(@as(usize, 0), s.count(.input));
}

test "the events land in the order they were recorded" {
    // The hold delays an output record, and a resize or a control that
    // followed it must still come after it in the file. Getting this wrong
    // is invisible until a replay diverges.
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "order");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 10, .rows = 3 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);

    const t0 = nowNs();
    w.output("A", t0);
    w.resize(20, 4, t0 + 100); // must not overtake "A"
    w.output("B", t0 + 200);
    w.control(.full_reset, t0 + 300); // must not overtake "B"
    w.close(.clean);
    w.deinit();

    const bytes = try readBack(testing.allocator, path);
    defer testing.allocator.free(bytes);
    var s = try parse(testing.allocator, bytes);
    defer s.deinit(testing.allocator);

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);
    for (s.events) |e| switch (e.kind) {
        .output => try seen.appendSlice(testing.allocator, e.payload),
        .resize => try seen.append(testing.allocator, 'R'),
        .control => try seen.append(testing.allocator, 'C'),
        else => {},
    };
    try testing.expectEqualStrings("ARBC", seen.items);
}

test "input is not recorded unless it was asked for" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "noinput");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 10, .rows = 3 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);

    w.input("hunter2\n", nowNs());
    w.output("prompt$ ", nowNs());
    w.close(.clean);
    w.deinit();

    const bytes = try readBack(testing.allocator, path);
    defer testing.allocator.free(bytes);

    // Asserted over the whole file, not by reading a flag back: a flag says
    // what the writer believed, and the question is what is on the disk.
    try testing.expect(std.mem.indexOf(u8, bytes, "hunter2") == null);
    var s = try parse(testing.allocator, bytes);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), s.count(.input));
}

test "input is recorded when it was" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "input");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 10, .rows = 3, .record_input = true });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);
    w.input("ls\n", nowNs());
    w.close(.clean);
    w.deinit();

    const bytes = try readBack(testing.allocator, path);
    defer testing.allocator.free(bytes);
    var s = try parse(testing.allocator, bytes);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), s.count(.input));
    try testing.expectEqualStrings("ls\n", s.events[0].payload);
}

test "toggling input recording mid-session takes effect at once" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "toggle");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 10, .rows = 3 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);

    w.input("BEFORE", nowNs());
    w.record_input = true;
    w.input("DURING", nowNs());
    w.record_input = false;
    w.input("AFTER", nowNs());
    w.close(.clean);
    w.deinit();

    const bytes = try readBack(testing.allocator, path);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "BEFORE") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "DURING") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "AFTER") == null);
}

// -- redaction and the straddle ------------------------------------------

test "a secret split at every offset is redacted" {
    // The test the one-read delay exists for, written against every possible
    // boundary rather than the one someone thought of. Two modes fail without
    // the hold: the prefix itself is split, and -- worse -- the whole prefix
    // lands in the first read with the run continuing into the second, where
    // `scrub` sees a run below `min_run` and skips it entirely.
    const secret = "session_015fCwM6faCRNYfgauovyEUw";
    const line = "banner: " ++ secret ++ " end\n";

    for (1..line.len) |split| {
        var dir_buf: [256]u8 = undefined;
        const dir = tempDir(&dir_buf, "straddle");
        defer removeTree(dir);

        var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
        const path = try testing.allocator.dupe(u8, w.path);
        defer testing.allocator.free(path);

        const t = nowNs();
        w.output(line[0..split], t);
        w.output(line[split..], t + 1000);
        w.close(.clean);
        w.deinit();

        const bytes = try readBack(testing.allocator, path);
        defer testing.allocator.free(bytes);

        if (std.mem.indexOf(u8, bytes, "015fCwM6") != null) {
            std.debug.print("secret survived a split at offset {d}\n", .{split});
            return error.SecretLeakedAcrossReads;
        }

        // The rest of the line is untouched, which is the other half of the
        // promise: a recording is a faithful record of everything else. The
        // check is on the joined payloads rather than on the file, because a
        // record boundary sits wherever the split was.
        var s = try parse(testing.allocator, bytes);
        defer s.deinit(testing.allocator);
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(testing.allocator);
        for (s.events) |e| {
            if (e.kind == .output) try joined.appendSlice(testing.allocator, e.payload);
        }
        try testing.expectEqualStrings("banner: session_" ++ "x" ** 24 ++ " end\n", joined.items);
    }
}

test "the redacted flag lands on the record that changed" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "flag");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);

    const t = nowNs();
    w.output("clean line\n", t);
    w.output("ghp_ABCDEFGHIJKLMNOPQRSTUV\n", t + 1000);
    w.output("clean again\n", t + 2000);
    try testing.expectEqual(@as(u64, 1), w.stats.redactions);
    w.close(.clean);
    w.deinit();

    const bytes = try readBack(testing.allocator, path);
    defer testing.allocator.free(bytes);
    var s = try parse(testing.allocator, bytes);
    defer s.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), s.redactions());
    for (s.events) |e| {
        if (e.kind != .output) continue;
        const marked = e.flags & flag_redacted != 0;
        try testing.expectEqual(std.mem.indexOf(u8, e.payload, "ghp_") != null, marked);
    }
}

test "a token spanning three reads keeps its tail -- the documented limit" {
    // Asserted so that improving it is a deliberate change with a failing
    // test to update, rather than something nobody notices either way.
    // `min_run` still catches the head, so what escapes is the far end of a
    // token long enough to cross two boundaries.
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "three");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);

    const t = nowNs();
    w.output("session_0123456789ab", t); // prefix plus min_run, complete
    w.output("MIDDLEPART", t + 1000);
    w.output("TAILPART end\n", t + 2000);
    w.close(.clean);
    w.deinit();

    const bytes = try readBack(testing.allocator, path);
    defer testing.allocator.free(bytes);
    // The head is redacted...
    try testing.expect(std.mem.indexOf(u8, bytes, "0123456789ab") == null);
    // ...and the third read's share of the token is not. This is the limit.
    try testing.expect(std.mem.indexOf(u8, bytes, "TAILPART") != null);
}

test "the flush timer drains the held read" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "drain");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);

    const t = nowNs();
    w.output("held\n", t);
    // Nothing on disk yet: the read is held and the buffer is unflushed.
    const early = try readBack(testing.allocator, path);
    defer testing.allocator.free(early);
    try testing.expect(std.mem.indexOf(u8, early, "held") == null);

    w.maybeFlush(t + flush_after_ns + 1);
    const late = try readBack(testing.allocator, path);
    defer testing.allocator.free(late);
    try testing.expect(std.mem.indexOf(u8, late, "held") != null);

    w.close(.clean);
    w.deinit();
}

// -- timing ----------------------------------------------------------------

test "deltas do not drift, however many records there are" {
    // The bug this is here for: `(now - last) / 1000` throws the
    // sub-microsecond remainder away on every record, and at a terminal's
    // write rates that compounds into about 4% of the session going missing.
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "drift");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);

    // 20,000 records 1,500 ns apart: half a microsecond dropped each time,
    // which is a third of the elapsed time if the truncation accumulates.
    const step_ns = 1_500;
    const n = 20_000;
    const base = w.base_ns;
    for (1..n + 1) |i| w.output("x", base + i * step_ns);
    w.close(.clean);
    w.deinit();

    const bytes = try readBack(testing.allocator, path);
    defer testing.allocator.free(bytes);
    var s = try parse(testing.allocator, bytes);
    defer s.deinit(testing.allocator);

    // The last output record was held until close, so it carries the
    // timestamp of read n. Expected elapsed: n * 1500 ns = 30,000 us.
    var last_output_us: u64 = 0;
    for (s.events) |e| {
        if (e.kind == .output) last_output_us = e.at_us;
    }
    const expect_us = n * step_ns / 1000;
    const err = if (last_output_us > expect_us) last_output_us - expect_us else expect_us - last_output_us;
    // One microsecond for the whole file, not one per record.
    try testing.expect(err <= 1);
}

test "a gap longer than a u32 of microseconds is bridged by ticks" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "tick");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);

    const base = w.base_ns;
    w.output("before", base);
    // Three hours: two and a half times what a u32 of microseconds holds.
    const gap_ns: u64 = 3 * 60 * 60 * std.time.ns_per_s;
    w.output("after", base + gap_ns);
    w.close(.clean);
    w.deinit();

    const bytes = try readBack(testing.allocator, path);
    defer testing.allocator.free(bytes);
    var s = try parse(testing.allocator, bytes);
    defer s.deinit(testing.allocator);

    try testing.expect(s.count(.tick) >= 2);
    var last_us: u64 = 0;
    for (s.events) |e| {
        if (e.kind == .output and std.mem.eql(u8, e.payload, "after")) last_us = e.at_us;
    }
    try testing.expectEqual(gap_ns / 1000, last_us);
}

test "an idle session still writes, so a sweep cannot delete it out from under itself" {
    // The bug: `flushNow` returns without a `write(2)` when nothing is
    // buffered, so a window left at a prompt has a frozen mtime. `sweep`
    // goes by mtime *because* mtime is supposed to be self-protecting, so
    // after `retain_days` another instance unlinked a file whose writer was
    // still holding it open and still appending -- to a nameless inode.
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "idle");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);

    // Get the header onto the disk, so there is an mtime to move.
    w.maybeFlush(w.last_flush_ns + flush_after_ns + 1);
    const early = try readBack(testing.allocator, path);
    defer testing.allocator.free(early);
    try testing.expect(early.len > 0);
    const before = try mtimeNs(path);

    spin(20);

    // The reader loop's own shape, which is the only shape this can be got
    // wrong in: a wake-up every 100 ms with a silent child, for two minutes
    // of it. Jumping the clock straight to `idle_tick_ns` would pass even if
    // every one of these no-op flushes moved `last_write_ns` -- and that is
    // exactly the mistake, because a no-op flush touches no inode.
    const start = w.last_write_ns;
    var at = start;
    while (at <= start + 2 * idle_tick_ns) : (at += 100 * std.time.ns_per_ms) {
        w.maybeFlush(at);
    }
    try testing.expect(try mtimeNs(path) > before);

    const late = try readBack(testing.allocator, path);
    defer testing.allocator.free(late);
    try testing.expect(late.len > early.len);
    var s = try parse(testing.allocator, late);
    defer s.deinit(testing.allocator);
    // Two minutes, two ticks -- and nothing else. The format already has a
    // tick for a gap; inventing a record type for a keepalive would be
    // inventing an event. One per second would be a write loop.
    try testing.expectEqual(@as(usize, 2), s.count(.tick));
    try testing.expectEqual(@as(usize, 2), s.events.len);

    w.close(.clean);
    w.deinit();
}

test "an out-of-band record never writes, however full the buffer is" {
    // `resize` and `control` are emitted from the *main* thread with the
    // terminal mutex held. Before the reserved tail existed, one that landed
    // on a nearly-full buffer performed a 64 KiB `write(2)` inside that
    // critical section -- 2,234-5,578 µs measured, four orders of magnitude
    // above the 12-byte append it is supposed to be, and exactly the stall
    // sprint 1 exists to prevent.
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "oob");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);

    // Fill the way a program printing at pty speed does, until one more
    // record of that size would cross the ordinary limit.
    const chunk = [_]u8{'z'} ** 1024;
    const t = nowNs();
    var i: usize = 0;
    while (w.used + record_header_len + chunk.len <= buf_usable) : (i += 1) {
        w.output(&chunk, t + i * 1000);
    }
    // So there really is a held read waiting, and draining it really would
    // have crossed the line. Without both, this test proves nothing.
    try testing.expectEqual(chunk.len, w.hold_len);
    try testing.expect(w.used + record_header_len + chunk.len > buf_usable);

    const flushes = w.stats.flushes;
    const bytes_before = w.stats.bytes;
    w.resize(60, 12, t + 1_000_000);
    w.control(.full_reset, t + 1_001_000);
    w.focus(false, t + 1_002_000);

    try testing.expectEqual(flushes, w.stats.flushes);
    try testing.expectEqual(bytes_before, w.stats.bytes);
    // All of it went into the reserved tail rather than onto the disk.
    try testing.expect(w.used > buf_usable);

    // The next ordinary record is what pays for it, on the reader thread.
    w.output("A", t + 2_000_000);
    w.output("B", t + 2_001_000);
    try testing.expect(w.stats.flushes > flushes);

    w.close(.clean);
    w.deinit();

    // And the ordering the drain exists for survived: the held read is in
    // front of the three out-of-band records, not behind them.
    const bytes = try readBack(testing.allocator, path);
    defer testing.allocator.free(bytes);
    var s = try parse(testing.allocator, bytes);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), s.count(.resize));
    try testing.expectEqual(@as(usize, 1), s.count(.control));
    try testing.expectEqual(@as(usize, 1), s.count(.focus));
    var last_output: usize = 0;
    var first_oob: usize = s.events.len;
    for (s.events, 0..) |e, idx| switch (e.kind) {
        .output => last_output = idx,
        .resize, .control, .focus => first_oob = @min(first_oob, idx),
        else => {},
    };
    try testing.expect(first_oob < last_output);
    try testing.expectEqualStrings("z" ** 1024, s.events[first_oob - 1].payload);
}

// -- failure -------------------------------------------------------------

test "a torn tail is reported, not resynchronised" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "torn");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);
    const t = nowNs();
    w.output("first record", t);
    w.output("second record", t + 1000);
    w.close(.clean);
    w.deinit();

    const whole = try readBack(testing.allocator, path);
    defer testing.allocator.free(whole);

    // Cut at every offset past the header and check nothing is invented.
    var cut: usize = header_len;
    while (cut < whole.len) : (cut += 1) {
        var s = try parse(testing.allocator, whole[0..cut]);
        defer s.deinit(testing.allocator);
        for (s.events) |e| {
            // Every event reported must lie wholly inside what was read.
            const end = @intFromPtr(e.payload.ptr) + e.payload.len;
            try testing.expect(end <= @intFromPtr(whole.ptr) + cut);
        }
        // A cut that happens to land on a record boundary is a clean
        // prefix, not a tear; only an incomplete record at the end is one.
    }

    // Half a record header left is a torn tail, and says so.
    var s = try parse(testing.allocator, whole[0 .. header_len + 3]);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), s.events.len);
    try testing.expectEqual(@as(?u64, header_len), s.truncated_at);
    try testing.expect(!s.closed_cleanly);
}

test "a file with no end record is not closed cleanly" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "noend");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);
    w.output("some output", nowNs());
    w.maybeFlush(nowNs() + flush_after_ns + 1);
    // No close: the process died here.
    _ = std.c.close(w.fd);
    w.fd = -1;
    w.recording = false;
    w.deinit();

    const bytes = try readBack(testing.allocator, path);
    defer testing.allocator.free(bytes);
    var s = try parse(testing.allocator, bytes);
    defer s.deinit(testing.allocator);
    try testing.expect(!s.closed_cleanly);
    try testing.expectEqual(@as(?EndReason, null), s.end_reason);
    try testing.expect(s.events.len > 0);
}

test "a header that has been tampered with is refused" {
    const h = Header{ .cols = 80, .rows = 24, .wall_start_ns = 1, .session_id = @splat(7) };
    var b = h.encode();
    _ = try Header.decode(&b);

    b[12] ^= 0xff; // cols, inside the crc'd range
    try testing.expectError(Error.BadHeaderChecksum, Header.decode(&b));

    b[12] ^= 0xff;
    b[0] = 'X';
    try testing.expectError(Error.NotARecording, Header.decode(&b));

    try testing.expectError(Error.ShortHeader, Header.decode(b[0..10]));
}

test "a write error stops the recording and does not retry" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "wfail");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);

    // Take the descriptor out from under it, which is the cheapest honest
    // stand-in for a disk that has gone away.
    _ = std.c.close(w.fd);

    const t = nowNs();
    w.output("one", t);
    w.output("two", t + 1000);
    w.maybeFlush(t + flush_after_ns + 1);

    try testing.expect(!w.recording);
    try testing.expectEqual(@as(i32, -1), w.fd);

    // Everything after is a no-op rather than a crash: the terminal keeps
    // running when its recorder does not.
    w.output("three", t + 2000);
    w.input("four", t + 3000);
    w.resize(1, 1, t + 4000);
    w.control(.full_reset, t + 5000);
    w.close(.clean);
    w.deinit();

    const bytes = try readBack(testing.allocator, path);
    defer testing.allocator.free(bytes);
    // Not a byte reached the disk: the header was still in the buffer when
    // the first flush failed, and nothing is ever retried. A zero-length
    // `.trec` is a legible outcome -- `parse` refuses it as not a recording
    // rather than reporting an empty one.
    try testing.expectEqual(@as(usize, 0), bytes.len);
    try testing.expectError(Error.ShortHeader, parse(testing.allocator, bytes));
}

test "a write error reads as 'not closed cleanly', not as an end record" {
    // What `fail` actually achieves, pinned rather than assumed. It makes one
    // best-effort attempt at `end(write_error)`; on the failure it is named
    // for -- a disk with no space -- the descriptor that refused the flush
    // refuses those nine bytes too. So the file carries the bytes that were
    // already down, no `end` record, and `closed_cleanly == false`. That last
    // one is the signal. Nothing in this file should claim more.
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "wfail2");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);

    const t = nowNs();
    w.output("KEPT-ONE", t);
    w.output("KEPT-TWO", t + 1000);
    w.maybeFlush(t + flush_after_ns + 1);
    try testing.expect(w.stats.bytes > 0); // a real flush really landed

    // Now take the disk away. Nothing else opens a file between here and the
    // failed write, so the descriptor number cannot have been reused.
    _ = std.c.close(w.fd);

    w.output("LOST-THREE", t + 2000);
    w.maybeFlush(t + 2 * flush_after_ns + 2);
    try testing.expect(!w.recording);

    w.close(.clean);
    w.deinit();

    const bytes = try readBack(testing.allocator, path);
    defer testing.allocator.free(bytes);
    var s = try parse(testing.allocator, bytes);
    defer s.deinit(testing.allocator);

    // The prefix that got there is intact and readable.
    try testing.expect(std.mem.indexOf(u8, bytes, "KEPT-ONE") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "KEPT-TWO") != null);
    // Nothing was retried, so the buffered record is simply gone.
    try testing.expect(std.mem.indexOf(u8, bytes, "LOST-THREE") == null);
    // And this is the whole of what a reader learns about the failure.
    try testing.expect(!s.closed_cleanly);
    try testing.expectEqual(@as(?EndReason, null), s.end_reason);
    try testing.expectEqual(@as(usize, 0), s.count(.end));
}

test "a geometry no writer could have produced is refused, not allocated from" {
    // Four bytes with no checksum behind them. At 65535 x 65535 that is 4.3
    // billion cells -- about 68 GB -- and the reader used to hand them
    // straight to `Terminal.resize`.
    var h = Header{ .cols = max_dim, .rows = max_dim, .wall_start_ns = 1, .session_id = @splat(3) };
    _ = try Header.decode(&h.encode());

    h.cols = max_dim + 1;
    try testing.expectError(Error.GeometryOutOfRange, Header.decode(&h.encode()));
    h.cols = 80;
    h.rows = std.math.maxInt(u16);
    try testing.expectError(Error.GeometryOutOfRange, Header.decode(&h.encode()));

    // The writer holds the same bound, so refusing it costs no readable file.
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "geom");
    defer removeTree(dir);
    try testing.expectError(
        Error.GeometryOutOfRange,
        Writer.open(testing.allocator, dir, .{ .cols = max_dim + 1, .rows = 24 }),
    );

    // And a `resize` record cannot carry one either.
    var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);
    w.resize(std.math.maxInt(u16), std.math.maxInt(u16), nowNs());
    w.close(.clean);
    w.deinit();

    const bytes = try readBack(testing.allocator, path);
    defer testing.allocator.free(bytes);
    var s = try parse(testing.allocator, bytes);
    defer s.deinit(testing.allocator);
    for (s.events) |e| {
        if (e.kind != .resize) continue;
        try testing.expectEqual(max_dim, std.mem.readInt(u16, e.payload[0..2], .little));
        try testing.expectEqual(max_dim, std.mem.readInt(u16, e.payload[2..4], .little));
    }
}

test "the size cap ends the session rather than filling the disk" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "cap");
    defer removeTree(dir);

    const cap = 128 * 1024;
    var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24, .size_cap = cap });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);

    const chunk = [_]u8{'z'} ** 4096;
    const t = nowNs();
    for (0..200) |i| w.output(&chunk, t + i * 1000);
    try testing.expect(!w.recording);
    w.deinit();

    const bytes = try readBack(testing.allocator, path);
    defer testing.allocator.free(bytes);
    var s = try parse(testing.allocator, bytes);
    defer s.deinit(testing.allocator);
    try testing.expect(s.closed_cleanly);
    try testing.expectEqual(EndReason.size_cap, s.end_reason.?);
    // Overshoot is bounded by one buffer plus one record, not unbounded.
    try testing.expect(bytes.len < cap + buf_capacity + max_payload);
}

// -- the disk ------------------------------------------------------------

test "the file is 0600 in a 0700 directory, created that way" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "modes");
    defer removeTree(dir);

    var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    var st: std.c.Stat = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.fstat(w.fd, &st));
    try testing.expectEqual(@as(u32, 0o600), st.mode & 0o777);
    w.close(.clean);
    w.deinit();

    var dir_z: [std.c.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrintZ(&dir_z, "{s}", .{dir}) catch unreachable;
    const dfd = std.c.open(p.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    try testing.expect(dfd >= 0);
    defer _ = std.c.close(dfd);
    var dst: std.c.Stat = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.fstat(dfd, &dst));
    try testing.expectEqual(@as(u32, 0o700), dst.mode & 0o777);
}

test "a sessions directory that already exists is tightened to 0700" {
    // `EEXIST` counted as success and the mode went unchecked, so a
    // `chmod 0777` on an existing record directory stuck: start times,
    // session-id prefixes, sizes and counts, all world-listable, which is
    // precisely what `makeDir`'s own comment says the mode is there to stop.
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "loose");
    defer removeTree(dir);

    var dir_z: [std.c.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrintZ(&dir_z, "{s}", .{dir}) catch unreachable;
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(p.ptr, 0o777));
    // Said again through chmod, because umask trims the mkdir mode.
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(p.ptr, 0o777));
    try testing.expectEqual(@as(u32, 0o777), try dirMode(dir));

    try testing.expect(makeDir(dir));
    try testing.expectEqual(@as(u32, 0o700), try dirMode(dir));

    // And through the door a session actually comes in by.
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(p.ptr, 0o755));
    var w = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    w.close(.clean);
    w.deinit();
    try testing.expectEqual(@as(u32, 0o700), try dirMode(dir));
}

test "a name collision fails rather than appending to somebody else's session" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "excl");
    defer removeTree(dir);
    try testing.expect(makeDir(dir));

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/taken.trec", .{dir}) catch unreachable;

    var first = try Writer.openPath(testing.allocator, path, .{ .cols = 80, .rows = 24 });
    defer first.deinit();
    try testing.expectError(
        error.RecordFileUnavailable,
        Writer.openPath(testing.allocator, path, .{ .cols = 80, .rows = 24 }),
    );
}

test "the retention sweep goes by mtime and keeps what is inside the window" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "sweep");
    defer removeTree(dir);
    try testing.expect(makeDir(dir));

    var fresh = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    const fresh_path = try testing.allocator.dupe(u8, fresh.path);
    defer testing.allocator.free(fresh_path);
    fresh.output("recent", nowNs());
    fresh.close(.clean);
    fresh.deinit();

    const now_s = @divFloor(wallNs(), std.time.ns_per_s);

    // Nothing is old enough yet.
    try testing.expectEqual(@as(usize, 0), sweep(dir, default_retain_days, now_s));
    const still_there = try readBack(testing.allocator, fresh_path);
    testing.allocator.free(still_there);
    try testing.expect(still_there.len > 0);

    // Pretend "now" is a month later, which is the same arithmetic as the
    // file being a month old without having to fake an mtime.
    const later = now_s + 30 * 24 * 60 * 60;
    try testing.expectEqual(@as(usize, 1), sweep(dir, default_retain_days, later));
    try testing.expectError(error.FileNotFound, readBack(testing.allocator, fresh_path));

    // Zero means forever, whatever the dates say.
    var again = try Writer.open(testing.allocator, dir, .{ .cols = 80, .rows = 24 });
    again.close(.clean);
    again.deinit();
    try testing.expectEqual(@as(usize, 0), sweep(dir, 0, later));
}

test "a disabled recorder writes nothing and never touches a file" {
    var w = Writer.disabled(testing.allocator);
    defer w.deinit();
    try testing.expect(!w.recording);
    w.output("nothing", nowNs());
    w.input("nothing", nowNs());
    w.record_input = true;
    w.input("still nothing", nowNs());
    w.resize(1, 1, nowNs());
    w.focus(true, nowNs());
    w.control(.full_reset, nowNs());
    w.maybeFlush(nowNs());
    w.close(.clean);
    try testing.expectEqual(@as(u64, 0), w.stats.bytes);
    try testing.expectEqual(@as(u64, 0), w.stats.records);
}

test "a timestamp formats as the filename says it does" {
    var buf: [20]u8 = undefined;
    // 2026-08-29T14:03:11Z
    try testing.expectEqualStrings("2026-08-29T14-03-11Z", stampUtc(&buf, 1788012191));
    try testing.expectEqualStrings("1970-01-01T00-00-00Z", stampUtc(&buf, 0));
    try testing.expectEqualStrings("1970-01-01T00-00-00Z", stampUtc(&buf, -1));
}

test "session ids differ between sessions" {
    const a = randomId();
    const b = randomId();
    try testing.expect(!std.mem.eql(u8, &a, &b));
}
