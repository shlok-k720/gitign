#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/release.sh VERSION [--tag]

Validate VERSION, write it to VERSION.txt and VERSION_STRING in gitignore.sh.
With --tag, commit those files and create an annotated vVERSION tag.
EOF
}

if (($# == 0)); then
    usage >&2
    exit 2
fi

version="${1#v}"
shift
create_tag=false
while (($#)); do
    case "$1" in
        --tag) create_tag=true ;;
        --help) usage; exit 0 ;;
        *) printf 'release: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] \
    || { printf 'release: "%s" is not a semantic version.\n' "$version" >&2; exit 2; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"

if "$create_tag" && [[ -n "$(git status --porcelain)" ]]; then
    printf 'release: commit or stash existing changes before creating a tag.\n' >&2
    exit 1
fi
if "$create_tag" && git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
    printf 'release: tag v%s already exists.\n' "$version" >&2
    exit 1
fi

printf '%s\n' "$version" > VERSION.txt
temporary_file="$(mktemp gitignore.sh.release.XXXXXX)"
awk -v version="$version" '
    /^VERSION_STRING=/ { print "VERSION_STRING=\"" version "\""; next }
    { print }
' gitignore.sh > "$temporary_file"
mv "$temporary_file" gitignore.sh
chmod +x gitignore.sh

if "$create_tag"; then
    git add VERSION.txt gitignore.sh
    git commit -m "Release v$version"
    git tag -a "v$version" -m "Release v$version"
    printf 'Created commit and tag v%s. Push with: git push origin main --tags\n' "$version"
else
    printf 'Updated VERSION.txt and gitignore.sh to %s.\n' "$version"
fi
