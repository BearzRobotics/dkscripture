const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const parse = @import("parse.zig");
const db = @import("db.zig");

const Allocator = std.mem.Allocator;

/// A quote source. Built-in ones are extracted by parse.zig. To add saints /
/// Church Fathers later: put a `fathers.tsv` (lines of `reference<TAB>text`)
/// in the data directory, uncomment the `fathers` line, and run
/// `dkscripture build` - the topic tagging then applies to it automatically.
const Source = struct {
    id: []const u8,
    name: []const u8,
    kind: enum { dr, trent, ccc, custom },
    /// Relative chance of being picked when no source is named.
    weight: usize = 1,
};

const sources = [_]Source{
    .{ .id = "dr", .name = "Douay-Rheims Bible", .kind = .dr, .weight = 2 },
    .{ .id = "trent", .name = "Catechism of the Council of Trent", .kind = .trent },
    .{ .id = "ccc", .name = "Catechism of the Catholic Church", .kind = .ccc },
    // .{ .id = "fathers", .name = "Church Fathers", .kind = .custom },
    // .{ .id = "saints", .name = "Saints", .kind = .custom },
};

/// The finished database, compiled in (see build.zig).
const embedded_quotes = @embedFile("quotes.tsv");

const dr_url = "https://www.gutenberg.org/cache/epub/1581/pg1581.txt";
const trent_url = "https://archive.org/download/catechismofcounc0000cath/catechismofcounc0000cath_djvu.txt";
const ccc_base = "https://www.vatican.va/archive/ENG0015/";

const recent_limit = 500;
const red = "\x1b[31m";
const dim = "\x1b[2m";
const bold = "\x1b[1m";
const reset = "\x1b[0m";

const usage =
    \\dkscripture - quotes from the Douay-Rheims Bible, the Catechism of the
    \\Council of Trent and the Catechism of the Catholic Church.
    \\
    \\Usage:
    \\  dkscripture                    one random quote
    \\  dkscripture dr ccc             one quote from each named source, on a
    \\                                 shared random topic (dr | trent | ccc)
    \\  dkscripture all                one quote from every source, same topic
    \\  dkscripture -t mercy [sources] choose the topic yourself
    \\  dkscripture topics             list topics and how many quotes each has
    \\  dkscripture fetch [-f]         re-download the source texts and rebuild the
    \\                                 database (optional: one is built in)
    \\  dkscripture build              rebuild the quote database from saved sources
    \\  dkscripture where              show where the data is stored
    \\
    \\  --no-color / --color           words of Christ are red when on a terminal
    \\
    \\Recently shown quotes are remembered and not repeated.
    \\Show a quote at every login by adding this to ~/.bashrc or ~/.zshrc:
    \\  command -v dkscripture >/dev/null && dkscripture
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const data = try dataDir(init, init.arena.allocator());
    const cmd: []const u8 = if (args.len > 1) args[1] else "";

    if (eql(cmd, "help") or eql(cmd, "-h") or eql(cmd, "--help")) {
        try out.writeAll(usage);
    } else if (eql(cmd, "where")) {
        try out.print("{s}\n", .{data});
    } else if (eql(cmd, "fetch")) {
        const force = args.len > 2 and (eql(args[2], "-f") or eql(args[2], "--force"));
        try out.flush();
        try fetch(gpa, io, data, force);
        try build(gpa, io, data, out);
    } else if (eql(cmd, "build")) {
        try build(gpa, io, data, out);
    } else if (eql(cmd, "topics")) {
        try listTopics(gpa, io, data, out);
    } else {
        try quoteCommand(init, args[1..], data, out);
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn fail(out: *Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    out.print(fmt, args) catch {};
    out.flush() catch {};
    std.process.exit(2);
}

fn firstRunHint(out: *Io.Writer) !void {
    try out.writeAll("No quotes found. Run `dkscripture fetch` to download the sources and build them.\n");
}

fn dataDir(init: std.process.Init, arena: Allocator) ![]const u8 {
    if (init.environ_map.get("XDG_DATA_HOME")) |x| if (x.len > 0)
        return std.fmt.allocPrint(arena, "{s}/dkscripture", .{x});
    const home = init.environ_map.get("HOME") orelse return error.NoHomeDirectory;
    return std.fmt.allocPrint(arena, "{s}/.local/share/dkscripture", .{home});
}

fn randomBelow(io: Io, n: usize) usize {
    var b: [8]u8 = undefined;
    io.random(&b);
    return @intCast(std.mem.readInt(u64, &b, .little) % n);
}

fn path(gpa: Allocator, data: []const u8, parts: []const []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.appendSlice(gpa, data);
    for (parts) |p| {
        try list.append(gpa, '/');
        try list.appendSlice(gpa, p);
    }
    return list.toOwnedSlice(gpa);
}

fn fileExists(io: Io, data: []const u8, name: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ data, name }) catch return false;
    Dir.cwd().access(io, p, .{}) catch return false;
    return true;
}

