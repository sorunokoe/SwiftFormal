#!/usr/bin/env bash
# Installs the optional pre-commit hook (Scripts/hooks/pre-commit) and the blame setting. Never required: CI is the authority.
# Remove it with: rm .git/hooks/pre-commit
set -euo pipefail
cd "$(dirname "$0")/.."
hooks=$(git rev-parse --git-path hooks)
mkdir -p "$hooks"
cp Scripts/hooks/pre-commit "$hooks/pre-commit"
chmod +x "$hooks/pre-commit"
git config blame.ignoreRevsFile .git-blame-ignore-revs
echo "installed $hooks/pre-commit and blame.ignoreRevsFile"
