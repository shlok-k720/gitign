#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source_script="$script_dir/gitignore.sh"
bin_dir="$HOME/.local/bin"
command_path="$bin_dir/gitign"
zshrc="$HOME/.zshrc"
path_marker="# gitign command"

version_file="$script_dir/VERSION.txt"

if [[ ! -f "$source_script" ]]; then
    printf 'gitign installer: missing %s\n' "$source_script" >&2
    exit 1
fi

if [[ ! -f "$version_file" ]]; then
    printf 'gitign installer: missing %s\n' "$version_file" >&2
    exit 1
fi

version="$(<"$version_file")"
if [[ -z "$version" || "$version" == *$'\n'* || "$version" == *'"'* || "$version" == *'\\'* ]]; then
    printf 'gitign installer: %s must contain one plain version string.\n' "$version_file" >&2
    exit 1
fi

mkdir -p "$bin_dir"

if [[ -e "$command_path" || -L "$command_path" ]]; then
    rm "$command_path"
fi

# Copy the file to the target location instead of creating a symlink.
cp "$source_script" "$command_path"

# Inject the real version string directly into the deployed file
# Works on both Linux and macOS
sed -i.bak -E "s/^(VERSION_STRING=).*/\1\"$version\"/" "$command_path"
rm -f "${command_path}.bak"

chmod +x "$command_path"

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

printf 'Installed gitign version %s at %s\n' "$version" "$command_path"
printf 'Run: source ~/.zshrc\n'
