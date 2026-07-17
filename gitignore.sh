#!/usr/bin/env bash
set -eo pipefail

VERSION_STRING="1.1.2"

usage() {
    cat <<'EOF'
Usage:
  gitign [options] <pattern> [pattern...]
  gitign --init
  gitign --undo [--dry-run]

Add Git ignore patterns, untrack matching files, and optionally handle their
local copies. Patterns are relative to the directory where gitign is called.

Safety and commits:
  --no-auto-commit           Leave changes for review and manual commit.
  --commit-message MESSAGE   Use MESSAGE for the automatic commit.
  --delete_local             Permanently delete matching local files/directories.
  --trash                    Move matching local files/directories to the operating system Trash.
  --backup-dir DIRECTORY     Move matching local paths into DIRECTORY.
  --dry-run                  Preview all changes without modifying anything.
  --undo                     Reverse the most recent gitign action when possible.

Pattern and scope:
  --recursive-filenames      Treat bare filenames as recursive (file -> **/file).
  --global                   Write patterns to Git's global ignore file.

Output:
  --verbose                  Show every planned match and action.
  --quiet                    Suppress normal output.
  --yes                      Skip interactive confirmation prompts.
  --help                     Show this help.
  --init                     Create a default .gitignrc in the current directory.
  --version                  Show the installed version.

Presets:
  dsstore, nodemodules, env, logs, coverage, dist, vscode, idea, pythoncache

Examples:
  gitign nodemodules
  gitign --init
  gitign --recursive-filenames database.db
  gitign --no-auto-commit --delete_local build/
  gitign --backup-dir ../gitign-backups '**/*.log'
  gitign --dry-run --global env
EOF
}

initialize_config() {
    local destination="$initial_directory/.gitignrc"

    [[ ! -e "$destination" ]] || die "$destination already exists; it was not replaced."

    cat > "$destination" <<'EOF'
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
EOF

    success "Created default configuration: $destination"
}

color_enabled=false
quiet=false
verbose=false

initialize_color() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        color_enabled=true
    fi
}

format() {
    local color="$1"
    shift
    if "$color_enabled"; then
        printf '\033[%sm%s\033[0m' "$color" "$*"
    else
        printf '%s' "$*"
    fi
}

info() {
    "$quiet" || printf '%s\n' "$*"
}

success() {
    "$quiet" || printf '%s %s\n' "$(format '32' '✓')" "$*"
}

warning() {
    "$quiet" || printf '%s %s\n' "$(format '33' 'Warning:')" "$*" >&2
}

error() {
    printf '%s %s\n' "$(format '31' 'gitign:')" "$*" >&2
}

die() {
    error "$*"
    exit 1
}

version() {
    printf 'gitign version %s\n' "$VERSION_STRING"
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

is_boolean() {
    [[ "$1" == true || "$1" == false ]]
}

is_absolute_path() {
    [[ "$1" == /* || "$1" =~ ^[A-Za-z]:[\\/].* ]]
}

normalize_backup_directory() {
    local directory="$1"
    local converter=""

    if [[ "$directory" =~ ^[A-Za-z]:[\\/].* ]]; then
        for converter in cygpath wslpath; do
            if command -v "$converter" >/dev/null 2>&1; then
                "$converter" -u "$directory"
                return
            fi
        done
        die 'a Windows-style --backup-dir path requires cygpath or wslpath.'
    fi
    printf '%s' "$directory"
}

array_contains() {
    local needle="$1"
    shift
    local item=""
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

add_unique_affected_path() {
    local value="$1"
    if ! array_contains "$value" "${affected_paths[@]}"; then
        affected_paths+=("$value")
    fi
}

confirm() {
    local question="$1"
    local answer=""

    "$assume_yes" && return 0
    if [[ ! -t 0 ]]; then
        return 0
    fi

    printf '%s %s [y/N] ' "$(format '33' 'Confirm:')" "$question" >&2
    IFS= read -r answer
    [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]]
}

is_broad_pattern() {
    local pattern="$1"
    [[ "$pattern" == *'*'* || "$pattern" == *'?'* || "$pattern" == *'['* ]]
}

validate_pattern() {
    local pattern="$1"
    if [[ -z "$pattern" || "$pattern" == *$'\n'* || "$pattern" == \!* || "$pattern" == \#* ]]; then
        die "\"$pattern\" is not an ignore pattern that adds files."
    fi
}

expand_preset() {
    case "$1" in
        dsstore) printf '%s' '**/.DS_Store' ;;
        nodemodules) printf '%s' '**/node_modules/' ;;
        env) printf '%s' '**/.env' ;;
        logs) printf '%s' '**/*.log' ;;
        coverage) printf '%s' 'coverage/' ;;
        dist) printf '%s' 'dist/' ;;
        vscode) printf '%s' '.vscode/' ;;
        idea) printf '%s' '.idea/' ;;
        pythoncache) printf '%s' '**/__pycache__/' ;;
        *) printf '%s' "$1" ;;
    esac
}

