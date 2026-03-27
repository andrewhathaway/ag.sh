#!/usr/bin/env bash
# ============================================================================
# ag.sh -- Agentic Development Environment
# ============================================================================
#
# Compatible with bash 4+ and zsh 5+. Sourced, not executed directly.
#
# A shell toolkit for managing multiple Claude Code CLI instances, each
# running in its own tmux pane with an isolated git worktree.
#
# Source of truth: git worktrees on disk (survive tmux crashes / reboots).
# tmux is the ephemeral UI layer on top.
#
# ============================================================================
# QUICK REFERENCE
# ============================================================================
#
#   ag                                  Show agent status (same as ag ls)
#   ag spawn <task> [--prompt "..."]    Create worktree + branch + window, start claude
#   ag spawn <t1> <t2> <t3>            Spawn multiple agents at once
#   ag kill <t1> [t2 ...] [--force/-f]  Kill window(s), keep worktree + branch
#   ag rm <t1> [t2 ...] [--force/-f]    Kill window + remove worktree + delete branch
#   ag ls                               List all agents with colored status
#   ag cd <task>                        cd into a task's worktree
#   ag push <task>                      Push task branch to origin
#   ag diff <task> [--stat]             Diff task branch vs base branch
#   ag attach                           Attach to this repo's tmux session
#   ag resume [task ...]                Respawn windows for stopped worktrees
#   ag shell <task>                     Open a shell-only window in a worktree
#   ag layout [h|v|even-h|even-v]       Change pane layout in task windows
#   ag help                             Show this reference
#
# ============================================================================
# WORKFLOW
# ============================================================================
#
#   cd ~/my-project
#   ag spawn auth --prompt "Fix the JWT refresh bug"
#   ag spawn billing
#   # You now have two tmux windows, each with claude (top) + shell (bottom).
#   # Switch windows: <prefix> w (picker), <prefix> n/p (next/prev)
#   # Zoom one pane: <prefix> z  (toggle)
#   # Detach: <prefix> d  (prefix is ctrl-b by default)
#   # Next day:
#   ag resume          # brings everything back
#   ag ls              # see status
#   ag rm auth -f      # done with auth, clean up
#
# ============================================================================
# CONFIGURATION
# ============================================================================
#
# AGENT_CLI:
#   The command to run in each pane. Defaults to "claude".
#   Examples:
#     export AGENT_CLI="claude"
#     export AGENT_CLI="claude --dangerously-skip-permissions"
#
# AGENT_WORKTREE_PARENT:
#   Override where worktrees are stored. By default, if your repo is at
#   /home/you/src/myrepo, worktrees go in /home/you/src/myrepo-worktrees/.
#   Override example:
#     export AGENT_WORKTREE_PARENT="$HOME/worktrees"
#     -> $HOME/worktrees/myrepo/<task>
#
# AGENT_BRANCH_PREFIX:
#   Namespace for agent branches. Default: "agent".
#   Branch for task "auth" -> agent/auth
#
# AGENT_DEFAULT_LAYOUT:
#   Default tmux layout for the two panes within each task window.
#   Default: "main-horizontal" (claude on top, shell on bottom).
#   Options: main-horizontal, main-vertical, even-horizontal, even-vertical
#
# AGENT_IGNORE_BRANCHES:
#   Space-separated list of branch names to exclude from `ag ls` when
#   AGENT_BRANCH_PREFIX is empty. These are your "base" branches that
#   should not be treated as agent tasks.
#   Default: "main master develop"
#   Example: export AGENT_IGNORE_BRANCHES="main master develop trunk release"
#
# ============================================================================

# ----------------------------------------------------------------------------
# Configuration defaults
# ----------------------------------------------------------------------------
# These can be overridden by exporting them before this file is sourced.
# Each has a sensible default so things work out of the box.
# ----------------------------------------------------------------------------

AGENT_CLI="${AGENT_CLI:-claude}"
AGENT_WORKTREE_PARENT="${AGENT_WORKTREE_PARENT:-}"
AGENT_BRANCH_PREFIX="${AGENT_BRANCH_PREFIX:-agent}"
AGENT_DEFAULT_LAYOUT="${AGENT_DEFAULT_LAYOUT:-main-horizontal}"
AGENT_IGNORE_BRANCHES="${AGENT_IGNORE_BRANCHES:-main master develop}"

# ----------------------------------------------------------------------------
# Runtime compatibility check
# ----------------------------------------------------------------------------
# Associative arrays (declare -A) require bash 4+ or zsh 5+. macOS ships
# with bash 3.x at /usr/bin/bash which will fail. Check early and warn.
# ----------------------------------------------------------------------------
if [[ -n "${BASH_VERSION:-}" ]]; then
  if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ag.sh: bash ${BASH_VERSION} is too old. Requires bash 4+ (for associative arrays)." >&2
    echo "ag.sh: Install a newer bash (e.g., 'brew install bash') or use zsh." >&2
    return 0 2>/dev/null || true
  fi
fi

# ----------------------------------------------------------------------------
# Color constants
# ----------------------------------------------------------------------------
# Used for log output and the status table. These are ANSI escape codes.
# We define them once here so they're easy to tweak or disable.
# ----------------------------------------------------------------------------

__AG_GREEN='\033[32m'
__AG_YELLOW='\033[33m'
__AG_RED='\033[31m'
__AG_CYAN='\033[36m'
__AG_DIM='\033[2m'
__AG_BOLD='\033[1m'
__AG_RESET='\033[0m'

# ----------------------------------------------------------------------------
# Per-invocation cache
# ----------------------------------------------------------------------------
# These get populated on first use and cleared at the start of each ag() call.
# This eliminates redundant subprocess calls (git rev-parse, basename, etc.)
# within a single command. For example, `ag ls` with 5 tasks used to call
# `git rev-parse --show-toplevel` 15+ times; with caching it's called once.
# ----------------------------------------------------------------------------
__AG_CACHE_REPO_ROOT=""
__AG_CACHE_REPO_NAME=""
__AG_CACHE_WT_PARENT=""

__ag_cache_clear() {
  __AG_CACHE_REPO_ROOT=""
  __AG_CACHE_REPO_NAME=""
  __AG_CACHE_WT_PARENT=""
}


# ============================================================================
# SECTION 1: Logging Helpers
# ============================================================================
# All output goes to stderr so it doesn't interfere with function return
# values that callers might capture with $().
# ============================================================================

# ----------------------------------------------------------------------------
# __ag_log -- Info-level message
# ----------------------------------------------------------------------------
# Usage: __ag_log "Created worktree for auth"
# Output: ag: Created worktree for auth  (in cyan)
# ----------------------------------------------------------------------------
__ag_log() {
  printf '%b\n' "${__AG_CYAN}ag:${__AG_RESET} $*" >&2
}

# ----------------------------------------------------------------------------
# __ag_warn -- Warning-level message
# ----------------------------------------------------------------------------
# Usage: __ag_warn "Worktree already exists"
# Output: ag: Worktree already exists  (in yellow)
# ----------------------------------------------------------------------------
__ag_warn() {
  printf '%b\n' "${__AG_YELLOW}ag:${__AG_RESET} $*" >&2
}

# ----------------------------------------------------------------------------
# __ag_err -- Error-level message
# ----------------------------------------------------------------------------
# Usage: __ag_err "Not inside a git repo"
# Output: ag: Not inside a git repo  (in red)
# Returns 1 so callers can do: __ag_err "msg" && return 1
# or just: __ag_err "msg"; return 1
# ----------------------------------------------------------------------------
__ag_err() {
  printf '%b\n' "${__AG_RED}ag:${__AG_RESET} $*" >&2
  return 1
}

# ----------------------------------------------------------------------------
# __ag_confirm -- Interactive y/N confirmation prompt
# ----------------------------------------------------------------------------
# Usage:
#   __ag_confirm "Remove worktree for 'auth'?" "$force"
#
# Arguments:
#   $1 - The question to display
#   $2 - Force flag: if "1", skip prompt and return 0 (confirmed)
#
# Returns:
#   0 if the user confirmed (y/Y) or force was set
#   1 if the user declined or gave empty input
#
# The default is N (decline), so just pressing Enter declines.
# This is intentional for destructive operations.
# ----------------------------------------------------------------------------
__ag_confirm() {
  local prompt="$1"
  local force="${2:-0}"

  # In force mode, skip the interactive prompt entirely
  if [[ "$force" == "1" ]]; then
    return 0
  fi

  # Show the prompt in yellow to draw attention
  printf '%b' "${__AG_YELLOW}${prompt}${__AG_RESET} [y/N]: " >&2

  # Read a single line of input
  # Note: we use printf + read (not read -p) for zsh compatibility
  local reply
  read -r reply

  case "$reply" in
    [yY]|[yY][eE][sS])
      return 0
      ;;
    *)
      __ag_log "Cancelled."
      return 1
      ;;
  esac
}


