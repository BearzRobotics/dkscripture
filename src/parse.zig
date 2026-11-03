//! Turns the raw source documents into quote files.
//!
//! Every quote file is plain text, one quote per line: `reference<TAB>text`.
//! Adding a new source later (saints, Church Fathers, ...) only needs another
//! file in that format, see `sources` in main.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Quotes = std.ArrayList(u8);

/// Append one `reference<TAB>text` line. Tabs/newlines inside are flattened.
fn addQuote(gpa: Allocator, out: *Quotes, ref: []const u8, text: []const u8) !void {
    try out.appendSlice(gpa, ref);
    try out.append(gpa, '\t');
    for (text) |c| try out.append(gpa, if (c == '\t' or c == '\n' or c == '\r') ' ' else c);
    try out.append(gpa, '\n');
}

/// Collapse whitespace runs to single spaces and trim the ends.
fn squash(gpa: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pending_space = false;
    for (s) |c| {
        if (std.ascii.isWhitespace(c)) {
            pending_space = out.items.len != 0;
            continue;
        }
        if (pending_space) try out.append(gpa, ' ');
        pending_space = false;
        try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

/// Shorten `s` to at most `max` bytes, ending on a sentence boundary that is
/// at least `min` bytes in. Returns null if no such boundary exists.
fn clipToSentence(s: []const u8, min: usize, max: usize) ?[]const u8 {
    if (s.len <= max) return s;
    var i: usize = @min(max, s.len - 1);
    while (i >= min) : (i -= 1) {
        const c = s[i];
        if ((c == '.' or c == '?' or c == '!') and (i + 1 == s.len or s[i + 1] == ' ')) {
            return s[0 .. i + 1];
        }
    }
    return null;
}

// ---------------------------------------------------------------- Douay-Rheims

/// Project Gutenberg #1581. Verse lines look like `1:1. In the beginning...`
/// and chapters start with `Genesis Chapter 1`. Footnote paragraphs have no
/// verse number and are skipped.
pub fn douayRheims(gpa: Allocator, text: []const u8) ![]u8 {
    var out: Quotes = .empty;
    errdefer out.deinit(gpa);

    var book: []const u8 = "";
    var verse: std.ArrayList(u8) = .empty;
    defer verse.deinit(gpa);
    var verse_ref: []const u8 = ""; // "c:v", slice into `text`
    var speech: Speech = .{};

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            try flushVerse(gpa, &out, book, verse_ref, &verse, &speech);
            verse_ref = "";
            continue;
        }
        if (verse_ref.len > 0) {
            try verse.append(gpa, ' ');
            try verse.appendSlice(gpa, line);
            continue;
        }
        if (parseChapterHeader(line)) |b| {
            if (!std.mem.eql(u8, b, book)) speech = .{ .in_gospel = isGospel(b) };
            book = b;
            speech.jesus_ctx = true; // a new chapter usually resumes with Jesus
            continue;
        }
        if (parseVerseStart(line)) |v| {
            verse_ref = v.ref;
            verse.clearRetainingCapacity();
            try verse.appendSlice(gpa, v.text);
        }
    }
    try flushVerse(gpa, &out, book, verse_ref, &verse, &speech);
    return out.toOwnedSlice(gpa);
}

fn flushVerse(gpa: Allocator, out: *Quotes, book: []const u8, ref: []const u8, verse: *std.ArrayList(u8), speech: *Speech) !void {
    defer verse.clearRetainingCapacity();
    if (ref.len == 0 or book.len == 0) return;
    const plain = try squash(gpa, verse.items);
    defer gpa.free(plain);
    const t = try markChrist(gpa, plain, speech);
    defer gpa.free(t);
    if (t.len < 60 or t.len > 450) return;
    const r = try std.fmt.allocPrint(gpa, "{s} {s} (Douay-Rheims)", .{ book, ref });
    defer gpa.free(r);
    try addQuote(gpa, out, r, t);
}

fn parseChapterHeader(line: []const u8) ?[]const u8 {
    const i = std.mem.lastIndexOf(u8, line, " Chapter ") orelse return null;
    const num = line[i + " Chapter ".len ..];
    if (num.len == 0) return null;
    for (num) |c| if (!std.ascii.isDigit(c)) return null;
    if (std.ascii.isDigit(line[0])) return null;
    return line[0..i];
}

