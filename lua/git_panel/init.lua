-- Dependency-free Git dashboard. Public entry points: open(), close(), refresh().
local api, fn, uv = vim.api, vim.fn, (vim.uv or vim.loop)
local github = require('git_panel.github')
local help_ui = require('git_panel.help')
local local_model = require('git_panel.model')
local signed_merge = require('git_panel.signed_merge')
local connections = require('git_panel.connections')

local function attach_pane(win, role, content)
  local loaded, panes = pcall(require, 'ux_chrome.panes')
  if not loaded then return false end
  local ok, err = pcall(panes.attach, {
    id = 'git.panel.' .. role, role = role, content = content, window = win,
  })
  if not ok then vim.notify('GitPanel Chrome pane: ' .. tostring(err), vim.log.levels.WARN) end
  return ok
end

local VIEWS = {
  { id = 'work', label = 'Changes' },
  { id = 'history', label = 'History' },
  { id = 'actions', label = 'Actions', github = true },
  { id = 'issues', label = 'Issues', github = true },
  { id = 'pulls', label = 'Pull Requests', github = true },
}
local VIEW_INDEX = {}
for index, view in ipairs(VIEWS) do VIEW_INDEX[view.id] = index end

local DEFAULT_CONFIG = {
  help = {
    border = 'rounded',
    max_width = 88,
  },
  github = {
    enabled = true,
    profile = nil,
    profiles = {},
    transport = 'auto',
    host = nil,
    repository = nil,
    remote_path_prefix = nil,
    api_url = nil,
    allow_insecure_http = false,
    api_version = '2026-03-10',
    token_provider = nil,
    refresh_interval = 60,
    per_page = 30,
    timeout = 15000,
    merge_backend = 'api',
    gh_command = 'gh',
    curl_command = 'curl',
  },
}

local M = {
  buf = nil,
  win = nil,
  mode = nil,        -- 'tab' | 'split'
  view = 'work',     -- 'work' (Staged/Unstaged) | 'history' (Committed/Uncommitted)
  folds = { pushed = true },  -- section_id -> collapsed; Pushed starts folded (long history)
  root = nil,        -- repo root for the active panel
  line_map = {},     -- 1-indexed line number -> item descriptor
  model = nil,       -- last completed asynchronous local snapshot
  detail_buf = nil,  -- contextual preview rail (wide tab layout only)
  detail_win = nil,
  tab = nil,
  model_generation = 0,
  detail_generation = 0,
  cursor_generation = 0,
  prev_win = nil,    -- window we came from (for opening files)
  start_dir = nil,   -- dir used to locate the repo
  config = vim.deepcopy(DEFAULT_CONFIG),
}
local PANEL_WIDTH = 48
local WIDE_MIN_COLUMNS = 120
local DETAIL_MIN_WIDTH = 38
local ns = api.nvim_create_namespace('gitpanel')
local home = uv.os_homedir() or ''
local github_runtime = {
  root = nil,
  repository = nil,
  repository_error = nil,
  client = nil,
  views = {},
  generation = 0,
}
local configured_github = vim.deepcopy(DEFAULT_CONFIG.github)