canonical_path() {
    local path="$1"
    local directory=""
    directory="$(cd -P "$(dirname "$path")" && pwd)"
    printf '%s/%s' "$directory" "$(basename "$path")"
}

resolve_repository() {
    local selected_repository=""

    if [[ "$(git -C "$initial_directory" rev-parse --is-inside-work-tree 2>/dev/null || true)" == true ]]; then
        repo_root="$(git -C "$initial_directory" rev-parse --show-toplevel)"
        called_from="$(git -C "$initial_directory" rev-parse --show-prefix)"
    else
        printf 'No Git repository found. Enter a repository path, or type init to initialize one in %s: ' \
            "$initial_directory" >&2
        if ! IFS= read -r selected_repository; then
            die 'no repository choice received.'
        fi

        if [[ "$selected_repository" == init ]]; then
            "$dry_run" && die 'cannot initialize a repository during --dry-run.'
            git -C "$initial_directory" init
            repo_root="$initial_directory"
            called_from=""
        elif [[ -n "$selected_repository" ]] \
            && [[ "$(git -C "$selected_repository" rev-parse --is-inside-work-tree 2>/dev/null || true)" == true ]]; then
            repo_root="$(git -C "$selected_repository" rev-parse --show-toplevel)"
            called_from=""
        else
            die "\"$selected_repository\" is not a Git working tree."
        fi
    fi

    called_from="${called_from%/}"
    cd "$repo_root"
    git_directory="$(git rev-parse --git-dir)"
    if ! is_absolute_path "$git_directory"; then
        git_directory="$repo_root/$git_directory"
    fi
}

load_config() {
    local line=""
    local key=""
    local value=""

    config_file="$initial_directory/.gitignrc"
    if [[ ! -f "$config_file" && "$initial_directory" != "$repo_root" ]]; then
        config_file="$repo_root/.gitignrc"
    fi
    [[ -f "$config_file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] || die "$config_file contains an invalid setting: $line"
        key="$(trim "${line%%=*}")"
        value="$(trim "${line#*=}")"

        case "$key" in
            auto_commit|delete_local|recursive_filenames|global_ignore|confirm|verbose|quiet)
                is_boolean "$value" || die "$config_file: $key must be true or false."
                ;;
            deletion_mode)
                [[ "$value" == keep || "$value" == delete || "$value" == trash || "$value" == backup ]] \
                    || die "$config_file: deletion_mode must be keep, delete, trash, or backup."
                ;;
            backup_dir|commit_message)
                ;;
            *)
                die "$config_file contains an unknown setting: $key"
                ;;
        esac

        case "$key" in
            auto_commit) config_auto_commit="$value" ;;
            delete_local) config_delete_local="$value" ;;
            recursive_filenames) config_recursive_filenames="$value" ;;
            global_ignore) config_global_ignore="$value" ;;
            confirm) config_confirm="$value" ;;
            verbose) config_verbose="$value" ;;
            quiet) config_quiet="$value" ;;
            deletion_mode) config_deletion_mode="$value" ;;
            backup_dir) config_backup_dir="$value" ;;
            commit_message) config_commit_message="$value" ;;
        esac
    done < "$config_file"
}

apply_configuration() {
    [[ -n "$config_auto_commit" ]] && auto_commit="$config_auto_commit"
    [[ -n "$config_recursive_filenames" ]] && recursive_filenames="$config_recursive_filenames"
    [[ -n "$config_global_ignore" ]] && global_ignore="$config_global_ignore"
    [[ -n "$config_confirm" ]] && confirmation_enabled="$config_confirm"
    [[ -n "$config_verbose" ]] && verbose="$config_verbose"
    [[ -n "$config_quiet" ]] && quiet="$config_quiet"
    [[ -n "$config_deletion_mode" ]] && deletion_mode="$config_deletion_mode"
    [[ -n "$config_backup_dir" ]] && backup_dir="$config_backup_dir"
    [[ -n "$config_commit_message" ]] && commit_message="$config_commit_message"
    if [[ "$config_delete_local" == true && -z "$config_deletion_mode" ]]; then
        deletion_mode=delete
    fi

    [[ -n "$cli_auto_commit" ]] && auto_commit="$cli_auto_commit"
    [[ -n "$cli_recursive_filenames" ]] && recursive_filenames="$cli_recursive_filenames"
    [[ -n "$cli_global_ignore" ]] && global_ignore="$cli_global_ignore"
    [[ -n "$cli_confirmation_enabled" ]] && confirmation_enabled="$cli_confirmation_enabled"
    [[ -n "$cli_verbose" ]] && verbose="$cli_verbose"
    [[ -n "$cli_quiet" ]] && quiet="$cli_quiet"
    [[ -n "$cli_deletion_mode" ]] && deletion_mode="$cli_deletion_mode"
    [[ -n "$cli_backup_dir" ]] && backup_dir="$cli_backup_dir"
    [[ -n "$cli_commit_message" ]] && commit_message="$cli_commit_message"

    "$quiet" && verbose=false
    if [[ "$deletion_mode" == backup && -z "$backup_dir" ]]; then
        die '--backup-dir requires a directory.'
    fi
    if [[ "$deletion_mode" == backup ]]; then
        backup_dir="$(normalize_backup_directory "$backup_dir")"
    fi
    if [[ "$deletion_mode" == trash ]]; then
        detect_trash_platform
    fi
}

