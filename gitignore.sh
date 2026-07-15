#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: gitign <pattern> [pattern...]

Add Git ignore patterns relative to the directory where this command is run,
then stop tracking matching files without deleting them locally.

Presets:
  dsstore    Ignore .DS_Store in this directory and all of its subdirectories.
  nodemodules Ignore node_modules directories in this directory and all subdirectories.
EOF
}

if (($# == 0)); then
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

for argument in "$@"; do
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
    fi
done
