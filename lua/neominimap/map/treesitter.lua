local M = {}

local config = require("neominimap.config")
local api = vim.api
local treesitter = vim.treesitter

local namespace = api.nvim_create_namespace("neominimap_treesitter")

---@param group string
local function resolve_hl_link(group)
    local hl = vim.api.nvim_get_hl(0, { name = group })
    while hl.link do
        group = hl.link
        hl = vim.api.nvim_get_hl(0, { name = group })
    end
    return hl
end

---The effective foreground a capture group paints, or nil for a transparent
---one. Mirrors the highlighter's dotted-name fallback: "@a.b.c" falls back to
---"@a.b", then "@a", until a DEFINED group is found; that group's (possibly
---absent) fg is the answer, links followed. A capture that lands on no fg —
---@spell, helper captures, fg-less groups — paints nothing rather than
---erasing what sits below it.
---@param group string
---@return integer|nil fg
local function resolve_capture_fg(group)
    while group ~= "" do
        local hl = resolve_hl_link(group)
        if next(hl) ~= nil then
            return hl.fg
        end
        group = group:match("^(.*)%.[^.]*$") or ""
    end
    return nil
end

---@type table<string, integer|false> capture name -> fg (false = transparent)
local fg_cache = {}
---@type table<integer, string> fg -> minimap highlight group
local group_cache = {}

function M.clear_hl_cache()
    fg_cache = {}
    group_cache = {}
end

---@param capture string a capture name, without the leading "@"
---@return integer|nil fg
local capture_fg = function(capture)
    local cached = fg_cache[capture]
    if cached ~= nil then
        return cached or nil
    end
    local fg = resolve_capture_fg("@" .. capture)
    fg_cache[capture] = fg or false
    return fg
end

---@param fg integer
---@return string
local get_or_create_group = function(fg)
    local group = group_cache[fg]
    if not group then
        group = string.format("_Neominimap_%06x", fg)
        api.nvim_set_hl(0, group, { fg = string.format("#%06x", fg) })
        group_cache[fg] = group
    end
    return group
end

---@class (exact) Neominimap.BufferHighlight
---@field start_row integer
---@field end_row integer
---@field start_col integer
---@field end_col integer
---@field group string
---@field level integer The level on the language tree. 0 = root

---@async
---@param bufnr integer
---@return Neominimap.BufferHighlight[]
local get_buffer_highlights_co = function(bufnr)
    local co = require("neominimap.cooperative")
    local co_api = require("neominimap.cooperative.api")
    local highlights = {} ---@type Neominimap.BufferHighlight[]

    ---@param parser vim.treesitter.LanguageTree
    ---@param level integer
    local function traverse(parser, level)
        local trees = (function()
            if vim.fn.has("0.11") == 1 then
                return co_api.parse_language_tree_co(parser)
            else
                parser:parse()
                return parser:trees()
            end
        end)()

        co.for_in_co(pairs(trees))(100, function(_, tree) ---@cast tree TSTree
            local root = tree:root()
            local query = treesitter.query.get(parser:lang(), "highlights")
            if not query then
                return
            end
            local iter = query:iter_captures(root, bufnr)
            co.for_in_co(iter)(5000, function(capture_id, node)
                local hl_group = query.captures[capture_id]
                local start_row, start_col, end_row, end_col = node:range()
                highlights[#highlights + 1] = {
                    start_row = start_row + 1,
                    start_col = start_col,
                    end_row = end_row + 1,
                    end_col = end_col,
                    group = hl_group,
                    level = level,
                }
            end)
        end)

        co.for_in_co(pairs(parser:children()))(1, function(_, child_parser)
            traverse(child_parser, level + 1)
        end)
    end

    local ok, parser = pcall(treesitter.get_parser, bufnr)
    if not ok or not parser then
        return {}
    end

    traverse(parser, 0)

    return highlights
end

---@class (exact) Neominimap.MinimapHighlight
---@field line integer 0-based minimap row
---@field start_cell integer 1-based first minimap cell (codepoint) of the run
---@field end_cell integer 1-based last minimap cell (inclusive)
---@field group string

