# gitign

Latest version: <!-- VERSION -->v1.1.1

`gitign` adds Git ignore rules, stops tracking matching files, and optionally deletes, trashes, or backs up local matches. It previews every resolved pattern before changing anything and automatically commits repository changes by default.

## Install

Requirements: Git and Bash. The installer supports Zsh, Bash, and Fish.

Gitign runs on macOS and Linux, plus Windows through Git Bash or WSL. The `--trash` adapter uses each platform's native trash location:

| Platform | `--trash` destination |
| --- | --- |
| macOS | User Trash (`~/.Trash`) |
| Linux and WSL | FreeDesktop Trash (`$XDG_DATA_HOME/Trash`, or `~/.local/share/Trash`) |
| Windows Git Bash | Windows Recycle Bin through PowerShell |

On Linux, gitign uses a same-filesystem FreeDesktop Trash directory when the source is on a different mounted volume. WSL uses the Linux Trash adapter because Windows Recycle Bin APIs cannot recycle its UNC filesystem paths. On unsupported Bash environments, or when Git Bash cannot find Windows PowerShell, `--trash` stops with a clear error. Use `--backup-dir` for a portable recoverable alternative.

All remaining Gitign commands use Git plus standard Bash/POSIX utilities and work across these supported environments. Shell scripts are checked out with LF line endings, including under Git Bash with `core.autocrlf=true`.

Clone into any editable directory:

```sh
git clone https://github.com/shlok-k720/gitign.git ~/gitign
cd ~/gitign
bash compile-gitign.sh
```

On macOS, cloning into `~/Library/Application Support/gitign` is recommended because it keeps a user-level tool separate from project folders:

```sh
git clone https://github.com/shlok-k720/gitign.git \
  "$HOME/Library/Application Support/gitign"
bash "$HOME/Library/Application Support/gitign/compile-gitign.sh"
```

Restart the selected shell, or source its startup file. The installer detects `$SHELL` automatically; pass `--shell zsh`, `--shell bash`, or `--shell fish` to override it.

```sh
source ~/.zshrc
gitign --version
```

The installed command is `~/.local/bin/gitign`. It is a version-injected copy of `gitignore.sh`; after pulling repository updates, rerun the installer:

```sh
cd ~/gitign
git pull
bash compile-gitign.sh --reinstall
```

Installer lifecycle commands:

```sh
bash compile-gitign.sh --print-install-path
bash compile-gitign.sh --reinstall
bash compile-gitign.sh --uninstall
```

## Quick start

Run `gitign` from any directory inside a Git working tree:

```sh
gitign nodemodules
gitign dsstore
gitign database.db
gitign '*/tmp.js'
gitign build/
```

`gitign` shows the resolved ignore pattern and the number of tracked/local matches before it applies an action. Patterns are relative to the directory where the command is run. Prefix a pattern with `/` to make it relative to the repository root.

Quote patterns containing `*`, `?`, `[`, or `!` so the shell passes them to `gitign` unchanged.

## Options

| Option | Default | Behavior |
| --- | --- | --- |
| `--no-auto-commit` | disabled | Leave the ignore and untracking changes for review. |
| `--commit-message TEXT` | generated | Use `TEXT` for the automatic commit. |
| `--delete_local` | disabled | Permanently delete precisely matched local files/directories. |
| `--trash` | disabled | Move matches to the native operating system Trash. |
| `--backup-dir DIR` | disabled | Move matches into `DIR`, preserving their relative paths. |
| `--dry-run` | disabled | Show the plan without changing files, Git config, or commits. |
| `--undo` | n/a | Undo the latest recorded gitign action when it is safe. |
| `--init` | n/a | Create a default `.gitignrc` in the current directory. |
| `--recursive-filenames` | disabled | Turn a bare filename such as `database.db` into `**/database.db`. |
| `--global` | disabled | Add rules to Git's global ignore file rather than repository `.gitignore`. |
| `--verbose` | disabled | List every planned match. |
| `--quiet` | disabled | Suppress normal output; errors still print. |
| `--yes` | disabled | Skip interactive confirmations. |
| `--help`, `--version` | n/a | Display usage or installed version. |

Both `--delete_local` and `--delete-local` are accepted.

On Windows Git Bash and WSL, `--backup-dir` accepts either a POSIX path or a drive-letter path such as `C:\Users\you\gitign-backups`; gitign converts the latter before moving files.

## Presets

| Preset | Ignore pattern |
| --- | --- |
| `dsstore` | `**/.DS_Store` |
| `nodemodules` | `**/node_modules/` |
| `env` | `**/.env` |
| `logs` | `**/*.log` |
| `coverage` | `coverage/` |
| `dist` | `dist/` |
| `vscode` | `.vscode/` |
| `idea` | `.idea/` |
| `pythoncache` | `**/__pycache__/` |

