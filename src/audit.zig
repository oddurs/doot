//! What agent CLIs actually ask a terminal to do, and what this one does
//! about it.
//!
//! A0 of docs/roadmap/agentic.md. Every sprint on that roadmap claims agents
//! need something. This feeds the recorded corpora through the real parser,
//! tallies every distinct sequence, and prints it beside what `terminal.zig`
//! does with it — so the claim has a source and the roadmap's table is
//! measured rather than remembered.
//!
//!   zig build audit
//!
//! The status column is a committed table below, not an inference: nothing
//! at run time can see whether a `switch` arm is the *right* arm. Anything
//! a corpus contains that the table does not mention is printed as
//! `unlisted`, which is the point — a new sequence from a new agent version
//! shows up as a question rather than as silence.

const std = @import("std");
const vt = @import("vt.zig");

const corpora = [_]struct { name: []const u8, bytes: []const u8 }{
    .{ .name = "agent-claude", .bytes = @embedFile("corpus_agent_claude") },
    .{ .name = "agent-stream", .bytes = @embedFile("corpus_agent_stream") },
    .{ .name = "altscreen", .bytes = @embedFile("corpus_altscreen") },
    .{ .name = "sgr", .bytes = @embedFile("corpus_sgr") },
    .{ .name = "region", .bytes = @embedFile("corpus_region") },
};

const Status = enum {
    /// Implemented, and doing what the sequence means.
    handled,
    /// Not implemented, and ignoring it is correct or harmless.
    ignored,
    /// Implemented as something else. The screen is wrong afterwards.
    mishandled,

    fn label(self: Status) []const u8 {
        return switch (self) {
            .handled => "handled",
            .ignored => "ignored",
            .mishandled => "MIS-HANDLED",
        };
    }
};

const Known = struct {
    /// The private-marker byte, 0 for none.
    private: u8 = 0,
    /// The first intermediate byte, 0 for none. `CSI SP @` is SL, not ICH.
    /// `csiDispatch` ignores any sequence carrying one (S0), so a row here
    /// says what the sequence means, not what happens to it.
    intermediate: u8 = 0,
    final: u8,
    status: Status,
    what: []const u8,
    note: []const u8 = "",
};