fn readAll(gpa: Allocator, io: Io, p: []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(io, p, gpa, .limited(256 * 1024 * 1024));
}

fn writeAll(io: Io, p: []const u8, data: []const u8) !void {
    try Dir.cwd().writeFile(io, .{ .sub_path = p, .data = data });
}

// ----------------------------------------------------------- the database

const Entry = struct {
    id: []const u8,
    source: usize, // index into `sources`
    tmask: u64, // bit per topic
    topics: []const u8,
    ref: []const u8,
    text: []const u8,
};

const Db = struct {
    body: []u8,
    entries: []Entry,

    fn deinit(d: *Db, gpa: Allocator) void {
        gpa.free(d.entries);
        gpa.free(d.body);
    }
};

fn sourceIndex(id: []const u8) ?usize {
    for (sources, 0..) |s, i| {
        if (eql(s.id, id)) return i;
    }
    return null;
}

fn loadDb(gpa: Allocator, io: Io, data: []const u8) !Db {
    const p = try path(gpa, data, &.{"quotes.tsv"});
    defer gpa.free(p);
    // A database the user built with `fetch`/`build` wins; otherwise the one
    // compiled into the program is used.
    const body = readAll(gpa, io, p) catch try gpa.dupe(u8, embedded_quotes);
    errdefer gpa.free(body);

    var list: std.ArrayList(Entry) = .empty;
    errdefer list.deinit(gpa);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const id = f.next() orelse continue;
        const src = sourceIndex(f.next() orelse continue) orelse continue;
        const tags = f.next() orelse continue;
        const ref = f.next() orelse continue;
        const text = f.rest();
        var mask: u64 = 0;
        var tt = std.mem.splitScalar(u8, tags, ',');
        while (tt.next()) |slug| {
            if (db.topicIndex(slug)) |i| mask |= @as(u64, 1) << @intCast(i);
        }
        try list.append(gpa, .{ .id = id, .source = src, .tmask = mask, .topics = tags, .ref = ref, .text = text });
    }
    return .{ .body = body, .entries = try list.toOwnedSlice(gpa) };
}

// -------------------------------------------------------- recent history

fn loadRecent(gpa: Allocator, io: Io, data: []const u8) ![]u8 {
    const p = try path(gpa, data, &.{"recent.txt"});
    defer gpa.free(p);
    return readAll(gpa, io, p) catch gpa.dupe(u8, "");
}

fn isRecent(recent: []const u8, id: []const u8) bool {
    var it = std.mem.splitScalar(u8, recent, '\n');
    while (it.next()) |r| {
        if (eql(r, id)) return true;
    }
    return false;
}

/// Append `ids` to the history, keeping only the newest `recent_limit`.
fn saveRecent(gpa: Allocator, io: Io, data: []const u8, old: []const u8, ids: []const []const u8) !void {
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(gpa);
    try all.appendSlice(gpa, old);
    for (ids) |id| {
        try all.appendSlice(gpa, id);
        try all.append(gpa, '\n');
    }
    var lines: usize = 0;
    for (all.items) |c| {
        if (c == '\n') lines += 1;
    }
    var skip = if (lines > recent_limit) lines - recent_limit else 0;
    var start: usize = 0;
    while (skip > 0) : (skip -= 1) {
        start = std.mem.indexOfScalarPos(u8, all.items, start, '\n').? + 1;
    }
    const p = try path(gpa, data, &.{"recent.txt"});
    defer gpa.free(p);
    try writeAll(io, p, all.items[start..]);
}

// ------------------------------------------------------------- quote command

