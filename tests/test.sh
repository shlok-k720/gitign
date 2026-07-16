#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
gitign="$root/gitignore.sh"
installer="$root/compile-gitign.sh"
release_tool="$root/scripts/release.sh"
version="$(<"$root/VERSION.txt")"
workspace="$(mktemp -d)"
pass_count=0

cleanup() {
    rm -rf "$workspace"
}
trap cleanup EXIT

pass() {
    printf 'ok %d - %s\n' "$((pass_count + 1))" "$1"
    pass_count=$((pass_count + 1))
}

new_repository() {
    local repository="$1"
    mkdir -p "$repository"
    git -C "$repository" init -q
    git -C "$repository" config user.name gitign-test
    git -C "$repository" config user.email gitign-test@example.invalid
}

test_auto_commit_and_noop() {
    local repository="$workspace/auto"
    new_repository "$repository"
    touch "$repository/database.db"
    git -C "$repository" add database.db
    git -C "$repository" commit -qm initial

    (
        cd "$repository"
        printf 'init\n' | "$gitign" --yes --commit-message 'Ignore local database' database.db >/dev/null
    )
    [[ -f "$repository/database.db" ]]
    [[ -z "$(git -C "$repository" ls-files -- database.db)" ]]
    grep -Fqx 'database.db' "$repository/.gitignore"
    [[ "$(git -C "$repository" log -1 --format=%s)" == 'Ignore local database' ]]
    [[ "$("$gitign" --version)" == "gitign version $version" ]]

    local output=""
    output="$(
        cd "$repository"
        "$gitign" --yes database.db
    )"
    [[ "$output" == *'No changes:'* ]]
    pass 'auto commit, custom message, version, and no-op reporting'
}

test_dry_run_and_recursive_config() {
    local repository="$workspace/dry-run"
    new_repository "$repository"
    mkdir -p "$repository/nested"
    touch "$repository/nested/cache.db"
    printf 'auto_commit=false\nrecursive_filenames=true\n' > "$repository/.gitignrc"
    git -C "$repository" add .
    git -C "$repository" commit -qm initial

    local output=""
    output="$(
        cd "$repository"
        "$gitign" --dry-run --delete_local cache.db
    )"
    [[ "$output" == *'Pattern: **/cache.db'* ]]
    [[ "$output" == *'potential local matches: 1'* ]]
    [[ "$output" == *'Dry run:'* ]]
    [[ ! -e "$repository/.gitignore" ]]

    (
        cd "$repository"
        printf 'init\n' | "$gitign" --yes cache.db >/dev/null
    )
    grep -Fqx '**/cache.db' "$repository/.gitignore"
    [[ "$(git -C "$repository" log -1 --format=%s)" == initial ]]
    pass 'dry run and repository-local recursive filename configuration'
}

test_preflight_guards() {
    local repository="$workspace/guards"
    new_repository "$repository"
    touch "$repository/data.db" "$repository/other.txt"
    printf '*.db\n' > "$repository/.gitignore"
    git -C "$repository" add .gitignore other.txt
    git -C "$repository" add -f data.db
    git -C "$repository" commit -qm initial
    printf 'staged\n' >> "$repository/other.txt"
    git -C "$repository" add other.txt

    ! (
        cd "$repository"
        "$gitign" --no-auto-commit data.db >/dev/null 2>&1
    )
    [[ -n "$(git -C "$repository" ls-files -- data.db)" ]]
    ! (
        cd "$repository"
        "$gitign" --commit-message $'invalid\nmessage' data.db >/dev/null 2>&1
    )
    [[ ! -f "$repository/.gitignore.gitign"* ]]
    pass 'preflight guards protect staged work and reject invalid commit messages'
}

