# gitign

`gitign` adds Git ignore patterns, removes matching files from Git tracking, optionally deletes those files locally, and commits those changes by default.

## Install

Requirements: Git, Bash, and Zsh. The installer puts the `gitign` command in `~/.local/bin` and adds that directory to `~/.zshrc`.

Clone the repository anywhere you can edit it:

```sh
git clone https://github.com/AlphaGo729/gitign.git ~/gitign
cd ~/gitign
bash compile-gitign.sh
source ~/.zshrc
```

Keeping the clone in `~/Library/Application Support/gitign` is recommended on macOS because it separates this user-level tool from project folders:

```sh
git clone https://github.com/AlphaGo729/gitign.git \
  "$HOME/Library/Application Support/gitign"
bash "$HOME/Library/Application Support/gitign/compile-gitign.sh"
source ~/.zshrc
```

The installer creates `~/.local/bin/gitign` as a standalone copied command. Re-run `bash compile-gitign.sh` after pulling updates in the clone to refresh the installed command.

## Use

Run `gitign` from any directory inside a Git working tree:

```sh
gitign dsstore
gitign nodemodules
gitign database.db
gitign '*/tmp.js'
gitign build/
gitign '**/*.log'
gitign --delete_local build/
```

Arguments are Git ignore patterns relative to the directory where you run `gitign`; each is written to the repository root's `.gitignore`. A leading `/` makes a pattern relative to the repository root.

| Command | Pattern added | Result |
| --- | --- | --- |
| `gitign dsstore` | `**/.DS_Store` | Ignores `.DS_Store` recursively. |
| `gitign nodemodules` | `**/node_modules/` | Ignores `node_modules` folders recursively. |
| `gitign cache/` | `cache/` | Ignores a directory and its contents. |
| `gitign '**/database.db'` | `**/database.db` | Ignores matching files recursively. |

Quote patterns containing `*`, `?`, `[`, or `!` so your shell passes the pattern to `gitign` instead of expanding it first.

Other commands:
```sh
gitign --version
gitign --help
```

## Local deletion

Pass `--delete_local` to remove matching local files and directories after they have been ignored:

```sh
gitign --delete_local build/
gitign --delete_local nodemodules
gitign --delete_local '**/*.log'
```

By default, `gitign` keeps your local files. `--delete_local` is opt-in because it permanently removes matching local content from the working tree.

## Automatic commits

`gitign` commits its `.gitignore` and matching untracking changes by default:

```sh
gitign database.db
# Creates: gitign: ignore database.db
```

Use `--no-auto-commit` to leave changes for review and manual staging:

```sh
gitign --no-auto-commit database.db
git status
git add .gitignore
git add -u
git commit -m "Ignore database"
```

`--auto-commit` explicitly enables the default behavior. When auto-commit is enabled, `gitign` refuses to run if the staging area already has changes, preventing it from committing unrelated staged edits.

## Missing repository or `.gitignore`

Outside a repository, `gitign` prompts for the path to an existing Git working tree or for `init`, which runs `git init` in the current directory.

If that repository has no root `.gitignore`, it prompts for a path inside the repository or for `init`, which creates the file at the repository root.

## How it works

1. Git resolves the working tree, repository root, and relative directory where the command was called.
2. Presets expand into normal Git ignore patterns, and duplicate patterns are not appended.
3. `git ls-files -ci --exclude=<pattern>` finds tracked files that now match.
4. If `--delete_local` is given, `gitign` deletes matching local files and directories after they become ignored.
5. `git rm --cached` removes tracked matches from Git's index.
6. Unless `--no-auto-commit` is given, Git commits the `.gitignore` update and the files that `gitign` untracked. It first requires a clean staging area, so no unrelated staged changes are included.

Without `--delete_local`, the files remain on your computer throughout this process.