# ============================================================================
# SECTION 2: Git Helpers
# ============================================================================
# Low-level functions for interacting with git. These are the foundation
# that worktree and tmux helpers build on.
# ============================================================================

# ----------------------------------------------------------------------------
# __ag_require_git -- Ensure we are inside a git repository
# ----------------------------------------------------------------------------
# Almost every command needs this. We fail fast with a clear message rather
# than letting git commands produce cryptic errors downstream.
# ----------------------------------------------------------------------------
__ag_require_git() {
  if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    __ag_err "Not inside a git repository. cd into a repo first."
    return 1
  fi
}

# ----------------------------------------------------------------------------
# __ag_repo_root -- Absolute path to the repo root
# ----------------------------------------------------------------------------
# Used for running git commands from a known location, regardless of where
# the user's shell is currently cd'd to within the repo.
# ----------------------------------------------------------------------------
__ag_repo_root() {
  if [[ -z "$__AG_CACHE_REPO_ROOT" ]]; then
    __AG_CACHE_REPO_ROOT="$(git rev-parse --show-toplevel)"
  fi
  printf '%s\n' "$__AG_CACHE_REPO_ROOT"
}

# ----------------------------------------------------------------------------
# __ag_repo_name -- The repo's directory name (basename of root)
# ----------------------------------------------------------------------------
# Used as the tmux session name. If your repo is at /home/you/src/platform,
# the session will be called "platform".
# ----------------------------------------------------------------------------
__ag_repo_name() {
  if [[ -z "$__AG_CACHE_REPO_NAME" ]]; then
    __AG_CACHE_REPO_NAME="$(basename "$(__ag_repo_root)")"
  fi
  printf '%s\n' "$__AG_CACHE_REPO_NAME"
}

# ----------------------------------------------------------------------------
# __ag_default_base -- Detect the default branch (main, master, or HEAD)
# ----------------------------------------------------------------------------
# Different repos use main or master. We check for both in order of
# preference, falling back to whatever HEAD currently points at.
# This is used when creating new branches for tasks.
# ----------------------------------------------------------------------------
__ag_default_base() {
  local root
  root="$(__ag_repo_root)"

  if git -C "$root" show-ref --verify --quiet refs/heads/main; then
    echo "main"
  elif git -C "$root" show-ref --verify --quiet refs/heads/master; then
    echo "master"
  else
    # Fallback: whatever branch is currently checked out
    git -C "$root" symbolic-ref --short HEAD 2>/dev/null || echo "main"
  fi
}

# ----------------------------------------------------------------------------
# __ag_branch_name -- Convert a task name to a branch name
# ----------------------------------------------------------------------------
# Applies the configured prefix. By default:
#   auth       -> agent/auth
#   api/fix    -> agent/api/fix
#
# The prefix is configurable via AGENT_BRANCH_PREFIX.
# ----------------------------------------------------------------------------
__ag_branch_name() {
  local task="$1"
  if [[ -n "$AGENT_BRANCH_PREFIX" ]]; then
    printf '%s/%s\n' "$AGENT_BRANCH_PREFIX" "$task"
  else
    printf '%s\n' "$task"
  fi
}

# ----------------------------------------------------------------------------
# __ag_branch_exists -- Check if a local branch exists
# ----------------------------------------------------------------------------
# Returns 0 if the branch exists, 1 if not.
# Used to decide whether to create a new branch or reuse an existing one.
# ----------------------------------------------------------------------------
__ag_branch_exists() {
  local branch="$1"
  git show-ref --verify --quiet "refs/heads/$branch"
}


# ============================================================================
# SECTION 3: Worktree Helpers
# ============================================================================
# Functions for creating, finding, and removing git worktrees.
# Worktrees are the durable state -- they survive tmux crashes and reboots.
# ============================================================================

# ----------------------------------------------------------------------------
# __ag_worktree_parent -- Directory where all worktrees for this repo live
# ----------------------------------------------------------------------------
# Default layout:
#   Repo at:     /home/you/src/myrepo
#   Worktrees:   /home/you/src/myrepo-worktrees/
#
# With AGENT_WORKTREE_PARENT override:
#   Override:    $HOME/worktrees
#   Worktrees:   $HOME/worktrees/myrepo/
#
# We keep worktrees outside the main repo to avoid clutter and make it
# obvious which checkout is the "real" one.
# ----------------------------------------------------------------------------
__ag_worktree_parent() {
  if [[ -z "$__AG_CACHE_WT_PARENT" ]]; then
    local root repo
    root="$(__ag_repo_root)"
    repo="$(__ag_repo_name)"

    if [[ -n "${AGENT_WORKTREE_PARENT}" ]]; then
      __AG_CACHE_WT_PARENT="${AGENT_WORKTREE_PARENT%/}/${repo}"
    else
      __AG_CACHE_WT_PARENT="$(dirname "$root")/${repo}-worktrees"
    fi
  fi
  printf '%s\n' "$__AG_CACHE_WT_PARENT"
}

# ----------------------------------------------------------------------------
# __ag_task_to_dirname -- Convert a task name to a safe directory name
# ----------------------------------------------------------------------------
# Branch names can contain slashes and spaces, but directory names are
# easier to manage if we flatten them to dashes.
#
# Examples:
#   auth       -> auth
#   api/fix    -> api-fix
#   my task    -> my-task
# ----------------------------------------------------------------------------
__ag_task_to_dirname() {
  local task="$1"
  printf '%s\n' "$task" | sed -E 's#[/[:space:]]+#-#g'
}

# ----------------------------------------------------------------------------
# __ag_worktree_path -- Full filesystem path for a task's worktree
# ----------------------------------------------------------------------------
# Combines the worktree parent directory with the sanitized task name.
# All commands use this to agree on where a task's checkout lives.
# ----------------------------------------------------------------------------
__ag_worktree_path() {
  local task="$1"
  local parent dir
  parent="$(__ag_worktree_parent)"
  dir="$(__ag_task_to_dirname "$task")"
  printf '%s/%s\n' "$parent" "$dir"
}

# ----------------------------------------------------------------------------
# __ag_worktree_exists -- Check if a worktree directory exists on disk
# ----------------------------------------------------------------------------
# A git worktree has a .git file (not directory) in its root.
# Returns 0 if the worktree is present, 1 otherwise.
# ----------------------------------------------------------------------------
__ag_worktree_exists() {
  local task="$1"
  local wt_path
  wt_path="$(__ag_worktree_path "$task")"
  [[ -d "$wt_path" && ( -f "$wt_path/.git" || -d "$wt_path/.git" ) ]]
}

# ----------------------------------------------------------------------------
# __ag_ensure_worktree -- Idempotently create a branch + worktree for a task
# ----------------------------------------------------------------------------
# This is safe to call multiple times. If the worktree already exists,
# it logs and returns. If the branch exists but worktree doesn't, it
# attaches the branch. If neither exists, it creates both.
#
# Flow:
#   1. Prune stale worktree metadata (handles manually deleted dirs)
#   2. If worktree already exists -> done
#   3. Create parent directory
#   4. If branch exists -> attach it to a new worktree
#   5. If branch doesn't exist -> create branch from default base
#
# Arguments:
#   $1 - task name
# ----------------------------------------------------------------------------
__ag_ensure_worktree() {
  local task="$1"
  local root wt_path branch base wt_parent

  root="$(__ag_repo_root)"
  branch="$(__ag_branch_name "$task")"
  wt_path="$(__ag_worktree_path "$task")"
  wt_parent="$(dirname "$wt_path")"

  # Clean up any stale worktree references from previous manual deletions
  git -C "$root" worktree prune >/dev/null 2>&1 || true

  # Already exists? Nothing to do.
  if __ag_worktree_exists "$task"; then
    __ag_log "Worktree already exists: $wt_path"
    return 0
  fi

  # Ensure the parent directory exists
  mkdir -p "$wt_parent"

  if __ag_branch_exists "$branch"; then
    # Branch exists but no worktree -- attach it
    __ag_log "Attaching existing branch '$branch' to worktree..."
    git -C "$root" worktree add "$wt_path" "$branch" || return 1
  else
    # Neither branch nor worktree exist -- create both
    base="$(__ag_default_base)"
    __ag_log "Creating branch '$branch' from '$base' with worktree..."
    git -C "$root" worktree add -b "$branch" "$wt_path" "$base" || return 1
  fi

  __ag_log "Worktree ready: $wt_path"
}