/// What `terminal.zig` does today. Keep this in step with `csiDispatch`.
const known_csi = [_]Known{
    .{ .final = 'A', .status = .handled, .what = "CUU cursor up" },
    .{ .final = 'B', .status = .handled, .what = "CUD cursor down" },
    .{ .final = 'C', .status = .handled, .what = "CUF cursor right" },
    .{ .final = 'D', .status = .handled, .what = "CUB cursor left" },
    .{ .final = 'E', .status = .handled, .what = "CNL next line" },
    .{ .final = 'F', .status = .handled, .what = "CPL previous line" },
    .{ .final = 'G', .status = .handled, .what = "CHA column" },
    .{ .final = 'H', .status = .handled, .what = "CUP position" },
    .{ .final = 'I', .status = .handled, .what = "CHT tab forward" },
    .{ .final = 'J', .status = .handled, .what = "ED erase display" },
    .{ .final = 'K', .status = .handled, .what = "EL erase line" },
    .{ .final = 'L', .status = .handled, .what = "IL insert lines" },
    .{ .final = 'M', .status = .handled, .what = "DL delete lines" },
    .{ .final = 'P', .status = .handled, .what = "DCH delete chars" },
    .{ .final = 'S', .status = .handled, .what = "SU scroll up" },
    .{ .final = 'T', .status = .handled, .what = "SD scroll down" },
    .{ .final = 'X', .status = .handled, .what = "ECH erase chars" },
    .{ .final = 'Z', .status = .handled, .what = "CBT tab back" },
    .{ .final = '@', .status = .handled, .what = "ICH insert chars" },
    .{ .final = '`', .status = .handled, .what = "HPA column" },
    .{ .final = 'd', .status = .handled, .what = "VPA row" },
    .{ .final = 'f', .status = .handled, .what = "HVP position" },
    .{ .final = 'g', .status = .handled, .what = "TBC clear tabs" },
    .{ .final = 'h', .status = .handled, .what = "SM set mode" },
    .{ .final = 'l', .status = .handled, .what = "RM reset mode" },
    .{ .final = 'm', .status = .handled, .what = "SGR" },
    .{ .final = 'n', .status = .handled, .what = "DSR status report" },
    .{ .final = 'r', .status = .handled, .what = "DECSTBM scroll region" },
    .{ .final = 's', .status = .handled, .what = "save cursor" },
    .{ .final = 'u', .status = .handled, .what = "restore cursor" },
    .{ .final = 'c', .status = .handled, .what = "DA device attributes" },

    .{ .private = '?', .final = 'h', .status = .handled, .what = "DEC set mode" },
    .{ .private = '?', .final = 'l', .status = .handled, .what = "DEC reset mode" },

    // The private-marker rows. `csiDispatch` used to switch on the final
    // byte without looking at `csi.private`, so these reached the arm for
    // the unprefixed sequence and did something unrelated (#28). S0 made
    // it ignore any private form it does not implement; A2 implements them.
    .{
        .private = '>',
        .final = 'm',
        .status = .ignored,
        .what = "xterm modifyOtherKeys",
        .note = "ignored until it is implemented; was mis-handled, see #28",
    },
    .{
        .private = '<',
        .final = 'u',
        .status = .ignored,
        .what = "kitty keyboard pop",
        .note = "ignored until it is implemented; was mis-handled, see #28",
    },
    .{
        .private = '>',
        .final = 'u',
        .status = .ignored,
        .what = "kitty keyboard push",
        .note = "ignored until it is implemented; was mis-handled, see #28",
    },
    .{
        .private = '=',
        .final = 'u',
        .status = .ignored,
        .what = "kitty keyboard set",
        .note = "ignored until it is implemented; was mis-handled, see #28",
    },
    .{
        .private = '?',
        .final = 'u',
        .status = .ignored,
        .what = "kitty keyboard query",
        .note = "ignored until it is implemented; was mis-handled, see #28",
    },
    .{
        .private = '>',
        .final = 'q',
        .status = .ignored,
        .what = "XTVERSION query",
        .note = "no reply; the agent waits out its timeout",
    },
    .{
        .private = '?',
        .final = 'q',
        .status = .ignored,
        .what = "DECSCUSR-adjacent query",
        .note = "no reply",
    },
    .{ .private = '>', .final = 'c', .status = .ignored, .what = "secondary DA", .note = "no reply" },
    .{ .private = '?', .final = 'n', .status = .handled, .what = "DECXCPR cursor report", .note = "replies `CSI ? r ; c R`" },
    .{ .private = '?', .final = 'J', .status = .handled, .what = "DECSED selective erase", .note = "ED: nothing is protected without DECSCA" },
    .{ .private = '?', .final = 'K', .status = .handled, .what = "DECSEL selective erase", .note = "EL, likewise" },
    .{ .private = '>', .final = 'K', .status = .ignored, .what = "xterm key resource" },

    // Intermediate-bearing forms. `csiDispatch` reads neither the private
    // marker nor the intermediates, so these run the plain final byte's arm.
    .{
        .intermediate = ' ',
        .final = '@',
        .status = .ignored,
        .what = "SL scroll left",
        .note = "ignored until it is implemented; was mis-handled, see #28",
    },
    .{
        .intermediate = ' ',
        .final = 'A',
        .status = .ignored,
        .what = "SR scroll right",
        .note = "ignored until it is implemented; was mis-handled, see #28",
    },
    .{
        .intermediate = ' ',
        .final = 'q',
        .status = .ignored,
        .what = "DECSCUSR cursor shape",
        .note = "wanted by X3",
    },
};

