-- Past-session recall without dragging transcripts into context.
--
-- `session_index` greps a normalized outline of every message; `session_read`
-- expands one window. Tool-result bodies (a single `out` record in this store
-- runs to 143 KB) and thinking are scrubbed to markers, so search costs
-- O(matches), never O(transcript). Mirrors maki's index/read split.

local truncate = require("maki.truncate")
local output_limits = require("maki.output_limits")

local SNIPPET_CHARS = 120
local ERROR_CHARS = 60
local TARGET_CHARS = 80
local DEFAULT_HITS = 20
local DEFAULT_LIST = 30
local DEFAULT_READ = 4
local SESSIONS = "sessions"

-- Parsed sessions keyed by id. braid: memory-only, drop if a session is ever
-- rewritten without a new mtime.
local memo = {}

local function sessions_dir()
  local state = maki.env.state_dir()
  if not state then
    return nil, "cannot resolve state dir"
  end
  local dir = maki.fs.joinpath(state, SESSIONS)
  if not maki.fs.metadata(dir) then
    return nil, "no sessions directory"
  end
  return dir
end

local function squeeze(s)
  return (s or ""):gsub("%s+", " ")
end

local function clipped(s, n)
  s = squeeze(s)
  return #s <= n and s or s:sub(1, n)
end

local function result_text(content)
  if type(content) == "string" then
    return content
  end
  for _, part in ipairs(type(content) == "table" and content or {}) do
    if type(part) == "table" and part.type == "text" then
      return part.text
    end
  end
  return ""
end