# ----------------------------------------------------------------------------
# __ag_remove_worktree -- Remove a worktree and optionally its branch
# ----------------------------------------------------------------------------
# Uses --force to handle worktrees with uncommitted changes.
# Also runs git worktree prune to clean up metadata.
#
# Arguments:
#   $1 - task name
# ----------------------------------------------------------------------------
__ag_remove_worktree() {
  local task="$1"
  local root wt_path branch

  root="$(__ag_repo_root)"
  wt_path="$(__ag_worktree_path "$task")"
  branch="$(__ag_branch_name "$task")"

  # Remove the worktree directory
  if [[ -d "$wt_path" ]]; then
    __ag_log "Removing worktree: $wt_path"
    git -C "$root" worktree remove --force "$wt_path" || {
      __ag_err "Failed to remove worktree: $wt_path"
      return 1
    }
  else
    __ag_warn "Worktree directory not found: $wt_path (already removed?)"
  fi

  # Delete the branch
  if __ag_branch_exists "$branch"; then
    __ag_log "Deleting branch: $branch"
    git -C "$root" branch -D "$branch" >/dev/null 2>&1 || {
      __ag_warn "Could not delete branch '$branch' (may be checked out elsewhere)"
    }
  fi

  # Clean up any stale references
  git -C "$root" worktree prune >/dev/null 2>&1 || true

  __ag_log "Cleaned up agent '$task'"
}

# ----------------------------------------------------------------------------
# __ag_list_agent_worktrees -- List all task names that have agent worktrees
# ----------------------------------------------------------------------------
# Parses `git worktree list --porcelain` and filters for branches matching
# the agent prefix. Returns one task name per line.
#
# This is the source of truth for ag ls and ag resume -- it tells us
# which tasks exist on disk regardless of tmux state.
#
# Output format (one per line):
#   auth
#   billing
#   api-fix
# ----------------------------------------------------------------------------
__ag_list_agent_worktrees() {
  local root prefix
  root="$(__ag_repo_root)"
  prefix="$AGENT_BRANCH_PREFIX"

  # git worktree list --porcelain outputs blocks like:
  #   worktree /path/to/worktree
  #   HEAD abc123
  #   branch refs/heads/agent/auth
  #   <blank line>
  #
  # We look for lines starting with "branch refs/heads/<prefix>/"
  # and extract the task name (everything after the prefix).
  # Build the prefix to match against. With a branch prefix like "agent",
  # we look for "refs/heads/agent/". With an empty prefix, we match all
  # worktree branches (refs/heads/) except the main repo worktree.
  local match_prefix
  if [[ -n "$prefix" ]]; then
    match_prefix="refs/heads/${prefix}/"
  else
    match_prefix="refs/heads/"
  fi

  git -C "$root" worktree list --porcelain 2>/dev/null | \
    awk -v prefix="$match_prefix" -v has_prefix="${prefix:+1}" \
        -v ignore_list="$AGENT_IGNORE_BRANCHES" '
      BEGIN {
        # Build a set of branch names to ignore when prefix is empty
        n = split(ignore_list, ignored, " ")
        for (i = 1; i <= n; i++) ignore[ignored[i]] = 1
      }
      /^branch / {
        branch = $2
        if (index(branch, prefix) == 1) {
          # Strip the prefix to get the task name
          task = substr(branch, length(prefix) + 1)
          # With no prefix, skip branches in the ignore list
          if (!has_prefix && (task in ignore)) next
          if (task != "") print task
        }
      }
    '
}


# ============================================================================
# SECTION 4: tmux Helpers
# ============================================================================
# Functions for managing tmux sessions, windows, and panes.
#
# Architecture:
#   - One tmux SESSION per repo (named after the repo directory)
#   - One tmux WINDOW per task (named after the task)
#   - Each window has TWO PANES:
#       Top pane:    claude CLI (title: "agent:<task>")
#       Bottom pane: plain shell (title: "shell:<task>")
#
# This gives each task its own self-contained workspace. Switch between
# tasks with ctrl-a w (window picker) or ctrl-a n/p (next/prev).
#
# tmux is the ephemeral UI layer -- it can die and be rebuilt from
# worktree state via `ag resume`.
# ============================================================================

# ----------------------------------------------------------------------------
# __ag_session_name -- The tmux session name for this repo
# ----------------------------------------------------------------------------
# Same as the repo directory name. Each repo gets its own session.
# ----------------------------------------------------------------------------
__ag_session_name() {
  local name
  name="$(__ag_repo_name)"
  # tmux silently replaces dots and colons with underscores in session names;
  # mirror that so our targets match what tmux actually creates
  name="${name//./_}"
  name="${name//:/_}"
  printf '%s\n' "$name"
}

# ----------------------------------------------------------------------------
# __ag_has_previous_session -- Check if the agent CLI has a prior conversation
# ----------------------------------------------------------------------------
# Checks for a resumable conversation in the given working directory.
# Supports claude (~/.claude/projects/<encoded>/) and codex (~/.codex/sessions/).
#
# Arguments:
#   $1 - absolute path to the working directory (worktree)
#
# Returns:
#   0 if a previous session exists, 1 otherwise
# ----------------------------------------------------------------------------
__ag_has_previous_session() {
  local dir="$1"
  local cli_base
  cli_base="$(basename "${AGENT_CLI%% *}")"

  case "$cli_base" in
    claude)
      # Claude Code encodes project paths by replacing / and . with -
      local encoded="${dir//\//-}"
      encoded="${encoded//./-}"
      local project_dir="${HOME}/.claude/projects/${encoded}"
      [[ -d "$project_dir" ]] && compgen -G "${project_dir}/*.jsonl" >/dev/null 2>&1
      ;;
    codex)
      # Codex stores sessions globally under ~/.codex/sessions/ with cwd in the JSONL.
      # A lightweight check: see if any session file references this directory.
      local sessions_dir="${HOME}/.codex/sessions"
      [[ -d "$sessions_dir" ]] && grep -rlq "\"cwd\":\"${dir}\"" "$sessions_dir" 2>/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

# __ag_resume_cmd -- Build the CLI command to resume a previous conversation
# ----------------------------------------------------------------------------
# Returns the full command string to continue the most recent conversation
# in the current directory, or empty string if the CLI doesn't support it.
#
# Arguments:
#   $1 - absolute path to the working directory (worktree)
# ----------------------------------------------------------------------------
__ag_resume_cmd() {
  local wt_path="$1"
  local cli_base
  cli_base="$(basename "${AGENT_CLI%% *}")"

  case "$cli_base" in
    claude)
      printf '%s\n' "cd $(printf '%q' "$wt_path") && ${AGENT_CLI} --continue; exec ${SHELL}"
      ;;
    codex)
      printf '%s\n' "cd $(printf '%q' "$wt_path") && codex resume --last; exec ${SHELL}"
      ;;
    *)
      # Unknown CLI -- no resume support, start fresh
      printf '%s\n' ""
      ;;
  esac
}

# __ag_session_exists -- Check if the tmux session exists
# ----------------------------------------------------------------------------
# Returns 0 if the session is alive, 1 otherwise.
# Also returns 1 if tmux is not installed.
# ----------------------------------------------------------------------------
__ag_session_exists() {
  local session
  session="$(__ag_session_name)"
  command -v tmux >/dev/null 2>&1 && tmux has-session -t "=$session" 2>/dev/null
}

# ----------------------------------------------------------------------------
# __ag_require_tmux -- Fail fast if tmux is not available
# ----------------------------------------------------------------------------
__ag_require_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    __ag_err "tmux is required but not installed."
    return 1
  fi
}