const known_osc = [_]struct { code: u16, status: Status, what: []const u8, note: []const u8 = "" }{
    .{ .code = 0, .status = .handled, .what = "icon + window title" },
    .{ .code = 1, .status = .ignored, .what = "icon title" },
    .{ .code = 2, .status = .handled, .what = "window title" },
    .{ .code = 4, .status = .ignored, .what = "set palette colour", .note = "the palette stays the theme's" },
    .{ .code = 7, .status = .ignored, .what = "working directory", .note = "wanted by A3" },
    .{ .code = 8, .status = .ignored, .what = "hyperlink", .note = "wanted by A4" },
    .{ .code = 9, .status = .ignored, .what = "desktop notification", .note = "wanted by A1" },
    .{ .code = 10, .status = .ignored, .what = "foreground colour query", .note = "no reply" },
    .{ .code = 11, .status = .ignored, .what = "background colour query", .note = "no reply" },
    .{ .code = 52, .status = .ignored, .what = "clipboard", .note = "see S0 before implementing" },
    .{ .code = 133, .status = .ignored, .what = "semantic prompt marks", .note = "the keystone of A3" },
    .{ .code = 633, .status = .ignored, .what = "VS Code shell integration" },
    .{ .code = 777, .status = .ignored, .what = "notification (urxvt form)", .note = "wanted by A1" },
};

/// One observed sequence, and how often.
const Seen = struct {
    count: u64 = 0,
    corpora: u32 = 0, // bitmask, one bit per corpus
};

/// Tallies rather than acts. The parser cannot tell the difference.
const Tally = struct {
    csi: std.AutoHashMapUnmanaged(u32, Seen) = .empty,
    osc: std.AutoHashMapUnmanaged(u16, Seen) = .empty,
    esc: std.AutoHashMapUnmanaged(u32, Seen) = .empty,
    executes: std.AutoHashMapUnmanaged(u8, Seen) = .empty,
    printed: u64 = 0,
    alloc: std.mem.Allocator,
    bit: u32 = 0,

    fn key(private: u8, intermediate: u8, final: u8) u32 {
        return (@as(u32, private) << 16) | (@as(u32, intermediate) << 8) | final;
    }

    fn bump(self: *Tally, map: anytype, k: anytype) void {
        const gop = map.getOrPut(self.alloc, k) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.count += 1;
        gop.value_ptr.corpora |= self.bit;
    }

    pub fn print(self: *Tally, cp: u21) void {
        _ = cp;
        self.printed += 1;
    }
    pub fn printRun(self: *Tally, run: []const u8) void {
        self.printed += run.len;
    }
    pub fn execute(self: *Tally, b: u8) void {
        self.bump(&self.executes, b);
    }
    pub fn escDispatch(self: *Tally, intermediates: []const u8, final: u8) void {
        self.bump(&self.esc, key(0, if (intermediates.len > 0) intermediates[0] else 0, final));
    }
    pub fn csiDispatch(self: *Tally, csi: vt.Csi) void {
        self.bump(&self.csi, key(
            csi.private,
            if (csi.intermediates.len > 0) csi.intermediates[0] else 0,
            csi.final,
        ));
    }
    pub fn oscDispatch(self: *Tally, data: []const u8) void {
        const semi = std.mem.indexOfScalar(u8, data, ';') orelse data.len;
        const code = std.fmt.parseInt(u16, data[0..semi], 10) catch 0xffff;
        self.bump(&self.osc, code);
    }
};

/// How many distinct sequences a single corpus contributed.
fn distinctIn(map: anytype, bit: u32) usize {
    var n: usize = 0;
    var it = map.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.corpora & bit != 0) n += 1;
    }
    return n;
}