---Extracts the highlighting from the given buffer using treesitter.
---
---Captures resolve to effective COLORS first — applied in order, later
---captures painting over earlier ones, fg-less captures transparent — the
---same layering the editor itself renders. Each minimap cell then takes the
---most common effective color among the codepoints it covers; ties break on
---the lower color value, so the same buffer always renders the same.
---@async
---@param bufnr integer
---@return Neominimap.MinimapHighlight[]
M.extract_highlights_co = function(bufnr)
    local text = require("neominimap.map.text")
    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local tabwidth = vim.bo[bufnr].tabstop
    local line_count = #lines
    local minimap_width = config:get_minimap_width()
    local minimap_height = math.ceil(line_count / 4 / config.y_multiplier)

    ---@type integer[][]
    local utf8_pos_list = vim.tbl_map(vim.str_utf_pos, lines)
    ---@type integer[][]
    local code_point_list = vim.tbl_map(function(str)
        return text.codepoints_pos(str, tabwidth)
    end, lines)

    ---@type fun(row:integer, byte_idx:integer):integer? byte_idx is 1-based
    local byte_to_codepoint_idx = function(row, byte_idx)
        if code_point_list[row] == nil then
            return nil
        end
        local utf8_idx = text.byte_index_to_utf8_index(byte_idx, utf8_pos_list[row])
        return code_point_list[row][utf8_idx]
    end

    local co = require("neominimap.cooperative")

    -- Paint pass: the effective color of every codepoint.
    -- get_buffer_highlights_co yields captures in application order (a tree's
    -- own captures in query order, injections after their host), so painting
    -- is a plain overwrite; transparency is the skip.
    ---@type table<integer, table<integer, integer>> row -> codepoint -> fg
    local colors = {}
    co.for_co(1, line_count, 1, 10000, function(row)
        colors[row] = {}
    end)
    co.defer_co()
    if not api.nvim_buf_is_valid(bufnr) then
        return {}
    end

    co.for_in_co(ipairs(get_buffer_highlights_co(bufnr)))(2000, function(_, h) ---@cast h Neominimap.BufferHighlight
        local fg = capture_fg(h.group)
        if fg then
            -- Treesitter ranges are 0-based with an exclusive end column, so
            -- +1 makes start 1-based while the raw end column IS the 1-based
            -- inclusive last byte; an end column of 0 means the capture
            -- stopped at the previous row's boundary.
            local last_row = h.end_row
            local last_col = h.end_col
            if last_col == 0 then
                last_row = last_row - 1
                last_col = math.huge
            end
            for row = h.start_row, math.min(last_row, line_count) do
                local from = row == h.start_row and h.start_col + 1 or 1
                local to = row == last_row and math.min(last_col, #lines[row]) or #lines[row]
                local from_cp = byte_to_codepoint_idx(row, from)
                local to_cp = byte_to_codepoint_idx(row, to)
                if from_cp ~= nil and to_cp ~= nil then
                    local line_colors = colors[row]
                    for col = from_cp, to_cp do
                        line_colors[col] = fg
                    end
                end
            end
        end
    end)
    co.defer_co()
    if not api.nvim_buf_is_valid(bufnr) then
        return {}
    end

    -- Downscale: vote per cell over the painted codepoints' colors.
    local fold = require("neominimap.map.fold")
    local coord = require("neominimap.map.coord")
    local folds = fold.get_cached_folds(bufnr)
    ---@type table<integer, table<integer, table<integer, integer>>> mrow -> mcol -> fg -> count
    local cells = {}
    co.for_co(1, minimap_height, 1, 10000, function(mrow)
        local line = {}
        for mcol = 1, minimap_width do
            line[mcol] = {}
        end
        cells[mrow] = line
    end)
    co.defer_co()
    if not api.nvim_buf_is_valid(bufnr) then
        return {}
    end

    co.for_co(1, line_count, 1, 1000, function(row)
        local vrow, hide = fold.subtract_fold_lines(folds, row)
        if not hide then
            for col, fg in pairs(colors[row]) do
                local mrow, mcol = coord.codepoint_to_mcodepoint(vrow, col)
                if cells[mrow] and mcol <= minimap_width then
                    local counts = cells[mrow][mcol]
                    counts[fg] = (counts[fg] or 0) + 1
                end
            end
        end
    end)
    co.defer_co()
    if not api.nvim_buf_is_valid(bufnr) then
        return {}
    end

    ---@type Neominimap.MinimapHighlight[]
    local ret = {}
    co.for_co(1, minimap_height, 1, 5000, function(mrow)
        ---@type table<integer, integer>
        local winner = {}
        for mcol = 1, minimap_width do
            local best, best_count
            for fg, count in pairs(cells[mrow][mcol]) do
                if best == nil or count > best_count or (count == best_count and fg < best) then
                    best, best_count = fg, count
                end
            end
            winner[mcol] = best
        end
        -- Consecutive cells that agree merge into one extmark.
        local x = 1
        while x <= minimap_width do
            local fg = winner[x]
            if fg == nil then
                x = x + 1
            else
                local end_x = x
                while end_x < minimap_width and winner[end_x + 1] == fg do
                    end_x = end_x + 1
                end
                ret[#ret + 1] = {
                    line = mrow - 1,
                    start_cell = x,
                    end_cell = end_x,
                    group = get_or_create_group(fg),
                }
                x = end_x + 1
            end
        end
    end)

    return ret
end

--- Applies the given highlights to the given buffer.
--- If there are multiple highlights for the same position, all of them will be applied.
---
--- Cell indices are converted to byte columns against the rendered minimap
--- line itself: minimap glyphs have no fixed byte width (the octant set mixes
--- 1-byte spaces, 3-byte block elements and 4-byte Symbols for Legacy
--- Computing), so a cell's byte offset depends on every glyph before it.
---@async
---@param mbufnr integer
---@param highlights Neominimap.MinimapHighlight[]
M.apply_co = function(mbufnr, highlights)
    api.nvim_buf_clear_namespace(mbufnr, namespace, 0, -1)
    local lines = api.nvim_buf_get_lines(mbufnr, 0, -1, false)
    ---@type table<integer, integer[]> row -> byte start of each codepoint
    local pos_cache = {}
    local co = require("neominimap.cooperative")
    co.for_in_co(ipairs(highlights))(5000, function(_, hl)
        local line = lines[hl.line + 1]
        if line then
            local pos = pos_cache[hl.line]
            if not pos then
                pos = vim.str_utf_pos(line)
                pos_cache[hl.line] = pos
            end
            local col = pos[hl.start_cell] and pos[hl.start_cell] - 1 or #line
            local end_col = pos[hl.end_cell + 1] and pos[hl.end_cell + 1] - 1 or #line
            if col < end_col then
                api.nvim_buf_set_extmark(mbufnr, namespace, hl.line, col, {
                    end_col = end_col,
                    hl_group = hl.group,
                })
            end
        end
    end)
end

return M
