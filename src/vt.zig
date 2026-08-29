//! The VT/ANSI escape-sequence parser.
//!
//! This is Paul Williams' DEC-compatible state machine
//! (https://vt100.net/emu/dec_ansi_parser), which is what every serious
//! terminal emulator is built on. Bytes go in; `print`, `execute`,
//! `csiDispatch`, `escDispatch` and `oscDispatch` callbacks come out.
//!
//! The parser owns no terminal state at all -- it doesn't know what a cursor
//! is. That separation is what makes it testable in isolation, and it's why
//! this file has unit tests that never touch a screen.

const std = @import("std");

pub const max_params = 32;
pub const max_intermediates = 4;
pub const max_osc = 4096;

const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    osc_string,
    /// DCS / SOS / PM / APC payloads. We swallow these until ST rather than
    /// act on them, which keeps sixel and DECRQSS from corrupting the screen.
    string_ignore,
};

pub const Parser = struct {
    state: State = .ground,

    params: [max_params]u16 = @splat(0),
    /// Whether each param was introduced by ':' (a sub-parameter) rather than
    /// ';'. SGR truecolor needs this: `38;2;R;G;B` and `38:2:CS:R:G:B` differ
    /// by a colorspace field that only the colon form carries.
    subs: [max_params]bool = @splat(false),
    n_params: usize = 0,
    has_params: bool = false,

    /// A private-marker byte ('?', '<', '=', '>') seen at the start of a CSI.
    private: u8 = 0,

    intermediates: [max_intermediates]u8 = @splat(0),
    n_intermediates: usize = 0,

    osc_buf: [max_osc]u8 = undefined,
    n_osc: usize = 0,

    /// Partial UTF-8 sequence carried across `advance` calls.
    utf8_cp: u21 = 0,
    utf8_need: u3 = 0,

    /// Drive the state machine over `bytes`.
    ///
    /// In the ground state a run of printable ASCII is handed to the handler
    /// as one slice through `printRun` rather than one `print` per byte. That
    /// is the common case by a wide margin -- `cat` of a source file is
    /// nothing else -- and it lets the terminal do one wrap check per row
    /// segment instead of re-deriving width and margins per character. The
    /// run stops at anything outside 0x20..0x7e, so ESC, controls and UTF-8
    /// lead bytes still go through `advance` exactly as before, and a run cut
    /// in two by a read boundary is indistinguishable from a whole one.
    pub fn feed(self: *Parser, handler: anytype, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            if (self.state == .ground and self.utf8_need == 0) {
                const start = i;
                while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x7e) i += 1;
                if (i > start) {
                    handler.printRun(bytes[start..i]);
                    continue;
                }
            }
            self.advance(handler, bytes[i]);
            i += 1;
        }
    }

    pub fn advance(self: *Parser, handler: anytype, b: u8) void {
        // ESC, CAN and SUB abort whatever is in flight, from any state.
        switch (b) {
            0x18, 0x1a => {
                self.utf8_need = 0;
                if (self.state == .osc_string) self.dispatchOsc(handler);
                self.state = .ground;
                handler.execute(b);
                return;
            },
            0x1b => {
                self.utf8_need = 0;
                if (self.state == .osc_string) self.dispatchOsc(handler);
                self.clear();
                self.state = .escape;
                return;
            },
            else => {},
        }

        switch (self.state) {
            .ground => self.ground(handler, b),
            .escape => self.escape(handler, b),
            .escape_intermediate => switch (b) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.execute(b),
                0x20...0x2f => self.collect(b),
                0x30...0x7e => {
                    handler.escDispatch(self.intermediates[0..self.n_intermediates], b);
                    self.state = .ground;
                },
                else => {},
            },
            .csi_entry => switch (b) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.execute(b),
                0x20...0x2f => {
                    self.collect(b);
                    self.state = .csi_intermediate;
                },
                0x30...0x39, 0x3a, 0x3b => {
                    self.param(b);
                    self.state = .csi_param;
                },
                0x3c...0x3f => {
                    self.private = b;
                    self.state = .csi_param;
                },
                0x40...0x7e => self.dispatchCsi(handler, b),
                else => {},
            },
            .csi_param => switch (b) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.execute(b),
                0x30...0x39, 0x3a, 0x3b => self.param(b),
                0x3c...0x3f => self.state = .csi_ignore,
                0x20...0x2f => {
                    self.collect(b);
                    self.state = .csi_intermediate;
                },
                0x40...0x7e => self.dispatchCsi(handler, b),
                else => {},
            },
            .csi_intermediate => switch (b) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.execute(b),
                0x20...0x2f => self.collect(b),
                0x30...0x3f => self.state = .csi_ignore,
                0x40...0x7e => self.dispatchCsi(handler, b),
                else => {},
            },
            .csi_ignore => switch (b) {
                0x40...0x7e => self.state = .ground,
                else => {},
            },
            .osc_string => switch (b) {
                0x07 => { // BEL terminates OSC, xterm-style
                    self.dispatchOsc(handler);
                    self.state = .ground;
                },
                0x20...0xff => {
                    if (self.n_osc < max_osc) {
                        self.osc_buf[self.n_osc] = b;
                        self.n_osc += 1;
                    }
                },
                else => {},
            },
            .string_ignore => {},
        }
    }

    fn ground(self: *Parser, handler: anytype, b: u8) void {
        // UTF-8 continuation of a codepoint started on a previous byte.
        if (self.utf8_need > 0) {
            if (b & 0xc0 == 0x80) {
                self.utf8_cp = (self.utf8_cp << 6) | (b & 0x3f);
                self.utf8_need -= 1;
                if (self.utf8_need == 0) handler.print(self.utf8_cp);
            } else {
                // Malformed. Emit a replacement char and reprocess this byte.
                self.utf8_need = 0;
                handler.print(0xfffd);
                self.ground(handler, b);
            }
            return;
        }

        switch (b) {
            0x00...0x1f => handler.execute(b),
            0x20...0x7e => handler.print(b),
            0x7f => {}, // DEL is ignored
            0xc2...0xdf => {
                self.utf8_cp = b & 0x1f;
                self.utf8_need = 1;
            },
            0xe0...0xef => {
                self.utf8_cp = b & 0x0f;
                self.utf8_need = 2;
            },
            0xf0...0xf4 => {
                self.utf8_cp = b & 0x07;
                self.utf8_need = 3;
            },
            else => handler.print(0xfffd), // 0x80..0xc1, 0xf5..0xff: invalid
        }
    }

    fn escape(self: *Parser, handler: anytype, b: u8) void {
        switch (b) {
            0x00...0x17, 0x19, 0x1c...0x1f => handler.execute(b),
            0x20...0x2f => {
                self.collect(b);
                self.state = .escape_intermediate;
            },
            // DCS, SOS, PM and APC all introduce a string payload we skip.
            'P', 'X', '^', '_' => self.state = .string_ignore,
            '[' => self.state = .csi_entry,
            ']' => self.state = .osc_string,
            0x30...0x4f, 0x51...0x57, 0x59, 0x5a, 0x5c, 0x60...0x7e => {
                handler.escDispatch(self.intermediates[0..self.n_intermediates], b);
                self.state = .ground;
            },
            else => {},
        }
    }

    fn clear(self: *Parser) void {
        self.params[0] = 0;
        self.subs[0] = false;
        self.n_params = 0;
        self.has_params = false;
        self.private = 0;
        self.n_intermediates = 0;
        self.n_osc = 0;
    }

    fn collect(self: *Parser, b: u8) void {
        if (self.n_intermediates < max_intermediates) {
            self.intermediates[self.n_intermediates] = b;
            self.n_intermediates += 1;
        }
    }

    fn param(self: *Parser, b: u8) void {
        self.has_params = true;
        if (b == ';' or b == ':') {
            if (self.n_params + 1 < max_params) {
                self.n_params += 1;
                self.params[self.n_params] = 0;
                self.subs[self.n_params] = (b == ':');
            }
            return;
        }
        const slot = &self.params[self.n_params];
        slot.* = std.math.mul(u16, slot.*, 10) catch 65535;
        slot.* = std.math.add(u16, slot.*, b - '0') catch 65535;
    }

    fn dispatchCsi(self: *Parser, handler: anytype, final: u8) void {
        const count = if (self.has_params) self.n_params + 1 else 0;
        handler.csiDispatch(.{
            .params = self.params[0..count],
            .subs = self.subs[0..count],
            .intermediates = self.intermediates[0..self.n_intermediates],
            .private = self.private,
            .final = final,
        });
        self.state = .ground;
    }

    fn dispatchOsc(self: *Parser, handler: anytype) void {
        if (self.n_osc > 0) handler.oscDispatch(self.osc_buf[0..self.n_osc]);
        self.n_osc = 0;
    }
};

