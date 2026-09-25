local panel
local fixture = vim.fn.tempname()

local function git(args)
  local command = { "git" }
  vim.list_extend(command, args)
  local result = vim.system(command, {
    cwd = fixture,
    text = true,
    env = { LC_ALL = "C", GIT_CONFIG_NOSYSTEM = "1" },
  }):wait()
  assert(
    result.code == 0,
    ("%s failed:\n%s"):format(table.concat(command, " "), result.stderr or "")
  )
  return result.stdout or ""
end

local function assert_contains(text, needle)
  assert(text:find(needle, 1, true), ("expected output to contain %q"):format(needle))
end

local function panel_text()
  return table.concat(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false), "\n")
end

local github_fixtures = {
  overview = {
    {
      kind = "overview", id = "1", name = "git-panel", full_name = "octo/git-panel",
      description = "A focused Git workspace for Neovim.", visibility = "public",
      default_branch = "bet", url = "https://github.com/octo/git-panel",
    },
  },
  actions = {
    {
      kind = "action", id = "101", number = 17, name = "CI", title = "test GitHub tabs",
      status = "completed", conclusion = "success", branch = "feat/github-workspace-tabs",
      event = "pull_request", actor = "gitpanel-ci", updated_at = "2026-08-16T12:00:00Z",
      url = "https://github.com/octo/git-panel/actions/runs/101",
    },
  },
  issues = {
    {
      kind = "issue", id = "201", number = 5, title = "Readable key guide", state = "open",
      author = "octo", labels = { "area:rendering", "accessibility" }, comments = 2,
      body = "Improve the key guide.", updated_at = "2026-08-16T12:00:00Z",
      url = "https://github.com/octo/git-panel/issues/5",
    },
  },
  pulls = {
    {
      kind = "pull", id = "301", number = 8, title = "Add repository views", state = "open",
      draft = true, author = "octo", head = "feature", head_sha = string.rep("a", 40),
      head_label = "octo:feature", head_repository = "octo/git-panel", base = "bluff",
      base_repository = "octo/git-panel", labels = {}, comments = 0,
      body = "Actions, Issues, and Pull Requests.", updated_at = "2026-08-16T12:00:00Z",
      url = "https://github.com/octo/git-panel/pull/8",
    },
  },
}