For example:

```sh
gitign nodemodules env
gitign --recursive-filenames database.db
gitign --global dsstore
```

## Safety, local files, and commits

`gitign` appends a pattern only when that exact pattern is not already present. It uses Git's ignore matcher after adding the rule, so local deletion handles only paths matched by the requested rule, not files that merely overlap an older ignore rule.

| Mode | Git ignore rule | Git tracking | Local file |
| --- | --- | --- | --- |
| `gitign build/` | added | matching tracked files are untracked | kept |
| `gitign --delete_local build/` | added | matching tracked files are untracked | permanently deleted |
| `gitign --trash build/` | added | matching tracked files are untracked | moved to the native operating system Trash |
| `gitign --backup-dir ../backups build/` | added | matching tracked files are untracked | moved to a recoverable backup |

Examples:

```sh
# Preview first: no changes are made.
gitign --dry-run --verbose --delete_local build/

# Remove the local build output permanently.
gitign --delete_local build/

# Safer alternatives.
gitign --trash nodemodules
gitign --backup-dir ../gitign-backups '**/*.log'
```

Local handling is opt-in; normal `gitign` commands never remove local files. `--trash` detects macOS, FreeDesktop Linux/WSL, and Windows Git Bash automatically. `--backup-dir` works on every Gitign-supported Bash environment and is the only deletion mode whose untracked files can be restored by `--undo`.

When standard input is a terminal, gitign asks before local deletion/trash/backup and before automatic commits for broad operations (multiple or glob patterns). In non-interactive shells and CI, it proceeds automatically; use `--dry-run` to preview scripts, or `--yes` to make approval explicit.

Automatic commits require a clean staging area, so gitign never captures unrelated staged work. Its generated message is `gitign: ignore PATTERN` for one pattern or `gitign: ignore N patterns` for multiple patterns. Use `--commit-message` to override it:

```sh
gitign --commit-message "Ignore generated assets" dist/
gitign --no-auto-commit --delete_local build/
git status
```

If no ignore rule, index entry, or local path changes, gitign explicitly reports that no commit was created.

## Undo

`gitign --undo` reverses the latest action recorded for the current repository:

```sh
gitign --backup-dir ../gitign-backups '*.log'
gitign --undo
```

For an automatic commit, undo creates a Git revert and only runs when the gitign commit is still `HEAD`. For a non-committed action, it removes the rule it added and restores affected index entries. Backup-mode local files are moved back when their original path is free. Permanently deleted and trashed files cannot be restored automatically.

Use `gitign --dry-run --undo` to preview the undo plan.

## Repository configuration

Run `gitign --init` in the directory where you want a complete default `.gitignrc`:

```ini
gitign --init
```

It creates:

```ini
# gitign configuration
# Command-line options override these values.
auto_commit=true
delete_local=false
deletion_mode=keep
backup_dir=
recursive_filenames=false
global_ignore=false
confirm=true
verbose=false
quiet=false
commit_message=
```

`--init` never overwrites an existing `.gitignrc`; edit that file directly when you want to change defaults.

Gitign loads a `.gitignrc` in the current directory first, then falls back to the repository root. Command-line options override configuration; `--no-auto-commit` remains the opt-out because automatic commits are enabled by default.

Supported keys:

```ini
auto_commit=true|false
delete_local=true|false
deletion_mode=keep|delete|trash|backup
backup_dir=PATH
recursive_filenames=true|false
global_ignore=true|false
confirm=true|false
verbose=true|false
quiet=true|false
commit_message=TEXT
```

`--global` writes to the file configured by `git config --global core.excludesFile`. If no file is configured, gitign creates and configures `~/.config/git/ignore`.

## Missing setup

Outside a repository, gitign asks for an existing repository path or `init` to run `git init` in the current directory. If the repository has no `.gitignore`, it asks for a path inside the repository or `init` to create the root `.gitignore`.

## How it works

1. Resolves the Git repository and loads optional `.gitignrc` defaults.
2. Expands presets and optional recursive filename patterns.
3. Previews exact resolved rules plus tracked/local candidate counts.
4. Adds rules to repository or global ignore configuration.
5. Uses `git rm --cached` to remove matching tracked entries without deleting them by default.
6. When requested, uses Git's ignore matcher to precisely select local paths for deletion, backup, or OS-specific Trash handling.
7. Records the action under `.git/gitign/` for one-step undo.
8. Commits the staged repository changes only when auto-commit is enabled and the staging area was initially clean.

## Development and releases (only for developer)

Run the shell suite:

```sh
bash tests/test.sh
```

Set a semantic version consistently in `VERSION.txt` and `VERSION_STRING`:

```sh
scripts/release.sh 1.2.3
```

Create a version commit and annotated tag:

```sh
scripts/release.sh 1.2.3 --tag
git push origin main --tags
```