const Verse = struct { ref: []const u8, text: []const u8 };

fn parseVerseStart(line: []const u8) ?Verse {
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i == 0 or i >= line.len or line[i] != ':') return null;
    i += 1;
    const vstart = i;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i == vstart or i + 1 >= line.len or line[i] != '.' or line[i + 1] != ' ') return null;
    return .{ .ref = line[0..i], .text = line[i + 2 ..] };
}

// ---------------------------------------------- Words of Christ in the Gospels

/// The Douay-Rheims text has no quotation marks; speech is introduced like
/// `Jesus saith to her: Give me to drink.` We follow who is speaking from
/// verse to verse and wrap Our Lord's words in `christ_on`/`christ_off`.
/// This is a heuristic: it handles dialogue and discourses well, and can
/// miss the narrative part of parables.
const Speech = struct {
    in_gospel: bool = false,
    /// Christ was speaking in the previous verse.
    carry: bool = false,
    /// The narrative is currently about Jesus, so "he said" means him.
    jesus_ctx: bool = true,
};

fn isGospel(book: []const u8) bool {
    const names = [_][]const u8{ "Matthew", "Mark", "Luke", "John" };
    for (names) |n| {
        if (std.mem.eql(u8, book, n)) return true;
    }
    return false;
}

const speech_verbs = [_][]const u8{ "said", "saith", "answered", "answering", "spoke", "cried", "asked", "say", "saying" };
const person_words = [_][]const u8{ "i", "my", "me", "mine", "you", "ye", "thou", "thee", "thy", "thine", "your", "yours" };
/// Phrases that mark narration, i.e. the end of a speech.
const narrative_cues = [_][]const u8{ "Jesus", "disciples", "multitude", "multitudes", "Pharisees", "scribes", "it came to pass", "departed", "was come", "went up", "went out", "went into", "abode", "he went", "went again", "walked" };

fn wordIn(list: []const []const u8, w: []const u8) bool {
    var buf: [16]u8 = undefined;
    if (w.len > buf.len) return false;
    const lw = std.ascii.lowerString(&buf, w);
    for (list) |x| {
        if (std.mem.eql(u8, x, lw)) return true;
    }
    return false;
}

fn hasPersonWord(s: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, s, " ,.;:?!\"'()[]");
    while (it.next()) |w| {
        if (wordIn(&person_words, w)) return true;
    }
    return false;
}

fn hasNarrativeCue(s: []const u8) bool {
    for (narrative_cues) |c| {
        if (std.mem.indexOf(u8, s, c) != null) return true;
    }
    return false;
}

fn markChrist(gpa: Allocator, s: []const u8, st: *Speech) ![]u8 {
    const db = @import("db.zig");
    if (!st.in_gospel) return gpa.dupe(u8, s);

    // 1. A speech introduction near the start: "<speaker> <verb> ...: words"
    const head = s[0..@min(s.len, 140)];
    var it = std.mem.tokenizeAny(u8, head, " ,;:");
    var verb_at: ?usize = null;
    var verb_end: usize = 0;
    while (it.next()) |w| {
        if (wordIn(&speech_verbs, w)) {
            verb_end = it.index;
            verb_at = it.index - w.len;
            break;
        }
    }
    if (verb_at) |v| {
        // Where the speech starts: a colon soon after the verb, else a comma.
        const colon = std.mem.indexOfScalarPos(u8, s, verb_end, ':');
        const comma = std.mem.indexOfScalarPos(u8, s, verb_end, ',');
        const sep: ?usize = if (colon != null and colon.? < verb_end + 90)
            colon
        else if (comma != null and comma.? < verb_end + 50)
            comma
        else
            null;
        if (sep) |c| {
            var subject = std.mem.trim(u8, s[0..v], " ,");
            for ([_][]const u8{ "And ", "But ", "Then ", "Now ", "Yet " }) |p| {
                if (std.mem.startsWith(u8, subject, p)) subject = subject[p.len..];
            }
            const last = lastWord(subject);
            // "But I say to you": the subject is the speaker's own pronoun, and
            // inside a speech any subject without a proper name is just part of it.
            const own_words = subject.len == 0 or hasPersonWord(subject) or
                (st.carry and !wordIn(&.{ "he", "they", "she" }, last) and !hasCapital(subject) and !isNarrator(subject) and wordCount(subject) <= 3);
            if (own_words) return markContinuation(gpa, s, st);
            const names_jesus = std.mem.startsWith(u8, subject, "Jesus") or
                std.mem.startsWith(u8, subject, "The Lord") or std.mem.eql(u8, last, "Jesus");
            // "...opening his mouth he taught them, saying:" - a lone "he" in a
            // subject with no other name means the narrative's main figure.
            const is_he = wordIn(&.{"he"}, last) or (!hasCapital(subject) and hasWord(subject, "he"));
            const christ = names_jesus or (is_he and (st.carry or st.jesus_ctx));
            const was_carry = st.carry;
            st.carry = christ;
            if (names_jesus or christ) {
                st.jesus_ctx = true;
            } else if (!is_he and !wordIn(&.{ "they", "she" }, last)) {
                st.jesus_ctx = false; // someone else is speaking
            }
            const rest = std.mem.trim(u8, s[c + 1 ..], " ");
            // A bare "he said" is ambiguous (Herod? a bystander?): only trust it
            // if Christ was already speaking or the words are plainly his.
            if (christ and !names_jesus and !was_carry and rest.len > 0 and !hasPersonWord(rest)) {
                st.carry = false;
                return gpa.dupe(u8, s);
            }
            if (!christ) return gpa.dupe(u8, s);
            if (rest.len == 0) return gpa.dupe(u8, s);
            return std.fmt.allocPrint(gpa, "{s} {c}{s}{c}", .{ s[0 .. c + 1], db.christ_on, rest, db.christ_off });
        }
    }

    // 2. No introduction: carry on if Christ was speaking, unless narration.
    return markContinuation(gpa, s, st);
}