-- One searchable line per message. Tool targets carry the nouns worth
-- grepping (paths, commands, patterns); result bodies are markers only.
local function norm(content)
  local parts = {}
  for _, block in ipairs(content or {}) do
    local kind = block.type
    if kind == "text" then
      local t = squeeze(block.text)
      if t ~= "" then
        parts[#parts + 1] = t
      end
    elseif kind == "tool_use" then
      local input = block.input or {}
      local target = clipped(
        input.path or input.file_path or input.pattern or input.command or input.query or "",
        TARGET_CHARS
      )
      parts[#parts + 1] = "[" .. block.name .. (target ~= "" and " " .. target or "") .. "]"
    elseif kind == "tool_result" then
      parts[#parts + 1] = block.is_error and "[err: " .. clipped(result_text(block.content), ERROR_CHARS) .. "]" or "[ok]"
    end
  end
  return table.concat(parts, " ")
end

local function window(text, query, width)
  local at = text:lower():find(query:lower(), 1, true)
  if not at then
    return nil
  end
  local from = math.max(1, at - math.floor((width - #query) / 2))
  local to = math.min(#text, from + width - 1)
  return (from > 1 and "…" or "") .. text:sub(from, to) .. (to < #text and "…" or "")
end

local function ago(seconds)
  local d = math.max(os.time() - (seconds or 0), 0)
  if d < 3600 then
    return math.floor(d / 60) .. "m"
  end
  if d < 86400 then
    return math.floor(d / 3600) .. "h"
  end
  return math.floor(d / 86400) .. "d"
end

local function load(path, id)
  local meta = maki.fs.metadata(path)
  if not meta then
    return nil, "cannot stat " .. id
  end
  local cached = memo[id]
  if cached and cached.size == meta.size and cached.mtime == meta.mtime then
    return cached
  end
  local raw, err = maki.fs.read(path)
  if not raw then
    return nil, err
  end
  local session = { size = meta.size, mtime = meta.mtime or 0, msgs = {} }
  for _, line in ipairs(maki.split(raw, "\n")) do
    if line:sub(1, 1) == "{" then
      -- A live session can leave a half-written trailing line; skip it.
      local ok, rec = pcall(maki.json.decode, line)
      if ok and rec then
        if rec.t == "header" then
          session.id, session.cwd = rec.id, rec.cwd
        elseif rec.t == "meta" and rec.title then
          session.title = rec.title
        elseif rec.t == "msg" and rec.d then
          session.msgs[#session.msgs + 1] = { role = rec.d.role, text = norm(rec.d.content) }
        end
      end
    end
  end
  memo[id] = session
  return session
end

local function collect(query, limit, all)
  local dir, err = sessions_dir()
  if not dir then
    return nil, err
  end
  local files = maki.fs.glob("*.jsonl", { path = dir, sort = "mtime" })
  if not files then
    return nil, "cannot list sessions"
  end
  local cwd = maki.uv.cwd()
  local rows = {}
  for _, path in ipairs(files) do
    local id = maki.fs.basename(path):gsub("%.jsonl$", "")
    local session = load(path, id)
    if session and (all or session.cwd == cwd) then
      if query == "" then
        rows[#rows + 1] = string.format(
          "%s  %s  (%s, %d msgs, %s ago)",
          id,
          session.title or "untitled",
          session.cwd or "?",
          #session.msgs,
          ago(session.mtime)
        )
        if #rows >= limit then
          break
        end
      else
        for i, m in ipairs(session.msgs) do
          local snip = window(m.text, query, SNIPPET_CHARS)
          if snip then
            rows[#rows + 1] = string.format("%s %s#%d | %s", id, m.role, i, snip)
            if #rows >= limit then
              return rows
            end
          end
        end
      end
    end
  end
  return rows
end

maki.api.register_tool({
  name = "session_index",
  kind = "search",
  description = [[Search your past chat sessions.

- Case-insensitive literal match over a normalized outline; tool-result bodies and thinking are scrubbed, so a hit is cheap.
- Omit `query` to list recent sessions.
- Follow up with `session_read` to expand a hit.]],

  schema = {
    type = "object",
    properties = {
      query = { type = "string", description = "Literal text to find (case-insensitive). Omit to list sessions." },
      scope = { type = "string", description = "cwd (default) or all to search every project." },
      limit = { type = "integer", description = "Max rows (default 20, or 30 when listing)." },
    },
  },

  handler = function(input, ctx)
    local query = squeeze(input.query or "")
    local limit = input.limit or (query == "" and DEFAULT_LIST or DEFAULT_HITS)
    local rows, err = collect(query, limit, input.scope == "all")
    if not rows then
      return { llm_output = "error: " .. err, is_error = true }
    end
    if #rows == 0 then
      return query == "" and "no sessions found" or ("no matches for " .. query)
    end
    local max_lines, max_bytes = output_limits.resolve({}, ctx)
    return truncate(table.concat(rows, "\n"), max_lines, max_bytes)
  end,
})

maki.api.register_tool({
  name = "session_read",
  kind = "read",
  description = [[Read messages from a past session.

- Takes an id (or unique prefix) from `session_index` and returns its newest `last` messages, scrubbed the same way.]],

  schema = {
    type = "object",
    properties = {
      id = { type = "string", description = "Session id or unique prefix.", required = true },
      last = { type = "integer", description = "How many newest messages to return (default 4)." },
    },
    required = { "id" },
  },

  handler = function(input, ctx)
    local dir, err = sessions_dir()
    if not dir then
      return { llm_output = "error: " .. err, is_error = true }
    end
    local matches = maki.fs.glob(input.id .. "*.jsonl", { path = dir }) or {}
    local path = matches[1]
    if not path then
      return { llm_output = "error: no session matching " .. input.id, is_error = true }
    end
    local id = maki.fs.basename(path):gsub("%.jsonl$", "")
    local session, read_err = load(path, id)
    if not session then
      return { llm_output = "error: " .. read_err, is_error = true }
    end
    local count = math.min(input.last or DEFAULT_READ, #session.msgs)
    local rows = { string.format("%s  %s  (%s)", id, session.title or "untitled", session.cwd or "?") }
    for i = #session.msgs - count + 1, #session.msgs do
      rows[#rows + 1] = string.format("%s#%d  %s\n%s", id, i, session.msgs[i].role, session.msgs[i].text)
    end
    local max_lines, max_bytes = output_limits.resolve({}, ctx)
    return truncate(table.concat(rows, "\n"), max_lines, max_bytes)
  end,
})