fn quoteCommand(init: std.process.Init, args: []const [:0]const u8, data: []const u8, out: *Io.Writer) !void {
    const gpa = init.gpa;
    const io = init.io;

    var selected: [sources.len]bool = @splat(false);
    var all = false;
    var topic: ?usize = null;
    var color: ?bool = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (eql(a, "-t") or eql(a, "--topic")) {
            i += 1;
            if (i >= args.len) fail(out, "{s} needs a topic; see `dkscripture topics`\n", .{a});
            topic = db.topicIndex(args[i]) orelse fail(out, "unknown topic '{s}'; see `dkscripture topics`\n", .{args[i]});
        } else if (eql(a, "--no-color")) {
            color = false;
        } else if (eql(a, "--color")) {
            color = true;
        } else if (eql(a, "all")) {
            all = true;
        } else if (sourceIndex(a)) |s| {
            selected[s] = true;
        } else {
            fail(out, "unknown argument '{s}'\n\n{s}", .{ a, usage });
        }
    }

    var database = loadDb(gpa, io, data) catch return firstRunHint(out);
    defer database.deinit(gpa);
    const entries = database.entries;

    var has: [sources.len]bool = @splat(false);
    for (entries) |e| has[e.source] = true;

    // Which sources to show.
    var sel: [sources.len]usize = undefined;
    var n_sel: usize = 0;
    var any_named = false;
    for (selected) |b| any_named = any_named or b;
    if (all or any_named) {
        for (0..sources.len) |s| {
            if ((all or selected[s]) and has[s]) {
                sel[n_sel] = s;
                n_sel += 1;
            }
        }
    } else {
        var avail: [sources.len]usize = undefined;
        var n: usize = 0;
        for (0..sources.len) |s| {
            if (has[s]) {
                avail[n] = s;
                n += 1;
            }
        }
        if (n == 0) return firstRunHint(out);
        // Weighted pick (Scripture counts double) so it isn't drowned out.
        var total: usize = 0;
        for (avail[0..n]) |s| total += sources[s].weight;
        var roll = randomBelow(io, total);
        for (avail[0..n]) |s| {
            if (roll < sources[s].weight) {
                sel[0] = s;
                break;
            }
            roll -= sources[s].weight;
        }
        n_sel = 1;
    }
    if (n_sel == 0) return firstRunHint(out);

    const recent = try loadRecent(gpa, io, data);
    defer gpa.free(recent);

    // With several sources and no topic given, find a topic they all have.
    if (topic == null and n_sel > 1) {
        var use_recent = true;
        while (true) {
            var shared: u64 = ~@as(u64, 0);
            for (sel[0..n_sel]) |s| {
                var m: u64 = 0;
                for (entries) |e| {
                    if (e.source == s and (!use_recent or !isRecent(recent, e.id))) m |= e.tmask;
                }
                shared &= m;
            }
            if (shared != 0) {
                var pick = randomBelow(io, @popCount(shared));
                while (pick > 0) : (pick -= 1) shared &= shared - 1;
                topic = @ctz(shared);
                break;
            }
            if (!use_recent) break;
            use_recent = false;
        }
    }

    const use_color = color orelse (!hasEnv(init, "NO_COLOR") and (Io.File.stdout().isTty(io) catch false));

    var shown: [sources.len][]const u8 = undefined;
    var n_shown: usize = 0;
    var header_done = false;
    for (sel[0..n_sel]) |s| {
        const e = pickEntry(io, entries, recent, s, topic, true) orelse
            pickEntry(io, entries, recent, s, topic, false) orelse {
            try out.print("\n  (no {s} quotes on that topic)\n", .{sources[s].name});
            continue;
        };
        if (!header_done) {
            header_done = true;
            try out.writeAll("\n");
            if (topic) |t| {
                if (use_color) try out.writeAll(bold);
                try out.print("  \u{271D} {s}", .{db.topics[t].title});
                if (use_color) try out.writeAll(reset);
                try out.writeAll("\n\n");
            }
        }
        try showEntry(out, e, use_color);
        shown[n_shown] = e.id;
        n_shown += 1;
    }
    if (n_shown > 0) saveRecent(gpa, io, data, recent, shown[0..n_shown]) catch {};
}

fn hasEnv(init: std.process.Init, key: []const u8) bool {
    return init.environ_map.get(key) != null;
}

/// Random entry of source `s` (optionally on `topic`, optionally not recent).
fn pickEntry(io: Io, entries: []const Entry, recent: []const u8, s: usize, topic: ?usize, avoid_recent: bool) ?*const Entry {
    const bit: u64 = if (topic) |t| @as(u64, 1) << @intCast(t) else 0;
    var count: usize = 0;
    for (entries) |*e| {
        if (eligible(e, recent, s, bit, avoid_recent)) count += 1;
    }
    if (count == 0) return null;
    var want = randomBelow(io, count);
    for (entries) |*e| {
        if (!eligible(e, recent, s, bit, avoid_recent)) continue;
        if (want == 0) return e;
        want -= 1;
    }
    return null;
}

