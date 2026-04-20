# Changelog

## v1.1

### Added

- Added repository-local `.agrc` prepare hooks. When a new task worktree is created, `ag spawn` runs an executable `.agrc` from that worktree before creating the tmux window.
- Added `AGENT_SHELL_HEIGHT_PERCENT` to configure how much vertical space the bottom shell region uses during spawn. The default remains `30`, preserving the original 70/30 agent/shell split.
- Added `AGENT_SHELL_PANES` to configure how many side-by-side shell panes are created below the agent pane. The default remains `1`.

### Changed

- Failed `.agrc` preparation now prevents tmux presentation and removes the unprepared worktree so retrying `ag spawn <task>` starts cleanly.
- `ag spawn` now creates one agent pane on top and a configurable shell pane region underneath.

## v1

### Added

- Initial `ag.sh` workflow for spawning isolated agent tasks in git worktrees.
- Per-repository tmux sessions with one task window per agent.
- Commands for spawning, listing, attaching, resuming, pausing, removing, opening, pushing, diffing, and changing task layouts.
- Bash and zsh tab completion for core commands and task names.
