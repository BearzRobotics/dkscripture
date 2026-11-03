//! The quote database: candidate quotes are tagged with topics by keyword
//! and written to one file, `quotes.tsv`, one entry per line:
//!
//!     id <TAB> source <TAB> topic,topic <TAB> reference <TAB> text
//!
//! Quotes with no topic match are dropped, which keeps the database to
//! passages that are actually about something. In `text`, the bytes
//! `christ_on` / `christ_off` wrap words spoken by Our Lord (shown in red).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const christ_on: u8 = 0x01;
pub const christ_off: u8 = 0x02;

pub const Topic = struct {
    slug: []const u8,
    title: []const u8,
    /// Lowercase words. A trailing `*` matches any word starting with it.
    stems: []const []const u8,
};

pub const topics = [_]Topic{
    .{ .slug = "love", .title = "Love & Charity", .stems = &.{ "lov*", "charit*", "beloved", "neighbo*" } },
    .{ .slug = "faith", .title = "Faith", .stems = &.{ "faith*", "believ*", "belief", "creed" } },
    .{ .slug = "hope", .title = "Hope & Trust", .stems = &.{ "hope*", "hoped", "trust*", "confiden*" } },
    .{ .slug = "mercy", .title = "Mercy", .stems = &.{ "merc*", "compassion*", "pity", "pitied" } },
    .{ .slug = "forgiveness", .title = "Forgiveness", .stems = &.{ "forgiv*", "pardon*", "remission", "absolv*", "absolution" } },
    .{ .slug = "repentance", .title = "Repentance & Penance", .stems = &.{ "repent*", "penance", "penit*", "contrit*", "contrition", "convert*", "conversion" } },
    .{ .slug = "sin", .title = "Sin", .stems = &.{ "sin", "sins", "sinner*", "sinned", "sinneth", "sinful", "iniquit*", "transgress*", "wickedness", "vice", "vices" } },
    .{ .slug = "prayer", .title = "Prayer", .stems = &.{ "pray*", "supplicat*", "intercess*", "petition*" } },
    .{ .slug = "humility", .title = "Humility", .stems = &.{ "humil*", "meek*", "lowly" } },
    .{ .slug = "pride", .title = "Pride", .stems = &.{ "pride", "proud", "haughty", "vainglor*", "arrogan*" } },
    .{ .slug = "suffering", .title = "Suffering & the Cross", .stems = &.{ "suffer*", "afflict*", "tribulation*", "cross", "passion", "patien*", "persecut*", "martyr*" } },
    .{ .slug = "peace", .title = "Peace", .stems = &.{ "peace*", "peaceable", "reconcil*" } },
    .{ .slug = "wisdom", .title = "Wisdom", .stems = &.{ "wisdom", "wise", "wiser", "prudent", "prudence", "understanding" } },
    .{ .slug = "truth", .title = "Truth", .stems = &.{ "truth", "truths", "truthful" } },
    .{ .slug = "justice", .title = "Justice & Righteousness", .stems = &.{ "justice", "righteous*", "justified" } },
    .{ .slug = "wealth", .title = "Riches, Poverty & Alms", .stems = &.{ "poor", "poverty", "rich", "riches", "alms*", "mammon", "treasure*", "covet*", "avarice", "wealth*" } },
    .{ .slug = "eucharist", .title = "The Eucharist", .stems = &.{ "eucharist*", "chalice", "consecrat*", "viaticum", "transubstantiat*", "sacrament", "sacraments" } },
    .{ .slug = "baptism", .title = "Baptism", .stems = &.{ "baptis*", "baptiz*", "baptized", "regenerat*" } },
    .{ .slug = "church", .title = "The Church", .stems = &.{ "church*", "apostle*", "apostolic", "pope", "pontiff", "bishop*", "hierarchy" } },
    .{ .slug = "mary", .title = "Our Lady", .stems = &.{ "mary", "virgin*", "immaculate", "theotokos", "annunciation" } },
    .{ .slug = "spirit", .title = "The Holy Spirit", .stems = &.{ "ghost", "paraclete", "comforter", "spirit", "spirits" } },
    .{ .slug = "grace", .title = "Grace", .stems = &.{ "grace", "graces", "gracious", "sanctifying", "justification" } },
    .{ .slug = "salvation", .title = "Salvation & Redemption", .stems = &.{ "salvation", "saviour", "savior", "redeem*", "redempt*", "redeemer", "ransom*" } },
    .{ .slug = "eternal", .title = "Eternal Life & Heaven", .stems = &.{ "everlasting", "eternal*", "eternity", "resurrect*", "immortal*", "heavenly", "beatific*", "glorif*" } },
    .{ .slug = "death", .title = "Death & Judgment", .stems = &.{ "death", "die", "dies", "died", "dead", "hell", "damn*", "purgator*" } },
    .{ .slug = "commandments", .title = "Commandments & Obedience", .stems = &.{ "command*", "commandment*", "law", "obey*", "obedien*", "precept*", "decalogue" } },
    .{ .slug = "family", .title = "Marriage & Family", .stems = &.{ "marriage*", "matrimon*", "spouse*", "husband*", "wife", "wives", "parents", "honour", "honor" } },
    .{ .slug = "fear", .title = "Fear of the Lord", .stems = &.{ "fear", "feareth", "fearing", "reverence", "awe" } },
    .{ .slug = "joy", .title = "Joy", .stems = &.{ "joy*", "rejoic*", "gladness", "glad" } },
    .{ .slug = "discipline", .title = "Fasting & Self-Denial", .stems = &.{ "fast", "fasting", "fasted", "fasts", "abstain", "abstinence", "temperance", "chast*", "mortif*", "continence" } },
    .{ .slug = "praise", .title = "Praise & Worship", .stems = &.{ "praise*", "worship*", "adore*", "adoration", "thanksgiving", "thanks", "magnif*" } },
    .{ .slug = "scripture", .title = "Scripture & Tradition", .stems = &.{ "scripture*", "tradition*", "gospel*", "prophet*" } },
    .{ .slug = "angels", .title = "Angels", .stems = &.{ "angel*", "archangel*", "cherubim", "seraphim" } },
    .{ .slug = "temptation", .title = "Temptation & Spiritual Combat", .stems = &.{ "tempt*", "devil*", "satan*", "demon*" } },
};