fn eligible(e: *const Entry, recent: []const u8, s: usize, bit: u64, avoid_recent: bool) bool {
    if (e.source != s) return false;
    if (bit != 0 and e.tmask & bit == 0) return false;
    if (avoid_recent and isRecent(recent, e.id)) return false;
    return true;
}

fn showEntry(out: *Io.Writer, e: *const Entry, color: bool) !void {
    try wrap(out, e.text, 72, "  ", color);
    if (color) try out.writeAll(dim);
    try out.print("      \u{2014} {s}", .{e.ref});
    if (color) try out.writeAll(reset);
    try out.writeAll("\n\n");
}

/// Word-wrap `text`. Bytes christ_on/christ_off switch red on and off
/// (or are dropped when colour is disabled).
fn wrap(out: *Io.Writer, text: []const u8, width: usize, indent: []const u8, color: bool) !void {
    var col: usize = 0;
    var in_red = false;
    try out.writeAll(indent);
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |w| {
        var visible: usize = 0;
        for (w) |c| {
            if (c == db.christ_on or c == db.christ_off) continue;
            if (c & 0xC0 != 0x80) visible += 1; // count UTF-8 code points
        }
        if (col > 0 and col + 1 + visible > width) {
            if (in_red and color) try out.writeAll(reset);
            try out.writeAll("\n");
            try out.writeAll(indent);
            if (in_red and color) try out.writeAll(red);
            col = 0;
        }
        if (col > 0) {
            try out.writeAll(" ");
            col += 1;
        }
        for (w) |c| {
            if (c == db.christ_on) {
                in_red = true;
                if (color) try out.writeAll(red);
            } else if (c == db.christ_off) {
                in_red = false;
                if (color) try out.writeAll(reset);
            } else try out.writeAll(&.{c});
        }
        col += visible;
    }
    if (in_red and color) try out.writeAll(reset);
    try out.writeAll("\n");
}

fn listTopics(gpa: Allocator, io: Io, data: []const u8, out: *Io.Writer) !void {
    var database = loadDb(gpa, io, data) catch return firstRunHint(out);
    defer database.deinit(gpa);
    try out.print("{s:<14} {s:<32}", .{ "topic", "title" });
    for (sources) |s| try out.print(" {s:>6}", .{s.id});
    try out.writeAll("\n");
    for (db.topics, 0..) |t, ti| {
        try out.print("{s:<14} {s:<32}", .{ t.slug, t.title });
        const bit = @as(u64, 1) << @intCast(ti);
        for (0..sources.len) |si| {
            var n: usize = 0;
            for (database.entries) |e| {
                if (e.source == si and e.tmask & bit != 0) n += 1;
            }
            try out.print(" {d:>6}", .{n});
        }
        try out.writeAll("\n");
    }
}

// -------------------------------------------------------------------- fetch

fn curl(gpa: Allocator, io: Io, extra: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "curl", "-fsSL", "--retry", "2", "-A", "dkscripture/0.1 (personal local copy)" });
    try argv.appendSlice(gpa, extra);
    const res = std.process.run(gpa, io, .{ .argv = argv.items }) catch |e| {
        std.debug.print("could not run curl ({s}); is it installed?\n", .{@errorName(e)});
        return e;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("download failed: {s}\n", .{res.stderr});
    return error.DownloadFailed;
}