-- ---------------------------------------------------------------------------
-- git runner: argv only (no shell), explicit cwd, stable locale, no locks.
-- ---------------------------------------------------------------------------
local function git(args, opts)
  opts = opts or {}
  local cmd = { 'git' }
  for _, a in ipairs(args) do cmd[#cmd + 1] = a end
  local res = vim.system(cmd, {
    text = true,
    cwd = opts.cwd or M.root or M.start_dir or fn.getcwd(),
    env = { LC_ALL = 'C', GIT_OPTIONAL_LOCKS = '0' },
  }):wait()
  if res.code ~= 0 and not opts.allow_fail then
    vim.notify('git ' .. table.concat(args, ' ') .. '\n' ..
      ((res.stderr or ''):gsub('%s+$', '')), vim.log.levels.ERROR)
  end
  return res
end
local function chomp(s)
  local trimmed = (s or ''):gsub('%s+$', '')
  return trimmed
end
local function trim(s)
  return (s or ''):match('^%s*(.-)%s*$')
end
local function is_github_view(view)
  local index = VIEW_INDEX[view]
  return index and VIEWS[index].github == true or false
end

local function reset_github_runtime(root)
  github_runtime.generation = github_runtime.generation + 1
  github_runtime.root = root
  github_runtime.repository = nil
  github_runtime.repository_error = nil
  github_runtime.client = nil
  github_runtime.views = {}
end

local function github_state(view)
  local state = github_runtime.views[view]
  if not state then
    state = { status = 'idle', items = {}, updated_at = nil, request_id = 0 }
    github_runtime.views[view] = state
  end
  return state
end

local function resolve_github_runtime()
  local opts = M.config.github
  if not opts.enabled then
    github_runtime.repository_error = 'GitHub integration is disabled in setup().'
    return nil
  end
  if github_runtime.root ~= M.root then reset_github_runtime(M.root) end
  if github_runtime.repository or github_runtime.repository_error then
    return github_runtime.repository
  end

  local repository, err = github.resolve_repository(M.root, opts)
  github_runtime.repository = repository
  github_runtime.repository_error = err
  if repository then
    local client_opts = vim.tbl_deep_extend('force', vim.deepcopy(opts), { root = M.root })
    local factory = opts.client_factory or github.new
    github_runtime.client = factory(client_opts)
  end
  return repository
end

local function github_snapshot(view)
  local repository = resolve_github_runtime()
  local state = github_state(view)
  return {
    repository = repository,
    repository_error = github_runtime.repository_error,
    status = state.status,
    items = state.items,
    error = state.error,
    updated_at = state.updated_at,
    transport = state.transport,
  }
end


local function github_dashboard_snapshot()
  local snapshots = {}
  for _, view in ipairs({ 'overview', 'actions', 'issues', 'pulls' }) do
    snapshots[view] = github_snapshot(view)
  end
  return snapshots
end

local function github_summary(snapshots)
  snapshots = snapshots or {}
  local summary = {}
  for _, view in ipairs({ 'issues', 'pulls' }) do
    local snapshot = snapshots[view]
    if snapshot and snapshot.status == 'ready' then
      summary[view] = { count = #(snapshot.items or {}) }
    end
  end
  local actions = snapshots.actions
  if actions and actions.status == 'ready' then
    local run = (actions.items or {})[1]
    local value = run and (run.conclusion or run.status)
    local glyph = ({ success = '✓', failure = '✗', cancelled = '○',
      in_progress = '●', queued = '◌' })[value] or (#(actions.items or {}) > 0 and '·' or '0')
    summary.actions = { state = glyph, count = #(actions.items or {}) }
  end
  return summary
end

local function remote_names()
  local res = git({ 'remote' }, { allow_fail = true })
  local names = {}
  if res.code == 0 then
    for name in (res.stdout or ''):gmatch('[^\r\n]+') do
      names[#names + 1] = name
    end
  end
  return names
end

-- In-progress sequencer operation, if any. Merge/cherry-pick/revert leave a
-- *_HEAD marker; rebase leaves a state directory. All live in the (possibly
-- per-worktree) git dir, so resolve it once and stat the markers — one git
-- call instead of one per marker, since this runs on every refresh.
local function op_state()
  local gd = chomp(git({ 'rev-parse', '--absolute-git-dir' }, { allow_fail = true }).stdout)
  if gd == '' then return nil end
  local function has(name) return uv.fs_stat(gd .. '/' .. name) ~= nil end
  if has('MERGE_HEAD') then return 'merge' end
  if has('CHERRY_PICK_HEAD') then return 'cherry-pick' end
  if has('REVERT_HEAD') then return 'revert' end
  if has('rebase-merge') or has('rebase-apply') then return 'rebase' end
  return nil
end

-- ---------------------------------------------------------------------------
-- Rendering: model -> (lines, line_map, highlights)
-- ---------------------------------------------------------------------------
local function tilde(p)
  if home ~= '' and p:sub(1, #home) == home then return '~' .. p:sub(#home + 1) end
  return p
end
local function status_letter(rec)
  -- prefer the meaningful side; renames show R, untracked ?, etc.
  local c = rec.x ~= '.' and rec.x or rec.y
  if c == '.' or c == nil then c = '?' end
  return c
end

local function relative_time(timestamp)
  timestamp = tonumber(timestamp)
  if not timestamp then return '' end
  local seconds = math.max(0, os.time() - timestamp)
  if seconds < 60 then return 'now' end
  if seconds < 3600 then return math.floor(seconds / 60) .. 'm ago' end
  if seconds < 86400 then return math.floor(seconds / 3600) .. 'h ago' end
  if seconds < 86400 * 30 then return math.floor(seconds / 86400) .. 'd ago' end
  if seconds < 86400 * 365 then return math.floor(seconds / (86400 * 30)) .. 'mo ago' end
  return math.floor(seconds / (86400 * 365)) .. 'y ago'
end

local function render(m)
  local lines, map, hls = {}, {}, {}
  local panel_width = (M.win and api.nvim_win_is_valid(M.win))
      and api.nvim_win_get_width(M.win) or PANEL_WIDTH
  local function emit(text, item, hl)
    lines[#lines + 1] = text
    local lnum = #lines
    if item then map[lnum] = item end
    if hl then hls[#hls + 1] = { line = lnum - 1, cs = 0, ce = #text, group = hl } end
    return lnum
  end
  local function span(lnum, cs, ce, group)
    hls[#hls + 1] = { line = lnum - 1, cs = cs, ce = ce, group = group }
  end
  local function folded(id) return M.folds[id] == true end
  local function chevron(id) return folded(id) and '▸' or '▾' end
  local function row_limit() return math.max(24, panel_width - 3) end
  local function shorten(text, limit)
    text = tostring(text or '')
    if fn.strdisplaywidth(text) <= limit then return text end
    local chars = fn.strchars(text)
    while chars > 1 do
      local candidate = fn.strcharpart(text, 0, chars - 1) .. '…'
      if fn.strdisplaywidth(candidate) <= limit then return candidate end
      chars = chars - 1
    end
    return '…'
  end
  local function one_line(text)
    return trim(tostring(text or ''):gsub('%c', ' '):gsub('%s+', ' '))
  end

  -- ---- repository identity and working-state summary -------------------
  local name = fn.fnamemodify(M.root or '', ':t')
  local hline = emit('  ' .. name, { kind = 'head' }, 'GitPanelHeader')
  span(hline, 2, 2 + #name, 'GitPanelTitle')
  if M.mode == 'tab' then emit('  ' .. tilde(M.root or ''), nil, 'GitPanelHint') end

  local branch
  if m.head.unborn then
    branch = (m.head.branch or 'HEAD') .. ' · no commits yet'
  elseif m.head.detached then
    branch = 'detached @ ' .. (m.head.sha or '?')
  else
    branch = m.head.branch or '?'
    if m.head.upstream then branch = branch .. '  →  ' .. m.head.upstream end
  end
  local sync = {}
  if (m.head.ahead or 0) > 0 then sync[#sync + 1] = '↑' .. m.head.ahead .. ' ahead' end
  if (m.head.behind or 0) > 0 then sync[#sync + 1] = '↓' .. m.head.behind .. ' behind' end
  if m.synced then sync[#sync + 1] = '✓ synced' end
  if not m.head.upstream and not m.head.unborn then sync[#sync + 1] = 'no upstream' end
  emit(shorten('  ' .. branch .. (#sync > 0 and ('  ·  ' .. table.concat(sync, '  ')) or ''), row_limit()),
    { kind = 'head' }, 'GitPanelHeader')

  local change_count = #m.staged + #m.unstaged + #m.untracked + #m.conflicts
  local state = m.working_clean and '✓ clean' or ('● ' .. change_count .. ' change' ..
    (change_count == 1 and '' or 's'))
  local chips = { state, tostring(m.commit_count or 0) .. ' commits',
    tostring(#m.branches) .. ' branches', tostring(#m.worktrees) .. ' worktrees' }
  emit('  ' .. table.concat(chips, '  ·  '), nil,
    m.working_clean and 'GitPanelStaged' or 'GitPanelUnstaged')
  if m.latest then
    emit(shorten('  Latest  ' .. m.latest.sha .. '  ' .. m.latest.subject ..
      (m.latest.author and ('  ·  ' .. m.latest.author) or '') ..
      (m.latest.timestamp and ('  ·  ' .. relative_time(m.latest.timestamp)) or ''), row_limit()),
      { kind = 'commit', value = m.latest.sha, section = 'latest', data = m.latest }, 'GitPanelHint')
  end
  emit('')

  local function tab_line(first, last)
    local text, tabs = '  ', {}
    for index = first, last do
      local view = VIEWS[index]
      local summary = m.github_summary and m.github_summary[view.id]
      local badge = ''
      if summary then
        if view.id == 'actions' and summary.state then badge = ' ' .. summary.state
        elseif summary.count ~= nil then badge = ' ' .. summary.count end
      end
      local label = (view.id == M.view and '▸ ' or '  ') .. index .. ' ' .. view.label .. badge
      if index > first then text = text .. '   ' end
      local start_col = #text
      text = text .. label
      tabs[#tabs + 1] = { view = view, start_col = start_col, end_col = #text }
    end
    local line = emit(text)
    for _, tab in ipairs(tabs) do
      span(line, tab.start_col, tab.end_col,
        tab.view.id == M.view and 'GitPanelTabActive' or 'GitPanelTabInactive')
    end
  end
  if M.mode == 'split' then
    tab_line(1, 3)
    tab_line(4, 5)
  else
    tab_line(1, #VIEWS)
  end
  -- in-progress merge/rebase/cherry-pick/revert banner
  if m.op then
    local OP = { merge = 'MERGING', rebase = 'REBASING',
                 ['cherry-pick'] = 'CHERRY-PICKING', revert = 'REVERTING' }
    local n = #m.conflicts
    local status = (n > 0) and (n .. ' conflict' .. (n == 1 and '' or 's') .. ' to resolve')
                            or 'all conflicts resolved'
    -- git inverts ours/theirs during a rebase (you replay onto the base), so
    -- spell out the meaning to avoid discarding the wrong side.
    local sides = (m.op == 'rebase') and 'o ours(base) · t theirs(your commit)'
                                      or  'o ours · t theirs'
    emit('  ⚠ ' .. (OP[m.op] or m.op:upper()) .. ' — ' .. status ..
      '   ·  ' .. sides .. ' · > continue · A abort', { kind = 'op' }, 'GitPanelOp')
  end
  emit('')

  -- ---- a foldable section with header + body rows ------------------------
  local function section(id, title, count, render_body)
    local head_item = { kind = 'section', section = id }
    -- an empty section is one dimmed line: present for orientation, quiet
    -- enough that populated sections carry the eye
    local empty = count == 0 or count == '0'
    local h = emit(' ' .. chevron(id) .. ' ' .. title ..
      (count ~= nil and ('  (' .. count .. ')') or ''), head_item,
      empty and 'GitPanelHint' or 'GitPanelSection')
    span(h, 1, 4, 'GitPanelHint')
    if not folded(id) then render_body() end
  end
  local function empty_row(text)
    emit('     ' .. text, nil, 'GitPanelHint')
  end
  -- a file/change row with a coloured status letter
  local function file_row(rec, section_id, staged)
    local letter = status_letter(rec)
    local disp = rec.path
    if rec.orig then disp = rec.orig .. ' → ' .. rec.path end
    local prefix = '     ' .. letter .. '  '
    local lnum = emit(shorten(prefix .. disp, row_limit()),
      { kind = 'file', value = rec.path, orig = rec.orig, section = section_id,
        staged = staged, untracked = (letter == '?'),
        conflict = (rec.badge == 'conflict') or nil, data = rec })
    local grp = 'GitPanelUnstaged'
    if rec.badge == 'conflict' or letter == 'U' then grp = 'GitPanelConflict'
    elseif letter == '?' then grp = 'GitPanelUntracked'
    elseif staged then grp = 'GitPanelStaged' end
    span(lnum, 5, 6, grp)                       -- the status letter
    if rec.orig then span(lnum, #prefix, #prefix + #rec.orig, 'GitPanelHint') end
  end
  -- a conflicted-file row: <XY>  <path>   (both modified)
  local CONFLICT_KIND = {
    DD = 'both deleted', AU = 'added by us', UD = 'deleted by them',
    UA = 'added by them', DU = 'deleted by us', AA = 'both added', UU = 'both modified',
  }
  local function conflict_row(rec)
    local xy = (rec.x or '?') .. (rec.y or '?')
    local label = CONFLICT_KIND[xy] or 'unmerged'
    local prefix = '     ' .. xy .. '  '
    local lnum = emit(prefix .. rec.path .. '   (' .. label .. ')',
      { kind = 'file', value = rec.path, section = 'conflicts', conflict = true })
    span(lnum, 5, 5 + #xy, 'GitPanelConflict')            -- the XY code
    span(lnum, #prefix + #rec.path, -1, 'GitPanelHint')   -- the "(label)"
  end
  -- a commit row: <sha> <sig> <subject>  (refs)
  -- sig glyph from git's %G?: ✓ good signature (G, or U = good/unknown trust),
  -- ✗ unsigned (N), ? signed but unverifiable here (E = key missing),
  -- ! bad/expired/revoked (B/X/Y/R). Absent sig field (push rows reuse
  -- commit_row callers that predate the field) renders no glyph.
  local sig_glyphs = {
    G = { '✓', 'GitPanelSigOk' },   U = { '✓', 'GitPanelSigOk' },
    N = { '✗', 'GitPanelSigNone' }, E = { '?', 'GitPanelSigUnknown' },
    B = { '!', 'GitPanelSigBad' },  X = { '!', 'GitPanelSigBad' },
    Y = { '!', 'GitPanelSigBad' },  R = { '!', 'GitPanelSigBad' },
  }
  local function commit_row(c, section_id)
    local refs = (c.refs and c.refs ~= '') and ('  (' .. c.refs .. ')') or ''
    local prefix = '     '
    local glyph, glyph_hl = '', nil
    local g = c.sig and sig_glyphs[c.sig]
    if g then glyph, glyph_hl = g[1] .. ' ', g[2] end
    local full_row = prefix .. c.sha .. '  ' .. glyph .. c.subject .. refs
    local row = shorten(full_row, row_limit())
    local lnum = emit(row,
      { kind = 'commit', value = c.sha, section = section_id, data = c })
    span(lnum, #prefix, #prefix + #c.sha, 'GitPanelHash')
    if glyph_hl then
      span(lnum, #prefix + #c.sha + 2, #prefix + #c.sha + 2 + #glyph, glyph_hl)
    end
    if refs ~= '' and row == full_row then
      span(lnum, #prefix + #c.sha + 2 + #glyph + #c.subject, -1, 'GitPanelRef')
    end
  end
  -- a push row: <sha>  <date>  <reflog subject>. <CR> shows old..new commits.
  local function push_row(e)
    local prefix = '     '
    local date = (e.date and e.date ~= '') and (e.date .. '  ') or ''
    local lnum = emit(prefix .. e.short .. '  ' .. date .. (e.subject or ''),
      { kind = 'push', value = e.new, old = e.old, section = 'pushed' })
    span(lnum, #prefix, #prefix + #e.short, 'GitPanelHash')
    if date ~= '' then
      span(lnum, #prefix + #e.short + 2, #prefix + #e.short + 2 + #e.date, 'GitPanelHint')
    end
  end

  local function item_date(item)
    local timestamp = item.updated_at or item.created_at
    return timestamp and timestamp:sub(1, 10) or nil
  end

  local function github_map_item(item, section_id)
    return {
      kind = 'github',
      resource = item.kind,
      value = item.id,
      section = section_id,
      url = item.url,
      data = item,
    }
  end

  local ACTION_STATE = {
    success = { '✓', 'GitPanelGitHubSuccess' },
    failure = { '✗', 'GitPanelGitHubFailure' },
    timed_out = { '!', 'GitPanelGitHubFailure' },
    action_required = { '!', 'GitPanelGitHubFailure' },
    cancelled = { '○', 'GitPanelGitHubMuted' },
    skipped = { '○', 'GitPanelGitHubMuted' },
    neutral = { '○', 'GitPanelGitHubMuted' },
    in_progress = { '●', 'GitPanelGitHubRunning' },
    queued = { '◌', 'GitPanelGitHubQueued' },
    requested = { '◌', 'GitPanelGitHubQueued' },
    waiting = { '◌', 'GitPanelGitHubQueued' },
    pending = { '◌', 'GitPanelGitHubQueued' },
  }

  local function action_row(item)
    local state = item.conclusion or item.status or 'unknown'
    local state_style = ACTION_STATE[state] or { '?', 'GitPanelGitHubMuted' }
    local prefix = '     ' .. state_style[1] .. '  '
    local title = item.name .. (item.number and (' #' .. item.number) or '')
    if item.title and item.title ~= item.name then title = title .. ' — ' .. item.title end
    local metadata = { state:gsub('_', ' ') }
    if item.branch then metadata[#metadata + 1] = item.branch end
    if item.event then metadata[#metadata + 1] = item.event end
    if item.actor then metadata[#metadata + 1] = '@' .. item.actor end
    local date = item_date(item)
    if date then metadata[#metadata + 1] = date end
    local row = shorten(prefix .. title .. '  [' .. table.concat(metadata, ' · ') .. ']', row_limit())
    local lnum = emit(row, github_map_item(item, 'github-actions'))
    span(lnum, 5, 5 + #state_style[1], state_style[2])
  end

  local function issue_row(item)
    local number = '#' .. tostring(item.number or '?')
    local prefix = '     ' .. number .. '  '
    local metadata = {}
    if item.author then metadata[#metadata + 1] = '@' .. item.author end
    if item.comments and item.comments > 0 then
      metadata[#metadata + 1] = item.comments .. ' comment' .. (item.comments == 1 and '' or 's')
    end
    local labels = {}
    for index = 1, math.min(2, #(item.labels or {})) do labels[#labels + 1] = item.labels[index] end
    if #labels > 0 then metadata[#metadata + 1] = table.concat(labels, ', ') end
    local date = item_date(item)
    if date then metadata[#metadata + 1] = date end
    local suffix = #metadata > 0 and ('  [' .. table.concat(metadata, ' · ') .. ']') or ''
    local row = shorten(prefix .. item.title .. suffix, row_limit())
    local lnum = emit(row, github_map_item(item, 'github-issues'))
    span(lnum, 5, 5 + #number, 'GitPanelGitHubNumber')
  end

  local function pull_row(item)
    local number = '#' .. tostring(item.number or '?')
    local prefix = '     ' .. number .. '  '
    local metadata = {}
    if item.draft then metadata[#metadata + 1] = 'draft' end
    if item.head or item.base then metadata[#metadata + 1] = (item.head or '?') .. ' → ' .. (item.base or '?') end
    if item.author then metadata[#metadata + 1] = '@' .. item.author end
    local date = item_date(item)
    if date then metadata[#metadata + 1] = date end
    local suffix = #metadata > 0 and ('  [' .. table.concat(metadata, ' · ') .. ']') or ''
    local row = shorten(prefix .. item.title .. suffix, row_limit())
    local lnum = emit(row, github_map_item(item, 'github-pulls'))
    span(lnum, 5, 5 + #number, item.draft and 'GitPanelGitHubMuted' or 'GitPanelGitHubNumber')
  end

  local function render_branches()
    section('branches', 'Branches', #m.branches, function()
    local TRACK_GLYPH = { ['='] = '✓', ['>'] = '↑', ['<'] = '↓', ['<>'] = '↕' }
    for _, b in ipairs(m.branches) do
      local marker = b.current and '*' or ' '
      local row = '     ' .. marker .. ' ' .. b.name
      local tr = b.track ~= '' and (TRACK_GLYPH[b.track] or b.track) or ''
      if tr ~= '' then row = row .. '  ' .. tr end
      if b.worktree and not b.current then
        row = row .. '  ⊘ ' .. fn.fnamemodify(b.worktree, ':t')
      end
      if M.mode == 'tab' and b.subject and b.subject ~= '' then
        row = row .. '  ·  ' .. b.subject
        if b.timestamp then row = row .. '  ' .. relative_time(b.timestamp) end
      end
      row = shorten(row, row_limit())
      local lnum = emit(row,
        { kind = 'branch', value = b.name, current = b.current, worktree = b.worktree,
          upstream = b.upstream, remote = b.remote, remote_ref = b.remote_ref, data = b })
      if b.current then span(lnum, 5, 7 + #b.name, 'GitPanelBranchCurrent')
      elseif b.worktree then span(lnum, 7 + #b.name, -1, 'GitPanelHint') end
    end
    end)
  end

  local function render_worktrees()
    section('worktrees', 'Worktrees', #m.worktrees, function()
      for _, w in ipairs(m.worktrees) do
        local marker = w.current and '*' or ' '
        local flags = {}
        if w.flags.locked then flags[#flags + 1] = 'locked' end
        if w.flags.prunable then flags[#flags + 1] = 'prunable' end
        local row = '     ' .. marker .. ' ' .. tilde(w.path) .. '   ' .. w.label
        if #flags > 0 then row = row .. '  [' .. table.concat(flags, ',') .. ']' end
        local lnum = emit(shorten(row, row_limit()),
          { kind = 'worktree', value = w.path, current = w.current, data = w })
        if w.current then span(lnum, 5, #row, 'GitPanelWorktreeCurrent') end
      end
    end)
  end

  local function render_stashes()
    if #m.stashes == 0 then return end
    section('stashes', 'Stashes', #m.stashes, function()
      for _, stash in ipairs(m.stashes) do
        local row = '     ' .. stash.name .. '  ' .. stash.subject
        if stash.timestamp then row = row .. '  ·  ' .. relative_time(stash.timestamp) end
        local lnum = emit(shorten(row, row_limit()),
          { kind = 'stash', value = stash.name, data = stash, section = 'stashes' })
        span(lnum, 5, 5 + #stash.name, 'GitPanelHash')
      end
    end)
  end

  local function render_tags()
    if #m.tags == 0 then return end
    section('tags', 'Tags', #m.tags, function()
      for index = 1, math.min(#m.tags, 12) do
        local tag = m.tags[index]
        local row = '     ' .. tag.name
        if tag.subject ~= '' then row = row .. '  ' .. tag.subject end
        if tag.timestamp then row = row .. '  ·  ' .. relative_time(tag.timestamp) end
        emit(shorten(row, row_limit()), { kind = 'tag', value = tag.name, data = tag, section = 'tags' })
      end
      if #m.tags > 12 then empty_row('… ' .. (#m.tags - 12) .. ' more tags') end
    end)
  end

  local function render_recent(limit)
    section('committed', 'Recent commits', math.min(#m.commits, limit), function()
      if #m.commits == 0 then return empty_row('(no commits yet)') end
      for index = 1, math.min(#m.commits, limit) do commit_row(m.commits[index], 'committed') end
    end)
  end

  -- ---- Changes region: divider that toggles the view --------------------
  local function divider(label, hint)
    local lnum = emit('── ' .. label .. ' ' .. string.rep('─', math.max(2, row_limit() - #label - 4)),
      { kind = 'viewheader' }, 'GitPanelDivider')
    -- hint row only when it carries information the header hints don't
    if hint then emit('     ' .. hint, nil, 'GitPanelHint') end
  end

  if M.view == 'work' then
    divider('Working tree')
    if m.working_clean then
      emit('     ✓ Working tree clean', { kind = 'clean' }, 'GitPanelStaged')
    end
    if m.op or #m.conflicts > 0 then
      section('conflicts', 'Conflicts', #m.conflicts, function()
        if #m.conflicts == 0 then
          return empty_row('(all resolved — > continue · A abort)')
        end
        for _, r in ipairs(m.conflicts) do conflict_row(r) end
      end)
    end
    if #m.staged > 0 then
      section('staged', 'Staged', #m.staged, function()
        for _, r in ipairs(m.staged) do file_row(r, 'staged', true) end
      end)
    end
    if #m.unstaged > 0 then
      section('unstaged', 'Unstaged', #m.unstaged, function()
        for _, r in ipairs(m.unstaged) do file_row(r, 'unstaged', false) end
      end)
    end
    if #m.untracked > 0 then
      section('untracked', 'Untracked', #m.untracked, function()
        for _, r in ipairs(m.untracked) do
          file_row({ x = '?', y = '?', path = r.path }, 'untracked', false)
        end
      end)
    end
    local ucount = (#m.unpushed > 50) and '50+' or #m.unpushed
    section('unpushed', 'Outgoing commits', ucount, function()
      if #m.unpushed == 0 then
        -- the publish affordance is real information; plain emptiness is not
        if not m.has_remotes then empty_row('(no remote configured — P to publish)') end
        return
      end
      local shown = math.min(#m.unpushed, 50)
      for i = 1, shown do commit_row(m.unpushed[i], 'unpushed') end
      if #m.unpushed > 50 then
        empty_row('… more commits not shown (see ↑ ahead-count in the header)')
      end
    end)
    if #m.pushes > 0 then
      section('pushed', 'Recent push events', #m.pushes, function()
        for _, e in ipairs(m.pushes) do push_row(e) end
      end)
    end
    render_recent(M.mode == 'split' and 5 or 8)
    render_branches()
    render_stashes()
    render_worktrees()
  elseif M.view == 'history' then
    divider('Repository history')
    section('uncommitted', 'Uncommitted', #m.uncommitted, function()
      if #m.uncommitted == 0 then return empty_row('(working tree clean)') end
      for _, r in ipairs(m.uncommitted) do file_row(r, 'uncommitted', r.x ~= '.' and r.x ~= '?') end
    end)
    render_recent(M.mode == 'split' and 20 or 30)
    render_branches()
    render_tags()
    render_stashes()
    render_worktrees()
  else
    local view = VIEWS[VIEW_INDEX[M.view]] or { label = M.view }
    local remote = m.github or {}
    local repository = remote.repository
    local location = repository and (repository.host .. '/' .. repository.repository)
      or 'GitHub repository unavailable'
    local sync = ''
    if remote.status == 'loading' then
      sync = ' · syncing…'
    elseif remote.updated_at then
      sync = ' · synced ' .. os.date('%H:%M:%S', remote.updated_at)
      if remote.transport then sync = sync .. ' via ' .. remote.transport end
    end
    divider('GitHub ' .. view.label, location .. sync)

    if remote.repository_error then
      empty_row(one_line(remote.repository_error))
      empty_row('Configure github.repository = "OWNER/REPO" for an explicit override.')
      empty_row('A proxied remote also needs github.remote_path_prefix + api_url.')
    elseif remote.error and #(remote.items or {}) == 0 then
      emit(shorten('     ⚠ ' .. one_line(remote.error.message), row_limit()),
        nil, 'GitPanelGitHubFailure')
      empty_row('Press r to retry; g? shows authentication and transport guidance.')
    else
      if remote.status == 'loading' then
        emit('     ◌ Synchronizing without blocking Neovim…', nil, 'GitPanelGitHubQueued')
      elseif remote.error then
        emit(shorten('     ⚠ Showing cached data: ' .. one_line(remote.error.message), row_limit()),
          nil, 'GitPanelGitHubFailure')
      end

      local items = remote.items or {}
      local section_id = 'github-' .. M.view
      local empty = {
        actions = '(no workflow runs found)',
        issues = '(no open issues)',
        pulls = '(no open pull requests)',
      }
      local title = {
        actions = 'Recent workflow runs',
        issues = 'Open issues',
        pulls = 'Open pull requests',
      }
      section(section_id, title[M.view] or view.label, #items, function()
        if #items == 0 then return empty_row(empty[M.view] or '(nothing to show)') end
        for _, item in ipairs(items) do
          if M.view == 'actions' then action_row(item)
          elseif M.view == 'issues' then issue_row(item)
          else pull_row(item) end
        end
      end)
    end
  end

  emit('')
  if is_github_view(M.view) then
    emit('  gC connection · gD doctor · r sync · q quit', nil, 'GitPanelHint')
  elseif M.mode == 'split' then
    emit('  Tab cycle · 1–5 jump · s/u stage · g? help · q quit', nil, 'GitPanelHint')
  else
    emit('  <Tab>/<S-Tab> switch · 1–5 jump · s/u stage · <CR> inspect · g? help · q quit',
      nil, 'GitPanelHint')
  end

  return lines, map, hls
end

-- ---------------------------------------------------------------------------
-- Highlight groups (re-applied on ColorScheme so they survive a theme reload)
-- ---------------------------------------------------------------------------
local function define_hl()
  local link = function(a, b) api.nvim_set_hl(0, a, { link = b, default = true }) end
  link('GitPanelHeader', 'Title')
  link('GitPanelTitle', 'Directory')
  link('GitPanelHint', 'Comment')
  link('GitPanelTabActive', 'TabLineSel')
  link('GitPanelTabInactive', 'TabLine')
  link('GitPanelSection', 'Statement')
  link('GitPanelDivider', 'Title')
  link('GitPanelBranchCurrent', 'Function')
  link('GitPanelWorktreeCurrent', 'Function')
  link('GitPanelStaged', 'DiagnosticOk')
  link('GitPanelUnstaged', 'DiagnosticWarn')
  link('GitPanelUntracked', 'DiagnosticHint')
  link('GitPanelConflict', 'DiagnosticError')
  link('GitPanelOp', 'WarningMsg')
  link('GitPanelHash', 'Constant')
  link('GitPanelRef', 'Special')
  link('GitPanelSigOk', 'DiagnosticOk')
  link('GitPanelSigNone', 'DiagnosticWarn')
  link('GitPanelSigUnknown', 'DiagnosticHint')
  link('GitPanelSigBad', 'DiagnosticError')
  link('GitPanelGitHubSuccess', 'DiagnosticOk')
  link('GitPanelGitHubFailure', 'DiagnosticError')
  link('GitPanelGitHubRunning', 'DiagnosticInfo')
  link('GitPanelGitHubQueued', 'DiagnosticHint')
  link('GitPanelGitHubMuted', 'Comment')
  link('GitPanelGitHubNumber', 'Special')
  link('GitPanelHelpTitle', 'Title')
  link('GitPanelHelpTitleAccent', 'Special')
  link('GitPanelHelpBorder', 'FloatBorder')
  link('GitPanelHelpIntro', 'Comment')
  link('GitPanelHelpSection', 'Statement')
  link('GitPanelHelpRule', 'WinSeparator')
  link('GitPanelHelpKey', 'Special')
  link('GitPanelHelpWarningKey', 'DiagnosticWarn')
  link('GitPanelHelpDescription', 'NormalFloat')
  link('GitPanelHelpWarning', 'DiagnosticWarn')
  link('GitPanelHelpNote', 'Comment')
  link('GitPanelHelpFooter', 'Comment')
end

-- ---------------------------------------------------------------------------
-- Buffer / window lifecycle
-- ---------------------------------------------------------------------------
local function with_writable(fnc)
  api.nvim_set_option_value('modifiable', true, { buf = M.buf })
  local ok, err = pcall(fnc)
  api.nvim_set_option_value('modifiable', false, { buf = M.buf })
  if not ok then error(err) end
end

local function find_win()
  if not (M.buf and api.nvim_buf_is_valid(M.buf)) then return nil end
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(w) == M.buf then return w end
  end
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(w) == M.buf then return w end
  end
  return nil
end

local function detail_is_valid()
  return M.detail_buf and api.nvim_buf_is_valid(M.detail_buf)
    and M.detail_win and api.nvim_win_is_valid(M.detail_win)
end

local function ensure_detail_buf()
  if M.detail_buf and api.nvim_buf_is_valid(M.detail_buf) then return M.detail_buf end
  local buf = api.nvim_create_buf(false, true)
  local o = function(name, value) api.nvim_set_option_value(name, value, { buf = buf }) end
  o('buftype', 'nofile'); o('bufhidden', 'hide'); o('swapfile', false)
  o('buflisted', false); o('filetype', 'gitpaneldetail'); o('modifiable', false)
  pcall(api.nvim_buf_set_name, buf, 'gitpanel://context')
  vim.keymap.set('n', 'q', function() M.close() end,
    { buffer = buf, nowait = true, silent = true, desc = 'Close GitPanel' })
  M.detail_buf = buf
  return buf
end

local function set_detail(lines, filetype)
  if not detail_is_valid() then return end
  local old_type = api.nvim_get_option_value('filetype', { buf = M.detail_buf })
  if old_type ~= (filetype or 'gitpaneldetail') then
    local old = M.detail_buf
    M.detail_buf = nil
    api.nvim_win_set_buf(M.detail_win, ensure_detail_buf())
    api.nvim_buf_delete(old, { force = true })
    pcall(api.nvim_buf_set_name, M.detail_buf, 'gitpanel://context')
  end
  lines = lines or {}
  api.nvim_set_option_value('modifiable', true, { buf = M.detail_buf })
  api.nvim_buf_set_lines(M.detail_buf, 0, -1, false, lines)
  api.nvim_set_option_value('modifiable', false, { buf = M.detail_buf })
  api.nvim_set_option_value('filetype', filetype or 'gitpaneldetail', { buf = M.detail_buf })
  attach_pane(M.detail_win, 'context', filetype == 'markdown' and 'markdown'
    or filetype == 'diff' and 'diff' or 'plaintext')
end

local function detail_overview()
  local model = M.model
  if not model then return { '  Repository context', '', '  ◌ Reading repository state…' } end
  local lines = { '  Repository overview', '', '  ' .. fn.fnamemodify(M.root or '', ':t'),
    '  ' .. tilde(M.root or ''), '' }
  local head = model.head or {}
  lines[#lines + 1] = '  Branch       ' .. (head.branch or ('detached @ ' .. (head.sha or '?')))
  lines[#lines + 1] = '  Upstream     ' .. (head.upstream or 'not configured')
  lines[#lines + 1] = '  Working tree ' .. (model.working_clean and 'clean' or
    (#model.uncommitted .. ' changed paths'))
  lines[#lines + 1] = '  Sync         ' .. (model.synced and 'up to date' or
    ('↑' .. (head.ahead or 0) .. '  ↓' .. (head.behind or 0)))
  lines[#lines + 1] = '  History      ' .. tostring(model.commit_count or 0) .. ' commits'

  local snapshot = model.github_snapshots and model.github_snapshots.overview
  local overview = snapshot and (snapshot.items or {})[1]
  if overview then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '  GitHub'
    lines[#lines + 1] = '  ' .. (overview.full_name or overview.name or '') ..
      '  ·  ' .. (overview.visibility or 'unknown')
    if overview.default_branch then
      lines[#lines + 1] = '  Default      ' .. overview.default_branch
    end
    if overview.description and overview.description ~= '' then
      lines[#lines + 1] = ''
      lines[#lines + 1] = '  ' .. overview.description
    end
  elseif snapshot and snapshot.status == 'loading' then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '  ◌ Loading GitHub repository context…'
  end

  lines[#lines + 1] = ''
  lines[#lines + 1] = '  Remotes'
  if #model.remote_details == 0 then
    lines[#lines + 1] = '  No remotes configured'
  else
    for _, remote in ipairs(model.remote_details) do
      lines[#lines + 1] = '  ' .. remote.name .. '  ' .. (remote.fetch_url or remote.push_url or '')
    end
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = ('  %d branches  ·  %d worktrees  ·  %d tags  ·  %d stashes')
    :format(#model.branches, #model.worktrees, #model.tags, #model.stashes)
  lines[#lines + 1] = ''
  lines[#lines + 1] = '  Move the cursor to preview a change, commit, branch, tag, stash, or worktree.'
  return lines
end

local function detail_git(args, cwd, title, leading, filetype)
  M.detail_generation = M.detail_generation + 1
  local generation = M.detail_generation
  local loading = { '  ' .. title, '', '  ◌ Loading preview…' }
  set_detail(loading, filetype)
  local command = { 'git' }
  vim.list_extend(command, args)
  vim.system(command, { text = true, cwd = cwd or M.root,
    env = { LC_ALL = 'C', GIT_OPTIONAL_LOCKS = '0' } }, function(result)
    vim.schedule(function()
      if generation ~= M.detail_generation or not detail_is_valid() then return end
      local lines = { '  ' .. title, '' }
      for _, line in ipairs(leading or {}) do lines[#lines + 1] = '  ' .. line end
      if #(leading or {}) > 0 then lines[#lines + 1] = '' end
      local output = result.stdout or ''
      if output == '' then output = result.stderr or '' end
      local output_lines = vim.split(output:gsub('%s+$', ''), '\n', { plain = true })
      if #output_lines == 1 and output_lines[1] == '' then
        output_lines = { '(no diff or additional detail)' }
      end
      for index = 1, math.min(#output_lines, 400) do lines[#lines + 1] = output_lines[index] end
      if #output_lines > 400 then lines[#lines + 1] = '… preview truncated at 400 lines' end
      set_detail(lines, filetype)
    end)
  end)
end

function M.update_detail()
  if not detail_is_valid() then return end
  local panel_win = find_win()
  local item = panel_win and M.line_map[api.nvim_win_get_cursor(panel_win)[1]] or nil
  if not item or item.kind == 'head' or item.kind == 'section'
      or item.kind == 'viewheader' or item.kind == 'clean' then
    M.detail_generation = M.detail_generation + 1
    return set_detail(detail_overview())
  end

  if item.kind == 'file' then
    local title = (item.staged and 'Staged change · ' or 'Working change · ') .. item.value
    local args
    if item.untracked then
      args = { 'diff', '--no-index', '--', '/dev/null', M.root .. '/' .. item.value }
    elseif item.staged then
      args = { 'diff', '--cached', '--', item.value }
    else
      args = { 'diff', '--', item.value }
    end
    return detail_git(args, M.root, title, nil, 'diff')
  elseif item.kind == 'commit' then
    return detail_git({ 'show', '--stat', '--format=fuller', item.value }, M.root,
      'Commit · ' .. item.value, nil, 'git')
  elseif item.kind == 'branch' then
    local data = item.data or {}
    local info = { data.current and 'Current branch' or 'Local branch' }
    if data.upstream then info[#info + 1] = 'Upstream: ' .. data.upstream end
    if data.worktree then info[#info + 1] = 'Worktree: ' .. tilde(data.worktree) end
    return detail_git({ 'log', '-1', '--decorate=short', '--stat', '--format=fuller', item.value },
      M.root, 'Branch · ' .. item.value, info, 'git')
  elseif item.kind == 'worktree' then
    return detail_git({ 'status', '--short', '--branch' }, item.value,
      'Worktree · ' .. tilde(item.value), nil, 'git')
  elseif item.kind == 'stash' then
    return detail_git({ 'stash', 'show', '--stat', '--patch', item.value }, M.root,
      'Stash · ' .. item.value, nil, 'diff')
  elseif item.kind == 'tag' then
    return detail_git({ 'show', '--stat', '--format=fuller', item.value }, M.root,
      'Tag · ' .. item.value, nil, 'git')
  elseif item.kind == 'push' then
    local range = item.old and (item.old .. '..' .. item.value) or item.value
    return detail_git({ 'log', '--stat', '--oneline', range }, M.root,
      'Push event · ' .. tostring(item.value):sub(1, 7), nil, 'git')
  elseif item.kind == 'github' then
    M.detail_generation = M.detail_generation + 1
    local data = item.data or {}
    local lines = { '  GitHub · ' .. (data.kind or item.resource or 'item'), '',
      '  ' .. (data.title or data.name or data.full_name or '(untitled)'), '' }
    local fields = { { 'State', data.conclusion or data.status or data.state },
      { 'Author', data.author or data.actor }, { 'Branch', data.branch },
      { 'From', data.head }, { 'Into', data.base }, { 'Updated', data.updated_at },
      { 'URL', data.url } }
    for _, field in ipairs(fields) do
      if field[2] ~= nil and field[2] ~= '' then
        lines[#lines + 1] = ('  %-10s %s'):format(field[1], tostring(field[2]))
      end
    end
    if data.body and data.body ~= '' then
      lines[#lines + 1] = ''; lines[#lines + 1] = '  Description'; lines[#lines + 1] = ''
      vim.list_extend(lines, vim.split(data.body, '\n', { plain = true }))
    end
    return set_detail(lines, 'markdown')
  end
  M.detail_generation = M.detail_generation + 1
  set_detail(detail_overview())
end

local function request_github_view(view, force)
  if view ~= 'overview' and not is_github_view(view) then return end
  local state = github_state(view)
  if state.status == 'loading' and not force then return end
  local previous_repository = github_runtime.repository and
    (github_runtime.repository.host .. '/' .. github_runtime.repository.repository) or nil
  if force then
    github_runtime.generation = github_runtime.generation + 1
    for _, pending in pairs(github_runtime.views) do
      pending.request_id = pending.request_id + 1
      if pending.status == 'loading' then
        pending.status = #pending.items > 0 and 'stale' or 'idle'
      end
    end
    github_runtime.repository = nil
    github_runtime.repository_error = nil
    github_runtime.client = nil
  end
  local repository = resolve_github_runtime()
  local current_repository = repository and (repository.host .. '/' .. repository.repository) or nil
  if force and previous_repository ~= current_repository then
    github_runtime.views = {}
    state = github_state(view)
  end
  if not repository or not github_runtime.client then return end

  local refresh_interval = tonumber(M.config.github.refresh_interval) or 60
  local fresh = state.updated_at and (os.time() - state.updated_at) < refresh_interval
  if not force and state.status == 'ready' and fresh then return end

  state.status = 'loading'
  state.error = nil
  state.request_id = state.request_id + 1
  local request_id = state.request_id
  local generation = github_runtime.generation
  local root = M.root

  github_runtime.client:fetch(view, repository, function(err, items, metadata)
    vim.schedule(function()
      if generation ~= github_runtime.generation or root ~= M.root
          or request_id ~= state.request_id then return end
      if err then
        state.error = err
        state.status = #state.items > 0 and 'stale' or 'error'
      else
        state.items = items or {}
        state.error = nil
        state.status = 'ready'
        state.updated_at = os.time()
        state.transport = metadata and metadata.transport or nil
      end
      if M.model and M.buf and api.nvim_buf_is_valid(M.buf) then
        M.refresh({ skip_remote_fetch = true, reuse_model = true })
      end
    end)
  end)
end


local function request_github_dashboard(force)
  for _, view in ipairs({ 'overview', 'actions', 'issues', 'pulls' }) do
    request_github_view(view, force)
    -- A forced refresh resets the shared runtime once. Subsequent views must
    -- use that fresh client without resetting the requests just started.
    force = false
  end
end

function M.refresh(opts)
  opts = opts or {}
  if not (M.buf and api.nvim_buf_is_valid(M.buf)) then return end
  if not opts.skip_remote_fetch then
    request_github_dashboard(opts.force_remote == true)
  end
  local win = find_win()
  -- remember the logical item under the cursor to restore it after rebuild
  local function item_key(it)
    return (it.kind or '') .. '\0' .. tostring(it.value or '') .. '\0' ..
           tostring(it.section or '') .. '\0' .. tostring(it.old or '')
  end
  local prev_key
  if win then
    local it = M.line_map[api.nvim_win_get_cursor(win)[1]]
    if it then prev_key = item_key(it) end
  end

  local function apply_model(model)
    if not (M.buf and api.nvim_buf_is_valid(M.buf)) then return end
    local snapshots = github_dashboard_snapshot()
    model.github_snapshots = snapshots
    model.github_summary = github_summary(snapshots)
    if is_github_view(M.view) then model.github = snapshots[M.view] end
    local lines, map, hls = render(model)
    M.model, M.line_map = model, map
    with_writable(function() api.nvim_buf_set_lines(M.buf, 0, -1, false, lines) end)

    api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
    for _, h in ipairs(hls) do
      pcall(api.nvim_buf_set_extmark, M.buf, ns, h.line, h.cs,
        { end_col = (h.ce == -1) and nil or h.ce,
          end_row = (h.ce == -1) and h.line + 1 or nil, hl_group = h.group })
    end

    if win and api.nvim_win_is_valid(win) and prev_key then
      for lnum, it in pairs(map) do
        if item_key(it) == prev_key then
          pcall(api.nvim_win_set_cursor, win, { lnum, 0 })
          break
        end
      end
    end
    if M.update_detail then M.update_detail() end
  end

  if opts.reuse_model and M.model then return apply_model(M.model) end

  M.model_generation = M.model_generation + 1
  local generation, root = M.model_generation, M.root
  if not M.model then
    with_writable(function()
      api.nvim_buf_set_lines(M.buf, 0, -1, false, {
        '  GitPanel', '', '  ◌ Reading repository state…', '',
        '  Git commands are running concurrently; Neovim remains responsive.',
      })
    end)
  end
  local_model.gather(root, {}, function(model)
    if generation ~= M.model_generation or root ~= M.root then return end
    apply_model(model)
  end)
end

local function set_win_opts(win, fixed_width, role)
  local w = function(n, v) api.nvim_set_option_value(n, v, { win = win }) end
  w('winfixwidth', fixed_width == true)
  if attach_pane(win, role or 'navigation', role == 'context' and 'plaintext' or 'list') then return true end
  w('number', false); w('relativenumber', false); w('signcolumn', 'no')
  w('cursorline', true); w('wrap', false); w('list', false); w('foldcolumn', '0')
  return false
end

local function ensure_buf()
  if M.buf and api.nvim_buf_is_valid(M.buf) then return M.buf end
  local buf = api.nvim_create_buf(false, true)
  local o = function(n, v) api.nvim_set_option_value(n, v, { buf = buf }) end
  o('buftype', 'nofile'); o('bufhidden', 'hide'); o('swapfile', false)
  o('buflisted', false); o('filetype', 'gitpanel'); o('modifiable', false)
  pcall(api.nvim_buf_set_name, buf, 'gitpanel://status')
  M.buf = buf
  M.attach_keys()
  api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = function()
      M.cursor_generation = M.cursor_generation + 1
      local generation = M.cursor_generation
      vim.defer_fn(function()
        if generation == M.cursor_generation then M.update_detail() end
      end, 70)
    end,
  })
  return buf
end

local function close_detail()
  M.detail_generation = M.detail_generation + 1
  if M.detail_win and api.nvim_win_is_valid(M.detail_win) then
    pcall(api.nvim_win_close, M.detail_win, true)
  end
  M.detail_win = nil
end

local function ensure_detail_layout()
  if M.mode ~= 'tab' or vim.o.columns < WIDE_MIN_COLUMNS
      or not (M.win and api.nvim_win_is_valid(M.win)) then
    close_detail()
    return
  end
  if not detail_is_valid() then
    api.nvim_set_current_win(M.win)
    vim.cmd('rightbelow vsplit')
    M.detail_win = api.nvim_get_current_win()
    api.nvim_win_set_buf(M.detail_win, ensure_detail_buf())
    if not set_win_opts(M.detail_win, false, 'context') then
      api.nvim_set_option_value('cursorline', false, { win = M.detail_win })
      api.nvim_set_option_value('wrap', true, { win = M.detail_win })
    end
  end
  local target = math.max(DETAIL_MIN_WIDTH, math.floor(vim.o.columns * 0.35))
  pcall(api.nvim_win_set_width, M.detail_win, target)
  api.nvim_set_current_win(M.win)
  M.update_detail()
end

local function open_tab()
  vim.cmd('tabnew')
  M.mode = 'tab'
  M.tab = api.nvim_get_current_tabpage()
  M.win = api.nvim_get_current_win()
  api.nvim_win_set_buf(M.win, M.buf)
  set_win_opts(M.win, false)
  ensure_detail_layout()
end
local function open_split()
  close_detail()
  vim.cmd('topleft vsplit')
  M.mode = 'split'; M.tab = nil
  M.win = api.nvim_get_current_win()
  api.nvim_win_set_buf(M.win, M.buf)
  api.nvim_win_set_width(M.win, PANEL_WIDTH)
  set_win_opts(M.win, true)
end

local function detect_root()
  local cur = api.nvim_get_current_win()
  if cur ~= M.win then M.prev_win = cur end
  local bufname = api.nvim_buf_get_name(0)
  local dir = (bufname ~= '' and fn.filereadable(bufname) == 1) and fn.fnamemodify(bufname, ':p:h')
    or fn.getcwd()
  M.start_dir = dir
  local r = vim.system({ 'git', 'rev-parse', '--show-toplevel' },
    { text = true, cwd = dir }):wait()
  if r.code ~= 0 then return nil end
  return chomp(r.stdout)
end

local function prepare_github_config(base, requested)
  local effective, profile_error = connections.resolve(base, requested)
  if not effective then return nil, profile_error end
  local transport = effective.transport
  if transport ~= 'auto' and transport ~= 'gh' and transport ~= 'curl' then
    return nil, 'github.transport must be "auto", "gh", or "curl"'
  end
  local merge_backend = effective.merge_backend
  if merge_backend ~= 'api' and merge_backend ~= 'signed_git' then
    return nil, 'github.merge_backend must be "api" or "signed_git"'
  end
  if type(effective.allow_insecure_http) ~= 'boolean' then
    return nil, 'github.allow_insecure_http must be a boolean'
  end
  local prefix = effective.remote_path_prefix
  if prefix ~= nil then
    if type(prefix) == 'string' then prefix = { prefix } end
    if type(prefix) ~= 'table' then
      return nil, 'github.remote_path_prefix must be a string or list of strings'
    end
    for _, entry in ipairs(prefix) do
      if type(entry) ~= 'string' then
        return nil, 'github.remote_path_prefix entries must be strings'
      end
    end
  end
  effective.per_page = math.max(1, math.min(100,
    tonumber(effective.per_page) or DEFAULT_CONFIG.github.per_page))
  effective.refresh_interval = math.max(0,
    tonumber(effective.refresh_interval) or DEFAULT_CONFIG.github.refresh_interval)
  effective.timeout = math.max(1000,
    tonumber(effective.timeout) or DEFAULT_CONFIG.github.timeout)
  return effective
end

function M.setup(opts)
  if opts ~= nil and type(opts) ~= 'table' then
    error('git_panel.setup() expects a table')
  end
  local merged = vim.tbl_deep_extend('force', vim.deepcopy(DEFAULT_CONFIG), opts or {})
  configured_github = vim.deepcopy(merged.github)
  local effective, config_error = prepare_github_config(configured_github, configured_github.profile)
  if not effective then error('git_panel.setup(): ' .. config_error) end
  merged.github = effective
  M.config = merged
  reset_github_runtime(M.root)
  if M.buf and api.nvim_buf_is_valid(M.buf) then M.refresh() end
  return M
end

local function active_connection_label()
  return connections.label(configured_github, M.config.github.profile)
end

function M.connection_profiles()
  local choices, choices_error = connections.choices(configured_github, M.config.github.profile)
  if not choices then error('git_panel: ' .. choices_error) end
  return choices
end

function M.connection_profile_names()
  local names = {}
  for _, choice in ipairs(M.connection_profiles()) do names[#names + 1] = choice.id end
  return names
end

local function activate_connection(profile)
  local effective, config_error = prepare_github_config(configured_github, profile)
  if not effective then
    vim.notify('GitPanel connection: ' .. config_error, vim.log.levels.ERROR)
    return false
  end
  M.config.github = effective
  reset_github_runtime(M.root)
  if M.buf and api.nvim_buf_is_valid(M.buf) then M.refresh({ force_remote = true }) end
  vim.notify('GitPanel connection: ' .. active_connection_label(), vim.log.levels.INFO)
  return true
end

function M.select_connection(profile)
  if profile ~= nil and profile ~= '' then return activate_connection(profile) end
  local choices = M.connection_profiles()
  vim.ui.select(choices, {
    prompt = 'GitPanel GitHub connection:',
    format_item = function(choice)
      local marker = choice.active and '● ' or '  '
      local detail = choice.description and (' — ' .. choice.description) or ''
      return marker .. choice.label .. detail
    end,
  }, function(choice)
    if choice then activate_connection(choice.id) end
  end)
end

function M.open(mode)
  mode = mode or 'tab'
  local root = detect_root()
  if not root then
    vim.notify('GitPanel: not inside a git repository (' .. (M.start_dir or '?') .. ')',
      vim.log.levels.WARN)
    return
  end
  if M.root ~= root then
    reset_github_runtime(root)
    M.model = nil
    M.model_generation = M.model_generation + 1
  end
  M.root = root
  ensure_buf()
  local existing = find_win()
  if existing then
    M.win = existing
    api.nvim_set_current_win(existing)
    if M.mode ~= mode then M.toggle_layout() else M.refresh() end
    return
  end
  if mode == 'tab' then open_tab() else open_split() end
  M.refresh()
end

function M.close()
  local win = find_win()
  if not win then return end
  if M.mode == 'tab' and M.tab and api.nvim_tabpage_is_valid(M.tab) then
    api.nvim_set_current_tabpage(M.tab)
    if fn.tabpagenr('$') > 1 then
      vim.cmd('tabclose')
    else
      close_detail()
      api.nvim_set_current_win(win)
      vim.cmd('enew')
    end
    M.win, M.mode, M.tab, M.detail_win = nil, nil, nil, nil
    return
  end
  local last_win = #api.nvim_tabpage_list_wins(0) == 1
  local last_tab = fn.tabpagenr('$') == 1
  if last_win and last_tab then
    api.nvim_set_current_win(win); vim.cmd('enew')
  else
    pcall(api.nvim_win_close, win, true)
  end
  M.win, M.mode, M.tab = nil, nil, nil
end

function M.toggle_layout()
  local win = find_win()
  if not win then return M.open('split') end
  local target = (M.mode == 'tab') and 'split' or 'tab'
  api.nvim_set_current_win(win)
  -- Vacate the current panel window before building the new layout, so the
  -- panel buffer is never left showing in a stranded second window. Close it
  -- outright when something else would remain; otherwise swap in a scratch buf.
  if M.mode == 'tab' and fn.tabpagenr('$') > 1 then
    vim.cmd('tabclose')
    M.detail_win, M.tab = nil, nil
  elseif #api.nvim_tabpage_list_wins(0) > 1 or fn.tabpagenr('$') > 1 then
    close_detail()
    pcall(api.nvim_win_close, win, true)
  else
    close_detail()
    api.nvim_win_set_buf(win, api.nvim_create_buf(false, true))
  end
  if target == 'tab' then open_tab() else open_split() end
  M.refresh()
end

function M.select_view(view)
  local index = type(view) == 'number' and view or VIEW_INDEX[view]
  if not index or not VIEWS[index] then return end
  M.view = VIEWS[index].id
  M.refresh({ reuse_model = true })
end

function M.toggle_view(direction)
  local current = VIEW_INDEX[M.view] or 1
  local step = direction == -1 and -1 or 1
  local target = ((current - 1 + step) % #VIEWS) + 1
  M.select_view(target)
end

function M.previous_view() M.toggle_view(-1) end

function M.manual_refresh()
  M.refresh({ force_remote = true })
end

function M.toggle_fold()
  local it = M.line_map[api.nvim_win_get_cursor(0)[1]]
  if it and it.section then
    M.folds[it.section] = not M.folds[it.section]
    M.refresh({ skip_remote_fetch = true, reuse_model = true })
  elseif it and it.kind == 'viewheader' then
    M.toggle_view()
  end
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------
local function cur_item() return M.line_map[api.nvim_win_get_cursor(0)[1]] end
-- Run a mutating git command. Notifies on failure unless opts.quiet (callers
-- that inspect stderr themselves pass quiet=true to avoid a double message).
local function run(args, opts)
  opts = opts or {}
  local res = git(args, { allow_fail = true, cwd = opts.cwd })
  if res.code ~= 0 and not opts.quiet then
    vim.notify('git ' .. table.concat(args, ' ') .. '\n' .. chomp(res.stderr), vim.log.levels.WARN)
  end
  return res.code == 0, res
end

local function open_file(path, jump_conflict)
  local full = (M.root or '') .. '/' .. path
  local target
  -- Reuse a window only if it lives in the CURRENT tabpage, so tab-mode never
  -- yanks focus to a different tab. prev_win qualifies only when co-located.
  local here = {}
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do here[w] = true end
  if M.prev_win and here[M.prev_win] and api.nvim_win_is_valid(M.prev_win)
      and api.nvim_win_get_buf(M.prev_win) ~= M.buf then
    target = M.prev_win
  else
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(w) ~= M.buf then target = w; break end
    end
  end
  if target then
    api.nvim_set_current_win(target)
    vim.cmd('edit ' .. fn.fnameescape(full))
  elseif M.mode == 'split' then
    vim.cmd('rightbelow vsplit ' .. fn.fnameescape(full))
  else
    vim.cmd('split ' .. fn.fnameescape(full))
  end
  -- land on the first conflict marker so the user can start resolving at once
  if jump_conflict then pcall(fn.search, '^<<<<<<<', 'cw') end
end

-- Open text in a throwaway split. Git details default to filetype=git; remote
-- repository summaries opt into Markdown without introducing a UI dependency.
-- Diff/detail content opens in a centered float rather than a bottom split:
-- it reads at full width, keeps the panel layout untouched, and `q` (or
-- <Esc>) dismisses it without disturbing window arrangement.
local function show_scratch(text, opts)
  opts = opts or {}
  local buf = api.nvim_create_buf(false, true)
  local text_lines = vim.split(text or '', '\n', { plain = true })
  api.nvim_buf_set_lines(buf, 0, -1, false, text_lines)
  api.nvim_set_option_value('filetype', opts.filetype or 'git', { buf = buf })
  api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
  if opts.name then pcall(api.nvim_buf_set_name, buf, opts.name) end
  api.nvim_set_option_value('modifiable', false, { buf = buf })
  local width = math.max(40, math.min(110, vim.o.columns - 8))
  local height = math.max(6, math.min(#text_lines + 1, vim.o.lines - 6))
  local title = opts.title or (opts.name and opts.name:match('([^/]+)$'))
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
    style = 'minimal',
    border = 'rounded',
    title = title and (' ' .. title .. ' ') or nil,
    title_pos = 'center',
  })
  vim.wo[win].wrap = false
  for _, lhs in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', lhs, '<cmd>close<cr>', { buffer = buf, nowait = true, silent = true })
  end
  return buf, win
end

local function safe_endpoint_summary(value)
  value = github.redact(value or '')
  return value:gsub('^(%a[%w+.-]*://)[^/@]+@', '%1<redacted>@')
end

function M.connection_doctor()
  local root = M.root
  if not root then root = detect_root() end
  local opts = M.config.github
  local lines = {
    'GitPanel connection doctor',
    '',
    'Profile:       ' .. active_connection_label(),
    'Transport:     ' .. tostring(opts.transport or 'auto'),
    'GitHub CLI:    ' .. tostring(opts.gh_command or 'gh') ..
      (fn.executable(opts.gh_command or 'gh') == 1 and ' (available)' or ' (unavailable)'),
    'curl:          ' .. tostring(opts.curl_command or 'curl') ..
      (fn.executable(opts.curl_command or 'curl') == 1 and ' (available)' or ' (unavailable)'),
    'Credential:    ' .. (opts.token_provider and 'external provider configured' or
      'none stored by GitPanel'),
  }
  if not root then
    lines[#lines + 1] = 'Repository:    unavailable (not inside a Git repository)'
    lines[#lines + 1] = 'Status:        local repository discovery failed'
    return show_scratch(table.concat(lines, '\n'), {
      filetype = 'gitpaneldoctor', name = 'gitpanel://doctor', title = 'GitPanel Doctor',
    })
  end
  lines[#lines + 1] = 'Root:          ' .. root
  if not opts.enabled then
    lines[#lines + 1] = 'Repository:    unavailable'
    lines[#lines + 1] = 'Status:        GitHub integration is disabled'
    return show_scratch(table.concat(lines, '\n'), {
      filetype = 'gitpaneldoctor', name = 'gitpanel://doctor', title = 'GitPanel Doctor',
    })
  end

  local repository, repository_error = github.resolve_repository(root, opts)
  if not repository then
    lines[#lines + 1] = 'Repository:    unavailable'
    lines[#lines + 1] = 'Status:        ' .. tostring(repository_error or 'discovery failed')
    return show_scratch(table.concat(lines, '\n'), {
      filetype = 'gitpaneldoctor', name = 'gitpanel://doctor', title = 'GitPanel Doctor',
    })
  end
  lines[#lines + 1] = 'Repository:    ' .. repository.repository
  lines[#lines + 1] = 'Remote host:   ' .. repository.host
  lines[#lines + 1] = 'REST base:     ' .. safe_endpoint_summary(github.api_base(repository, opts))
  lines[#lines + 1] = 'Status:        checking repository access…'
  vim.notify('GitPanel doctor: checking ' .. repository.repository, vim.log.levels.INFO)

  local client_opts = vim.tbl_deep_extend('force', vim.deepcopy(opts), { root = root })
  local factory = opts.client_factory or github.new
  local client = factory(client_opts)
  client:fetch('overview', repository, function(err, _, metadata)
    vim.schedule(function()
      lines[#lines] = err and ('Status:        ' .. tostring(err.message or err.kind or err))
        or ('Status:        reachable via ' .. tostring(metadata and metadata.transport or 'configured transport'))
      show_scratch(table.concat(lines, '\n'), {
        filetype = 'gitpaneldoctor', name = 'gitpanel://doctor', title = 'GitPanel Doctor',
      })
    end)
  end)
end

local function show_commit(sha)
  show_scratch(git({ 'show', '--stat', '--patch', sha }, { allow_fail = true }).stdout)
end
-- Show the commits a push introduced: old..new. The oldest recorded push has
-- no known prior state, so fall back to showing its tip commit alone.
local function show_push(it)
  if it.old and it.old ~= '' then
    local res = git({ 'log', '--stat', '--patch', it.old .. '..' .. it.value }, { allow_fail = true })
    local out = res.stdout or ''
    if out:gsub('%s+', '') == '' then
      out = '(no commits to list for this push — the ref update introduced nothing new\n' ..
            'over its previous position, e.g. a re-push or a force update to ' .. it.value .. ')'
    end
    show_scratch(out)
  else
    show_scratch('(oldest recorded push — showing the pushed tip commit)\n\n' ..
      (git({ 'show', '--stat', '--patch', it.value }, { allow_fail = true }).stdout or ''))
  end
end

local function github_detail(item)
  local data = item.data or {}
  local lines = {}
  local function add(label, value)
    if value ~= nil and value ~= '' then lines[#lines + 1] = '- **' .. label .. ':** ' .. tostring(value) end
  end

  if item.resource == 'action' then
    lines[#lines + 1] = '# ' .. (data.name or 'Workflow') ..
      (data.number and (' #' .. data.number) or '')
    lines[#lines + 1] = ''
    add('Status', (data.conclusion or data.status or 'unknown'):gsub('_', ' '))
    add('Run title', data.title)
    add('Branch', data.branch)
    add('Event', data.event)
    add('Actor', data.actor and ('@' .. data.actor) or nil)
    add('Commit', data.sha)
    add('Updated', data.updated_at or data.created_at)
    add('GitHub', data.url)
  else
    local noun = item.resource == 'pull' and 'Pull request' or 'Issue'
    lines[#lines + 1] = '# ' .. noun .. ' #' .. tostring(data.number or '?') .. ': ' ..
      (data.title or '(untitled)')
    lines[#lines + 1] = ''
    add('State', data.draft and 'draft' or data.state)
    add('Author', data.author and ('@' .. data.author) or nil)
    if item.resource == 'pull' then add('Branches', (data.head or '?') .. ' → ' .. (data.base or '?')) end
    if data.labels and #data.labels > 0 then add('Labels', table.concat(data.labels, ', ')) end
    add('Comments', data.comments)
    add('Updated', data.updated_at or data.created_at)
    add('GitHub', data.url)
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## Description'
    lines[#lines + 1] = ''
    lines[#lines + 1] = data.body and data.body ~= '' and data.body or '_No description provided._'
  end

  lines[#lines + 1] = ''
  lines[#lines + 1] = '_Read-only GitHub summary · press `q` to close · `gx` in the panel opens the browser._'
  return table.concat(lines, '\n')
end

function M.open_github_detail()
  local item = cur_item()
  if not (item and item.kind == 'github') then
    return vim.notify('GitPanel: cursor not on a GitHub item', vim.log.levels.INFO)
  end
  show_scratch(github_detail(item), {
    filetype = 'markdown',
    name = 'gitpanel://github/' .. item.resource .. '/' .. tostring(item.value),
  })
end

function M.open_github_browser()
  local item = cur_item()
  if not (item and item.kind == 'github' and item.url) then
    return vim.notify('GitPanel: cursor not on a GitHub item', vim.log.levels.INFO)
  end
  local command, err = vim.ui.open(item.url)
  if not command then
    vim.notify('GitPanel: could not open ' .. item.url .. '\n' .. tostring(err or ''), vim.log.levels.WARN)
  end
end

-- ---- pull-request actions ----------------------------------------------------
-- The review-and-land loop on a PR row: `go` check out, `gd` diff vs base,
-- `gc` comment, `gm` merge (confirm; deletes the branch remote + local).
-- Reads stay ambient; every write asks first.

local function pull_under_cursor()
  local item = cur_item()
  if item and item.kind == 'github' and item.resource == 'pull' then return item end
  vim.notify('GitPanel: cursor not on a pull request', vim.log.levels.INFO)
  return nil
end

-- Repository metadata for GitHub-backed actions; nil (with a notice) when
-- GitHub is not resolvable here, so every action degrades to a no-op message.
local function github_repository_runtime()
  resolve_github_runtime()
  if github_runtime.repository then return github_runtime.repository end
  vim.notify('GitPanel: GitHub is unavailable for this repository' ..
    (github_runtime.repository_error and ('\n' .. github_runtime.repository_error) or ''),
    vim.log.levels.WARN)
  return nil
end

local function github_write_runtime()
  local repository = github_repository_runtime()
  if not repository then return nil end
  if github_runtime.client then return github_runtime.client, repository end
  vim.notify('GitPanel: the GitHub API client is unavailable for this repository',
    vim.log.levels.WARN)
  return nil
end

local function current_branch()
  local res = git({ 'rev-parse', '--abbrev-ref', 'HEAD' }, { allow_fail = true })
  return res.code == 0 and chomp(res.stdout) or ''
end

function M.pr_checkout()
  local item = pull_under_cursor()
  if not item then return end
  local data = item.data
  if not data.head then
    return vim.notify('GitPanel: pull request #' .. tostring(data.number) ..
      ' has no head branch (cross-fork PRs are not supported)', vim.log.levels.WARN)
  end
  local remote = (github_runtime.repository and github_runtime.repository.remote) or 'origin'
  git({ 'fetch', remote })
  M.checkout(data.head)
end

function M.pr_diff()
  local item = pull_under_cursor()
  if not item then return end
  local data = item.data
  if not (data.head and data.base) then
    return vim.notify('GitPanel: pull request is missing branch information', vim.log.levels.WARN)
  end
  local remote = (github_runtime.repository and github_runtime.repository.remote) or 'origin'
  git({ 'fetch', remote })
  local range = remote .. '/' .. data.base .. '...' .. remote .. '/' .. data.head
  local res = git({ 'diff', range }, { allow_fail = true })
  if res.code ~= 0 then
    return vim.notify('git diff ' .. range .. '\n' .. chomp(res.stderr), vim.log.levels.WARN)
  end
  local text = chomp(res.stdout)
  if text == '' then text = '(no differences — the pull request may already be merged)' end
  show_scratch(text, {
    filetype = 'diff',
    name = 'gitpanel://pull/' .. tostring(data.number) .. '.diff',
  })
end

function M.pr_comment()
  local item = pull_under_cursor()
  if not item then return end
  local data = item.data
  local client, repository = github_write_runtime()
  if not client then return end
  vim.ui.input({ prompt = 'Comment on #' .. tostring(data.number) .. ': ' }, function(msg)
    if not msg or trim(msg) == '' then return end
    client:comment_pull(repository, data.number, msg, function(err)
      if err then
        return vim.notify('GitPanel: comment failed\n' .. err.message, vim.log.levels.ERROR)
      end
      vim.notify('GitPanel: commented on #' .. tostring(data.number), vim.log.levels.INFO)
      M.refresh()
    end)
  end)
end

local function cleanup_merged_pull_branch(data, repository, remote_deleted)
  if not remote_deleted then return end
  local remote = repository.remote or 'origin'
  if current_branch() == data.head and data.base then
    local switched = run({ 'switch', '--', data.base }, { quiet = true })
    if switched then run({ 'pull', '--ff-only' }, { quiet = true }) end
  end
  git({ 'fetch', '--prune', remote }, { allow_fail = true })
  git({ 'branch', '-d', data.head }, { allow_fail = true })
end

local function finish_pull_merge(data, repository, remote_deleted, detail)
  cleanup_merged_pull_branch(data, repository, remote_deleted)
  vim.notify('GitPanel: merged #' .. tostring(data.number) .. ' into ' ..
    (data.base or '?') .. (detail and ('\n' .. detail) or ''), vim.log.levels.INFO)
  M.refresh()
end

local function merge_pull_via_api(client, repository, data)
  client:merge_pull(repository, data.number, data.head_sha, function(err)
    if err then
      return vim.notify('GitPanel: merge failed\n' .. err.message, vim.log.levels.ERROR)
    end

    -- Only the base repository's own head branches may be deleted here. A
    -- cross-fork PR can share a branch name with an unrelated base-repository
    -- branch, so missing ownership metadata also fails closed.
    local head_is_local = signed_merge.same_repository(data.head_repository,
      repository.repository)
    if not head_is_local then
      return finish_pull_merge(data, repository, false,
        'The head branch belongs to another repository and was left untouched.')
    end

    -- Best-effort branch cleanup: the merge itself already succeeded, so a
    -- failure here is reported but never treated as a failed merge.
    client:delete_branch(repository, data.head, function(ref_err)
      local deleted = not ref_err or ref_err.kind == 'not_found'
      if not deleted then
        vim.notify('GitPanel: merged, but the remote branch survived\n' .. ref_err.message,
          vim.log.levels.WARN)
      end
      finish_pull_merge(data, repository, deleted)
    end)
  end)
end

local function merge_pull_via_signed_git(repository, data)
  if not repository.remote then
    return vim.notify('GitPanel: signed_git requires a detected GitHub remote; ' ..
      'github.repository overrides without a matching remote cannot be pushed safely.',
      vim.log.levels.ERROR)
  end
  vim.notify('GitPanel: creating and pushing a signed merge commit…', vim.log.levels.INFO)
  local result, err = signed_merge.run({
    root = M.root,
    remote = repository.remote,
    repository = repository.repository,
    number = data.number,
    title = data.title,
    base = data.base,
    head = data.head,
    head_sha = data.head_sha,
    head_label = data.head_label,
    head_repository = data.head_repository,
  })
  if not result then
    return vim.notify('GitPanel: signed merge failed\n' .. err.message, vim.log.levels.ERROR)
  end
  if result.branch_delete_error then
    vim.notify(result.branch_delete_error, vim.log.levels.WARN)
  end
  if result.cleanup_error then
    vim.notify('GitPanel: merge succeeded, but temporary worktree cleanup failed\n' ..
      result.cleanup_error, vim.log.levels.WARN)
  end
  local detail = 'Signed commit ' .. result.merge_sha:sub(1, 12)
  if not result.head_is_local then
    detail = detail .. '; cross-repository head branch left untouched.'
  elseif result.branch_delete_error then
    detail = detail .. '; remote head branch left intact.'
  end
  finish_pull_merge(data, repository, result.remote_branch_deleted, detail)
end

function M.pr_merge()
  local item = pull_under_cursor()
  if not item then return end
  local data = item.data
  local repository = github_repository_runtime()
  if not repository then return end
  if data.draft then
    return vim.notify('GitPanel: #' .. tostring(data.number) .. ' is a draft — mark it ready first',
      vim.log.levels.WARN)
  end
  local backend = M.config.github.merge_backend or 'api'
  local action = backend == 'signed_git'
      and 'Create a signed merge commit in a temporary worktree and push it'
    or 'Merge through the GitHub API'
  local pick = fn.confirm(
    'Merge pull request #' .. tostring(data.number) .. ' "' .. (data.title or '') .. '"\n' ..
    'into ' .. (data.base or '?') .. '?\n\n' .. action ..
    '. The same-repository head branch "' .. (data.head or '?') ..
    '" is then deleted (remote and local).', '&No\n&Merge', 1)
  if pick ~= 2 then return end

  if backend == 'signed_git' then return merge_pull_via_signed_git(repository, data) end
  local client = github_runtime.client
  if not client then
    return vim.notify('GitPanel: the GitHub API client is unavailable for this repository',
      vim.log.levels.WARN)
  end
  merge_pull_via_api(client, repository, data)
end

function M.primary()
  local it = cur_item()
  if not it then return end
  if it.kind == 'section' or it.kind == 'viewheader' then M.toggle_fold()
  elseif it.kind == 'branch' then M.checkout(it.value)
  elseif it.kind == 'worktree' then M.switch_worktree(it.value)
  elseif it.kind == 'file' then open_file(it.value, it.conflict)
  elseif it.kind == 'commit' then show_commit(it.value)
  elseif it.kind == 'push' then show_push(it)
  elseif it.kind == 'github' then M.open_github_detail()
  elseif it.kind == 'op' then M.op_continue()
  end
end

-- Any file still in an unmerged (conflicted) state?
local function has_conflicts()
  local r = git({ 'diff', '--name-only', '--diff-filter=U' }, { allow_fail = true })
  return r.code == 0 and chomp(r.stdout) ~= ''
end

function M.stage()
  local it = cur_item()
  if not (it and it.kind == 'file') then return vim.notify('GitPanel: cursor not on a file', vim.log.levels.INFO) end
  -- Marking a conflict resolved (git add) while it still has markers would
  -- commit the markers; warn first. git diff --check flags leftover markers.
  if it.conflict then
    local chk = git({ 'diff', '--check', '--', it.value }, { allow_fail = true })
    if chk.code ~= 0 then
      local pick = fn.confirm('"' .. it.value .. '" still contains conflict markers ' ..
        '(<<<<<<< / =======  / >>>>>>>).\nStage it as resolved anyway?', '&Yes\n&No', 2)
      if pick ~= 1 then return end
    end
  end
  run({ 'add', '--', it.value }); M.refresh()
end
function M.unstage()
  local it = cur_item()
  if not (it and it.kind == 'file') then return vim.notify('GitPanel: cursor not on a file', vim.log.levels.INFO) end
  run({ 'reset', '-q', '--', it.value }); M.refresh()  -- works born and unborn
end
-- "Stage All" (git add -A) would sweep unresolved conflicts — marker text and
-- all — into the index; refuse while any conflict is unresolved.
function M.stage_all()
  if has_conflicts() then
    return vim.notify('GitPanel: unresolved conflicts — resolve with o/t or edit + s ' ..
      'before Stage All', vim.log.levels.WARN)
  end
  run({ 'add', '-A' }); M.refresh()
end
function M.unstage_all() run({ 'reset', '-q' }); M.refresh() end

function M.discard()
  local it = cur_item()
  if not (it and it.kind == 'file') then return end
  -- On a conflicted file "discard" is ambiguous (restore would silently pick
  -- the HEAD side); steer the user to the explicit resolve keys instead.
  if it.conflict then
    return vim.notify('GitPanel: "' .. it.value .. '" is conflicted — use o/t to take a ' ..
      'side, edit + s to resolve, or A to abort the operation', vim.log.levels.INFO)
  end
  local pick = fn.confirm('Discard changes to "' .. it.value .. '"? This cannot be undone.',
    '&Yes\n&No', 2)
  if pick ~= 1 then return end
  if it.untracked then
    run({ 'clean', '-f', '--', it.value })        -- delete the untracked file
  else
    run({ 'restore', '--staged', '--worktree', '--', it.value }) -- unstage + revert worktree
  end
  M.refresh()
end

-- ---- conflict resolution -------------------------------------------------
-- Resolve the conflicted file under the cursor by taking one whole side, then
-- stage it. "ours"/"theirs" follow git's flags: during a merge ours = HEAD
-- (current branch), theirs = the incoming branch; during a rebase they invert
-- (ours = the branch you're replaying onto). checkout --ours/--theirs only
-- works for content conflicts — for add/delete conflicts git errors and we
-- surface that so the user edits/stages manually instead.
local function resolve_side(side)
  local it = cur_item()
  if not (it and it.kind == 'file' and it.conflict) then
    return vim.notify('GitPanel: move the cursor onto a conflicted file', vim.log.levels.INFO)
  end
  local ok, res = run({ 'checkout', '--' .. side, '--', it.value }, { quiet = true })
  if not ok then
    return vim.notify('git checkout --' .. side .. ':\n' .. chomp(res.stderr) ..
      '\n(add/delete conflict — edit the file and press s to mark resolved)', vim.log.levels.WARN)
  end
  run({ 'add', '--', it.value })
  M.refresh()
end
function M.resolve_ours() resolve_side('ours') end
function M.resolve_theirs() resolve_side('theirs') end

-- Continue/finish the in-progress operation (commit the merge, advance the
-- rebase, …). core.editor=true accepts the prepared message without opening
-- an editor. git exits nonzero when it can't proceed (conflicts remain, or a
-- rebase step became empty and wants --skip) — its own message is the most
-- accurate, so we surface that verbatim and re-read state.
function M.op_continue()
  local op = op_state()
  if not op then
    return vim.notify('GitPanel: no merge/rebase/cherry-pick/revert in progress', vim.log.levels.INFO)
  end
  local ok, res = run({ '-c', 'core.editor=true', op, '--continue' }, { quiet = true })
  if not ok then
    vim.notify('git ' .. op .. ' --continue:\n' .. chomp(res.stderr) ..
      '\n(follow the message above, then > to continue or A to abort' ..
      (op == 'rebase' and '; for an empty patch: :!git rebase --skip)' or ')'),
      vim.log.levels.WARN)
  end
  M.refresh()
end
function M.op_abort()
  local op = op_state()
  if not op then
    return vim.notify('GitPanel: nothing to abort (no operation in progress)', vim.log.levels.INFO)
  end
  local pick = fn.confirm('Abort the in-progress ' .. op ..
    '?\nThis throws away the resolution done so far.', '&Yes\n&No', 2)
  if pick ~= 1 then return end
  local ok, res = run({ op, '--abort' }, { quiet = true })
  if not ok then vim.notify('git ' .. op .. ' --abort:\n' .. chomp(res.stderr), vim.log.levels.WARN) end
  M.refresh()
end

-- Signing failed (card absent, PIN cancelled, gpg broken)? Offer ONE explicit
-- fallback to an unsigned commit. Never silent: cancelling pinentry must not
-- quietly produce an unsigned commit, so the default answer is No. The panel's
-- ✓/✗ column shows what actually happened either way.
local function sign_failed(stderr)
  return stderr:find('gpg failed to sign', 1, true)
      or stderr:find('signing failed', 1, true)
end
local function run_commit(args)
  local ok, res = run(args, { quiet = true })
  if not ok and sign_failed(res.stderr) then
    local pick = fn.confirm('GPG signing failed (card absent / PIN cancelled?).\n' ..
      'Commit UNSIGNED instead?', '&Yes\n&No', 2)
    if pick == 1 then
      local retry = vim.deepcopy(args)
      table.insert(retry, 2, '--no-gpg-sign')
      ok, res = run(retry, { quiet = true })
      if ok then vim.notify('GitPanel: committed UNSIGNED', vim.log.levels.WARN) end
    end
  end
  if not ok then vim.notify('git commit:\n' .. chomp(res.stderr), vim.log.levels.ERROR) end
  return ok
end
local function do_commit(extra_args)
  vim.ui.input({ prompt = 'Commit message: ' }, function(msg)
    if not msg or msg == '' then return vim.notify('GitPanel: commit cancelled', vim.log.levels.INFO) end
    local args = { 'commit', '-m', msg }
    for _, a in ipairs(extra_args or {}) do args[#args + 1] = a end
    run_commit(args)
    M.refresh()
  end)
end
-- `c` always prompts for a message and commits. This works to finish a merge
-- (git commit completes it) and to commit at a rebase `edit` stop; to advance
-- with the prepared message (and for rebase after resolving a conflict) use
-- `>` / M.op_continue instead. git refuses to commit while conflicts remain.
function M.commit() do_commit() end
-- "Commit All" during an operation must not `git add -A` (that would sweep in
-- unresolved conflicts); once things are resolved it finishes the operation.
function M.commit_all()
  if has_conflicts() then
    return vim.notify('GitPanel: unresolved conflicts — resolve them first ' ..
      '(o/t or edit + s), then > to continue', vim.log.levels.WARN)
  end
  if op_state() then return M.op_continue() end
  run({ 'add', '-A' }); M.refresh(); do_commit()
end
function M.amend()
  vim.ui.input({ prompt = 'Amend message (empty = keep existing): ' }, function(msg)
    local args = (msg and msg ~= '') and { 'commit', '--amend', '-m', msg }
      or { 'commit', '--amend', '--no-edit' }
    run_commit(args)
    M.refresh()
  end)
end

function M.checkout(branch)
  local it = cur_item()
  branch = branch or (it and it.kind == 'branch' and it.value)
  if not branch then return end
  -- A branch checked out in another worktree cannot be switched to here (git's
  -- one-branch-per-worktree rule). Offer to jump to that worktree instead of
  -- surfacing the cryptic "'<b>' is already used by worktree at ..." error.
  if it and it.kind == 'branch' and it.worktree and not it.current then
    local pick = fn.confirm('"' .. branch .. '" is checked out in another worktree:\n  ' ..
      tilde(it.worktree) .. '\n(git allows a branch in only one worktree at a time)\n\n' ..
      'Jump to that worktree?', '&Yes\n&No', 1)
    if pick == 1 then M.switch_worktree(it.worktree) end
    return
  end
  local ok, res = run({ 'switch', '--', branch }, { quiet = true })
  if not ok then vim.notify('git switch:\n' .. chomp(res.stderr), vim.log.levels.WARN) end
  M.refresh()
end
function M.new_branch()
  vim.ui.input({ prompt = 'New branch name: ' }, function(nm)
    if not nm or nm == '' then return end
    local ok, res = run({ 'switch', '-c', nm }, { quiet = true })
    if not ok then vim.notify('git switch -c:\n' .. chomp(res.stderr), vim.log.levels.ERROR) end
    M.refresh()
  end)
end

local function rename_local_branch(old_name, new_name)
  if old_name == new_name then return true end
  local ok, res = run({ 'branch', '-m', '--', old_name, new_name }, { quiet = true })
  if not ok then
    vim.notify('git branch -m:\n' .. chomp(res.stderr), vim.log.levels.ERROR)
  end
  return ok
end

-- A Git remote has no atomic "rename branch" command. Safely emulate it by
-- creating the new ref, deleting the old ref with a lease, then updating the
-- local branch/upstream. If a host rejects deletion (commonly because the old
-- branch is its default or is protected), leave the local/upstream untouched;
-- the newly-created remote ref makes the operation safe to retry after the
-- repository setting is changed.
local function rename_remote_branch(it, new_name, rename_local)
  local old_local = it.value
  local remote = it.remote
  local old_remote = it.remote_ref and it.remote_ref:match('^refs/heads/(.+)$')
  if not remote or remote == '.' or not old_remote then
    return vim.notify('GitPanel: "' .. old_local .. '" has no tracked remote branch; ' ..
      'rename it locally, then use P to publish it', vim.log.levels.INFO)
  end

  local local_ref = 'refs/heads/' .. old_local
  local old_ref = 'refs/heads/' .. old_remote
  local new_ref = 'refs/heads/' .. new_name

  -- If only the local name differs, the remote is already named correctly.
  if old_remote == new_name then
    if rename_local and old_local ~= new_name then
      if not rename_local_branch(old_local, new_name) then M.refresh(); return end
      local ok, res = run({ 'branch', '--set-upstream-to=' .. remote .. '/' .. new_name,
        '--', new_name }, { quiet = true })
      if not ok then
        vim.notify('Branch renamed locally, but its upstream could not be set:\n' ..
          chomp(res.stderr), vim.log.levels.WARN)
      else
        vim.notify('GitPanel: renamed local branch ' .. old_local .. ' -> ' .. new_name,
          vim.log.levels.INFO)
      end
    else
      vim.notify('GitPanel: remote branch is already named ' .. remote .. '/' .. new_name,
        vim.log.levels.INFO)
    end
    M.refresh()
    return
  end

  -- Check this before touching the remote so a Both operation cannot become
  -- remote-only merely because the requested local target already exists.
  if rename_local and old_local ~= new_name then
    local exists = git({ 'show-ref', '--verify', '--quiet', 'refs/heads/' .. new_name },
      { allow_fail = true })
    if exists.code == 0 then
      return vim.notify('GitPanel: local branch already exists: ' .. new_name,
        vim.log.levels.ERROR)
    end
  end

  local local_sha_res = git({ 'rev-parse', '--verify', local_ref }, { allow_fail = true })
  if local_sha_res.code ~= 0 then
    return vim.notify('GitPanel: local branch no longer exists: ' .. old_local,
      vim.log.levels.WARN)
  end
  local local_sha = chomp(local_sha_res.stdout)

  -- Ask the server for exact ref names; remote-tracking refs may be stale.
  local ls = git({ 'ls-remote', '--heads', '--refs', remote, old_ref, new_ref },
    { allow_fail = true })
  if ls.code ~= 0 then
    return vim.notify('git ls-remote ' .. remote .. ':\n' .. chomp(ls.stderr),
      vim.log.levels.ERROR)
  end
  local heads = {}
  for line in (ls.stdout or ''):gmatch('[^\n]+') do
    local sha, ref = line:match('^(%x+)%s+(refs/heads/.+)$')
    if sha and ref then heads[ref] = sha end
  end
  local old_sha, new_sha = heads[old_ref], heads[new_ref]

  -- An existing target is accepted only when it is the same ref we are about
  -- to copy (or a copy left by an earlier, partially-completed rename).
  if new_sha and new_sha ~= local_sha and new_sha ~= old_sha then
    return vim.notify('GitPanel: refusing to overwrite existing remote branch ' ..
      remote .. '/' .. new_name, vim.log.levels.ERROR)
  end

  if old_sha then
    -- Fetch the source tip and require the selected local branch to contain it.
    -- This prevents deleting commits that exist only on the remote.
    local fetched = git({ 'fetch', '--no-tags', remote, old_ref }, { allow_fail = true })
    if fetched.code ~= 0 then
      return vim.notify('git fetch ' .. remote .. '/' .. old_remote .. ':\n' ..
        chomp(fetched.stderr), vim.log.levels.ERROR)
    end
    local tip = git({ 'rev-parse', '--verify', 'FETCH_HEAD' }, { allow_fail = true })
    if tip.code ~= 0 then
      return vim.notify('GitPanel: could not verify the remote source branch',
        vim.log.levels.ERROR)
    end
    old_sha = chomp(tip.stdout)
    local contains = git({ 'merge-base', '--is-ancestor', old_sha, local_ref },
      { allow_fail = true })
    if contains.code ~= 0 then
      return vim.notify('GitPanel: refusing to rename ' .. remote .. '/' .. old_remote ..
        ' because it has commits missing from local branch "' .. old_local ..
        '". Pull/merge that branch, then retry.', vim.log.levels.ERROR)
    end
  end

  if new_sha ~= local_sha then
    -- A lease with an empty expected value guarantees that a concurrently
    -- created target is not overwritten. For a retry, lease its known SHA.
    local expected = new_sha or ''
    local ok, res = run({ 'push', '--porcelain',
      '--force-with-lease=' .. new_ref .. ':' .. expected,
      remote, local_ref .. ':' .. new_ref }, { quiet = true })
    if not ok then
      return vim.notify('GitPanel: could not create ' .. remote .. '/' .. new_name ..
        '; the old branch was left untouched.\n' .. chomp(res.stderr), vim.log.levels.ERROR)
    end
  end

  if old_sha then
    -- The lease prevents deletion if somebody advanced the source branch
    -- after our fetch. The new ref remains as a safe copy if deletion fails.
    local ok, res = run({ 'push', '--porcelain',
      '--force-with-lease=' .. old_ref .. ':' .. old_sha,
      remote, ':' .. old_ref }, { quiet = true })
    if not ok then
      vim.notify('GitPanel: created ' .. remote .. '/' .. new_name .. ', but the server ' ..
        'refused to delete ' .. remote .. '/' .. old_remote .. '.\n' ..
        'Nothing was renamed locally and its upstream still points to the old branch. ' ..
        'If it is the default/protected branch, change that repository setting, then ' ..
        'press R again with the same new name.\n' .. chomp(res.stderr), vim.log.levels.WARN)
      M.refresh()
      return
    end
  end

  local local_name = old_local
  if rename_local and old_local ~= new_name then
    if not rename_local_branch(old_local, new_name) then
      -- The remote move is already complete; preserve a useful upstream on
      -- the still-old local name and report the recoverable partial result.
      run({ 'branch', '--set-upstream-to=' .. remote .. '/' .. new_name,
        '--', old_local }, { quiet = true })
      vim.notify('GitPanel: remote branch is now ' .. remote .. '/' .. new_name ..
        ', but the local rename failed. Its upstream was moved to the new remote branch.',
        vim.log.levels.WARN)
      M.refresh()
      return
    end
    local_name = new_name
  end

  local upstream_ok, upstream_res = run({
    'branch', '--set-upstream-to=' .. remote .. '/' .. new_name, '--', local_name,
  }, { quiet = true })
  if not upstream_ok then
    vim.notify('GitPanel: remote rename completed, but setting the upstream failed:\n' ..
      chomp(upstream_res.stderr), vim.log.levels.WARN)
  else
    local local_part = (rename_local and old_local ~= new_name)
      and ('local ' .. old_local .. ' -> ' .. new_name .. ' and ') or ''
    vim.notify('GitPanel: renamed ' .. local_part .. 'remote ' .. remote .. '/' ..
      old_remote .. ' -> ' .. remote .. '/' .. new_name, vim.log.levels.INFO)
  end
  -- Refresh origin/HEAD (or equivalent) when the server advertises one.
  git({ 'remote', 'set-head', remote, '--auto' }, { allow_fail = true })
  M.refresh()
end

function M.rename_branch()
  local it = cur_item()
  if not (it and it.kind == 'branch') then
    return vim.notify('GitPanel: move the cursor onto a branch to rename it',
      vim.log.levels.INFO)
  end
  local old_name = it.value
  vim.ui.input({ prompt = 'Rename branch "' .. old_name .. '" to: ', default = old_name },
    function(new_name)
      new_name = new_name and new_name:match('^%s*(.-)%s*$') or nil
      if not new_name or new_name == '' then
        return vim.notify('GitPanel: branch rename cancelled', vim.log.levels.INFO)
      end
      local valid = git({ 'check-ref-format', '--branch', new_name }, { allow_fail = true })
      if valid.code ~= 0 then
        return vim.notify('Invalid branch name "' .. new_name .. '":\n' ..
          chomp(valid.stderr), vim.log.levels.ERROR)
      end
      local remote_branch = it.remote_ref and it.remote_ref:match('^refs/heads/(.+)$')
      local has_remote = it.remote and it.remote ~= '.' and remote_branch
      if has_remote then
        local pick = fn.confirm(
          'Rename branch?\n\n  local:  ' .. old_name .. ' -> ' .. new_name ..
          '\n  remote: ' .. it.remote .. '/' .. remote_branch .. ' -> ' ..
          it.remote .. '/' .. new_name ..
          '\n\nRemote rename pushes the new ref and deletes the old ref.',
          '&Both (local + remote)\n&Local only\n&Remote only\n&Cancel', 4)
        if pick == 1 then return rename_remote_branch(it, new_name, true) end
        if pick == 3 then return rename_remote_branch(it, new_name, false) end
        if pick ~= 2 then return end
      end

      if old_name == new_name then
        return vim.notify('GitPanel: branch is already named ' .. new_name,
          vim.log.levels.INFO)
      end
      if rename_local_branch(old_name, new_name) then
        vim.notify('GitPanel: renamed local branch ' .. old_name .. ' -> ' .. new_name,
          vim.log.levels.INFO)
      end
      M.refresh()
    end)
end

function M.delete_branch()
  local it = cur_item()
  if not (it and it.kind == 'branch') then
    return vim.notify('GitPanel: move the cursor onto a branch to delete it', vim.log.levels.INFO)
  end
  if it.current then return vim.notify('GitPanel: cannot delete the current branch', vim.log.levels.WARN) end
  local ok, res = run({ 'branch', '-d', '--', it.value }, { quiet = true })
  if not ok then
    if (res.stderr or ''):match('not fully merged') then
      local pick = fn.confirm('Branch "' .. it.value .. '" is not fully merged. Force-delete?',
        '&Yes\n&No', 2)
      if pick == 1 then run({ 'branch', '-D', '--', it.value }) end
    else
      vim.notify('git branch -d:\n' .. chomp(res.stderr), vim.log.levels.WARN)
    end
  end
  M.refresh()
end
function M.merge()
  local it = cur_item()
  if not (it and it.kind == 'branch') then
    return vim.notify('GitPanel: move the cursor onto a branch to merge it', vim.log.levels.INFO)
  end
  if it.current then return vim.notify('GitPanel: that is already the current branch', vim.log.levels.INFO) end
  local pick = fn.confirm('Merge "' .. it.value .. '" into the current branch?', '&Yes\n&No', 1)
  if pick ~= 1 then return end
  local ok, res = run({ 'merge', '--', it.value }, { quiet = true })
  local out = chomp((res.stdout or '') .. (res.stderr or ''))
  if not ok then
    vim.notify('git merge:\n' .. out .. '\n(resolve conflicts, then commit; or :!git merge --abort)',
      vim.log.levels.WARN)
  else
    vim.notify('git merge: ' .. out, vim.log.levels.INFO)
  end
  M.refresh()
end

function M.switch_worktree(path)
  local it = cur_item()
  path = path or (it and it.kind == 'worktree' and it.value)
  if not path then return end
  if fn.isdirectory(path) == 0 then
    return vim.notify('GitPanel: worktree path missing: ' .. path, vim.log.levels.WARN)
  end
  vim.cmd('tcd ' .. fn.fnameescape(path))
  if M.root ~= path then reset_github_runtime(path) end
  M.root = path
  vim.notify('GitPanel: switched to worktree ' .. tilde(path), vim.log.levels.INFO)
  M.refresh()
end
function M.new_worktree()
  vim.ui.input({ prompt = 'New worktree path: ', default = (M.root or '') .. '-', completion = 'dir' },
    function(path)
      if not path or path == '' then return end
      vim.ui.input({ prompt = 'Branch (existing) or new name (blank = detach HEAD): ' }, function(br)
        local args
        if not br or br == '' then args = { 'worktree', 'add', '--', path }
        else args = { 'worktree', 'add', '--', path, br } end
        local ok, res = run(args, { quiet = true })
        if not ok and (res.stderr or ''):match('invalid reference') then
          -- branch doesn't exist: create it
          run({ 'worktree', 'add', '-b', br, '--', path })
        elseif not ok then
          vim.notify('git worktree add:\n' .. chomp(res.stderr), vim.log.levels.ERROR)
        end
        M.refresh()
      end)
    end)
end
function M.remove_worktree()
  local it = cur_item()
  if not (it and it.kind == 'worktree') then
    return vim.notify('GitPanel: move the cursor onto a worktree to remove it', vim.log.levels.INFO)
  end
  if it.current then return vim.notify('GitPanel: cannot remove the current worktree', vim.log.levels.WARN) end
  local pick = fn.confirm('Remove worktree "' .. tilde(it.value) .. '"?', '&Yes\n&No', 2)
  if pick ~= 1 then return end
  local ok, res = run({ 'worktree', 'remove', '--', it.value }, { quiet = true })
  if not ok and (res.stderr or ''):match('use %-%-force') then
    local p2 = fn.confirm('Worktree has changes. Force remove?', '&Yes\n&No', 2)
    if p2 == 1 then run({ 'worktree', 'remove', '--force', '--', it.value }) end
  elseif not ok then
    vim.notify('git worktree remove:\n' .. chomp(res.stderr), vim.log.levels.WARN)
  end
  M.refresh()
end

local function current_branch()
  local res = git({ 'symbolic-ref', '--quiet', '--short', 'HEAD' }, { allow_fail = true })
  if res.code ~= 0 then return nil end
  local branch = chomp(res.stdout)
  return branch ~= '' and branch or nil
end

local function push_branch(remote, branch, remote_was_added)
  local ok, res = run({ 'push', '-u', remote, branch }, { quiet = true })
  if not ok then
    local retained = remote_was_added and
      ('\nRemote "' .. remote .. '" remains configured; fix the error and press P to retry.') or ''
    vim.notify('git push -u ' .. remote .. ' ' .. branch .. ':\n' ..
      chomp(res.stderr) .. retained, vim.log.levels.WARN)
  else
    vim.notify('GitPanel: pushed ' .. branch .. ' to ' .. remote ..
      ' and set its upstream', vim.log.levels.INFO)
  end
  M.refresh()
  return ok
end

-- Git itself can attach and push to a URL, but creating a hosted repository is
-- provider-specific. GitHub's optional `gh` CLI provides that missing API; the
-- URL path remains available for GitLab, Bitbucket, self-hosted Git, and bare
-- repositories created outside the panel.
local function publish_github(branch)
  if fn.executable('gh') ~= 1 then
    return vim.notify('GitPanel: GitHub CLI (gh) is not installed. Install it and run ' ..
      '`gh auth login`, or choose "Attach an existing remote URL".', vim.log.levels.WARN)
  end

  local default_name = fn.fnamemodify(M.root or '', ':t')
  vim.ui.input({
    prompt = 'GitHub repository name (REPO or OWNER/REPO): ',
    default = default_name,
  }, function(repo)
    repo = trim(repo)
    if repo == '' then return end

    local visibilities = {
      { label = 'Private', flag = '--private' },
      { label = 'Public', flag = '--public' },
      { label = 'Internal (GitHub Enterprise)', flag = '--internal' },
    }
    vim.ui.select(visibilities, {
      prompt = 'Repository visibility:',
      format_item = function(item) return item.label end,
    }, function(visibility)
      if not visibility then return end
      local pick = fn.confirm(
        'Create GitHub repository "' .. repo .. '" as ' .. visibility.label:lower() ..
        '?\n\nThis adds remote "origin" and pushes branch "' .. branch .. '".',
        '&Create and push\n&Cancel', 2)
      if pick ~= 1 then return end

      local cmd = {
        'gh', 'repo', 'create', repo, visibility.flag,
        '--source', M.root, '--remote', 'origin', '--push',
      }
      vim.notify('GitPanel: creating ' .. repo .. ' and pushing ' .. branch .. '…',
        vim.log.levels.INFO)
      local res = vim.system(cmd, {
        text = true,
        cwd = M.root,
        env = { LC_ALL = 'C', GH_PROMPT_DISABLED = '1' },
      }):wait()

      if res.code ~= 0 then
        local detail = chomp((res.stderr or '') .. (res.stdout or ''))
        local origin = git({ 'remote', 'get-url', 'origin' }, { allow_fail = true })
        local partial = ''
        if origin.code == 0 then
          partial = '\n\norigin is now ' .. chomp(origin.stdout) ..
            '. The repository may already exist; fix the error and press P to retry the push.'
        end
        vim.notify('gh repo create failed:\n' .. detail .. partial, vim.log.levels.ERROR)
        M.refresh()
        return
      end

      -- gh normally establishes tracking with --push. Keep that invariant
      -- explicit in case a CLI/version leaves only the remote ref behind.
      local upstream = git({ 'rev-parse', '--verify', '--quiet', '@{upstream}' },
        { allow_fail = true })
      if upstream.code ~= 0 then
        local tracked = git({ 'branch', '--set-upstream-to=origin/' .. branch,
          '--', branch }, { allow_fail = true })
        if tracked.code ~= 0 then
          vim.notify('GitPanel: repository was created and pushed, but upstream tracking ' ..
            'could not be set:\n' .. chomp(tracked.stderr), vim.log.levels.WARN)
          M.refresh()
          return
        end
      end

      local url = chomp(res.stdout)
      vim.notify('GitPanel: created ' .. repo .. ' and pushed ' .. branch ..
        (url ~= '' and ('\n' .. url) or ''), vim.log.levels.INFO)
      M.refresh()
    end)
  end)
end

local function attach_remote_url(branch)
  vim.ui.input({ prompt = 'Remote URL to add as origin: ' }, function(url)
    url = trim(url)
    if url == '' then return end
    local ok, res = run({ 'remote', 'add', 'origin', url }, { quiet = true })
    if not ok then
      vim.notify('git remote add origin:\n' .. chomp(res.stderr), vim.log.levels.ERROR)
      M.refresh()
      return
    end
    push_branch('origin', branch, true)
  end)
end

function M.publish()
  if #remote_names() > 0 then return M.push() end

  local branch = current_branch()
  if not branch then
    return vim.notify('GitPanel: cannot publish a detached HEAD; switch to a branch first',
      vim.log.levels.WARN)
  end
  local head = git({ 'rev-parse', '--verify', '--quiet', 'HEAD' }, { allow_fail = true })
  if head.code ~= 0 then
    return vim.notify('GitPanel: create at least one commit before publishing this repository',
      vim.log.levels.INFO)
  end

  local gh_available = fn.executable('gh') == 1
  local choices = {
    { id = 'github', label = 'Create a new GitHub repository' ..
      (gh_available and '' or ' (gh not installed)') },
    { id = 'url', label = 'Attach an existing remote URL' },
  }
  vim.ui.select(choices, {
    prompt = 'No Git remote is configured. Publish how?',
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice then return end
    if choice.id == 'github' then publish_github(branch)
    else attach_remote_url(branch) end
  end)
end

function M.push()
  local remotes = remote_names()
  if #remotes == 0 then return M.publish() end

  local branch = current_branch()
  if not branch then
    return vim.notify('GitPanel: cannot push a detached HEAD; switch to a branch first',
      vim.log.levels.WARN)
  end

  local upstream = git({ 'rev-parse', '--verify', '--quiet', '@{upstream}' },
    { allow_fail = true })
  if upstream.code == 0 then
    local ok, res = run({ 'push' }, { quiet = true })
    if not ok then vim.notify('git push:\n' .. chomp(res.stderr), vim.log.levels.WARN) end
    M.refresh()
    return
  end

  if #remotes == 1 then return push_branch(remotes[1], branch) end
  vim.ui.select(remotes, { prompt = 'Push "' .. branch .. '" to remote:' }, function(remote)
    if remote then push_branch(remote, branch) end
  end)
end
function M.pull() run({ 'pull', '--ff-only' }); M.refresh() end
function M.fetch() run({ 'fetch', '--all', '--prune' }); M.refresh() end

function M.help()
  return help_ui.open(M.config.help)
end

function M.attach_keys()
  local buf = M.buf
  local function k(lhs, fnc, desc)
    vim.keymap.set('n', lhs, fnc, { buffer = buf, nowait = true, silent = true, desc = 'GitPanel: ' .. desc })
  end
  -- Some terminals/SSH paths encode the Enter key as LF or keypad Enter.
  -- Keep these mappings buffer-local: ordinary editing buffers retain their
  -- normal Enter motions, while every terminal representation works here.
  for _, lhs in ipairs({ '<CR>', '<NL>', '<kEnter>' }) do
    k(lhs, M.primary, 'primary action')
  end
  k('<Tab>', M.toggle_view, 'next view')
  k('<S-Tab>', M.previous_view, 'previous view')
  for index = 1, #VIEWS do
    local target = index
    k(tostring(target), function() M.select_view(target) end, 'open ' .. VIEWS[target].label .. ' view')
  end
  k('za', M.toggle_fold, 'fold/unfold section')
  k('s', M.stage, 'stage file')
  k('u', M.unstage, 'unstage file')
  k('S', M.stage_all, 'Stage All')
  k('U', M.unstage_all, 'Unstage All')
  k('x', M.discard, 'discard file (confirm)')
  k('o', M.resolve_ours, 'resolve conflict: take ours')
  k('t', M.resolve_theirs, 'resolve conflict: take theirs')
  k('>', M.op_continue, 'continue merge/rebase/cherry-pick')
  k('A', M.op_abort, 'abort merge/rebase/cherry-pick')
  k('c', M.commit, 'commit staged')
  k('C', M.commit_all, 'Commit All')
  k('a', M.amend, 'amend')
  k('b', M.new_branch, 'new branch')
  k('R', M.rename_branch, 'rename branch (local / remote)')
  k('m', M.merge, 'merge branch into current')
  k('d', function()
    local it = cur_item()
    if it and it.kind == 'worktree' then M.remove_worktree() else M.delete_branch() end
  end, 'delete branch / remove worktree')
  k('W', M.new_worktree, 'new worktree')
  k('P', M.push, 'push / publish repository')
  k('F', M.pull, 'pull (--ff-only)')
  k('f', M.fetch, 'fetch')
  k('L', M.toggle_layout, 'toggle tab/split')
  k('r', M.manual_refresh, 'refresh / synchronize')
  k('gx', M.open_github_browser, 'open GitHub item in browser')
  k('go', M.pr_checkout, 'check out pull request branch')
  k('gd', M.pr_diff, 'diff pull request against its base')
  k('gc', M.pr_comment, 'comment on pull request')
  k('gm', M.pr_merge, 'merge pull request with configured backend (confirm)')
  k('gC', M.select_connection, 'select GitHub connection profile')
  k('gD', M.connection_doctor, 'diagnose GitHub connection')
  k('q', M.close, 'close panel')
  k('g?', M.help, 'help')
  k('?', M.help, 'help')
end

-- startup wiring
define_hl()
api.nvim_create_autocmd('ColorScheme', {
  group = api.nvim_create_augroup('GitPanelHl', { clear = true }),
  callback = define_hl,
})
api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
  group = api.nvim_create_augroup('GitPanelLayout', { clear = true }),
  callback = function()
    if not find_win() then return end
    vim.schedule(function()
      if not find_win() then return end
      ensure_detail_layout()
      M.refresh({ skip_remote_fetch = true, reuse_model = true })
    end)
  end,
})

return M
