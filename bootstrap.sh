#!/usr/bin/env bash
# bootstrap.sh
# Creates the GitHub repo under patobytes/zammad-azure-deploy and pushes.
# Requires: gh CLI (https://cli.github.com) authenticated with your account.
set -euo pipefail

REPO="patobytes/zammad-azure-deploy"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Checking gh CLI..."
if ! command -v gh &>/dev/null; then
  echo "ERROR: gh CLI not found. Install from https://cli.github.com and run 'gh auth login'."
  exit 1
fi

echo "Creating repo $REPO (private)..."
gh repo create "$REPO" \
  --private \
  --description "Bicep deployment for Zammad on Azure App Service + PostgreSQL + Redis" \
  --confirm 2>/dev/null || echo "(repo may already exist, continuing)"

cd "$DIR"

if [ ! -d .git ]; then
  git init
  git branch -M main
fi

git remote remove origin 2>/dev/null || true
git remote add origin "https://github.com/$REPO.git"

git add .
git commit -m "chore: initial Zammad Azure deployment templates" --allow-empty

echo "Pushing to $REPO..."
git push -u origin main --force

echo ""
echo "Done. Your repo: https://github.com/$REPO"
echo ""
echo "Next steps:"
echo "  1. cd into this directory"
echo "  2. Run: claude"
echo "  3. Tell Claude Code: 'Deploy Zammad to Azure following CLAUDE.md'"