fn markContinuation(gpa: Allocator, s: []const u8, st: *Speech) ![]u8 {
    const db = @import("db.zig");
    if (st.carry) {
        if (hasPersonWord(s) or (!hasNarrativeCue(s) and !looksNarrative(s))) {
            return std.fmt.allocPrint(gpa, "{c}{s}{c}", .{ db.christ_on, s, db.christ_off });
        }
    }
    st.carry = false;
    if (std.mem.indexOf(u8, s, "Jesus") != null) st.jesus_ctx = true;
    return gpa.dupe(u8, s);
}

/// Subjects that mean a bystander is speaking, not Our Lord.
fn isNarrator(subject: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, subject, ' ');
    while (it.next()) |w| {
        if (wordIn(&.{ "men", "wondered", "who", "people", "multitude", "multitudes", "disciples", "woman", "man", "they", "themselves", "thought", "reasoned", "angel", "angels", "others", "some", "one", "many" }, w)) return true;
    }
    return false;
}

fn wordCount(s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |_| n += 1;
    return n;
}

/// Past-tense storytelling ("was", "followed"...) with no "you/I" to show
/// it is a discourse. Used to be careful about what we paint red.
fn looksNarrative(s: []const u8) bool {
    if (std.mem.indexOf(u8, s, " was ") != null or std.mem.indexOf(u8, s, " were ") != null or
        std.mem.indexOf(u8, s, " had ") != null) return true;
    var it = std.mem.tokenizeAny(u8, s, " ,.;:?!\"'()[]");
    while (it.next()) |w| {
        if (wordIn(&.{ "saw", "followed", "came", "went", "took", "rose", "fell", "entered", "sat", "stood", "wondered", "marvelled", "glorifying" }, w)) return true;
    }
    return false;
}

fn hasWord(s: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, s, " ,;:");
    while (it.next()) |w| {
        if (wordIn(&.{word}, w)) return true;
    }
    return false;
}