fn csiStatus(private: u8, intermediate: u8, final: u8) ?Known {
    for (known_csi) |k| {
        if (k.private == private and k.intermediate == intermediate and k.final == final) return k;
    }
    return null;
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var tally = Tally{ .alloc = gpa };
    defer {
        tally.csi.deinit(gpa);
        tally.osc.deinit(gpa);
        tally.esc.deinit(gpa);
        tally.executes.deinit(gpa);
    }

    std.debug.print("protocol audit: what the corpora ask for\n\n", .{});
    std.debug.print("  {s:<14} {s:>10} {s:>8} {s:>8} {s:>8}\n", .{ "corpus", "bytes", "CSI", "OSC", "ESC" });
    std.debug.print("  {s:-<14} {s:->10} {s:->8} {s:->8} {s:->8}\n", .{ "", "", "", "", "" });

    for (corpora, 0..) |corpus, i| {
        tally.bit = @as(u32, 1) << @intCast(i);
        var parser: vt.Parser = .{};
        parser.feed(&tally, corpus.bytes);
    }

    // Per corpus, from the bitmask each entry carries. Counting "new since
    // the last corpus" instead would report zero for every corpus after the
    // first, and read as though the generated corpora contain no escapes at
    // all -- `sgr` alone has twenty thousand SGR sequences.
    for (corpora, 0..) |corpus, i| {
        const bit = @as(u32, 1) << @intCast(i);
        std.debug.print("  {s:<14} {d:>10} {d:>8} {d:>8} {d:>8}\n", .{
            corpus.name,
            corpus.bytes.len,
            distinctIn(&tally.csi, bit),
            distinctIn(&tally.osc, bit),
            distinctIn(&tally.esc, bit),
        });
    }

    var mishandled: usize = 0;
    var unlisted: usize = 0;

    std.debug.print("\nCSI sequences observed\n\n", .{});
    std.debug.print("  {s:<12} {s:>9}  {s:<12}  {s:<26}  {s}\n", .{ "sequence", "count", "status", "what it means", "note" });
    std.debug.print("  {s:-<12} {s:->9}  {s:-<12}  {s:-<26}  {s:-<44}\n", .{ "", "", "", "", "" });

    var it = tally.csi.iterator();
    while (it.next()) |entry| {
        const private: u8 = @intCast((entry.key_ptr.* >> 16) & 0xff);
        const intermediate: u8 = @intCast((entry.key_ptr.* >> 8) & 0xff);
        const final: u8 = @truncate(entry.key_ptr.*);
        var name: [20]u8 = undefined;
        const seq = std.fmt.bufPrint(&name, "CSI{s}{c}{s}{c} {c}", .{
            if (private != 0) " " else "",
            if (private != 0) private else ' ',
            if (intermediate != 0) " " else "",
            if (intermediate != 0) intermediate else ' ',
            final,
        }) catch continue;

        if (csiStatus(private, intermediate, final)) |k| {
            if (k.status == .mishandled) mishandled += 1;
            std.debug.print("  {s:<12} {d:>9}  {s:<12}  {s:<26}  {s}\n", .{
                seq, entry.value_ptr.count, k.status.label(), k.what, k.note,
            });
        } else {
            unlisted += 1;
            std.debug.print("  {s:<12} {d:>9}  {s:<12}  {s:<26}  {s}\n", .{
                seq, entry.value_ptr.count, "unlisted", "-", "not in the table; decide",
            });
        }
    }

    std.debug.print("\nOSC sequences observed\n\n", .{});
    var osc_it = tally.osc.iterator();
    while (osc_it.next()) |entry| {
        const code = entry.key_ptr.*;
        var found = false;
        for (known_osc) |k| {
            if (k.code != code) continue;
            found = true;
            if (k.status == .mishandled) mishandled += 1;
            var label: [12]u8 = undefined;
            const name = std.fmt.bufPrint(&label, "OSC {d}", .{code}) catch "OSC";
            std.debug.print("  {s:<12} {d:>9}  {s:<12}  {s:<26}  {s}\n", .{
                name, entry.value_ptr.count, k.status.label(), k.what, k.note,
            });
            break;
        }
        if (!found) {
            unlisted += 1;
            std.debug.print("  OSC {d:<8} {d:>9}  {s:<12}  {s:<26}  {s}\n", .{
                code, entry.value_ptr.count, "unlisted", "-", "not in the table; decide",
            });
        }
    }

    std.debug.print(
        "\n{d} sequence(s) mis-handled, {d} unlisted\n",
        .{ mishandled, unlisted },
    );
    if (mishandled > 0) {
        std.debug.print(
            "A mis-handled row is a sequence this terminal executes as something else.\n" ++
                "It is not a missing feature; the screen is wrong afterwards.\n",
            .{},
        );
    }
}