local function run()
  assert(vim.fn.mkdir(fixture, "p") == 1, "failed to create Git fixture")
  git({ "init", "--initial-branch=bet" })
  git({ "config", "user.name", "GitPanel CI" })
  git({ "config", "user.email", "git-panel@example.invalid" })
  git({ "config", "commit.gpgsign", "false" })

  vim.fn.writefile({ "initial" }, fixture .. "/tracked.txt")
  git({ "add", "tracked.txt" })
  git({ "commit", "-m", "initial fixture" })
  vim.fn.writefile({ "changed" }, fixture .. "/tracked.txt")
  vim.fn.writefile({ "new" }, fixture .. "/untracked.txt")

  assert(vim.fn.exists(":GitPanel") == 2, ":GitPanel command was not registered")
  assert(vim.fn.exists(":GitPanelSplit") == 2, ":GitPanelSplit command was not registered")
  assert(vim.fn.exists(":GitPanelConnection") == 2,
    ":GitPanelConnection command was not registered")
  assert(vim.fn.exists(":GitPanelDoctor") == 2, ":GitPanelDoctor command was not registered")

  vim.cmd("lcd " .. vim.fn.fnameescape(fixture))
  panel = require("git_panel")
  panel.setup({
    github = {
      repository = "octo/git-panel",
      profile = "fixture",
      profiles = {
        fixture = {
          label = "Fixture transport",
          description = "Deterministic smoke-test API.",
          transport = "curl",
        },
      },
      client_factory = function()
        return {
          fetch = function(_, view, _, callback)
            vim.schedule(function()
              callback(nil, github_fixtures[view], { transport = "fixture" })
            end)
          end,
        }
      end,
    },
  })
  panel.open("split")

  assert(panel.mode == "split", "panel did not open in split mode")
  assert(vim.uv.fs_realpath(panel.root) == vim.uv.fs_realpath(fixture), "wrong repository root")
  assert(vim.wait(2000, function()
    return panel_text():find("▸ 1 Changes", 1, true) ~= nil
  end), "asynchronous local repository snapshot did not render")
  local rendered = panel_text()
  assert_contains(rendered, "▸ 1 Changes")
  assert_contains(rendered, "  5 Pull Requests")
  assert_contains(rendered, "Branches")
  assert_contains(rendered, "Unstaged  (1)")
  assert_contains(rendered, "Untracked  (1)")
  assert_contains(rendered, "Outgoing commits")
  assert_contains(rendered, "Recent commits")
  assert_contains(rendered, "Latest")

  panel.stage_all()
  local staged = git({ "diff", "--cached", "--name-only" })
  assert_contains(staged, "tracked.txt")
  assert_contains(staged, "untracked.txt")

  panel.unstage_all()
  assert(git({ "diff", "--cached", "--name-only" }) == "", "unstage-all left index changes")

  local help_buf, help_win = panel.help()
  assert(vim.api.nvim_win_is_valid(help_win), "help window did not open")
  local help_text = table.concat(vim.api.nvim_buf_get_lines(help_buf, 0, -1, false), "\n")
  assert_contains(help_text, "GitHub views")
  assert_contains(help_text, "gC")
  vim.api.nvim_win_close(help_win, true)
  vim.api.nvim_set_current_win(panel.win)

  local profile_choices = panel.connection_profiles()
  assert(profile_choices[2].id == "fixture" and profile_choices[2].active,
    "configured connection profile was not active")
  assert(panel.select_connection("fixture"), "connection profile could not be selected")
  panel.connection_doctor()
  assert(vim.wait(1000, function()
    return vim.api.nvim_buf_get_name(0) == "gitpanel://doctor"
  end), "connection doctor did not open its report")
  local doctor_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert_contains(doctor_text, "Profile:       Fixture transport")
  assert_contains(doctor_text, "Status:        reachable via fixture")
  vim.cmd("close")
  vim.api.nvim_set_current_win(panel.win)

  panel.toggle_view()
  assert(panel.view == "history", "history view did not activate")
  panel.previous_view()
  assert(panel.view == "work", "previous view did not return to changes")

  panel.select_view(3)
  assert(vim.wait(1000, function() return panel_text():find("CI #17", 1, true) ~= nil end),
    "Actions view did not render async fixture")
  assert_contains(panel_text(), "synced")
  assert_contains(panel_text(), "via fixture")

  panel.select_view(4)
  assert(vim.wait(1000, function() return panel_text():find("#5", 1, true) ~= nil end),
    "Issues view did not render async fixture")
  local issue_line
  for index, line in ipairs(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)) do
    if line:find("Readable key guide", 1, true) then issue_line = index; break end
  end
  assert(issue_line, "issue row was not mapped")
  vim.api.nvim_set_current_win(panel.win)
  vim.api.nvim_win_set_cursor(panel.win, { issue_line, 0 })
  panel.primary()
  assert_contains(vim.api.nvim_buf_get_name(0), "gitpanel://github/issue/201")
  vim.cmd("close")
  vim.api.nvim_set_current_win(panel.win)

  panel.select_view(5)
  assert(vim.wait(1000, function() return panel_text():find("#8", 1, true) ~= nil end),
    "Pull Requests view did not render async fixture")
  assert_contains(panel_text(), "Add repository views")

  local stale_callbacks = {}
  panel.setup({
    github = {
      repository = "octo/old-repository",
      client_factory = function()
        return {
          fetch = function(_, view, _, callback) stale_callbacks[view] = callback end,
        }
      end,
    },
  })
  panel.select_view(3)
  assert(stale_callbacks.actions, "stale-response fixture did not capture the old request")

  panel.setup({
    github = {
      repository = "octo/current-repository",
      client_factory = function()
        return {
          fetch = function(_, _, _, callback)
            vim.schedule(function()
              callback(nil, {
                {
                  kind = "action", id = "current", number = 18, name = "Current generation",
                  title = "accepted response", status = "completed", conclusion = "success",
                },
              }, { transport = "fixture" })
            end)
          end,
        }
      end,
    },
  })
  assert(vim.wait(1000, function()
    return panel_text():find("Current generation", 1, true) ~= nil
  end), "current-generation response did not render")
  stale_callbacks.actions(nil, {
    {
      kind = "action", id = "stale", number = 99, name = "Stale generation",
      title = "must be ignored", status = "completed", conclusion = "failure",
    },
  }, { transport = "stale-fixture" })
  vim.wait(100, function() return false end, 10)
  assert(not panel_text():find("Stale generation", 1, true),
    "a stale GitHub response replaced the current repository data")
  assert_contains(panel_text(), "Current generation")

  panel.select_view(2)
  assert(panel.view == "history", "numeric view selection did not activate history")
  vim.o.columns = 160
  panel.toggle_layout()
  assert(panel.mode == "tab", "layout did not toggle to tab mode")
  assert(panel.detail_win and vim.api.nvim_win_is_valid(panel.detail_win),
    "wide tab layout did not create the context rail")
  if vim.env.UX_CHROME_ROOT then
    local panes = require('ux_chrome.panes')
    assert(panes.inspect(panel.win).role == 'navigation')
    assert(panes.inspect(panel.detail_win).role == 'context')
    local tx = assert(require('ux_foundation').begin_transaction())
    assert(tx:stage('ux.chrome.panes/context/wrap/value', false))
    assert(vim.wo[panel.detail_win].wrap == false)
    assert(tx:revert()); assert(tx:commit())
    assert(vim.wo[panel.detail_win].wrap == true)
    panel.refresh({ skip_remote_fetch = true, reuse_model = true, presentation_only = true })
    local before = vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)
    local selected = vim.api.nvim_win_get_cursor(panel.win)
    local model_generation, detail_generation = panel.model_generation, panel.detail_generation
    local map = vim.deepcopy(panel.line_map)
    local styles = assert(require('ux_foundation').begin_transaction())
    assert(styles:stage('ux.chrome.components/navigation/padding/value', 4))
    local saw_header = false
    for _, line in ipairs(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)) do
      if line:match('^    [▸▾]') then saw_header = true end
    end
    assert(saw_header, 'shared padding did not reach Git sections')
    assert(vim.deep_equal(panel.line_map, map), 'presentation changed Git action targets')
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(panel.win), selected), 'presentation moved Git selection')
    assert(panel.model_generation == model_generation, 'presentation refreshed Git state')
    assert(panel.detail_generation == detail_generation, 'presentation refreshed Git detail')
    assert(styles:revert()); assert(styles:commit())
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false), before))
  end
  vim.api.nvim_win_set_cursor(panel.win, { 1, 0 })
  panel.update_detail()
  assert_contains(table.concat(vim.api.nvim_buf_get_lines(panel.detail_buf, 0, -1, false), "\n"),
    "Repository overview")
  panel.select_view("work")
  local tracked_line
  for index, line in ipairs(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)) do
    if line:find("tracked.txt", 1, true) and not line:find("untracked.txt", 1, true) then
      tracked_line = index
      break
    end
  end
  assert(tracked_line, "working-tree row was not rendered")
  vim.api.nvim_win_set_cursor(panel.win, { tracked_line, 0 })
  panel.update_detail()
  assert(vim.wait(2000, function()
    local detail = table.concat(vim.api.nvim_buf_get_lines(panel.detail_buf, 0, -1, false), "\n")
    return detail:find("+changed", 1, true) ~= nil
  end), "context rail did not render the selected file diff")
  panel.close()
end

local ok, message = xpcall(run, debug.traceback)
if panel then pcall(panel.close) end
vim.fn.delete(fixture, "rf")
if not ok then error(message) end

print("GitPanel smoke test passed")