fn hasCapital(s: []const u8) bool {
    for (s) |c| {
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

fn lastWord(s: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, s, " ,");
    const i = std.mem.lastIndexOfScalar(u8, t, ' ') orelse return t;
    return t[i + 1 ..];
}

// ------------------------------------------------- Catechism of the Council of Trent

/// archive.org OCR text of the McHugh & Callan translation (1923).
/// OCR noise is filtered out by only keeping paragraphs whose every word is
/// a word seen in the Douay-Rheims text or at least three times in the
/// catechism itself (OCR errors are almost always one-offs).
pub fn trent(gpa: Allocator, raw_text: []const u8, dr_text: []const u8) ![]u8 {
    const text = try asciiQuotes(gpa, raw_text);
    defer gpa.free(text);
    var heading: std.ArrayList(u8) = .empty;
    defer heading.deinit(gpa);
    var known = std.StringHashMap(void).init(gpa);
    defer freeKeys(gpa, &known);
    var counts = std.StringHashMap(u32).init(gpa);
    defer {
        var it = counts.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        counts.deinit();
    }

    try addWords(gpa, dr_text, &known, null);
    try addWords(gpa, text, null, &counts);
    var cit = counts.iterator();
    while (cit.next()) |e| {
        if (e.value_ptr.* >= 3 and !known.contains(e.key_ptr.*)) {
            try known.put(try gpa.dupe(u8, e.key_ptr.*), {});
        }
    }

    var out: Quotes = .empty;
    errdefer out.deinit(gpa);

    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(gpa);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (true) {
        const maybe = lines.next();
        const line = if (maybe) |l| std.mem.trim(u8, l, " \t\r") else "";
        if (maybe == null or line.len == 0) {
            if (block.items.len > 0) try considerTrent(gpa, &out, block.items, &known, &heading);
            block.clearRetainingCapacity();
            if (maybe == null) break;
            continue;
        }
        // Re-join words hyphenated across lines ("admir- able").
        if (block.items.len > 0 and block.items[block.items.len - 1] == '-' and
            block.items.len > 1 and std.ascii.isAlphabetic(block.items[block.items.len - 2]) and
            std.ascii.isLower(line[0]))
        {
            _ = block.pop();
        } else if (block.items.len > 0) {
            try block.append(gpa, ' ');
        }
        try block.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

fn freeKeys(gpa: Allocator, m: *std.StringHashMap(void)) void {
    var it = m.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    m.deinit();
}

/// Lowercased alphabetic words of `text` go into `set` and/or are counted.
fn addWords(gpa: Allocator, text: []const u8, set: ?*std.StringHashMap(void), counts: ?*std.StringHashMap(u32)) !void {
    var i: usize = 0;
    var buf: [64]u8 = undefined;
    while (i < text.len) {
        while (i < text.len and !std.ascii.isAlphabetic(text[i])) i += 1;
        const start = i;
        while (i < text.len and std.ascii.isAlphabetic(text[i])) i += 1;
        const w = text[start..i];
        if (w.len == 0 or w.len > buf.len) continue;
        const lower = std.ascii.lowerString(&buf, w);
        if (set) |s| {
            if (!s.contains(lower)) try s.put(try gpa.dupe(u8, lower), {});
        }
        if (counts) |c| {
            if (c.getPtr(lower)) |p| {
                p.* += 1;
            } else try c.put(try gpa.dupe(u8, lower), 1);
        }
    }
}

/// Curly quotes -> ASCII so OCR'd prose passes the plain-text filter.
fn asciiQuotes(gpa: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "\u{201C}") or std.mem.startsWith(u8, s[i..], "\u{201D}")) {
            try out.append(gpa, '"');
            i += 3;
        } else if (std.mem.startsWith(u8, s[i..], "\u{2018}") or std.mem.startsWith(u8, s[i..], "\u{2019}")) {
            try out.append(gpa, '\'');
            i += 3;
        } else {
            try out.append(gpa, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn allKnown(s: []const u8, known: *std.StringHashMap(void)) bool {
    var i: usize = 0;
    var buf: [64]u8 = undefined;
    while (i < s.len) {
        while (i < s.len and !std.ascii.isAlphabetic(s[i])) i += 1;
        const start = i;
        while (i < s.len and std.ascii.isAlphabetic(s[i])) i += 1;
        const w = s[start..i];
        if (w.len == 0) continue;
        if (w.len > buf.len) return false;
        if (w.len == 1 and std.mem.indexOfScalar(u8, "aAIO", w[0]) == null) return false;
        if (!known.contains(std.ascii.lowerString(&buf, w))) return false;
    }
    return true;
}

/// ALL-CAPS block such as "HUMILITY AND POVERTY OF CHRIST" -> remember as title.
fn noteHeading(gpa: Allocator, s: []const u8, known: *std.StringHashMap(void), heading: *std.ArrayList(u8)) !void {
    if (s.len < 8 or s.len > 90) return;
    for (s) |c| {
        if (std.ascii.isLower(c)) return;
        if (!(std.ascii.isUpper(c) or c == ' ' or c == '-' or c == ',')) return;
    }
    if (!allKnown(s, known)) return;
    if (std.mem.startsWith(u8, s, "ARTICLE") or std.mem.startsWith(u8, s, "PART") or std.mem.startsWith(u8, s, "CHAPTER")) return;
    heading.clearRetainingCapacity();
    var start_of_word = true;
    for (s) |c| {
        try heading.append(gpa, if (start_of_word) c else std.ascii.toLower(c));
        start_of_word = c == ' ' or c == '-';
    }
}

fn considerTrent(gpa: Allocator, out: *Quotes, raw: []const u8, known: *std.StringHashMap(void), heading: *std.ArrayList(u8)) !void {
    if (raw.len < 6) return;
    const s = try squash(gpa, raw);
    defer gpa.free(s);
    try noteHeading(gpa, s, known, heading);
    if (s.len < 120) return;
    if (s.len < 120) return;
    if (!std.ascii.isUpper(s[0]) or !std.ascii.isLower(s[1])) return;

    // Only plain prose: letters, spaces and ordinary punctuation. This also
    // drops anything with footnote numbers.
    for (s) |c| {
        const ok = std.ascii.isAlphabetic(c) or c == ' ' or std.mem.indexOfScalar(u8, ",.;:?!'-()\"", c) != null;
        if (!ok) return;
    }
    if (!allKnown(s, known)) return;

    const clipped = clipToSentence(s, 120, 650) orelse return;
    const last = clipped[clipped.len - 1];
    if (last != '.' and last != '?' and last != '!') return;
    const ref = if (heading.items.len > 0)
        try std.fmt.allocPrint(gpa, "Catechism of the Council of Trent: {s}", .{heading.items})
    else
        try gpa.dupe(u8, "Catechism of the Council of Trent");
    defer gpa.free(ref);
    try addQuote(gpa, out, ref, clipped);
}

// ----------------------------------------------------------------------- CCC

/// All page file names (`__P2.HTM`, ...) linked from the table of contents.
pub fn cccPageNames(gpa: Allocator, index_html: []const u8) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, index_html, pos, "__P")) |i| {
        var j = i + 3;
        while (j < index_html.len and (std.ascii.isAlphanumeric(index_html[j]))) j += 1;
        pos = j;
        if (!std.mem.startsWith(u8, index_html[j..], ".HTM")) continue;
        const name = index_html[i .. j + 4];
        var dup = false;
        for (names.items) |n| {
            if (std.mem.eql(u8, n, name)) dup = true;
        }
        if (!dup) try names.append(gpa, name);
    }
    return names.toOwnedSlice(gpa);
}

/// Extract numbered paragraphs from one Vatican IntraText page.
/// Paragraphs look like `<p class=MsoNormal>12\nText ...</p>`.
pub fn cccPage(gpa: Allocator, html: []const u8, out: *Quotes) !void {
    const open = "<p class=MsoNormal>";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, html, pos, open)) |i| {
        const body_start = i + open.len;
        const end = std.mem.indexOfPos(u8, html, body_start, "</p>") orelse break;
        pos = end + 4;
        const body = html[body_start..end];

        // Paragraph number is the first token, followed by a newline.
        var k: usize = 0;
        while (k < body.len and std.ascii.isDigit(body[k])) k += 1;
        if (k == 0 or k > 4 or k >= body.len or (body[k] != '\n' and body[k] != '\r')) continue;
        const n = std.fmt.parseInt(u32, body[0..k], 10) catch continue;
        if (n < 1 or n > 2865) continue;

        const plain = try htmlToText(gpa, body[k..]);
        defer gpa.free(plain);
        if (plain.len < 60) continue;
        const clipped = clipToSentence(plain, 100, 650) orelse continue;
        if (std.mem.indexOfScalar(u8, clipped, '<') != null) continue;

        const ref = try std.fmt.allocPrint(gpa, "CCC \u{a7}{d}", .{n});
        defer gpa.free(ref);
        try addQuote(gpa, out, ref, clipped);
    }
}

