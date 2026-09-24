# git-panel.nvim

[![CI](https://github.com/777lotto/git-panel.nvim/actions/workflows/ci.yml/badge.svg?branch=bluff)](https://github.com/777lotto/git-panel.nvim/actions/workflows/ci.yml)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io/)
[![Release](https://img.shields.io/github/v/release/777lotto/git-panel.nvim)](https://github.com/777lotto/git-panel.nvim/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A dependency-free local Git dashboard for Neovim with optional GitHub
repository views. It keeps branches, worktrees, changes, conflicts, commits,
workflow runs, issues, and pull requests in one keyboard-driven panel — and
lets you review, comment on, and merge pull requests without leaving it.

## Highlights

- Five first-class views: Changes, History, Actions, Issues, and Pull Requests.
- Non-blocking local snapshots: independent Git reads run concurrently and
  stale callbacks cannot replace a newer repository state.
- A responsive full-tab workspace with a live diff/object context rail on wide
  screens; the compact split keeps the focused navigation layout.
- Branch and worktree creation, switching, renaming, merging, and removal.
- Staging, discarding, signing-aware commits, and explicit conflict actions.
- Pull, fetch, push, and first-push repository publication.
- Asynchronous GitHub synchronization through `gh` or `curl` with no UI stalls.
- Named GitHub connection profiles with an in-editor selector and credential-safe doctor report.
- Structured, highlighted, responsive `?` key guide.
- Verified-signature indicators in commit history.
- No Neovim plugin dependencies.

## Requirements

- Neovim 0.10 or newer
- Git available on `PATH`

GitPanel's local views require nothing else. GitHub views use one optional
transport:

- authenticated [GitHub CLI](https://cli.github.com/) (`gh`) — recommended;
- `curl`, authenticated through a token provider for private repositories or
  anonymous for public repositories.

The `gh` CLI also enables GitHub repository creation during the first push.
Without it, the panel can still attach and push to any existing Git remote URL.

## Installation

With lazy.nvim:

```lua
{
  "777lotto/git-panel.nvim",
  cmd = { "GitPanel", "GitPanelSplit", "GitPanelConnection", "GitPanelDoctor" },
  keys = {
    { "<leader>gg", "<cmd>GitPanel<cr>", desc = "Git dashboard" },
    { "<leader>gG", "<cmd>GitPanelSplit<cr>", desc = "Git dashboard (split)" },
  },
}
```

`bluff` is the default and only long-lived branch. Pin a release tag for an
immutable installation, or let your plugin manager follow `bluff` and retain
its own tested lock.

With Neovim's native packages:

```sh
git clone https://github.com/777lotto/git-panel.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/git-panel.nvim
nvim --headless -c "helptags ALL" -c quit
```

## Commands

- `:GitPanel` opens the full dashboard in a tab.
- `:GitPanelSplit` opens it as a left split.
- `:GitPanelConnection [profile]` selects a preconfigured GitHub connection for the session.
- `:GitPanelDoctor` checks repository discovery and API reachability without displaying credentials.

The Lua API is available through `require("git_panel")`; its primary entry
point is `require("git_panel").open("tab")` or `.open("split")`.

## Main controls

| Key                 | Action                                                                                    |
| ------------------- | ----------------------------------------------------------------------------------------- |
| `<Tab>` / `<S-Tab>` | Move to the next / previous view                                                          |
| `1`–`5`             | Jump to Changes, History, Actions, Issues, or Pull Requests                               |
| `<CR>`              | Act on the item under the cursor (LF/keypad Enter also work)                              |
| `s` / `u`           | Stage / unstage the selected file                                                         |
| `S` / `U`           | Stage / unstage all                                                                       |
| `c` / `C`           | Commit staged / stage all and commit                                                      |
| `a`                 | Amend the last commit                                                                     |
| `b` / `R` / `d`     | Create / rename / delete a branch                                                         |
| `W`                 | Create a worktree                                                                         |
| `F` / `P` / `f`     | Pull / push-or-publish / fetch                                                            |
| `L`                 | Toggle tab and split layouts                                                              |
| `r`                 | Refresh local state and synchronize GitHub repository context                             |
| `gx`                | Open the selected GitHub item in a browser                                                |
| `go` / `gd`         | Check out / diff the selected pull request against its base                               |
| `gc` / `gm`         | Comment on / merge the selected pull request (confirm; uses the configured merge backend) |
| `gC` / `gD`         | Select a GitHub connection profile / diagnose repository access                           |
| `?` / `g?`          | Show the highlighted, scrollable key guide                                                |
| `q`                 | Close                                                                                     |

Conflict workflows expose take-ours/take-theirs, continue, and abort actions;
remote branch renames use leases and avoid overwriting an unrelated ref.

The full-tab layout adapts at 120 columns. At wider sizes, the dashboard uses
the left side for repository state and the right side for context: repository
and remote metadata by default, then a live diff, commit stat, branch tip,
worktree status, tag, stash, push, issue, workflow, or pull-request summary as
the cursor moves. Below that threshold it collapses to one pane. The split
layout remains a fixed-width, compact control surface.

When `P` is pressed in a repository with no configured remote, GitPanel offers
two paths:

- create a private, public, or internal GitHub repository with `gh repo create`,
  add it as `origin`, and push the current branch;
- attach an already-created URL as `origin` and push the current branch, which
  works with GitLab, Bitbucket, self-hosted Git, or a bare repository.

Publishing requires at least one local commit. If a remote already exists but
the branch has no upstream, `P` selects the remote when needed and pushes with
upstream tracking.

## GitHub repository views

The Actions and Issues views are read-only; the Pull Requests view adds
review-and-land actions that always confirm before writing. GitPanel resolves
the current repository from a GitHub.com or `*.ghe.com` remote, preferring
`origin`, then caches repository metadata and each view independently. Open
issue/PR counts and the latest workflow state appear in the view bar. The
context rail adds visibility, default branch, and description without adding
vanity metrics. Opening a view renders cached
content immediately and starts a background refresh when the cache is stale.
Loading, empty, authentication, permission, rate-limit, network, and stale-data
states are shown inside the panel.

- Actions shows recent workflow status, conclusion, branch, event, actor, and
  update date.
- Issues shows open issues, excluding pull requests returned by GitHub's Issues
  endpoint.
- Pull Requests shows open PRs, draft state, head/base branches, author, and
  update date.
- `<CR>` opens a Markdown summary in Neovim; `gx` opens the canonical GitHub URL.
- On a pull-request row: `go` fetches and checks out the head branch, `gd`
  opens the full `base...head` diff in a buffer, `gc` posts a conversation
  comment, and `gm` creates a merge commit using the configured backend. After
  a merge, GitPanel deletes a same-repository remote head branch, prunes, and —
  when you were on the PR branch — returns you to the base branch and
  fast-forwards it. Cross-repository head branches are never deleted from the
  base repository.

Zero-configuration `gh` authentication is the preferred path: run
`gh auth login`, or provide one of the token environment variables supported by
GitHub CLI. GitPanel calls `gh api` directly and never copies the stored token
into Lua configuration. `github.gh_command` may instead name a compatible API
wrapper; GitPanel invokes `COMMAND api ENDPOINT [flags]` and supplies `GH_HOST`,
so the wrapper does not need to expose the other `gh` command groups.

Optional settings:

```lua
require("git_panel").setup({
  help = {
    border = "rounded",
    max_width = 88,
  },
  github = {
    enabled = true,
    profile = nil,             -- initial named profile; nil uses the base settings
    profiles = {},             -- named, non-secret setting overrides
    transport = "auto",       -- "auto", "gh", or "curl"
    repository = nil,          -- "OWNER/REPO"; nil detects a Git remote
    host = nil,                -- required to identify a custom GHES host
    remote_path_prefix = nil,  -- path segments a proxy mounts repos under
    api_url = nil,             -- custom HTTPS REST base; auto selects curl
    allow_insecure_http = false, -- permit a plaintext http:// api_url
    refresh_interval = 60,     -- seconds
    per_page = 30,             -- 1..100
    timeout = 15000,           -- milliseconds
    token_provider = nil,
    merge_backend = "api",     -- "api" or "signed_git"
    gh_command = "gh",
    curl_command = "curl",
  },
})
```

### Connection profiles and diagnostics

Profiles group repository discovery, transport, endpoint, and merge settings
under a user-facing name. The base `github` settings remain the `default`
choice; a profile overrides them without changing the existing setup contract:

```lua
require("git_panel").setup({
  github = {
    profile = "team-broker",
    profiles = {
      ["github-cli"] = {
        label = "GitHub CLI",
        transport = "gh",
        gh_command = "gh",
      },
      ["team-broker"] = {
        label = "Team GitHub broker",
        description = "Credential-free repository API proxy.",
        transport = "curl",
        remote_path_prefix = "github/git",
        api_url = "https://broker.example/github/api",
      },
    },
  },
})
```

Use `:GitPanelConnection` or `gC` to switch among configured profiles. The
selection lasts for the current Neovim process and immediately resets the
remote caches; keep a durable default in `setup()`. `:GitPanelDoctor` or `gD`
reports the active profile, repository discovery, available executables, and a
live metadata request. It reports only whether an external credential provider
exists—GitPanel never asks for, renders, or persists a token. `default` is a
reserved selector name and cannot be used as a profile key.

### Proxied and self-hosted GitHub endpoints

Some environments reach GitHub through a broker or reverse proxy that holds the
credential, mounts repositories under a fixed path prefix, and publishes a
GitHub-compatible REST API at another path. A remote such as
`https://proxy.example/github/git/OWNER/REPO.git` is not discoverable by
default, because everything after the host must be exactly `OWNER/REPO`.

`github.remote_path_prefix` names the segments to remove before GitPanel reads
`OWNER/REPO`, and `github.api_url` points the curl transport at the proxy's REST
base:

```lua
require("git_panel").setup({
  github = {
    host = "proxy.example",
    remote_path_prefix = "github/git",   -- or a list: { "github/git", "mirror" }
    api_url = "https://proxy.example/github/api",
  },
})
```

Discovery still prefers `origin` and still ignores unrelated remotes. A prefix
is stripped only when the remote actually carries it, so `github.com` and
`*.ghe.com` remotes keep working unchanged alongside a configured proxy. Setting
`github.api_url` also makes that URL's host discoverable, so `github.host` is
only needed when the Git and API hosts differ. Because a custom `api_url`
selects the curl transport, a proxy that injects the credential upstream needs
no `token_provider` at all.

A proxy that terminates TLS upstream may expose only a plaintext endpoint on a
private network. That is opt-in:

```lua
require("git_panel").setup({
  github = {
    remote_path_prefix = "github/git",
    api_url = "http://10.0.0.1:8790/github/api",
    allow_insecure_http = true,
  },
})
```

`allow_insecure_http` relaxes only the URL scheme check. GitPanel still refuses
to send a bearer token over plaintext HTTP to any non-loopback host, so a
credential cannot be exposed on the wire by a configuration mistake; use an
`https` `api_url` when the endpoint itself requires a token.

`merge_backend = "api"` is the portable default. It asks GitHub to merge only
if the head still matches the SHA shown in GitPanel and, for a same-repository
pull request, deletes the head ref through the REST API.

`merge_backend = "signed_git"` is an opt-in capability for anyone with Git
commit signing and remote push authentication configured. It fetches the
current base and the pull request's exact advertised head SHA, creates a
`--no-ff --gpg-sign` merge in a temporary worktree, verifies that the result
contains a cryptographic signature and two parents, then pushes the base with a
normal non-force Git push. A same-repository head branch is deleted with an
exact-SHA lease; a fork branch is left alone. If signing fails or the PR head
changed, nothing is pushed and there is no unsigned or API fallback. Git's
configured OpenPGP, SSH, or S/MIME signing format is used.

For example, an API-only GitHub App wrapper can be combined with locally signed
Git transport without coupling the two mechanisms:

```lua
require("git_panel").setup({
  github = {
    gh_command = vim.fn.expand("~/.local/bin/gh-app"),
    merge_backend = "signed_git",
  },
})
```

The signed backend needs permission to push the base through the repository's
existing Git remote. Branch protection, rulesets, and merge queues can reject
that push; choose the API backend when GitHub must perform or queue the merge.
Comments and all GitHub view data continue to use the selected API transport in
either mode.

The curl transport needs a bearer token for private repositories. A synchronous
provider can read a short-lived token from an existing secret source:

```lua
require("git_panel").setup({
  github = {
    transport = "curl",
    token_provider = function(context)
      return vim.env.GITHUB_TOKEN
    end,
  },
})
```

Providers that mint an expiring GitHub App installation token can resolve it
asynchronously. Return `true` to signal that the provider will invoke
`done(token, error)` later:

```lua
require("git_panel").setup({
  github = {
    token_provider = function(context, done)
      vim.system({ "my-github-app-token-helper", context.repository },
        { text = true }, function(result)
          vim.schedule(function()
            if result.code == 0 then
              done(vim.trim(result.stdout))
            else
              done(nil, "GitHub App token helper failed")
            end
          end)
        end)
      return true
    end,
  },
})
```

GitHub App user access tokens and installation access tokens are supported as
bearer tokens. The App needs repository **Actions: read**, **Issues: read**, and
**Pull requests: read** permissions. `gc` additionally needs permission to
write issue or pull-request comments (**Issues: write** or **Pull requests:
write**). The API merge backend needs
**Contents: write** for merging and same-repository branch deletion; the signed
Git backend uses Git push authentication instead. A raw App private key is
deliberately not accepted: it is a long-lived signing credential used to mint
an installation token, and should stay in an external helper or vault.
Installation tokens expire after one hour, so GitPanel invokes the provider for
every request batch.
See GitHub's documentation for [App authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/about-authentication-with-a-github-app)
and [installation access tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).

Tokens are never persisted, rendered, notified, or placed in process arguments.
The `gh` transport passes a provider token through the appropriate environment
variable; the curl transport sends its authorization header over standard
input, ignores user-level curl configuration, and does not follow redirects.

## Platform support

| Platform | Status    | CI                                |
| -------- | --------- | --------------------------------- |
| Linux    | Supported | Neovim 0.10.4, 0.11.7, and 0.12.4 |
| macOS    | Supported | Neovim 0.12.4 smoke test          |
| Windows  | Untested  | Contributions welcome             |

Platform behavior is kept in the implementation and tested in Actions. It is
not split into operating-system branches or GitHub Environments.

## Branch and release model

- `bluff` is the default and only long-lived branch.
- Focused branches start from and merge into `bluff`.
- CI-created `vX.Y.Z` tags and GitHub Releases mark tested `bluff` commits.

Successful push CI on the current `bluff` head automatically publishes a
versioned GitHub Release and notifies `nvim-config` with that exact commit.
CI creates unsigned tags, starting at `v0.1.0` and incrementing the patch
version. Failed or superseded runs do not publish. The existing
`NVIM_CONFIG_DISPATCH_TOKEN` repository secret enables notification; a missing
secret fails visibly after publication. See [release automation](docs/releases.md)
for retry behavior, versioning, and the distinction between plugin releases
and configuration adoption.

See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and pull-request guidance.

## Community and roadmap

Use [Issues](https://github.com/777lotto/git-panel.nvim/issues) for reproducible,
actionable work. Questions, setup showcases, and exploratory ideas belong in
[Discussions](https://github.com/777lotto/git-panel.nvim/discussions). Work that
spans this plugin and `nvim-config` is planned in the public
[Neovim Workspace](https://github.com/users/777lotto/projects/5).

## Project layout

```text
git-panel.nvim/
├── .github/                 # CI, issue forms, and contribution templates
├── lua/git_panel/init.lua   # dashboard, actions, rendering, and public Lua API
├── lua/git_panel/connections.lua # named GitHub connection profile resolution
├── lua/git_panel/model.lua  # concurrent local Git snapshot and parsers
├── lua/git_panel/github.lua # GitHub discovery, transports, and response models
├── lua/git_panel/help.lua   # structured responsive key-guide renderer
├── plugin/git-panel.lua     # lightweight command registration
├── doc/git-panel.txt        # :help git-panel
├── scripts/check-lua.lua    # dependency-free compilation check
└── tests/                   # provider/unit tests and isolated Git smoke fixture
```

Run `:help git-panel` for the complete in-editor reference.

## License

git-panel.nvim is available under the [MIT License](LICENSE).
# Shared pane presentation

GitPanel optionally uses UX Chrome's `ux_chrome.panes` API for navigation and
context windows. Wrapping, gutters, selection, and pane colors are editable
through Foundation/Styling. Markdown context uses Chrome's renderer integration;
changing content type replaces the context scratch buffer to release the old
renderer. Without the API, GitPanel retains its native presentation.