pub const Csi = struct {
    params: []const u16,
    subs: []const bool,
    intermediates: []const u8,
    private: u8,
    final: u8,

    /// Parameter `i`, or `default` when absent or explicitly zero.
    /// VT semantics: an omitted or 0 parameter means "use the default".
    pub fn get(self: Csi, i: usize, default: u16) u16 {
        if (i >= self.params.len) return default;
        return if (self.params[i] == 0) default else self.params[i];
    }

    /// Parameter `i` with 0 preserved as a real value (for SGR, ED, EL...).
    pub fn raw(self: Csi, i: usize, default: u16) u16 {
        if (i >= self.params.len) return default;
        return self.params[i];
    }

    /// Was parameter `i` introduced by ':' rather than ';'?
    pub fn isSub(self: Csi, i: usize) bool {
        return i < self.subs.len and self.subs[i];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Recorder = struct {
    out: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,

    fn print(self: *Recorder, cp: u21) void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        self.out.appendSlice(self.alloc, buf[0..n]) catch {};
    }
    fn printRun(self: *Recorder, bytes: []const u8) void {
        self.out.appendSlice(self.alloc, bytes) catch {};
    }
    fn execute(self: *Recorder, b: u8) void {
        self.emit("<x{x:0>2}>", .{b});
    }
    fn escDispatch(self: *Recorder, _: []const u8, final: u8) void {
        self.emit("<esc {c}>", .{final});
    }
    fn oscDispatch(self: *Recorder, data: []const u8) void {
        self.emit("<osc {s}>", .{data});
    }
    fn csiDispatch(self: *Recorder, csi: Csi) void {
        self.emit("<csi", .{});
        if (csi.private != 0) self.emit(" {c}", .{csi.private});
        for (csi.params, 0..) |p, i| self.emit("{s}{d}", .{ if (csi.isSub(i)) ":" else " ", p });
        self.emit(" {c}>", .{csi.final});
    }
    fn emit(self: *Recorder, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.out.appendSlice(self.alloc, s) catch {};
    }
};

fn run(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var rec = Recorder{ .alloc = alloc };
    var p = Parser{};
    p.feed(&rec, input);
    return rec.out.toOwnedSlice(alloc);
}

test "plain ascii passes through" {
    const got = try run(testing.allocator, "hello");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello", got);
}

test "utf-8 is decoded across byte boundaries" {
    var rec = Recorder{ .alloc = testing.allocator };
    defer rec.out.deinit(testing.allocator);
    var p = Parser{};
    // A 3-byte codepoint delivered one byte at a time, as a real PTY would.
    p.feed(&rec, "\xe2");
    p.feed(&rec, "\x94");
    p.feed(&rec, "\x80");
    try testing.expectEqualStrings("\u{2500}", rec.out.items);
}

test "a printable run cut by a feed boundary reads the same as a whole one" {
    var rec = Recorder{ .alloc = testing.allocator };
    defer rec.out.deinit(testing.allocator);
    var p = Parser{};
    p.feed(&rec, "hel");
    p.feed(&rec, "lo \x1b[1mwor");
    p.feed(&rec, "ld\r\n");
    try testing.expectEqualStrings("hello <csi 1 m>world<x0d><x0a>", rec.out.items);
}

test "a printable run stops at a utf-8 lead byte and resumes after it" {
    // 0xc3 0xa9 is e-acute. The run must end before the lead byte, the
    // codepoint must decode through the slow path, and the run after it
    // must not be swallowed into the continuation.
    const got = try run(testing.allocator, "caf\xc3\xa9 ok");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("caf\u{e9} ok", got);
}

test "csi with parameters" {
    const got = try run(testing.allocator, "\x1b[1;31m");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("<csi 1 31 m>", got);
}

test "csi private marker" {
    const got = try run(testing.allocator, "\x1b[?1049h");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("<csi ? 1049 h>", got);
}

test "colon subparameters are recorded as sub-parameters" {
    const got = try run(testing.allocator, "\x1b[38:2::255:0:0m");
    defer testing.allocator.free(got);
    // ':' before a param marks it as a sub-parameter, so SGR can tell the
    // ITU truecolor form from the legacy one.
    try testing.expectEqualStrings("<csi 38:2:0:255:0:0 m>", got);
}

test "osc terminated by BEL and by ST" {
    const bel = try run(testing.allocator, "\x1b]0;title\x07");
    defer testing.allocator.free(bel);
    try testing.expectEqualStrings("<osc 0;title>", bel);

    const st = try run(testing.allocator, "\x1b]0;title\x1b\\");
    defer testing.allocator.free(st);
    try testing.expectEqualStrings("<osc 0;title><esc \\>", st);
}

test "DCS payloads are swallowed, not printed" {
    const got = try run(testing.allocator, "\x1bP1$r0m\x1b\\ok");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("<esc \\>ok", got);
}

test "escape mid-sequence abandons the old one" {
    const got = try run(testing.allocator, "\x1b[12\x1b[3m");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("<csi 3 m>", got);
}

test "control bytes execute while text flows around them" {
    const got = try run(testing.allocator, "a\r\nb");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("a<x0d><x0a>b", got);
}

test "csi default parameters" {
    const csi = Csi{
        .params = &.{ 0, 5 },
        .subs = &.{ false, false },
        .intermediates = &.{},
        .private = 0,
        .final = 'H',
    };
    try testing.expectEqual(@as(u16, 1), csi.get(0, 1)); // 0 means default
    try testing.expectEqual(@as(u16, 5), csi.get(1, 1));
    try testing.expectEqual(@as(u16, 1), csi.get(9, 1)); // absent means default
    try testing.expectEqual(@as(u16, 0), csi.raw(0, 1)); // raw keeps the 0
}