/// Strip tags and footnote markers, decode entities, convert Latin-1 to UTF-8.
fn htmlToText(gpa: Allocator, html: []const u8) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);

    var i: usize = 0;
    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            if (std.mem.startsWith(u8, html[i..], "<sup>")) {
                // drop footnote reference entirely
                i = if (std.mem.indexOfPos(u8, html, i, "</sup>")) |e| e + 6 else html.len;
                continue;
            }
            i = if (std.mem.indexOfScalarPos(u8, html, i, '>')) |e| e + 1 else html.len;
            try raw.append(gpa, ' ');
        } else if (c == '&') {
            const semi = std.mem.indexOfScalarPos(u8, html, i, ';');
            if (semi != null and semi.? - i <= 8) {
                try appendEntity(gpa, &raw, html[i + 1 .. semi.?]);
                i = semi.? + 1;
            } else {
                try raw.append(gpa, '&');
                i += 1;
            }
        } else if (c >= 0x80) {
            // The Vatican pages are ISO-8859-1.
            try raw.append(gpa, 0xC0 | (c >> 6));
            try raw.append(gpa, 0x80 | (c & 0x3F));
            i += 1;
        } else {
            try raw.append(gpa, c);
            i += 1;
        }
    }
    return squash(gpa, raw.items);
}

