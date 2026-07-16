#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: compile-gitign.sh [--reinstall | --uninstall | --print-install-path] [--shell SHELL]

Install gitign into ~/.local/bin and add that directory to the selected shell PATH.

Options:
  --reinstall             Replace the installed command (the default install behavior).
  --uninstall             Remove the installed command and gitign PATH block.
  --print-install-path    Print the command path and exit.
  --shell SHELL           Configure zsh, bash, or fish. Defaults to $SHELL.
  --help                  Show this help.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source_script="$script_dir/gitignore.sh"
version_file="$script_dir/VERSION.txt"
bin_dir="$HOME/.local/bin"
command_path="$bin_dir/gitign"
shell_name="$(basename "${SHELL:-zsh}")"
action=install

while (($#)); do
    case "$1" in
        --reinstall) action=install ;;
        --uninstall) action=uninstall ;;
        --print-install-path)
            printf '%s\n' "$command_path"
            exit 0
            ;;
        --shell)
            shift
            (($#)) || { printf 'gitign installer: --shell requires a shell name.\n' >&2; exit 2; }
            shell_name="$1"
            ;;
        --shell=*) shell_name="${1#*=}" ;;
        --help) usage; exit 0 ;;
        *) printf 'gitign installer: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

case "$shell_name" in
    zsh)
        shell_configs=("$HOME/.zshrc")
        path_block='case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac'
        ;;
    bash)
        shell_configs=("$HOME/.bashrc" "$HOME/.bash_profile")
        path_block='case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac'
        ;;
    fish)
        shell_configs=("$HOME/.config/fish/config.fish")
        path_block='if not contains -- "$HOME/.local/bin" $PATH
    set -gx PATH "$HOME/.local/bin" $PATH
end'
        ;;
    *)
        printf 'gitign installer: unsupported shell "%s"; choose zsh, bash, or fish.\n' "$shell_name" >&2
        exit 2
        ;;
esac

resolve_config_target() {
local path="$1"
local link_target=""
while [[ -L "$path" ]]; do
    link_target="$(readlink "$path")"
    if [[ "$link_target" == /* ]]; then
        path="$link_target"
    else
        path="$(dirname "$path")/$link_target"
    fi
done
printf '%s' "$path"
}

remove_path_block() {
local config="$1"
local target=""
local temporary_file=""
[[ -f "$config" ]] || return
target="$(resolve_config_target "$config")"
temporary_file="$(mktemp "$(dirname "$target")/.$(basename "$target").gitign.XXXXXX")"
awk '
    /^# >>> gitign PATH >>>$/ { skipping = 1; next }
    /^# <<< gitign PATH <<<$/{ skipping = 0; next }
    !skipping { print }
' "$target" > "$temporary_file"
mv "$temporary_file" "$target"
}

if [[ "$action" == uninstall ]]; then
rm -f "$command_path"
for shell_config in "${shell_configs[@]}"; do
    remove_path_block "$shell_config"
done
printf 'Uninstalled gitign from %s\n' "$command_path"
exit 0
fi

[[ -f "$source_script" ]] || { printf 'gitign installer: missing %s\n' "$source_script" >&2; exit 1; }
[[ -f "$version_file" ]] || { printf 'gitign installer: missing %s\n' "$version_file" >&2; exit 1; }
version="$(<"$version_file")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] \
    || { printf 'gitign installer: %s must contain a semantic version.\n' "$version_file" >&2; exit 1; }

mkdir -p "$bin_dir"
rm -f "$command_path"
awk -v version="$version" '
    /^VERSION_STRING=/ { print "VERSION_STRING=\"" version "\""; next }
    { print }
' "$source_script" > "$command_path"
chmod +x "$command_path"

for shell_config in "${shell_configs[@]}"; do
    shell_target="$(resolve_config_target "$shell_config")"
    mkdir -p "$(dirname "$shell_target")"
    touch "$shell_target"
    remove_path_block "$shell_config"
    cat >> "$shell_target" <<EOF

# >>> gitign PATH >>>
$path_block
# <<< gitign PATH <<<
EOF
done

printf 'Installed gitign version %s at %s\n' "$version" "$command_path"
printf 'Restart %s or source %s to use gitign.\n' "$shell_name" "${shell_configs[0]}"
