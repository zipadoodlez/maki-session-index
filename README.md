# maki-session-index

Ask your maki agent to search your *other* chat sessions.

Two tools, one Lua file, no maki changes:

| Tool | Does |
| --- | --- |
| `session_index` | greps a normalized outline of every session; omit `query` to list recent ones |
| `session_read` | expands the newest `last` messages of one session |

## Why it's cheap

Sessions store full transcripts, tool results and all — one `out` record in my
store ran to **143 KB**. Grepping that raw (even though it is line-oriented)
would drag those bodies into context.

So the plugin normalizes each message to one searchable line first:

- full text, whitespace-collapsed — *not* a head-slice, so the signal does not
  have to be in the first sentence
- tool calls as `[edit src/x.rs]`, `[bash cargo test]` — the nouns worth grepping
- tool results as `[ok]` / `[err: …]` — never the body
- thinking dropped

Search then returns a ~120-char **window around each hit**, so cost is
O(matches), never O(transcript). Parsed sessions are memoized in memory by
size+mtime, so repeat searches do not re-decode.

## Install

Managed, from git:

```lua
-- ~/.config/maki/init.lua
maki.pack.add({ "https://github.com/zipadoodlez/maki-session-index" })
```

Approve the `fs_read` permission prompt on first load.

Or by hand:

```sh
cp plugin/session_index.lua ~/.config/maki/lua/
```

then add `require("session_index")` to `~/.config/maki/init.lua` and
`fs_read = true` to `~/.config/maki/plugin.toml`.

Either way, `/reload`.

## Use

> search my past sessions for "cursor bug"

> list my recent sessions

`scope` defaults to the current project; pass `scope = "all"` to search every
project. cwd is compared against the one stored in each session header, so a
project entered through a symlink may need `scope = "all"`.

## Notes

- Read-only: it never focuses, resumes, or writes a session.
- Model-written summary lines would recall better than any digest, but
  generating them off the hot path needs background agents from an autocmd —
  i.e. maki after PR #1232.
- No persistent index yet: a full-store search decodes the files it walks
  (memoized per process).
