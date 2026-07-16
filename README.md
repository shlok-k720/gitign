# gitign

`gitign` adds Git ignore patterns, removes matching files from Git tracking without deleting them locally, and commits those changes by default.

## Install

Requirements: Git, Bash, and Zsh. The installer puts the `gitign` command in `~/.local/bin` and adds that directory to `~/.zshrc`.

Clone the repository anywhere you can edit it:

```sh
git clone https://github.com/shlok-k720/gitign.git ~/gitign
cd ~/gitign
bash compile-gitign.sh
source ~/.zshrc
```

Keeping the clone in `~/Library/Application Support/gitign` is recommended on macOS because it separates this user-level tool from project folders:

```sh
git clone https://github.com/shlok-720/gitign.git \
  "$HOME/Library/Application Support/gitign"
bash "$HOME/Library/Application Support/gitign/compile-gitign.sh"
source ~/.zshrc
```

The installer creates `~/.local/bin/gitign` as a symlink to `gitignore.sh`, so pulling updates in the clone updates the command.

## Use

Run `gitign` from any directory inside a Git working tree:

```sh
gitign dsstore
gitign nodemodules
gitign database.db
gitign '*/tmp.js'
gitign build/
gitign '**/*.log'
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
4. `git rm --cached` removes those files only from Git's index.
5. Unless `--no-auto-commit` is given, Git commits the `.gitignore` update and the files that `gitign` untracked. It first requires a clean staging area, so no unrelated staged changes are included.

The files remain on your computer throughout this process.
