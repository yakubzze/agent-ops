# Durable memory index

> Agents commonly load only the beginning of this file at session start — Claude
> Code takes the first **200 lines or 25 KB, whichever comes first** — and drop
> the rest silently. Keep it concise: one line per note. Topic files are not
> loaded automatically; they are read on demand.

- **[NOW — current state](NOW.md) — read first.** Short-term status, open
  threads, and claims; its own header defines how entries expire.

<!--
Add a line only after the target file exists. Make the note title an ordinary
Markdown link to that file, followed by one short hook that lets a reader decide
whether the note is relevant without opening it.

This index answers WHAT durable memory exists. It does not contain the memory
itself. Use ordinary Markdown links by default. If your project deliberately
uses a wiki-link syntax, document and test that convention; it is not universally
resolved by agent tools.
-->