comptime {
    std.debug.assert(topics.len <= 64);
}

pub fn topicIndex(slug: []const u8) ?usize {
    for (topics, 0..) |t, i| {
        if (std.mem.eql(u8, t.slug, slug)) return i;
    }
    return null;
}

/// Maps words to topics. Built once, then used for every candidate quote.
pub const Classifier = struct {
    exact: std.StringHashMap(u64),
    prefix: std.StringHashMap(u64),

    pub fn init(gpa: Allocator) !Classifier {
        var c: Classifier = .{
            .exact = std.StringHashMap(u64).init(gpa),
            .prefix = std.StringHashMap(u64).init(gpa),
        };
        errdefer c.deinit();
        for (topics, 0..) |t, i| {
            const bit = @as(u64, 1) << @intCast(i);
            for (t.stems) |stem| {
                if (stem[stem.len - 1] == '*') {
                    const g = try c.prefix.getOrPut(stem[0 .. stem.len - 1]);
                    g.value_ptr.* = (if (g.found_existing) g.value_ptr.* else 0) | bit;
                } else {
                    const g = try c.exact.getOrPut(stem);
                    g.value_ptr.* = (if (g.found_existing) g.value_ptr.* else 0) | bit;
                }
            }
        }
        return c;
    }

    pub fn deinit(c: *Classifier) void {
        c.exact.deinit();
        c.prefix.deinit();
    }

    /// Up to two topic indices, best first. Empty if nothing matched.
    pub fn classify(c: *const Classifier, text: []const u8) [2]?u8 {
        var score: [topics.len]u16 = @splat(0);
        var buf: [32]u8 = undefined;
        var i: usize = 0;
        while (i < text.len) {
            while (i < text.len and !std.ascii.isAlphabetic(text[i])) i += 1;
            const start = i;
            while (i < text.len and std.ascii.isAlphabetic(text[i])) i += 1;
            const w = text[start..i];
            if (w.len < 2 or w.len > buf.len) continue;
            const lw = std.ascii.lowerString(&buf, w);

            var mask: u64 = c.exact.get(lw) orelse 0;
            var n: usize = 3;
            while (n <= @min(lw.len, 12)) : (n += 1) {
                mask |= c.prefix.get(lw[0..n]) orelse 0;
            }
            while (mask != 0) {
                const b = @ctz(mask);
                score[b] += 1;
                mask &= mask - 1;
            }
        }

        // Short passages may rest on one keyword; longer ones need two.
        const need: u16 = if (text.len < 160) 1 else 2;
        for (&score) |*sc| {
            if (sc.* < need) sc.* = 0;
        }

        var best: ?u8 = null;
        for (score, 0..) |s, k| {
            if (s > 0 and (best == null or s > score[best.?])) best = @intCast(k);
        }
        var result: [2]?u8 = .{ best, null };
        if (best) |b| {
            var second: ?u8 = null;
            for (score, 0..) |s, k| {
                if (k == b or s == 0) continue;
                if (second == null or s > score[second.?]) second = @intCast(k);
            }
            if (second) |sc| {
                if (score[sc] >= 2 or score[sc] == score[b]) result[1] = sc;
            }
        }
        return result;
    }
};

pub fn quoteId(ref: []const u8, text: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(ref);
    h.update("|");
    h.update(text[0..@min(text.len, 80)]);
    return h.final();
}

/// Tag every `reference<TAB>text` line in `candidates` and append the ones
/// that match a topic to `out`. Returns the number kept.
pub fn addCandidates(
    gpa: Allocator,
    cl: *const Classifier,
    out: *std.ArrayList(u8),
    source_id: []const u8,
    candidates: []const u8,
) !usize {
    var kept: usize = 0;
    var lines = std.mem.splitScalar(u8, candidates, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const ref = line[0..tab];
        const text = line[tab + 1 ..];
        const t = cl.classify(text);
        const first = t[0] orelse continue;

        var tags: std.ArrayList(u8) = .empty;
        defer tags.deinit(gpa);
        try tags.appendSlice(gpa, topics[first].slug);
        if (t[1]) |s| {
            try tags.append(gpa, ',');
            try tags.appendSlice(gpa, topics[s].slug);
        }
        const row = try std.fmt.allocPrint(gpa, "{x:0>16}\t{s}\t{s}\t{s}\t{s}\n", .{ quoteId(ref, text), source_id, tags.items, ref, text });
        defer gpa.free(row);
        try out.appendSlice(gpa, row);
        kept += 1;
    }
    return kept;
}

test "classify" {
    var cl = try Classifier.init(std.testing.allocator);
    defer cl.deinit();
    const t = cl.classify("Blessed are the merciful: for they shall obtain mercy.");
    try std.testing.expectEqual(@as(?u8, @intCast(topicIndex("mercy").?)), t[0]);
    const none = cl.classify("And Abram dwelt in the land of Chanaan.");
    try std.testing.expectEqual(@as(?u8, null), none[0]);
}