fn appendEntity(gpa: Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    if (name.len > 1 and name[0] == '#') {
        const cp = std.fmt.parseInt(u21, name[1..], 10) catch return;
        var b: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &b) catch return;
        try out.appendSlice(gpa, b[0..n]);
        return;
    }
    const table = [_]struct { []const u8, []const u8 }{
        .{ "quot", "\"" },      .{ "amp", "&" },       .{ "lt", "<" },        .{ "gt", ">" },
        .{ "nbsp", " " },       .{ "copy", "(c)" },    .{ "rsquo", "'" },     .{ "lsquo", "'" },
        .{ "ldquo", "\"" },     .{ "rdquo", "\"" },    .{ "mdash", "\u{2014}" }, .{ "ndash", "\u{2013}" },
        .{ "hellip", "..." },   .{ "eacute", "\u{e9}" }, .{ "egrave", "\u{e8}" }, .{ "agrave", "\u{e0}" },
        .{ "ecirc", "\u{ea}" }, .{ "ouml", "\u{f6}" }, .{ "uuml", "\u{fc}" },  .{ "auml", "\u{e4}" },
        .{ "iuml", "\u{ef}" },  .{ "ccedil", "\u{e7}" },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e[0], name)) return out.appendSlice(gpa, e[1]);
    }
}

test "douay-rheims verses" {
    const gpa = std.testing.allocator;
    const src =
        \\Genesis Chapter 1
        \\
        \\God createth Heaven and Earth, and all things therein, in six days.
        \\
        \\1:1. In the beginning God created heaven, and earth. And the earth was void
        \\and empty, and darkness was upon the face of the deep.
        \\
        \\A note without a verse number.
        \\
    ;
    const out = try douayRheims(gpa, src);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(
        "Genesis 1:1 (Douay-Rheims)\tIn the beginning God created heaven, and earth. And the earth was void and empty, and darkness was upon the face of the deep.\n",
        out,
    );
}

test "ccc paragraph" {
    const gpa = std.testing.allocator;
    var out: Quotes = .empty;
    defer out.deinit(gpa);
    try cccPage(gpa,
        "<p class=MsoNormal>2\nSo that this call should resound throughout the world, Christ sent forth the apostles.<font><sup><a>4</a></sup></font> They went &quot;forth&quot;.</p>",
        &out,
    );
    try std.testing.expectEqualStrings(
        "CCC \u{a7}2\tSo that this call should resound throughout the world, Christ sent forth the apostles. They went \"forth\".\n",
        out.items,
    );
}

test "words of christ" {
    const gpa = std.testing.allocator;
    const src =
        \\John Chapter 4
        \\
        \\4:7. There cometh a woman of Samaria, to draw water. Jesus saith to
        \\her: Give me to drink and let me not be left without any help at all.
        \\
        \\4:9. Then that Samaritan woman saith to him: How dost thou, being a
        \\Jew, ask of me to drink, who am a Samaritan woman?
        \\
        \\4:10. Jesus answered and said to her: If thou didst know the gift of
        \\God and who he is that saith to thee.
        \\
        \\4:14. But the water that I will give him shall become in him a fountain.
        \\
    ;
    const out = try douayRheims(gpa, src);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "her: \x01Give me to drink") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "saith to him: How dost") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x01But the water that I will give him") != null);
}