resolve_global_ignore_file() {
    global_ignore_file="$(git config --global --path core.excludesFile 2>/dev/null || true)"
    global_config_needs_update=false
    if [[ -z "$global_ignore_file" ]]; then
        global_ignore_file="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
        global_config_needs_update=true
    fi
}

ensure_ignore_target() {
    ignore_target=repository
    if "$global_ignore"; then
        ignore_target=global
        resolve_global_ignore_file
        ignore_file="$global_ignore_file"
        if [[ ! -e "$ignore_file" ]]; then
            if "$dry_run"; then
                info "Would create global ignore file: $ignore_file"
            else
                mkdir -p "$(dirname "$ignore_file")"
                : > "$ignore_file"
            fi
        fi
        if "$global_config_needs_update"; then
            if "$dry_run"; then
                info "Would configure core.excludesFile: $ignore_file"
            else
                git config --global core.excludesFile "$ignore_file"
            fi
        fi
        canonical_ignore_file="$(canonical_path "$ignore_file")"
        return
    fi

    ignore_file="$repo_root/.gitignore"
    canonical_ignore_file="$ignore_file"
    if [[ -e "$ignore_file" ]]; then
        return
    fi

    if "$dry_run"; then
        info "Would create repository ignore file: $ignore_file"
        return
    fi

    local ignore_choice=""
    printf 'No .gitignore found. Enter a path inside this repository, or type init to create %s: ' \
        "$ignore_file" >&2
    if ! IFS= read -r ignore_choice; then
        die 'no .gitignore choice received.'
    fi
    if [[ "$ignore_choice" == init ]]; then
        : > "$ignore_file"
    elif [[ -n "$ignore_choice" ]]; then
        local ignore_root=""
        ignore_root="$(git -C "$ignore_choice" rev-parse --show-toplevel 2>/dev/null || true)"
        [[ "$ignore_root" == "$repo_root" ]] || die "\"$ignore_choice\" is not inside this Git repository."
        : > "$ignore_file"
    else
        die 'a repository path or init is required.'
    fi
}

append_pattern() {
    local pattern="$1"
    if [[ -s "$ignore_file" && "$(tail -c 1 "$ignore_file")" != $'\n' ]]; then
        printf '\n' >> "$ignore_file"
    fi
    printf '%s\n' "$pattern" >> "$ignore_file"
}

