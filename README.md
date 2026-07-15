# Git Ignore from Command Line

`gitign` adds Git ignore patterns and removes matching files from Git's index without deleting the local files.

## To access the copilot chat for this:
type 
```sh
copilot --resume=2ecba402-8800-46f5-80a1-f1349f0bd7f0
``` 
in the terminal.

## Install

The editable source and installer are in:

```sh
~/Library/Application\ Support/gitign/
```

Run the installer once:

```sh
bash ~/Library/Application\ Support/gitign/compile-gitign.sh
source ~/.zshrc
```

The installer creates `~/.local/bin/gitign` and adds that directory to the `PATH` in `~/.zshrc`. Bash scripts are interpreted rather than compiled; this installer makes the editable source available as the `gitign` command.

## Use

Run the command from any directory inside the Git repository:

```sh
gitign dsstore
gitign nodemodules
gitign database.db
gitign '*/tmp.js'
gitign build/
gitign app/config/local.json
```

Each argument is a Git ignore pattern, interpreted relative to the directory where `gitign` was run. It is added to the repository root's `.gitignore`. A pattern starting with `/` is instead relative to the repository root.

`dsstore` is a preset for `**/.DS_Store`, so it ignores `.DS_Store` in the current directory and every directory below it.

`nodemodules` is a preset for `**/node_modules/`, so it ignores every `node_modules` folder in the current directory and every directory below it.

## Missing repository or `.gitignore`

If you run `gitign` outside a Git repository, it waits for input. Enter the path to an existing repository, or enter `init` to run `git init` in the directory where you ran `gitign`.

If the repository has no root `.gitignore`, it also waits for input. Enter any path inside that repository to create its root `.gitignore`, or enter `init` to create it there directly.

To ignore files with a name everywhere below the current directory, use `**/`:

```sh
gitign '**/database.db'
```

To ignore all content in a folder, use a trailing slash:

```sh
gitign cache/
```

Quote patterns that contain `*`, `?`, `[`, or `!` when you do not want Zsh to expand them before `gitign` receives them:

```sh
gitign '*/tmp.js'
gitign '**/*.log'
```

`gitign` changes `.gitignore` and runs `git rm --cached` for tracked files matching each new pattern. The files stay on your computer; stage and commit `.gitignore` plus the removals when ready.