fn fetch(gpa: Allocator, io: Io, data: []const u8, force: bool) !void {
    const ccc_dir = try path(gpa, data, &.{ "raw", "ccc" });
    defer gpa.free(ccc_dir);
    try Dir.cwd().createDirPath(io, ccc_dir);

    const dr_path = try path(gpa, data, &.{ "raw", "douay-rheims.txt" });
    defer gpa.free(dr_path);
    const trent_path = try path(gpa, data, &.{ "raw", "trent-mchugh-callan.txt" });
    defer gpa.free(trent_path);

    if (force or !fileExists(io, data, "raw/douay-rheims.txt")) {
        std.debug.print("Downloading Douay-Rheims Bible (Project Gutenberg)...\n", .{});
        try curl(gpa, io, &.{ "-o", dr_path, dr_url });
    }
    if (force or !fileExists(io, data, "raw/trent-mchugh-callan.txt")) {
        std.debug.print("Downloading Catechism of the Council of Trent (archive.org)...\n", .{});
        try curl(gpa, io, &.{ "-o", trent_path, trent_url });
    }

    // CCC: table of contents first, then every page in a single curl run
    // (one connection, polite to the Vatican server).
    const index_path = try path(gpa, data, &.{ "raw", "ccc", "_INDEX.HTM" });
    defer gpa.free(index_path);
    if (force or !fileExists(io, data, "raw/ccc/_INDEX.HTM")) {
        try curl(gpa, io, &.{ "-o", index_path, ccc_base ++ "_INDEX.HTM" });
    }
    const index = try readAll(gpa, io, index_path);
    defer gpa.free(index);
    const names = try parse.cccPageNames(gpa, index);
    defer gpa.free(names);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    var todo: usize = 0;
    for (names) |name| {
        const rel = try std.fmt.allocPrint(arena, "raw/ccc/{s}", .{name});
        if (!force and fileExists(io, data, rel)) continue;
        try args.append(gpa, try std.fmt.allocPrint(arena, "{s}{s}", .{ ccc_base, name }));
        try args.append(gpa, "-o");
        try args.append(gpa, try std.fmt.allocPrint(arena, "{s}/{s}", .{ ccc_dir, name }));
        todo += 1;
    }
    if (todo > 0) {
        std.debug.print("Downloading Catechism of the Catholic Church ({d} pages from vatican.va)...\n", .{todo});
        try curl(gpa, io, args.items);
    }
}

// -------------------------------------------------------------------- build

/// Extract candidate quotes from every source, tag them by topic and write
/// the combined database to `quotes.tsv`.
fn build(gpa: Allocator, io: Io, data: []const u8, out: *Io.Writer) !void {
    const dr_raw = try path(gpa, data, &.{ "raw", "douay-rheims.txt" });
    defer gpa.free(dr_raw);
    const dr_text = readAll(gpa, io, dr_raw) catch {
        try out.writeAll("Sources not downloaded yet. Run `dkscripture fetch` first.\n");
        return;
    };
    defer gpa.free(dr_text);

    var cl = try db.Classifier.init(gpa);
    defer cl.deinit();
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(gpa);

    for (sources) |s| {
        const candidates: []u8 = switch (s.kind) {
            .dr => try parse.douayRheims(gpa, dr_text),
            .trent => blk: {
                const p = try path(gpa, data, &.{ "raw", "trent-mchugh-callan.txt" });
                defer gpa.free(p);
                const text = readAll(gpa, io, p) catch {
                    try out.print("{s}: raw text missing, skipped.\n", .{s.id});
                    continue;
                };
                defer gpa.free(text);
                break :blk try parse.trent(gpa, text, dr_text);
            },
            .ccc => blk: {
                const idx = try path(gpa, data, &.{ "raw", "ccc", "_INDEX.HTM" });
                defer gpa.free(idx);
                const index = readAll(gpa, io, idx) catch {
                    try out.print("{s}: raw pages missing, skipped.\n", .{s.id});
                    continue;
                };
                defer gpa.free(index);
                const names = try parse.cccPageNames(gpa, index);
                defer gpa.free(names);
                var q: parse.Quotes = .empty;
                errdefer q.deinit(gpa);
                for (names) |name| {
                    const pp = try path(gpa, data, &.{ "raw", "ccc", name });
                    defer gpa.free(pp);
                    const html = readAll(gpa, io, pp) catch continue;
                    defer gpa.free(html);
                    try parse.cccPage(gpa, html, &q);
                }
                break :blk try q.toOwnedSlice(gpa);
            },
            .custom => blk: {
                const file = try std.fmt.allocPrint(gpa, "{s}.tsv", .{s.id});
                defer gpa.free(file);
                const p = try path(gpa, data, &.{file});
                defer gpa.free(p);
                break :blk readAll(gpa, io, p) catch continue;
            },
        };
        defer gpa.free(candidates);

        var total: usize = 0;
        for (candidates) |c| {
            if (c == '\n') total += 1;
        }
        const kept = try db.addCandidates(gpa, &cl, &all, s.id, candidates);
        try out.print("{s}: {d} passages, {d} kept with topics\n", .{ s.id, total, kept });
    }

    const p = try path(gpa, data, &.{"quotes.tsv"});
    defer gpa.free(p);
    try writeAll(io, p, all.items);
    try out.print("Wrote {s}\n", .{p});
}

test {
    _ = parse;
    _ = db;
}