resolve_patterns() {
    local argument=""
    local pattern=""
    local resolved_patterns=()

    for argument in "${patterns[@]}"; do
        validate_pattern "$argument"
        pattern="$(expand_preset "$argument")"
        if "$recursive_filenames" \
            && [[ "$pattern" != */* ]] \
            && [[ "$pattern" != *'*'* && "$pattern" != *'?'* && "$pattern" != *'['* ]]; then
            pattern="**/$pattern"
        fi

        if ! "$global_ignore" && [[ "$pattern" != /* && -n "$called_from" ]]; then
            pattern="$called_from/$pattern"
        fi

        if ((${#resolved_patterns[@]} == 0)) || ! array_contains "$pattern" "${resolved_patterns[@]}"; then
            resolved_patterns+=("$pattern")
        fi
    done
    patterns=("${resolved_patterns[@]}")
}

collect_tracked_matches() {
    local pattern="$1"
    local path=""
    match_paths=()
    while IFS= read -r -d '' path; do
        match_paths+=("$path")
    done < <(git ls-files -ci -z --exclude="$pattern")
}

collect_preview_local_matches() {
    local pattern="$1"
    local path=""
    preview_local_paths=()
    while IFS= read -r -d '' path; do
        preview_local_paths+=("$path")
    done < <(git ls-files -oi -z --exclude="$pattern")
}

source_matches_ignore_file() {
    local source="$1"
    [[ "$source" == "$ignore_file" || "$source" == "$canonical_ignore_file" ]] && return 0
    [[ "$ignore_target" == repository && "$source" == .gitignore ]]
}

add_deletion_root() {
    local candidate="$1"
    local root=""
    local retained_roots=()

    candidate="${candidate#./}"
    [[ -n "$candidate" && "$candidate" != .gitignore ]] || return

    for root in "${deletion_paths[@]}"; do
        [[ "$candidate" == "$root" || "$candidate" == "$root/"* ]] && return
    done
    for root in "${deletion_paths[@]}"; do
        [[ "$root" == "$candidate/"* ]] || retained_roots+=("$root")
    done
    deletion_paths=("${retained_roots[@]}")
    deletion_paths+=("$candidate")
}

collect_precise_deletion_matches() {
    local pattern="$1"
    local source=""
    local line_number=""
    local matched_pattern=""
    local path=""

    deletion_paths=()
    while IFS= read -r -d '' source \
        && IFS= read -r -d '' line_number \
        && IFS= read -r -d '' matched_pattern \
        && IFS= read -r -d '' path; do
        if [[ "$matched_pattern" == "$pattern" ]] && source_matches_ignore_file "$source"; then
            add_deletion_root "$path"
        fi
    done < <((find . -mindepth 1 -path './.git' -prune -o -print0 \
        | git check-ignore -z -v --stdin --no-index) || true)
}

backup_destination_for() {
    local path="$1"
    local destination="$backup_directory/$path"
    local suffix=1
    while [[ -e "$destination" || -L "$destination" ]]; do
        destination="$backup_directory/$path.gitign-$suffix"
        suffix=$((suffix + 1))
    done
    printf '%s' "$destination"
}

detect_trash_platform() {
    local kernel=""
    kernel="$(uname -s)"
    windows_powershell_command=""

    case "$kernel" in
        Darwin)
            trash_platform=macos
            ;;
        Linux)
            # WSL paths may be UNC shares, which Windows cannot recycle. Its
            # Linux Trash adapter works for both native Linux and WSL files.
            trash_platform=linux
            ;;
        MINGW*|MSYS*|CYGWIN*)
            trash_platform=windows
            ;;
        *)
            die "--trash is unsupported on $kernel; use --backup-dir instead."
            ;;
    esac

    if [[ "$trash_platform" == windows ]]; then
        local candidate=""
        for candidate in powershell.exe powershell pwsh.exe; do
            if command -v "$candidate" >/dev/null 2>&1; then
                windows_powershell_command="$candidate"
                break
            fi
        done
        [[ -n "$windows_powershell_command" ]] \
            || die '--trash on Windows requires PowerShell; use --backup-dir instead.'
    fi
}

trash_escape_path() {
    local path="$1"
    local byte=""
    local encoded=""
    local byte_code=0
    local index=0
    local result=""
    local LC_ALL=C

    for ((index = 0; index < ${#path}; index++)); do
        byte="${path:index:1}"
        case "$byte" in
            [A-Za-z0-9._/-])
                result+="$byte"
                ;;
            *)
                encoded="$(printf '%s' "$byte" | od -An -tx1 | tr -d '[:space:]')"
                encoded="%$encoded"
                result+="$encoded"
                ;;
        esac
    done
    printf '%s' "$result"
}

unique_trash_destination() {
    local directory="$1"
    local name="$2"
    local destination="$directory/$name"
    local suffix=1

    while [[ -e "$destination" || -L "$destination" ]]; do
        destination="$directory/$name.gitign-$suffix"
        suffix=$((suffix + 1))
    done
    printf '%s' "$destination"
}

move_without_overwrite() {
    local source="$1"
    local destination="$2"

    mv -n -- "$source" "$destination" || return 1
    [[ ! -e "$source" && ! -L "$source" ]]
}

move_to_macos_trash() {
    local path="$1"
    local trash_directory="$HOME/.Trash"
    local destination=""

    mkdir -p "$trash_directory"
    while [[ -e "$path" || -L "$path" ]]; do
        destination="$(unique_trash_destination "$trash_directory" "$(basename "$path")")"
        if move_without_overwrite "$path" "$destination"; then
            return
        fi
        [[ -e "$destination" || -L "$destination" ]] || return 1
    done
    return 1
}

filesystem_device() {
    df -P "$1" | awk 'NR > 1 { device = $1 } END { print device }'
}

filesystem_mount_point() {
    df -P "$1" | awk 'NR > 1 { mount = $NF } END { print mount }'
}

prepare_linux_trash_directory() {
    local directory="$1"
    local child=""

    [[ ! -L "$directory" ]] || return 1
    mkdir -p "$directory" 2>/dev/null || return 1
    [[ -d "$directory" && ! -L "$directory" ]] || return 1

    for child in files info; do
        [[ ! -L "$directory/$child" ]] || return 1
        mkdir -p "$directory/$child" 2>/dev/null || return 1
        [[ -d "$directory/$child" && ! -L "$directory/$child" ]] || return 1
    done
}

linux_trash_directory_for() {
    local path="$1"
    local home_trash="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"
    local source_device=""
    local home_device=""
    local mount_point=""
    local shared_trash=""
    local private_trash=""
    local user_id=""

    prepare_linux_trash_directory "$home_trash" \
        || die "cannot create the home Trash directory; use --backup-dir instead."
    source_device="$(filesystem_device "$path")"
    home_device="$(filesystem_device "$home_trash")"
    [[ -n "$source_device" && -n "$home_device" ]] \
        || die 'could not identify the source filesystem for --trash.'
    if [[ "$source_device" == "$home_device" ]]; then
        linux_trash_directory="$home_trash"
        linux_trash_path_base=""
        return
    fi

    mount_point="$(filesystem_mount_point "$path")"
    [[ -n "$mount_point" ]] || die 'could not identify the source mount point for --trash.'
    user_id="$(id -u)"
    shared_trash="$mount_point/.Trash"
    private_trash="$mount_point/.Trash-$user_id"

    if [[ ! -L "$shared_trash" && -d "$shared_trash" && -k "$shared_trash" && -w "$shared_trash" ]] \
        && prepare_linux_trash_directory "$shared_trash/$user_id"; then
        linux_trash_directory="$shared_trash/$user_id"
        linux_trash_path_base="$mount_point"
        return
    fi

    prepare_linux_trash_directory "$private_trash" \
        || die "cannot create a Trash directory on $mount_point; use --backup-dir instead."
    linux_trash_directory="$private_trash"
    linux_trash_path_base="$mount_point"
}

move_to_linux_trash() {
    local path="$1"
    local absolute_path=""
    local trash_directory=""
    local files_directory=""
    local info_directory=""
    local base_name=""
    local name=""
    local destination=""
    local info_file=""
    local encoded_path=""
    local path_for_info=""
    local suffix=1

    absolute_path="$(canonical_path "$path")"
    linux_trash_directory=""
    linux_trash_path_base=""
    linux_trash_directory_for "$path"
    trash_directory="$linux_trash_directory"
    files_directory="$trash_directory/files"
    info_directory="$trash_directory/info"
    path_for_info="$absolute_path"
    if [[ -n "$linux_trash_path_base" ]]; then
        path_for_info="${absolute_path#"$linux_trash_path_base"/}"
        [[ "$path_for_info" != "$absolute_path" ]] \
            || die "cannot create a mount-relative Trash path for $path."
    fi
    base_name="$(basename "$path")"
    destination="$files_directory/$base_name"

    while [[ -e "$path" || -L "$path" ]]; do
        name="$(basename "$destination")"
        info_file="$info_directory/$name.trashinfo"
        if [[ -e "$destination" || -L "$destination" || -e "$info_file" ]]; then
            destination="$files_directory/$base_name.gitign-$suffix"
            suffix=$((suffix + 1))
            continue
        fi
        if ! (set -C; : > "$info_file") 2>/dev/null; then
            destination="$files_directory/$base_name.gitign-$suffix"
            suffix=$((suffix + 1))
            continue
        fi

        encoded_path="$(trash_escape_path "$path_for_info")"
        {
            printf '[Trash Info]\n'
            printf 'Path=%s\n' "$encoded_path"
            printf 'DeletionDate=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
        } > "$info_file"
        if move_without_overwrite "$path" "$destination"; then
            return
        fi
        rm -f -- "$info_file"
        [[ -e "$destination" || -L "$destination" ]] || return 1
    done

    return 1
}

windows_path_for() {
    local path="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$path"
    elif command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$path"
    else
        die '--trash on Windows requires cygpath or wslpath to convert the file path.'
    fi
}

move_to_windows_trash() {
    local path="$1"
    local windows_path=""
    local path_kind=file

    [[ -d "$path" && ! -L "$path" ]] && path_kind=directory
    windows_path="$(windows_path_for "$path")"

    GITIGN_TRASH_PATH="$windows_path" \
        GITIGN_TRASH_SOURCE="$path" \
        GITIGN_TRASH_KIND="$path_kind" \
        "$windows_powershell_command" -NoProfile -NonInteractive -Command '
            $ErrorActionPreference = "Stop"
            Add-Type -AssemblyName Microsoft.VisualBasic
            if ($env:GITIGN_TRASH_KIND -eq "directory") {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                    $env:GITIGN_TRASH_PATH,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                )
            } else {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                    $env:GITIGN_TRASH_PATH,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                )
            }
        '
}

move_to_trash() {
    local path="$1"
    case "$trash_platform" in
        macos) move_to_macos_trash "$path" ;;
        linux) move_to_linux_trash "$path" ;;
        windows) move_to_windows_trash "$path" ;;
        *) die 'internal error: no supported Trash platform was selected.' ;;
    esac
}

delete_local_paths() {
    local path=""
    local destination=""

    ((${#deletion_paths[@]})) || return

    if [[ "$deletion_mode" == backup ]]; then
        if is_absolute_path "$backup_dir"; then
            backup_directory="$backup_dir"
        else
            backup_directory="$repo_root/$backup_dir"
        fi
        for path in "${deletion_paths[@]}"; do
            if [[ "$backup_directory" == "$repo_root/$path" || "$backup_directory" == "$repo_root/$path/"* ]]; then
                die '--backup-dir cannot be inside a path selected for deletion.'
            fi
        done
        mkdir -p "$backup_directory"
    fi

    for path in "${deletion_paths[@]}"; do
        [[ -e "$path" || -L "$path" ]] || continue
        case "$deletion_mode" in
            delete)
                rm -rf -- "$path"
                ;;
            trash)
                move_to_trash "$path"
                ;;
            backup)
                destination="$(backup_destination_for "$path")"
                mkdir -p "$(dirname "$destination")"
                mv -- "$path" "$destination"
                deleted_sources+=("$path")
                deleted_destinations+=("$destination")
                ;;
        esac
        success "Handled local path: $path"
    done
}

preview_plan() {
    local pattern=""
    local pattern_exists=false
    local total_tracked=0
    local total_local=0

    for pattern in "${patterns[@]}"; do
        pattern_exists=false
        [[ -f "$ignore_file" ]] && grep -Fqx -- "$pattern" "$ignore_file" && pattern_exists=true
        collect_tracked_matches "$pattern"
        collect_preview_local_matches "$pattern"
        total_tracked=$((total_tracked + ${#match_paths[@]}))
        total_local=$((total_local + ${#match_paths[@]} + ${#preview_local_paths[@]}))

        info "Pattern: $pattern ($("$pattern_exists" && printf 'already present' || printf 'will add'))"
        info "  tracked matches: ${#match_paths[@]}"
        if [[ "$deletion_mode" != keep ]]; then
            info "  potential local matches: $(( ${#match_paths[@]} + ${#preview_local_paths[@]} ))"
        fi
        if "$verbose"; then
            local path=""
            for path in "${match_paths[@]}"; do
                info "    would untrack: $path"
                if [[ "$deletion_mode" != keep ]]; then
                    info "    would handle locally: $path"
                fi
            done
            if [[ "$deletion_mode" != keep ]]; then
                for path in "${preview_local_paths[@]}"; do
                    info "    would handle locally: $path"
                done
            fi
        fi
    done

    planned_tracked_count="$total_tracked"
    planned_local_count="$total_local"
    if "$dry_run"; then
        info 'Dry run: no files, ignore rules, configuration, or commits were changed.'
    fi
}

operation_is_broad() {
    local pattern=""
    ((${#patterns[@]} > 1)) && return 0
    for pattern in "${patterns[@]}"; do
        is_broad_pattern "$pattern" && return 0
    done
    "$recursive_filenames"
}

record_last_action() {
    local action_directory="$git_directory/gitign"
    local action_file="$action_directory/last-action"
    local path=""
    local index=0

    mkdir -p "$action_directory"
    {
        printf 'IGNORE_FILE=%s\n' "$canonical_ignore_file"
        printf 'IGNORE_TARGET=%s\n' "$ignore_target"
        printf 'AUTO_COMMIT=%s\n' "$auto_commit"
        printf 'COMMIT_SHA=%s\n' "$commit_sha"
        printf 'DELETION_MODE=%s\n' "$deletion_mode"
        printf 'BACKUP_DIRECTORY=%s\n' "${backup_directory:-}"
    } > "$action_file"

    : > "$action_directory/added-patterns"
    for path in "${added_patterns[@]}"; do
        printf '%s\0' "$path" >> "$action_directory/added-patterns"
    done
    : > "$action_directory/tracked-paths"
    for path in "${affected_paths[@]}"; do
        printf '%s\0' "$path" >> "$action_directory/tracked-paths"
    done
    : > "$action_directory/deleted-paths"
    while ((index < ${#deleted_sources[@]})); do
        printf '%s\0%s\0' "${deleted_sources[$index]}" "${deleted_destinations[$index]}" \
            >> "$action_directory/deleted-paths"
        index=$((index + 1))
    done
}

remove_last_pattern() {
    local target="$1"
    local pattern="$2"
    local temporary_file=""
    temporary_file="$(mktemp "${target}.gitign.XXXXXX")"
    awk -v pattern="$pattern" '
        { lines[NR] = $0 }
        $0 == pattern { last = NR }
        END {
            for (i = 1; i <= NR; i++) {
                if (i != last) {
                    print lines[i]
                }
            }
        }
    ' "$target" > "$temporary_file"
    mv "$temporary_file" "$target"
}

restore_backup_paths() {
    local path=""
    local backup_path=""
    while IFS= read -r -d '' path && IFS= read -r -d '' backup_path; do
        if [[ ! -e "$backup_path" && ! -L "$backup_path" ]]; then
            continue
        fi
        if [[ -e "$path" || -L "$path" ]]; then
            warning "Cannot restore $path because it already exists."
            continue
        fi
        mkdir -p "$(dirname "$path")"
        mv -- "$backup_path" "$path"
        success "Restored local path: $path"
    done < "$undo_directory/deleted-paths"
}

undo_last_action() {
    local action_file="$git_directory/gitign/last-action"
    local line=""
    local key=""
    local value=""
    local undo_ignore_file=""
    local undo_ignore_target=""
    local undo_commit_sha=""
    local undo_auto_commit=false
    local undo_deletion_mode=""
    local path=""
    local changed=false

    [[ -f "$action_file" ]] || die 'no gitign action is available to undo.'
    undo_directory="$(dirname "$action_file")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            IGNORE_FILE) undo_ignore_file="$value" ;;
            IGNORE_TARGET) undo_ignore_target="$value" ;;
            AUTO_COMMIT) undo_auto_commit="$value" ;;
            COMMIT_SHA) undo_commit_sha="$value" ;;
            DELETION_MODE) undo_deletion_mode="$value" ;;
        esac
    done < "$action_file"

    if "$dry_run"; then
        info "Would undo the latest gitign action using $undo_ignore_file."
        [[ -n "$undo_commit_sha" ]] && info "Would revert commit: $undo_commit_sha"
        [[ "$undo_deletion_mode" == backup ]] && info 'Would restore files from the recorded backup directory.'
        return
    fi

    if [[ "$undo_auto_commit" == true && -n "$undo_commit_sha" ]]; then
        [[ "$(git rev-parse HEAD)" == "$undo_commit_sha" ]] \
            || die 'the latest gitign commit is no longer HEAD, so it cannot be safely undone automatically.'
        git revert --no-edit "$undo_commit_sha"
        changed=true
    fi

    if [[ "$undo_auto_commit" != true || -z "$undo_commit_sha" || "$undo_ignore_target" == global ]]; then
        if [[ -f "$undo_directory/added-patterns" && -e "$undo_ignore_file" ]]; then
            while IFS= read -r -d '' path; do
                remove_last_pattern "$undo_ignore_file" "$path"
                changed=true
            done < "$undo_directory/added-patterns"
        fi
        if [[ -s "$undo_directory/tracked-paths" ]]; then
            local undo_tracked_paths=()
            while IFS= read -r -d '' path; do
                undo_tracked_paths+=("$path")
            done < "$undo_directory/tracked-paths"
            if ((${#undo_tracked_paths[@]})); then
                git reset -q HEAD -- "${undo_tracked_paths[@]}"
                changed=true
            fi
        fi
    fi

    if [[ "$undo_deletion_mode" == backup && -f "$undo_directory/deleted-paths" ]]; then
        restore_backup_paths
        changed=true
    elif [[ "$undo_deletion_mode" == delete || "$undo_deletion_mode" == trash ]]; then
        warning 'Locally deleted or trashed files cannot be restored automatically.'
    fi

    rm -rf -- "$undo_directory"
    "$changed" && success 'Undid the latest gitign action.' || info 'Nothing needed to be undone.'
}

initialize_color

auto_commit=true
recursive_filenames=false
global_ignore=false
confirmation_enabled=true
assume_yes=false
deletion_mode=keep
backup_dir=""
commit_message=""
dry_run=false
undo=false
initialize_config_file=false
patterns=()

cli_auto_commit=""
cli_recursive_filenames=""
cli_global_ignore=""
cli_confirmation_enabled=""
cli_verbose=""
cli_quiet=""
cli_deletion_mode=""
cli_backup_dir=""
cli_commit_message=""
config_auto_commit=""
config_delete_local=""
config_recursive_filenames=""
config_global_ignore=""
config_confirm=""
config_verbose=""
config_quiet=""
config_deletion_mode=""
config_backup_dir=""
config_commit_message=""

while (($#)); do
    case "$1" in
        --no-auto-commit) cli_auto_commit=false ;;
        --delete_local|--delete-local) cli_deletion_mode=delete ;;
        --trash) cli_deletion_mode=trash ;;
        --backup-dir)
            shift
            (($#)) || die '--backup-dir requires a directory.'
            cli_deletion_mode=backup
            cli_backup_dir="$1"
            ;;
        --backup-dir=*)
            cli_deletion_mode=backup
            cli_backup_dir="${1#*=}"
            ;;
        --commit-message)
            shift
            (($#)) || die '--commit-message requires text.'
            cli_commit_message="$1"
            ;;
        --commit-message=*) cli_commit_message="${1#*=}" ;;
        --recursive-filenames) cli_recursive_filenames=true ;;
        --no-recursive-filenames) cli_recursive_filenames=false ;;
        --global|--global-ignore) cli_global_ignore=true ;;
        --no-global) cli_global_ignore=false ;;
        --dry-run) dry_run=true ;;
        --undo) undo=true ;;
        --init) initialize_config_file=true ;;
        --yes) assume_yes=true ;;
        --verbose) cli_verbose=true; cli_quiet=false ;;
        --quiet) cli_quiet=true; cli_verbose=false ;;
        --help) usage; exit 0 ;;
        --version) version; exit 0 ;;
        --)
            shift
            patterns+=("$@")
            break
            ;;
        -*) die "unknown option: $1" ;;
        *) patterns+=("$1") ;;
    esac
    shift
done

initial_directory="$(pwd -P)"

if "$initialize_config_file" && { "$undo" || "$dry_run" || ((${#patterns[@]})); }; then
    die '--init cannot be combined with patterns, --undo, or --dry-run.'
fi
if "$initialize_config_file"; then
    initialize_config
    exit 0
fi
if "$undo" && ((${#patterns[@]})); then
    die '--undo cannot be combined with ignore patterns.'
fi
if ! "$undo" && ((${#patterns[@]} == 0)); then
    usage >&2
    exit 2
fi

repo_root=""
called_from=""
git_directory=""
resolve_repository
load_config
apply_configuration

if "$undo"; then
    undo_last_action
    exit 0
fi

if [[ -n "$commit_message" && "$commit_message" == *$'\n'* ]]; then
    die '--commit-message must be one line.'
fi

if "$auto_commit" && ! "$dry_run" && ! git diff --cached --quiet; then
    die 'the staging area already has changes; use --no-auto-commit or commit them first.'
fi

resolve_patterns
ensure_ignore_target
preview_plan

if "$dry_run"; then
    exit 0
fi

if ! "$auto_commit" && ((planned_tracked_count > 0)) && ! git diff --cached --quiet; then
    die 'the staging area already has changes; commit or stash them before untracking files.'
fi

if [[ "$deletion_mode" != keep && "$planned_local_count" -gt 0 ]] && "$confirmation_enabled"; then
    confirm "Handle local matches using --$deletion_mode?" || die 'cancelled before changing local files.'
fi
if "$auto_commit" && operation_is_broad && "$confirmation_enabled"; then
    confirm 'Create an automatic commit for this broad operation?' || die 'cancelled before automatic commit.'
fi

added_patterns=()
affected_paths=()
deleted_sources=()
deleted_destinations=()
commit_sha=""
made_changes=false

for pattern in "${patterns[@]}"; do
    if [[ -f "$ignore_file" ]] && grep -Fqx -- "$pattern" "$ignore_file"; then
        info "Already ignored: $pattern"
    else
        append_pattern "$pattern"
        added_patterns+=("$pattern")
        made_changes=true
        success "Added ignore pattern: $pattern"
    fi

    collect_tracked_matches "$pattern"
    if ((${#match_paths[@]})); then
        git rm -q --cached -r --ignore-unmatch -- "${match_paths[@]}"
        path_to_untrack=""
        for path_to_untrack in "${match_paths[@]}"; do
            add_unique_affected_path "$path_to_untrack"
        done
        made_changes=true
        success "Stopped tracking ${#match_paths[@]} matching path(s)."
    fi

    if [[ "$deletion_mode" != keep ]]; then
        collect_precise_deletion_matches "$pattern"
        if ((${#deletion_paths[@]})); then
            delete_local_paths
            made_changes=true
        fi
    fi
done

if "$auto_commit"; then
    [[ "$ignore_target" == repository ]] && git add -- .gitignore
    if ! git diff --cached --quiet; then
        if [[ -n "$commit_message" ]]; then
            :
        elif ((${#patterns[@]} == 1)); then
            commit_message="gitign: ignore ${patterns[0]}"
        else
            commit_message="gitign: ignore ${#patterns[@]} patterns"
        fi
        git commit -q -m "$commit_message"
        commit_sha="$(git rev-parse HEAD)"
        success "Created commit: $commit_message"
    else
        info 'No tracked changes were produced; no commit was created.'
    fi
fi

if "$made_changes"; then
    record_last_action
else
    info 'No changes: patterns already existed and no matching local or tracked files were found; no commit was created.'
fi
