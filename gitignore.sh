#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: gitign [--auto-commit | --no-auto-commit] [--delete_local] <pattern> [pattern...]

Add Git ignore patterns relative to the directory where this command is run,
then stop tracking matching files. Local files stay in place unless
--delete_local is provided. Changes are committed by default.

Options:
  --auto-commit     Commit gitign's changes (default).
  --no-auto-commit  Leave gitign's changes for review and manual commit.
  --delete_local    Delete matching local files and directories after ignoring them.
  --help            Show this help.
  --version         Show the version of gitign.

Presets:
  dsstore    Ignore .DS_Store in this directory and all of its subdirectories.
  nodemodules Ignore node_modules directories in this directory and all subdirectories.
EOF
}
VERSION_STRING="will-be-overrided"
version() {
    printf 'gitign version %s\n' "$VERSION_STRING"
}

delete_local_matches() {
    local pattern="$1"
    local delete_paths=()
    local source=""
    local line_number=""
    local matched_pattern=""
    local path=""

    while IFS= read -r -d '' source \
        && IFS= read -r -d '' line_number \
        && IFS= read -r -d '' matched_pattern \
        && IFS= read -r -d '' path; do
        if [[ "$source" == ".gitignore" && "$matched_pattern" == "$pattern" && "$path" != "./.gitignore" ]]; then
            delete_paths+=("$path")
        fi
    done < <((find . -mindepth 1 -path './.git' -prune -o -print0 \
        | git check-ignore -z -v --stdin --no-index) || true)

    if ((${#delete_paths[@]})); then
        rm -rf -- "${delete_paths[@]}"
    fi
}

auto_commit=true
delete_local=false
patterns=()

for argument in "$@"; do
    case "$argument" in
        --version)
            version
            exit 0
            ;;
        --auto-commit)
            auto_commit=true
            ;;
        --no-auto-commit)
            auto_commit=false
            ;;
        --delete_local)
            delete_local=true
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            patterns+=("$argument")
            ;;
    esac
done

if ((${#patterns[@]} == 0)); then
    usage >&2
    exit 2
fi

initial_directory="$(pwd -P)"

if [[ "$(git -C "$initial_directory" rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]]; then
    printf 'No Git repository found. Enter a repository path, or type init to initialize one in %s: ' \
        "$initial_directory" >&2
    if ! IFS= read -r repository_choice; then
        printf 'gitign: no repository choice received.\n' >&2
        exit 1
    fi

    if [[ "$repository_choice" == "init" ]]; then
        git -C "$initial_directory" init
    elif [[ -n "$repository_choice" ]]; then
        if [[ "$(git -C "$repository_choice" rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]]; then
            printf 'gitign: "%s" is not a Git working tree.\n' "$repository_choice" >&2
            exit 1
        fi
    else
        printf 'gitign: a repository path or init is required.\n' >&2
        exit 1
    fi
fi

if [[ "$(git -C "$initial_directory" rev-parse --is-inside-work-tree 2>/dev/null || true)" == "true" ]]; then
    repo_root="$(git -C "$initial_directory" rev-parse --show-toplevel)"
    called_from="$(git -C "$initial_directory" rev-parse --show-prefix)"
else
    repo_root="$(git -C "$repository_choice" rev-parse --show-toplevel)"
    called_from=""
fi
called_from="${called_from%/}"
cd "$repo_root"

if "$auto_commit" && ! git diff --cached --quiet; then
    printf 'gitign: the staging area already has changes; use --no-auto-commit or commit them first.\n' >&2
    exit 1
fi

if [[ ! -e .gitignore ]]; then
    printf 'No .gitignore found. Enter a path inside this repository, or type init to create %s/.gitignore: ' \
        "$repo_root" >&2
    if ! IFS= read -r ignore_choice; then
        printf 'gitign: no .gitignore choice received.\n' >&2
        exit 1
    fi

    if [[ "$ignore_choice" == "init" ]]; then
        : > .gitignore
    elif [[ -n "$ignore_choice" ]]; then
        ignore_root="$(git -C "$ignore_choice" rev-parse --show-toplevel 2>/dev/null || true)"
        if [[ "$ignore_root" != "$repo_root" ]]; then
            printf 'gitign: "%s" is not inside this Git repository.\n' "$ignore_choice" >&2
            exit 1
        fi
        : > .gitignore
    else
        printf 'gitign: a repository path or init is required.\n' >&2
        exit 1
    fi
fi

affected_paths=()

for argument in "${patterns[@]}"; do
    if [[ -z "$argument" || "$argument" == *$'\n'* || "$argument" == \!* || "$argument" == \#* ]]; then
        printf 'gitign: "%s" is not an ignore pattern that adds files.\n' "$argument" >&2
        exit 2
    fi

    case "$argument" in
        dsstore)
            pattern="**/.DS_Store"
            ;;
        nodemodules)
            pattern="**/node_modules/"
            ;;
        *)
            pattern="$argument"
            ;;
    esac

    # A leading slash deliberately makes a pattern relative to the repository root.
    if [[ "$pattern" != /* && -n "$called_from" ]]; then
        pattern="$called_from/$pattern"
    fi

    if [[ -f .gitignore ]] && grep -Fqx -- "$pattern" .gitignore; then
        printf 'Already ignored: %s\n' "$pattern"
    else
        printf '\n%s\n' "$pattern" >> .gitignore
        printf 'Added to .gitignore: %s\n' "$pattern"
    fi

    tracked_paths=()
    while IFS= read -r -d '' path; do
        tracked_paths+=("$path")
    done < <(git ls-files -ci -z --exclude="$pattern")

    if ((${#tracked_paths[@]})); then
        git rm --cached -r --ignore-unmatch -- "${tracked_paths[@]}"
        affected_paths+=("${tracked_paths[@]}")
    fi

    if "$delete_local"; then
        delete_local_matches "$pattern"
    fi
done

if "$auto_commit"; then
    git add .gitignore

    if ! git diff --cached --quiet -- .gitignore "${affected_paths[@]}"; then
        if ((${#patterns[@]} == 1)); then
            commit_message="gitign: ignore ${patterns[0]}"
        else
            commit_message="gitign: ignore ${#patterns[@]} patterns"
        fi
        git commit -m "$commit_message"
    fi
fi