# ----------------------------------------------------------------------------
# __ag_window_for_task -- Check if a tmux window exists for a task
# ----------------------------------------------------------------------------
# Each task gets its own window, named after the task's directory name.
# Returns the window target string if found.
#
# Arguments:
#   $1 - task name
#
# Output:
#   Window target string (e.g., "myproject:auth") if found
#
# Returns:
#   0 if window found, 1 if not
# ----------------------------------------------------------------------------
__ag_window_for_task() {
  local task="$1"
  local session dir_name

  session="$(__ag_session_name)"
  dir_name="$(__ag_task_to_dirname "$task")"

  if ! __ag_session_exists; then
    return 1
  fi

  # Check if a window with this name exists in the session
  if tmux list-windows -t "=$session" -F '#{window_name}' 2>/dev/null | grep -qx "$dir_name"; then
    printf '%s:%s\n' "$session" "$dir_name"
    return 0
  fi

  return 1
}

# ----------------------------------------------------------------------------
# __ag_pane_for_task -- Find the claude (agent) pane ID for a task
# ----------------------------------------------------------------------------
# Searches the task's window for the pane titled "agent:<task>".
# This is the top pane where claude runs.
#
# Arguments:
#   $1 - task name
#
# Output:
#   The pane ID (e.g., %42) if found, or empty string if not.
#
# Returns:
#   0 if pane found, 1 if not found
# ----------------------------------------------------------------------------
__ag_pane_for_task() {
  local task="$1"
  local session pane_id title target_title

  session="$(__ag_session_name)"
  target_title="agent:${task}"

  # If the session doesn't exist, there's definitely no pane
  if ! __ag_session_exists; then
    return 1
  fi

  # List all panes across all windows in the session (-s flag)
  # Format: pane_id|pane_title
  while IFS='|' read -r pane_id title; do
    if [[ "$title" == "$target_title" ]]; then
      printf '%s\n' "$pane_id"
      return 0
    fi
  done < <(tmux list-panes -s -t "=$session" -F '#{pane_id}|#{pane_title}' 2>/dev/null)

  return 1
}

# ----------------------------------------------------------------------------
# __ag_pane_status -- Determine what's running in a pane
# ----------------------------------------------------------------------------
# Checks the current command of a pane to determine if the agent CLI
# is running, or if the pane has fallen through to a shell.
#
# Arguments:
#   $1 - pane ID (e.g., %42)
#
# Output (printed to stdout):
#   "active" - the agent CLI is running
#   "idle"   - a shell is running (agent exited, fell through)
#   "unknown" - something else is running
# ----------------------------------------------------------------------------
__ag_pane_status() {
  local pane_id="$1"
  local current_cmd cli_name

  # Get the basename of the configured CLI for comparison
  # e.g., "claude --dangerously-skip-permissions" -> "claude"
  cli_name="$(basename "${AGENT_CLI%% *}")"

  # Query the pane's current foreground command
  current_cmd="$(tmux display-message -t "$pane_id" -p '#{pane_current_command}' 2>/dev/null)"

  if [[ "$current_cmd" == "$cli_name" ]]; then
    echo "active"
  elif [[ "$current_cmd" == "zsh" || "$current_cmd" == "bash" || "$current_cmd" == "sh" ]]; then
    echo "idle"
  else
    echo "unknown"
  fi
}

# ----------------------------------------------------------------------------
# __ag_spawn_task_window -- Create a tmux window with claude + shell panes
# ----------------------------------------------------------------------------
# This is the core window creation logic. Each task gets its own window
# containing two panes:
#
#   ┌──────────────────────────┐
#   │                          │
#   │     claude (top pane)    │
#   │     title: agent:<task>  │
#   │                          │
#   ├──────────────────────────┤
#   │  shell (bottom pane)     │
#   │  title: shell:<task>     │
#   └──────────────────────────┘
#
# The claude pane runs: cd <worktree> && <agent_cli> [prompt]; exec $SHELL
# The "; exec $SHELL" fallthrough means when claude exits, the pane
# stays open as a shell in the worktree directory.
#
# Arguments:
#   $1 - task name
#   $2 - optional prompt text for claude
# ----------------------------------------------------------------------------
__ag_spawn_task_window() {
  local task="$1"
  local prompt="${2:-}"
  local session wt_path dir_name cmd

  session="$(__ag_session_name)"
  wt_path="$(__ag_worktree_path "$task")"
  dir_name="$(__ag_task_to_dirname "$task")"

  # Build the agent CLI command string
  # We cd into the worktree, run the agent CLI, then fall through to a shell
  if [[ -n "$prompt" ]]; then
    cmd="cd $(printf '%q' "$wt_path") && ${AGENT_CLI} $(printf '%q' "$prompt"); exec ${SHELL}"
  else
    # No prompt -- check if there's a previous conversation to resume.
    # This picks up right where the agent left off after a reboot/crash.
    local resume_cmd
    resume_cmd=""
    if __ag_has_previous_session "$wt_path"; then
      resume_cmd="$(__ag_resume_cmd "$wt_path")"
    fi
    if [[ -n "$resume_cmd" ]]; then
      cmd="$resume_cmd"
    else
      cmd="cd $(printf '%q' "$wt_path") && ${AGENT_CLI}; exec ${SHELL}"
    fi
  fi

  # Create the window. Two paths:
  #   1. Session doesn't exist yet -> create session with first window
  #   2. Session exists -> add a new window to it
  if ! __ag_session_exists; then
    # Create the session with this task as the first window
    __ag_log "Creating tmux session '$session' with window '$dir_name'"
    tmux new-session -d -s "$session" -n "$dir_name" -c "$wt_path" -x 200 -y 50 || {
      __ag_err "Failed to create tmux session '$session'"
      return 1
    }
  else
    # Session exists, add a new window
    __ag_log "Creating window '$dir_name' in session '$session'"
    tmux new-window -t "=$session:" -n "$dir_name" -c "$wt_path" || {
      __ag_err "Failed to create window '$dir_name'"
      return 1
    }
  fi

  # The new window has one pane -- this becomes the claude pane (top)
  # Get its pane ID so we can target it
  local claude_pane
  claude_pane="$(tmux list-panes -t "=${session}:${dir_name}" -F '#{pane_id}' | head -1)"

  # Set the title and send the claude command
  tmux select-pane -t "$claude_pane" -T "agent:${task}"
  # Prefix with a space so the command is excluded from shell history
  # (requires HIST_IGNORE_SPACE in zsh or HISTCONTROL=ignorespace in bash)
  tmux send-keys -t "$claude_pane" " $cmd" Enter

  # Split the window vertically to create the shell pane (bottom)
  # Give the shell pane ~30% of the height; fall back to minimal split
  tmux split-window -v -t "=${session}:${dir_name}" -l '30%' -c "$wt_path" || \
  tmux split-window -v -t "=${session}:${dir_name}" -l 5 -c "$wt_path" || {
    __ag_warn "Failed to split window for shell pane (window still has claude)"
    return 0
  }

  # The split-window auto-selects the new (bottom) pane -- set its title
  tmux select-pane -T "shell:${task}"

  # Select the claude pane (top) so it's focused when the user sees the window
  tmux select-pane -t "$claude_pane"

  # Apply the configured layout
  __ag_apply_layout "" "$dir_name"

  __ag_log "Spawned agent '$task': claude (top) + shell (bottom)"
}

# ----------------------------------------------------------------------------
# __ag_kill_task_window -- Kill the entire tmux window for a task
# ----------------------------------------------------------------------------
# Destroys the window and both panes. The worktree and branch are NOT
# touched -- use __ag_remove_worktree for that.
#
# Arguments:
#   $1 - task name
#
# Returns:
#   0 if window was killed or didn't exist
# ----------------------------------------------------------------------------
__ag_kill_task_window() {
  local task="$1"
  local session dir_name

  session="$(__ag_session_name)"
  dir_name="$(__ag_task_to_dirname "$task")"

  if ! __ag_session_exists; then
    return 0
  fi

  # Check if the window exists before trying to kill it
  if tmux list-windows -t "=$session" -F '#{window_name}' 2>/dev/null | grep -qx "$dir_name"; then
    tmux kill-window -t "=${session}:${dir_name}" 2>/dev/null || true
    __ag_log "Killed window for '$task'"
  fi

  # If that was the last window, the session will die automatically.
  # That's fine -- ag resume or ag spawn will recreate it.
}

