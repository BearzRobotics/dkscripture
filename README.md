# dkscripture

Quotes from the Douay-Rheims Bible, the Catechism of the Council of Trent
(McHugh & Callan, 1923) and the Catechism of the Catholic Church (Zig 0.17.0).

    zig build -p ~/.local          # installs to ~/.local/bin, adds login hook to ~/.bashrc
    dkscripture fetch              # one-time download (~5 min, mostly CCC pages)

    dkscripture                    # one random quote
    dkscripture dr ccc             # one from each, on a shared random topic
    dkscripture all                # one from every source, same topic
    dkscripture -t mercy dr ccc    # pick the topic yourself
    dkscripture topics             # topics and counts per source

Add `command -v dkscripture >/dev/null && dkscripture` to `~/.bashrc` to
see one at every login.

## How it works
- `fetch` saves the original texts in `~/.local/share/dkscripture/raw/`.
- `build` extracts candidate passages, tags each with up to two topics by
  keyword (see `topics` in `src/db.zig`), drops passages that match no topic,
  and writes the database `quotes.tsv`:
  `id <TAB> source <TAB> topics <TAB> reference <TAB> text`.
- Running with several sources picks a topic all of them have, so the quotes
  go together. Recently shown quotes (last 500, `recent.txt`) are skipped.
- Words of Our Lord in the four Gospels are red (`--no-color` / `NO_COLOR`
  to turn off). The Douay-Rheims text has no quotation marks, so speakers are
  inferred from introductions like "Jesus saith to her:". It is deliberately
  conservative: it can miss narrative inside parables and now and then
  misattribute a line, so treat it as a reading aid, not an authority.

## Adding saints / Church Fathers later
Create `fathers.tsv` in the data directory (`reference<TAB>text` per line),
uncomment the `fathers` line in `sources` in `src/main.zig`, and run
`dkscripture build`. Topic tagging applies automatically.

## Sources
- Douay-Rheims: Project Gutenberg #1581 (public domain)
- Roman Catechism: archive.org scan, OCR filtered to clean paragraphs
- CCC: vatican.va. Copyright Libreria Editrice Vaticana; downloaded for
  personal use only, do not redistribute the data files.
