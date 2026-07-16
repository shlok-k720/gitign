#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source_script="$script_dir/gitignore.sh"
bin_dir="$HOME/.local/bin"
command_path="$bin_dir/gitign"
zshrc="$HOME/.zshrc"
path_marker="# gitign command"

if [[ ! -f "$source_script" ]]; then
    printf 'gitign installer: missing %s\n' "$source_script" >&2
    exit 1
fi

if [[ -e "$command_path" && ! -L "$command_path" ]]; then
    printf 'gitign installer: %s already exists and is not a symlink.\n' "$command_path" >&2
    exit 1
fi

mkdir -p "$bin_dir"
chmod +x "$source_script"
ln -sfn "$source_script" "$command_path"

touch "$zshrc"
if ! grep -Fqx -- "$path_marker" "$zshrc"; then
    cat >> "$zshrc" <<'EOF'

# gitign command
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
EOF
fi

printf 'Installed gitign version %s at %s\n' "$(cat "$script_dir/VERSION")" "$command_path"
printf 'Run: source ~/.zshrc\n'