test_precise_delete_backup_trash_and_undo() {
    local repository="$workspace/delete"
    local backup="$workspace/backup"
    local trash_home="$workspace/trash-home"
    new_repository "$repository"
    touch "$repository/app.log" "$repository/other.log" "$repository/keep.txt"
    printf '*.log\n' > "$repository/.gitignore"
    git -C "$repository" add .
    git -C "$repository" commit -qm initial

    (
        cd "$repository"
        "$gitign" --yes --delete_local app.log >/dev/null
    )
    [[ ! -e "$repository/app.log" ]]
    [[ -f "$repository/other.log" ]]
    [[ -f "$repository/keep.txt" ]]

    (
        cd "$repository"
        "$gitign" --yes --no-auto-commit --backup-dir "$backup" other.log >/dev/null
    )
    [[ ! -e "$repository/other.log" ]]
    [[ -f "$backup/other.log" ]]
    (
        cd "$repository"
        "$gitign" --undo >/dev/null
    )
    [[ -f "$repository/other.log" ]]

    touch "$repository/trash-me.tmp"
    (
        cd "$repository"
        HOME="$trash_home" "$gitign" --yes --no-auto-commit --trash trash-me.tmp >/dev/null
    )
    [[ ! -e "$repository/trash-me.tmp" ]]
    find "$trash_home/.Trash" -type f -name 'trash-me.tmp*' | grep -q .
    pass 'precise deletion, backup restoration, and macOS trash mode'
}