# ----------------------------------------------------------------------------
# __ag_apply_layout -- Apply layout to a task window's panes
# ----------------------------------------------------------------------------
# With the per-task window model, each window has exactly two panes
# (claude + shell). This applies the configured layout to arrange them.
#
# Arguments:
#   $1 - optional layout name (main-horizontal, even-vertical, etc.)
#   $2 - optional window dir_name (defaults to current window)
# ----------------------------------------------------------------------------
__ag_apply_layout() {
  local layout="${1:-$AGENT_DEFAULT_LAYOUT}"
  local dir_name="${2:-}"
  local session

  session="$(__ag_session_name)"

  if ! __ag_session_exists; then
    return 0
  fi

  if [[ -n "$dir_name" ]]; then
    # Apply to a specific task window
    tmux select-layout -t "=${session}:${dir_name}" "$layout" 2>/dev/null || true
  else
    # Apply to the current window
    tmux select-layout "$layout" 2>/dev/null || true
  fi
}


# ============================================================================
# SECTION 5: Command Implementations
# ============================================================================
# Each __ag_cmd_* function implements one subcommand of `ag`.
# They parse their own arguments, validate state, and call helpers.
# ============================================================================

# ----------------------------------------------------------------------------
# __ag_cmd_spawn -- Create worktree + branch + window, start the agent
# ----------------------------------------------------------------------------
# Usage:
#   ag spawn <task> [--prompt "..."]
#   ag spawn <task1> <task2> <task3>
#
# Flags:
#   --prompt / -p  "text"  -> initial prompt for claude (single task only)
#
# Behavior:
#   - Creates the worktree and branch if they don't exist
#   - Creates a tmux window with claude (top) + shell (bottom) panes
#   - If the task already has a window, switches to it instead
#   - If outside tmux, attaches to the session after spawning
#   - For multiple tasks, spawns all then attaches once
# ----------------------------------------------------------------------------
__ag_cmd_spawn() {
  __ag_require_git || return 1
  __ag_require_tmux || return 1

  # -- Parse arguments --
  local -a tasks
  tasks=()
  local prompt=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prompt|-p)
        if [[ -z "${2:-}" ]]; then
          __ag_err "--prompt requires a value"
          return 1
        fi
        prompt="$2"
        shift 2
        ;;
      -*)
        __ag_err "Unknown flag: $1 (see 'ag help')"
        return 1
        ;;
      *)
        tasks+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#tasks[@]} -eq 0 ]]; then
    __ag_err "Usage: ag spawn <task> [--prompt \"...\"]"
    return 1
  fi

  # Warn if prompt is used with multiple tasks
  if [[ ${#tasks[@]} -gt 1 && -n "$prompt" ]]; then
    local first_warn
    for first_warn in "${tasks[@]}"; do break; done
    __ag_warn "--prompt will only be applied to the first task ('${first_warn}')"
  fi

  # -- Spawn each task --
  local task task_prompt
  local is_first=1
  for task in "${tasks[@]}"; do

    # Only apply prompt to the first task
    task_prompt=""
    if [[ $is_first -eq 1 && -n "$prompt" ]]; then
      task_prompt="$prompt"
    fi
    is_first=0

    # Create worktree (idempotent)
    __ag_ensure_worktree "$task" || continue

    # Check if this task already has a window
    local existing_window
    existing_window="$(__ag_window_for_task "$task")"
    if [[ -n "$existing_window" ]]; then
      __ag_warn "Agent '$task' already has a window. Switching to it."
      tmux select-window -t "$existing_window" 2>/dev/null || true
      continue
    fi

    # Spawn the task window (creates session if needed)
    __ag_spawn_task_window "$task" "$task_prompt"
  done

  # If we're outside tmux, attach to the session so the user can see the windows
  if [[ -z "${TMUX:-}" ]]; then
    local session
    session="$(__ag_session_name)"
    if __ag_session_exists; then
      __ag_log "Attaching to session '$session'..."
      tmux attach -t "=$session"
    fi
  fi
}

# ----------------------------------------------------------------------------
# __ag_cmd_kill -- Kill task window(s), keep worktree(s) and branch(es)
# ----------------------------------------------------------------------------
# This is a "pause" operation. The worktree and branch remain on disk
# so you can resume later. The entire tmux window (claude + shell) is
# destroyed.
#
# Supports multiple tasks in one call.
#
# Usage:
#   ag kill <task> [--force]
#   ag kill <t1> <t2> <t3> --force
#
# Confirms before killing unless --force is passed. With multiple tasks
# and no --force, confirms once for all of them.
# ----------------------------------------------------------------------------
__ag_cmd_kill() {
  __ag_require_git || return 1

  # -- Parse arguments --
  local -a tasks
  tasks=()
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force|-f)
        force=1
        shift
        ;;
      -*)
        __ag_err "Unknown flag: $1"
        return 1
        ;;
      *)
        tasks+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#tasks[@]} -eq 0 ]]; then
    __ag_err "Usage: ag kill <task> [<task2> ...] [--force]"
    return 1
  fi

  # Filter to tasks that actually have windows
  local -a killable
  killable=()
  local task window_target
  for task in "${tasks[@]}"; do
    if ! __ag_worktree_exists "$task"; then
      __ag_warn "No worktree found for '$task', skipping."
      continue
    fi
    window_target="$(__ag_window_for_task "$task")"
    if [[ -z "$window_target" ]]; then
      __ag_warn "No active window for '$task'. Worktree is still on disk."
      continue
    fi
    killable+=("$task")
  done

  if [[ ${#killable[@]} -eq 0 ]]; then
    __ag_log "Nothing to kill."
    return 0
  fi

  # Build confirmation message
  local confirm_msg first_task
  for first_task in "${killable[@]}"; do break; done
  if [[ ${#killable[@]} -eq 1 ]]; then
    confirm_msg="Kill window for '${first_task}'? Worktree and branch will be kept."
  else
    confirm_msg="Kill ${#killable[@]} agent windows (${killable[*]})? Worktrees and branches will be kept."
  fi

  __ag_confirm "$confirm_msg" "$force" || return 0

  for task in "${killable[@]}"; do
    __ag_kill_task_window "$task"
  done
}

# ----------------------------------------------------------------------------
# __ag_cmd_rm -- Kill window + remove worktree + delete branch
# ----------------------------------------------------------------------------
# This is a full teardown. Everything related to each task is removed:
#   - The tmux window (if it exists)
#   - The worktree directory
#   - The git branch
#
# Supports multiple tasks in one call.
#
# Usage:
#   ag rm <task> [--force]
#   ag rm <t1> <t2> <t3> --force
#
# Confirms before removing unless --force is passed. With multiple tasks
# and no --force, confirms once for all of them.
# Will cd to repo root if the user is inside a worktree being removed.
# ----------------------------------------------------------------------------
__ag_cmd_rm() {
  __ag_require_git || return 1

  # -- Parse arguments --
  local -a tasks
  tasks=()
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force|-f)
        force=1
        shift
        ;;
      -*)
        __ag_err "Unknown flag: $1"
        return 1
        ;;
      *)
        tasks+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#tasks[@]} -eq 0 ]]; then
    __ag_err "Usage: ag rm <task> [<task2> ...] [--force]"
    return 1
  fi

  # Validate all tasks exist before confirming
  local -a valid_tasks
  valid_tasks=()
  for task in "${tasks[@]}"; do
    if ! __ag_worktree_exists "$task"; then
      __ag_warn "No worktree found for '$task', skipping."
    else
      valid_tasks+=("$task")
    fi
  done

  if [[ ${#valid_tasks[@]} -eq 0 ]]; then
    __ag_err "No valid tasks to remove."
    return 1
  fi

  # Build confirmation message listing all tasks
  local confirm_msg first_task
  for first_task in "${valid_tasks[@]}"; do break; done
  if [[ ${#valid_tasks[@]} -eq 1 ]]; then
    local branch
    branch="$(__ag_branch_name "$first_task")"
    confirm_msg="Remove agent '${first_task}'? This will kill the window, delete the worktree, and remove branch '${branch}'."
  else
    confirm_msg="Remove ${#valid_tasks[@]} agents (${valid_tasks[*]})? This will kill windows, delete worktrees, and remove branches."
  fi

  __ag_confirm "$confirm_msg" "$force" || return 0

  # Remove each task
  for task in "${valid_tasks[@]}"; do
    local wt_path
    wt_path="$(__ag_worktree_path "$task")"

    # Safety: don't remove a worktree the user is currently standing in
    if [[ "$PWD" == "$wt_path"* ]]; then
      __ag_log "You are inside worktree '$task'. Moving to repo root first."
      cd "$(__ag_repo_root)" || {
        __ag_err "Could not cd to repo root."
        return 1
      }
    fi

    # Kill the window if it exists
    __ag_kill_task_window "$task"

    # Remove the worktree and branch
    __ag_remove_worktree "$task"
  done
}

# ----------------------------------------------------------------------------
# __ag_cmd_ls -- List all agents with colored status
# ----------------------------------------------------------------------------
# Cross-references git worktrees with tmux pane state to show a status
# table. Works even if tmux isn't running (all agents show as "stopped").
#
# Usage:
#   ag ls
#
# Output:
#   myproject  (3 agents, 2 active)
#
#     TASK       STATUS       BRANCH             WORKTREE
#     auth       ● active     agent/auth         ../myproject-worktrees/auth
#     billing    ● idle       agent/billing      ../myproject-worktrees/billing
#     api        ○ stopped    agent/api          ../myproject-worktrees/api
# ----------------------------------------------------------------------------
__ag_cmd_ls() {
  __ag_require_git || return 1

  local repo session
  repo="$(__ag_repo_name)"
  session="$(__ag_session_name)"

  # Gather all agent worktrees
  local -a tasks
  tasks=()
  while IFS= read -r t; do
    [[ -n "$t" ]] && tasks+=("$t")
  done < <(__ag_list_agent_worktrees)

  if [[ ${#tasks[@]} -eq 0 ]]; then
    __ag_log "No agent worktrees found for '$repo'."
    __ag_log "Use 'ag spawn <task>' to create one."
    return 0
  fi

  # Build a map of task -> current command by scanning agent pane titles.
  # Uses an associative array which works in both bash 4+ and zsh 5+.
  declare -A pane_cmd_map
  pane_cmd_map=()

  if __ag_session_exists; then
    local pane_id pane_title pane_cmd ptask
    while IFS='|' read -r pane_id pane_title pane_cmd; do
      if [[ "$pane_title" == agent:* ]]; then
        ptask="${pane_title#agent:}"
        pane_cmd_map[$ptask]="$pane_cmd"
      fi
    done < <(tmux list-panes -s -t "=$session" -F '#{pane_id}|#{pane_title}|#{pane_current_command}' 2>/dev/null)
  fi

  # Count active agents and determine state for each task
  # Note: "status" is a read-only variable in zsh, so we use "state" instead
  local active_count=0
  local total_count=${#tasks[@]}
  local cli_name
  cli_name="$(basename "${AGENT_CLI%% *}")"

  declare -A task_state_map
  task_state_map=()
  local task state
  for task in "${tasks[@]}"; do
    state="stopped"
    if [[ -n "${pane_cmd_map[$task]+x}" ]]; then
      if [[ "${pane_cmd_map[$task]}" == "$cli_name" ]]; then
        state="active"
        (( active_count++ ))
      else
        state="idle"
      fi
    fi
    task_state_map[$task]="$state"
  done

  # Print header
  printf '\n  %b%s%b  (%d agents, %d active)\n\n' \
    "$__AG_BOLD" "$repo" "$__AG_RESET" \
    "$total_count" "$active_count"

  # Print column headers
  printf '  %-14s %-14s %-24s %s\n' "TASK" "STATUS" "BRANCH" "WORKTREE"

  # Print each agent row
  # Note: declare loop variables ONCE before the loop. In zsh, re-declaring
  # local inside a loop can leak output on subsequent iterations.
  local branch wt_path state_display rel_wt
  # Compute the repo parent once (not per-iteration) for relative paths
  local repo_parent
  repo_parent="$(dirname "$(__ag_repo_root)")"
  for task in "${tasks[@]}"; do
    state="${task_state_map[$task]}"
    branch="$(__ag_branch_name "$task")"
    wt_path="$(__ag_worktree_path "$task")"

    # Make worktree path relative for readability
    rel_wt="..${wt_path#$repo_parent}"

    # Format state with color and bullet
    case "$state" in
      active)
        state_display="${__AG_GREEN}● active${__AG_RESET}"
        ;;
      idle)
        state_display="${__AG_YELLOW}● idle${__AG_RESET}"
        ;;
      stopped)
        state_display="${__AG_DIM}○ stopped${__AG_RESET}"
        ;;
    esac

    # Print the row
    # Note: the state field uses %b for color codes, others use %s
    printf '  %-14s %b%-6s  %-24s %s\n' \
      "$task" "$state_display" "" "$branch" "$rel_wt"
  done

  printf '\n'
}

# ----------------------------------------------------------------------------
# __ag_cmd_attach -- Attach to this repo's tmux session
# ----------------------------------------------------------------------------
# Simple convenience wrapper. If the session doesn't exist, suggests
# spawning an agent first.
#
# Usage:
#   ag attach
# ----------------------------------------------------------------------------
__ag_cmd_attach() {
  __ag_require_git || return 1
  __ag_require_tmux || return 1

  local session
  session="$(__ag_session_name)"

  if ! __ag_session_exists; then
    __ag_err "No tmux session '$session' found. Use 'ag spawn <task>' to start."
    return 1
  fi

  if [[ -n "${TMUX:-}" ]]; then
    # Already inside tmux -- switch to the session instead of attaching
    __ag_log "Switching to session '$session'"
    tmux switch-client -t "=$session"
  else
    __ag_log "Attaching to session '$session'"
    tmux attach -t "=$session"
  fi
}

# ----------------------------------------------------------------------------
# __ag_cmd_resume -- Respawn windows for worktrees that don't have them
# ----------------------------------------------------------------------------
# Scans for agent worktrees whose tasks don't have a running tmux window,
# and creates a new window (claude + shell) for each one. This is how you
# rebuild the tmux UI after a reboot or tmux crash.
#
# Usage:
#   ag resume              Respawn all stopped agents
#   ag resume auth api     Respawn specific agents
# ----------------------------------------------------------------------------
__ag_cmd_resume() {
  __ag_require_git || return 1
  __ag_require_tmux || return 1

  # -- Parse arguments --
  local -a tasks
  tasks=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*)
        __ag_err "Unknown flag: $1"
        return 1
        ;;
      *)
        tasks+=("$1")
        shift
        ;;
    esac
  done

  # If no tasks specified, find all agent worktrees
  if [[ ${#tasks[@]} -eq 0 ]]; then
    __ag_log "Scanning for stopped agent worktrees..."
    while IFS= read -r t; do
      [[ -n "$t" ]] && tasks+=("$t")
    done < <(__ag_list_agent_worktrees)

    if [[ ${#tasks[@]} -eq 0 ]]; then
      __ag_log "No agent worktrees found. Use 'ag spawn <task>' to create one."
      return 0
    fi
  fi

  # Spawn windows for tasks that don't already have one
  local resumed=0
  for task in "${tasks[@]}"; do
    # Validate the worktree exists
    if ! __ag_worktree_exists "$task"; then
      __ag_warn "No worktree for '$task', skipping. Use 'ag spawn $task' to create one."
      continue
    fi

    # Skip if already has a window
    local existing_window
    existing_window="$(__ag_window_for_task "$task")"
    if [[ -n "$existing_window" ]]; then
      __ag_log "Agent '$task' already has a window, skipping."
      continue
    fi

    __ag_spawn_task_window "$task"
    (( resumed++ ))
  done

  if [[ $resumed -eq 0 ]]; then
    __ag_log "Nothing to resume (all agents already have windows or no worktrees found)."
  else
    __ag_log "Resumed $resumed agent(s)."
  fi

  # If outside tmux, attach to the session
  if [[ -z "${TMUX:-}" ]]; then
    local session
    session="$(__ag_session_name)"
    if __ag_session_exists; then
      tmux attach -t "=$session"
    fi
  fi
}

# ----------------------------------------------------------------------------
# __ag_cmd_shell -- Open a shell-only window for a task's worktree
# ----------------------------------------------------------------------------
# Creates a tmux window with a single shell pane in the task's worktree.
# No claude is started. Useful for inspecting what an agent has done,
# running tests, or manual edits.
#
# If the task already has a window (from ag spawn), this switches to it
# and selects the shell pane.
#
# Usage:
#   ag shell <task>
# ----------------------------------------------------------------------------
__ag_cmd_shell() {
  __ag_require_git || return 1
  __ag_require_tmux || return 1

  local task="${1:-}"
  if [[ -z "$task" ]]; then
    __ag_err "Usage: ag shell <task>"
    return 1
  fi

  # Ensure the worktree exists (creates it if needed)
  __ag_ensure_worktree "$task" || return 1

  local session wt_path dir_name
  session="$(__ag_session_name)"
  wt_path="$(__ag_worktree_path "$task")"
  dir_name="$(__ag_task_to_dirname "$task")"

  # If the task already has a window, switch to it and focus the shell pane
  local existing_window
  existing_window="$(__ag_window_for_task "$task")"
  if [[ -n "$existing_window" ]]; then
    __ag_log "Window for '$task' already exists. Focusing shell pane."
    tmux select-window -t "$existing_window" 2>/dev/null || true

    # Find and select the shell pane (title: shell:<task>)
    local pane_id title
    while IFS='|' read -r pane_id title; do
      if [[ "$title" == "shell:${task}" ]]; then
        tmux select-pane -t "$pane_id" 2>/dev/null || true
        break
      fi
    done < <(tmux list-panes -t "$existing_window" -F '#{pane_id}|#{pane_title}' 2>/dev/null)

    # Attach if outside tmux
    if [[ -z "${TMUX:-}" ]]; then
      tmux attach -t "=$session"
    fi
    return 0
  fi

  # No existing window -- create a shell-only window
  if ! __ag_session_exists; then
    __ag_log "Creating tmux session '$session' with shell window '$dir_name'"
    tmux new-session -d -s "$session" -n "$dir_name" -c "$wt_path" 2>/dev/null || {
      __ag_err "Failed to create tmux session"
      return 1
    }
  else
    tmux new-window -t "=$session:" -n "$dir_name" -c "$wt_path" 2>/dev/null || {
      __ag_err "Failed to create window '$dir_name'"
      return 1
    }
  fi

  # Set the pane title so ag ls can track it
  # We use "agent:<task>" even for shell-only so status detection works
  # (it will show as "idle" since no claude is running)
  local pane_id
  pane_id="$(tmux list-panes -t "=${session}:${dir_name}" -F '#{pane_id}' 2>/dev/null | head -1)"
  tmux select-pane -t "$pane_id" -T "agent:${task}"

  __ag_log "Opened shell for '$task' in $wt_path"

  # Attach if outside tmux
  if [[ -z "${TMUX:-}" ]]; then
    tmux attach -t "=$session"
  fi
}

# ----------------------------------------------------------------------------
# __ag_cmd_cd -- cd into a task's worktree in the current shell
# ----------------------------------------------------------------------------
# Switches your current shell's working directory into the task's worktree.
# Does NOT open tmux or start claude. Useful for quick inspection, running
# tests, or manual git operations.
#
# Usage:
#   ag cd <task>
# ----------------------------------------------------------------------------
__ag_cmd_cd() {
  __ag_require_git || return 1

  local task="${1:-}"
  if [[ -z "$task" ]]; then
    __ag_err "Usage: ag cd <task>"
    return 1
  fi

  if ! __ag_worktree_exists "$task"; then
    __ag_err "No worktree found for '$task'. Use 'ag spawn $task' to create one."
    return 1
  fi

  local wt_path
  wt_path="$(__ag_worktree_path "$task")"

  __ag_log "cd -> $wt_path"
  cd "$wt_path" || {
    __ag_err "Could not cd to $wt_path"
    return 1
  }
}

# ----------------------------------------------------------------------------
# __ag_cmd_push -- Push a task's branch to the remote
# ----------------------------------------------------------------------------
# Pushes the agent/<task> branch to origin. Sets upstream on first push.
# Useful before creating a PR.
#
# Usage:
#   ag push <task>
# ----------------------------------------------------------------------------
__ag_cmd_push() {
  __ag_require_git || return 1

  local task="${1:-}"
  if [[ -z "$task" ]]; then
    __ag_err "Usage: ag push <task>"
    return 1
  fi

  local root branch
  root="$(__ag_repo_root)"
  branch="$(__ag_branch_name "$task")"

  if ! __ag_branch_exists "$branch"; then
    __ag_err "Branch '$branch' does not exist."
    return 1
  fi

  __ag_log "Pushing '$branch' to origin..."
  git -C "$root" push -u origin "$branch" || {
    __ag_err "Failed to push '$branch'"
    return 1
  }

  __ag_log "Pushed '$branch' to origin."
}

# ----------------------------------------------------------------------------
# __ag_cmd_diff -- Show diff of a task branch vs its base
# ----------------------------------------------------------------------------
# Shows what the agent has changed compared to the base branch (main/master).
# Runs git diff from the repo root so it works from anywhere.
#
# Usage:
#   ag diff <task>          Show full diff
#   ag diff <task> --stat   Show diffstat summary only
# ----------------------------------------------------------------------------
__ag_cmd_diff() {
  __ag_require_git || return 1

  local task=""
  local stat_flag=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stat|-s)
        stat_flag="--stat"
        shift
        ;;
      -*)
        __ag_err "Unknown flag: $1"
        return 1
        ;;
      *)
        task="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$task" ]]; then
    __ag_err "Usage: ag diff <task> [--stat]"
    return 1
  fi

  local root branch base
  root="$(__ag_repo_root)"
  branch="$(__ag_branch_name "$task")"
  base="$(__ag_default_base)"

  if ! __ag_branch_exists "$branch"; then
    __ag_err "Branch '$branch' does not exist."
    return 1
  fi

  # Use three-dot diff to show changes since the branch diverged
  if [[ -n "$stat_flag" ]]; then
    git -C "$root" diff "$stat_flag" "${base}...${branch}"
  else
    git -C "$root" diff "${base}...${branch}"
  fi
}

# ----------------------------------------------------------------------------
# __ag_cmd_layout -- Re-layout panes in task windows
# ----------------------------------------------------------------------------
# Apply a layout to the current task window. With the per-task window
# model, each window has two panes (claude + shell).
#
# Usage:
#   ag layout                          (uses default: main-horizontal)
#   ag layout horizontal               (maps to main-horizontal)
#   ag layout vertical                 (maps to main-vertical)
#   ag layout even-horizontal          (even side-by-side split)
#   ag layout even-vertical            (even top-bottom split)
# ----------------------------------------------------------------------------
__ag_cmd_layout() {
  __ag_require_git || return 1
  __ag_require_tmux || return 1

  local layout="${1:-$AGENT_DEFAULT_LAYOUT}"

  # Map friendly names to tmux layout names
  case "$layout" in
    horizontal|h) layout="main-horizontal" ;;
    vertical|v)   layout="main-vertical" ;;
    even-h)       layout="even-horizontal" ;;
    even-v)       layout="even-vertical" ;;
    tiled|t)      layout="tiled" ;;
    # Pass through any other value (e.g., main-horizontal, even-vertical)
  esac

  __ag_apply_layout "$layout"
  __ag_log "Applied layout: $layout"
}

# ----------------------------------------------------------------------------
# __ag_cmd_help -- Show command reference
# ----------------------------------------------------------------------------
__ag_cmd_help() {
  cat <<EOF

  ${__AG_BOLD}ag${__AG_RESET} -- Agentic Development Environment

  ${__AG_BOLD}Commands:${__AG_RESET}

    ${__AG_CYAN}ag${__AG_RESET}                                  Show agent status (same as ag ls)
    ${__AG_CYAN}ag spawn${__AG_RESET} <task> [--prompt "..."]    Create worktree + branch + window, start claude
    ${__AG_CYAN}ag spawn${__AG_RESET} <t1> <t2> <t3>            Spawn multiple agents at once
    ${__AG_CYAN}ag kill${__AG_RESET} <t1> [t2 ...] [-f]          Kill window(s), keep worktree + branch
    ${__AG_CYAN}ag rm${__AG_RESET} <t1> [t2 ...] [-f]            Kill + remove worktree + delete branch
    ${__AG_CYAN}ag ls${__AG_RESET}                               List agents with status
    ${__AG_CYAN}ag cd${__AG_RESET} <task>                        cd into a task's worktree
    ${__AG_CYAN}ag push${__AG_RESET} <task>                      Push task branch to origin
    ${__AG_CYAN}ag diff${__AG_RESET} <task> [--stat]             Diff task branch vs base branch
    ${__AG_CYAN}ag attach${__AG_RESET}                           Attach to this repo's tmux session
    ${__AG_CYAN}ag resume${__AG_RESET} [task ...]                Respawn windows for stopped worktrees
    ${__AG_CYAN}ag shell${__AG_RESET} <task>                     Open a shell-only window in a worktree
    ${__AG_CYAN}ag layout${__AG_RESET} [h|v|even-h|even-v]      Change pane layout in current window
    ${__AG_CYAN}ag help${__AG_RESET}                             Show this reference

  ${__AG_BOLD}Window layout:${__AG_RESET}

    Each task gets its own tmux window with two panes:
    ┌──────────────────────────┐
    │     claude (top)         │
    ├──────────────────────────┤
    │     shell (bottom)       │
    └──────────────────────────┘

  ${__AG_BOLD}Lifecycle:${__AG_RESET}

    spawn  ->  agent works  ->  push + PR  ->  rm (cleanup)
                  |                               |
                kill (pause)              ag rm --force
                  |
               resume (restart)

  ${__AG_BOLD}Config:${__AG_RESET}

    AGENT_CLI              Command to run (default: "claude")
    AGENT_WORKTREE_PARENT  Override worktree location
    AGENT_BRANCH_PREFIX    Branch namespace (default: "agent")
    AGENT_DEFAULT_LAYOUT   Window layout (default: "main-horizontal")
    AGENT_IGNORE_BRANCHES  Branches to skip in ag ls when prefix is empty

  ${__AG_BOLD}tmux tips:${__AG_RESET}  (prefix is ctrl-b by default)

    <prefix> z      Toggle zoom on current pane (full screen / restore)
    <prefix> d      Detach from session (agents keep running)
    <prefix> w      Window picker (switch between tasks)
    <prefix> n/p    Next / previous window
    <prefix> arrows Navigate between panes within a window

EOF
}


# ============================================================================
# SECTION 6: Main Dispatch
# ============================================================================
# The `ag` function is the single entry point. It routes to subcommands.
# ============================================================================

# ----------------------------------------------------------------------------
# ag -- Main command dispatcher
# ----------------------------------------------------------------------------
# Usage:
#   ag <subcommand> [args...]
#
# If no subcommand is given, defaults to `ag ls`.
# Unknown subcommands show an error and suggest 'ag help'.
# ----------------------------------------------------------------------------
ag() {
  # Clear per-invocation cache so stale values don't persist
  __ag_cache_clear

  local cmd="${1:-ls}"
  shift 2>/dev/null || true

  case "$cmd" in
    spawn)    __ag_cmd_spawn "$@" ;;
    kill)     __ag_cmd_kill "$@" ;;
    rm)       __ag_cmd_rm "$@" ;;
    ls)       __ag_cmd_ls "$@" ;;
    cd)       __ag_cmd_cd "$@" ;;
    push)     __ag_cmd_push "$@" ;;
    diff)     __ag_cmd_diff "$@" ;;
    attach)   __ag_cmd_attach "$@" ;;
    resume)   __ag_cmd_resume "$@" ;;
    shell)    __ag_cmd_shell "$@" ;;
    layout)   __ag_cmd_layout "$@" ;;
    help)     __ag_cmd_help ;;
    *)
      __ag_err "Unknown command: $cmd"
      __ag_log "Run 'ag help' for available commands."
      return 1
      ;;
  esac
}