test_linux_and_windows_trash_adapters() {
    local fake_bin="$workspace/fake-bin"
    local linux_repository="$workspace/linux-trash"
    local linux_home="$workspace/linux-home"
    local mounted_volume="$workspace/mounted-volume"
    local mounted_repository="$mounted_volume/repository"
    local mounted_volume_physical=""
    local windows_repository="$workspace/windows-trash"
    local windows_home="$workspace/windows-home"
    local windows_log="$workspace/windows-trash.log"
    local windows_backup="$workspace/windows-backup"
    mkdir -p "$fake_bin" "$linux_home" "$windows_home" "$windows_backup"

    cat > "$fake_bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Linux\n'
EOF
    cat > "$fake_bin/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
path="$2"
if [[ "$path" != /* ]]; then
    path="$(cd -P "$(dirname "$path")" && pwd)/$(basename "$path")"
fi
if [[ -n "${GITIGN_TEST_MOUNT_ROOT:-}" ]]; then
    mount_root="$(cd -P "$GITIGN_TEST_MOUNT_ROOT" && pwd)"
else
    mount_root=/__gitign_no_mount__
fi
if [[ "$path" == "$mount_root"* ]]; then
    printf '/dev/gitign-mounted 100 1 99 1%% %s\n' "$GITIGN_TEST_MOUNT_ROOT"
else
    printf '/dev/gitign-home 100 1 99 1%% /home\n'
fi
EOF
    chmod +x "$fake_bin/uname" "$fake_bin/df"

    new_repository "$linux_repository"
    touch "$linux_repository/linux trash#.tmp"
    git -C "$linux_repository" add 'linux trash#.tmp'
    git -C "$linux_repository" commit -qm initial
    (
        cd "$linux_repository"
        printf 'init\n' | HOME="$linux_home" XDG_DATA_HOME="$linux_home/data" PATH="$fake_bin:$PATH" \
            "$gitign" --yes --no-auto-commit --trash 'linux trash#.tmp' >/dev/null
    )
    [[ ! -e "$linux_repository/linux trash#.tmp" ]]
    [[ -f "$linux_home/data/Trash/files/linux trash#.tmp" ]]
    grep -Fqx '[Trash Info]' "$linux_home/data/Trash/info/linux trash#.tmp.trashinfo"
    grep -Fq 'Path=' "$linux_home/data/Trash/info/linux trash#.tmp.trashinfo"
    grep -Fq 'linux%20trash%23.tmp' "$linux_home/data/Trash/info/linux trash#.tmp.trashinfo"

    new_repository "$mounted_repository"
    mounted_volume_physical="$(cd -P "$mounted_volume" && pwd)"
    touch "$mounted_repository/cross-volume.tmp"
    git -C "$mounted_repository" add cross-volume.tmp
    git -C "$mounted_repository" commit -qm initial
    (
        cd "$mounted_repository"
        printf 'init\n' | HOME="$linux_home" XDG_DATA_HOME="$linux_home/data" PATH="$fake_bin:$PATH" \
            GITIGN_TEST_MOUNT_ROOT="$mounted_volume_physical" \
            "$gitign" --yes --no-auto-commit --trash cross-volume.tmp >/dev/null
    )
    [[ ! -e "$mounted_repository/cross-volume.tmp" ]]
    [[ -f "$mounted_volume/.Trash-$(id -u)/files/cross-volume.tmp" ]]
    grep -Fqx 'Path=repository/cross-volume.tmp' \
        "$mounted_volume/.Trash-$(id -u)/info/cross-volume.tmp.trashinfo"

    cat > "$fake_bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'MINGW64_NT-10.0\n'
EOF
    cat > "$fake_bin/cygpath" <<'EOF'
#!/usr/bin/env bash
    case "$1" in
        -w) printf 'C:\\GitignTest\\%s\n' "$(basename "$2")" ;;
        -u) printf '%s\n' "$GITIGN_WINDOWS_BACKUP_DIR" ;;
        *) exit 2 ;;
    esac
EOF
    cat > "$fake_bin/powershell.exe" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$GITIGN_TRASH_PATH" "$GITIGN_TRASH_KIND" >> "$GITIGN_WINDOWS_TRASH_LOG"
rm -rf -- "$GITIGN_TRASH_SOURCE"
EOF
    chmod +x "$fake_bin/uname" "$fake_bin/cygpath" "$fake_bin/powershell.exe"

    new_repository "$windows_repository"
    touch "$windows_repository/windows-trash.tmp"
    git -C "$windows_repository" add windows-trash.tmp
    git -C "$windows_repository" commit -qm initial
    (
        cd "$windows_repository"
        printf 'init\n' | HOME="$windows_home" PATH="$fake_bin:$PATH" \
            GITIGN_WINDOWS_TRASH_LOG="$windows_log" \
            "$gitign" --yes --no-auto-commit --trash windows-trash.tmp >/dev/null
    )
    [[ ! -e "$windows_repository/windows-trash.tmp" ]]
    grep -Fqx 'C:\GitignTest\windows-trash.tmp|file' "$windows_log"

    touch "$windows_repository/windows-backup.tmp"
    (
        cd "$windows_repository"
        HOME="$windows_home" PATH="$fake_bin:$PATH" \
            GITIGN_WINDOWS_BACKUP_DIR="$windows_backup" \
            "$gitign" --yes --no-auto-commit --backup-dir 'C:\GitignBackup' windows-backup.tmp >/dev/null
    )
    [[ ! -e "$windows_repository/windows-backup.tmp" ]]
    [[ -f "$windows_backup/windows-backup.tmp" ]]
    pass 'FreeDesktop Linux Trash, Windows Recycle Bin, and Windows backup paths'
}

test_presets_global_and_quiet_output() {
    local repository="$workspace/presets"
    local home="$workspace/global-home"
    new_repository "$repository"
    mkdir -p "$repository/node_modules/pkg" "$repository/__pycache__" "$home"
    touch "$repository/.env" "$repository/node_modules/pkg/index.js" "$repository/__pycache__/module.pyc"
    git -C "$repository" add .
    git -C "$repository" commit -qm initial

    (
        cd "$repository"
        printf 'init\n' | "$gitign" --yes --no-auto-commit dsstore nodemodules pythoncache >/dev/null
    )
    grep -Fqx '**/.DS_Store' "$repository/.gitignore"
    grep -Fqx '**/node_modules/' "$repository/.gitignore"
    grep -Fqx '**/__pycache__/' "$repository/.gitignore"
    git -C "$repository" add .gitignore
    git -C "$repository" commit -qm preset-setup

    (
        cd "$repository"
        HOME="$home" "$gitign" --yes --no-auto-commit --global env >/dev/null
    )
    grep -Fqx '**/.env' "$home/.config/git/ignore"
    [[ -z "$(git -C "$repository" ls-files -- .env)" ]]

    local output=""
    output="$(
        cd "$repository"
        "$gitign" --quiet --no-auto-commit logs
    )"
    [[ -z "$output" ]]
    pass 'presets, global ignores, and quiet output'
}

test_undo_auto_commit() {
    local repository="$workspace/undo"
    new_repository "$repository"
    touch "$repository/coverage.txt"
    git -C "$repository" add coverage.txt
    git -C "$repository" commit -qm initial

    (
        cd "$repository"
        printf 'init\n' | "$gitign" --yes coverage.txt >/dev/null
        "$gitign" --undo >/dev/null
    )
    [[ -n "$(git -C "$repository" ls-files -- coverage.txt)" ]]
    [[ ! -s "$repository/.gitignore" ]]

    local manual_repository="$workspace/manual-undo"
    new_repository "$manual_repository"
    touch "$manual_repository/manual.txt"
    git -C "$manual_repository" add manual.txt
    git -C "$manual_repository" commit -qm initial
    (
        cd "$manual_repository"
        printf 'init\n' | "$gitign" --yes --no-auto-commit manual.txt >/dev/null
        "$gitign" --undo >/dev/null
    )
    [[ -n "$(git -C "$manual_repository" ls-files -- manual.txt)" ]]
    pass 'automatic-commit undo'
}

test_global_auto_commit_undo() {
    local repository="$workspace/global-undo"
    local home="$workspace/global-undo-home"
    mkdir -p "$home"
    new_repository "$repository"
    touch "$repository/.env"
    git -C "$repository" add -f .env
    git -C "$repository" commit -qm initial

    (
        cd "$repository"
        HOME="$home" "$gitign" --yes --global env >/dev/null
        HOME="$home" "$gitign" --undo >/dev/null
    )
    ! grep -Fqx '**/.env' "$home/.config/git/ignore"
    [[ -n "$(git -C "$repository" ls-files -- .env)" ]]
    pass 'global-ignore automatic commit undo'
}

test_installer_and_release_tooling() {
    local home="$workspace/installer-home"
    local unconfigured_home="$workspace/unconfigured-home"
    mkdir -p "$home"

    [[ "$(HOME="$home" "$installer" --print-install-path)" == "$home/.local/bin/gitign" ]]
    HOME="$home" SHELL=/bin/fish "$installer" --shell fish >/dev/null
    [[ -x "$home/.local/bin/gitign" ]]
    grep -Fqx '# >>> gitign PATH >>>' "$home/.config/fish/config.fish"
    [[ "$(HOME="$home" "$home/.local/bin/gitign" --version)" == "gitign version $version" ]]
    HOME="$home" "$installer" --uninstall --shell fish >/dev/null
    [[ ! -e "$home/.local/bin/gitign" ]]
    ! grep -Fq '# >>> gitign PATH >>>' "$home/.config/fish/config.fish"
    mkdir -p "$unconfigured_home"
    HOME="$unconfigured_home" "$installer" --uninstall --shell bash >/dev/null

    HOME="$home" SHELL=/bin/bash "$installer" --shell bash >/dev/null
    grep -Fqx '# >>> gitign PATH >>>' "$home/.bashrc"
    grep -Fqx '# >>> gitign PATH >>>' "$home/.bash_profile"
    mkdir -p "$home/dotfiles"
    touch "$home/dotfiles/zshrc"
    ln -s "$home/dotfiles/zshrc" "$home/.zshrc"
    HOME="$home" SHELL=/bin/zsh "$installer" --shell zsh >/dev/null
    [[ -L "$home/.zshrc" ]]
    grep -Fqx '# >>> gitign PATH >>>' "$home/dotfiles/zshrc"

    local release_copy="$workspace/release"
    mkdir -p "$release_copy/scripts"
    cp "$root/VERSION.txt" "$root/gitignore.sh" "$release_copy/"
    cp "$release_tool" "$release_copy/scripts/release.sh"
    ! "$release_copy/scripts/release.sh" invalid >/dev/null 2>&1
    "$release_copy/scripts/release.sh" 1.2.3 >/dev/null
    [[ "$(<"$release_copy/VERSION.txt")" == 1.2.3 ]]
    grep -Fqx 'VERSION_STRING="1.2.3"' "$release_copy/gitignore.sh"
    [[ "$(git -C "$root" check-attr eol -- gitignore.sh | awk '{ print $3 }')" == lf ]]
    pass 'cross-shell installer lifecycle and version release tooling'
}

bash -n "$gitign"
bash -n "$installer"
bash -n "$release_tool"
test_auto_commit_and_noop
test_dry_run_and_recursive_config
test_preflight_guards
test_precise_delete_backup_trash_and_undo
test_linux_and_windows_trash_adapters
test_presets_global_and_quiet_output
test_undo_auto_commit
test_global_auto_commit_undo
test_installer_and_release_tooling
printf '1..%d\n' "$pass_count"