# ============================================================================
# SECTION 7: Tab Completion (bash 4+ and zsh 5+)
# ============================================================================
# Provides intelligent tab completion for the `ag` command.
#
#   ag <tab>             -> completes subcommands
#   ag spawn <tab>       -> no completion (you type a new task name)
#   ag kill <tab>        -> completes task names that have worktrees
#   ag rm <tab>          -> completes task names that have worktrees
#   ag resume <tab>      -> completes task names that have worktrees
#   ag cd <tab>          -> completes task names that have worktrees
#   ag push <tab>        -> completes task names that have worktrees
#   ag diff <tab>        -> completes task names that have worktrees
#   ag shell <tab>       -> completes task names that have worktrees
#   ag layout <tab>      -> completes layout options
#
# Detects the current shell and registers the appropriate completion.
# ============================================================================

# -- Subcommand list (shared by both bash and zsh completions) --
__AG_SUBCOMMANDS="spawn kill rm ls cd push diff attach resume shell layout help"

if [[ -n "${ZSH_VERSION:-}" ]]; then
  # ---- Zsh completion ----
  _ag() {
    local -a subcommands layouts

    subcommands=(
      'spawn:Create worktree + branch + window, start claude'
      'kill:Kill window, keep worktree + branch (pause)'
      'rm:Kill window + remove worktree + delete branch'
      'ls:List agents with status'
      'cd:cd into a task worktree'
      'push:Push task branch to remote'
      'diff:Show diff of task branch vs base'
      'attach:Attach to tmux session'
      'resume:Respawn windows for stopped worktrees'
      'shell:Open a shell-only window in a worktree'
      'layout:Change pane layout in current window'
      'help:Show command reference'
    )

    layouts=(
      'horizontal:Main pane on top, shell below'
      'vertical:Main pane on left, shell right'
      'even-h:Even side-by-side split'
      'even-v:Even top-bottom split'
      'tiled:Tiled layout'
    )

    # First argument: complete subcommands
    if (( CURRENT == 2 )); then
      _describe 'ag command' subcommands
      return
    fi

    # Second+ arguments: context-dependent completion
    local subcmd="${words[2]}"

    case "$subcmd" in
      kill|rm|resume|cd|push|diff|shell)
        # Complete with existing task names from worktrees
        if git rev-parse --show-toplevel >/dev/null 2>&1; then
          local -a task_list
          task_list=()
          local t
          while IFS= read -r t; do
            [[ -n "$t" ]] && task_list+=("$t")
          done < <(__ag_list_agent_worktrees 2>/dev/null)
          _describe 'task' task_list
        fi
        ;;
      layout)
        _describe 'layout' layouts
        ;;
      spawn)
        _arguments '*: :' '--prompt[Initial prompt for claude]:prompt text:' '-p[Initial prompt for claude]:prompt text:'
        ;;
    esac
  }
  # Register completion. If compinit hasn't run yet (common when ag.sh is
  # sourced early in .zshrc -> .bash_profile chain), defer registration
  # until the precmd hook, which fires after all init files have loaded.
  if type compdef >/dev/null 2>&1; then
    compdef _ag ag
  else
    __ag_deferred_compdef() {
      if type compdef >/dev/null 2>&1; then
        compdef _ag ag
        # Remove this hook after it fires once
        add-zsh-hook -d precmd __ag_deferred_compdef
        unfunction __ag_deferred_compdef 2>/dev/null
      fi
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd __ag_deferred_compdef
  fi

elif [[ -n "${BASH_VERSION:-}" ]]; then
  # ---- Bash completion ----
  _ag_bash() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # First argument: complete subcommands
    if [[ $COMP_CWORD -eq 1 ]]; then
      COMPREPLY=($(compgen -W "$__AG_SUBCOMMANDS" -- "$cur"))
      return
    fi

    # Second+ arguments: context-dependent
    local subcmd="${COMP_WORDS[1]}"

    case "$subcmd" in
      kill|rm|resume|cd|push|diff|shell)
        # Complete with existing task names from worktrees
        if git rev-parse --show-toplevel >/dev/null 2>&1; then
          local task_names
          task_names="$(__ag_list_agent_worktrees 2>/dev/null | tr '\n' ' ')"
          COMPREPLY=($(compgen -W "$task_names" -- "$cur"))
        fi
        ;;
      layout)
        COMPREPLY=($(compgen -W "horizontal vertical even-h even-v tiled" -- "$cur"))
        ;;
      spawn)
        # Complete flags only
        if [[ "$cur" == -* ]]; then
          COMPREPLY=($(compgen -W "--prompt -p" -- "$cur"))
        fi
        ;;
    esac
  }
  complete -F _ag_bash ag
fi
