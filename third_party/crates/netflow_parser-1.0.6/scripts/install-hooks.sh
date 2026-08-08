#!/bin/bash
# Install Git hooks for README sync checking

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🔧 Installing Git hooks..."

# Check if we're in a git repository
if [ ! -d .git ]; then
    echo "Error: Not in a git repository root"
    exit 1
fi

# Create hooks directory if it doesn't exist
mkdir -p .git/hooks

# Install pre-commit hook
if [ -f .git/hooks/pre-commit ]; then
    echo -e "${YELLOW}⚠${NC}  Pre-commit hook already exists"
    echo "   Backing up to .git/hooks/pre-commit.backup"
    cp .git/hooks/pre-commit .git/hooks/pre-commit.backup
fi

echo "📝 Installing pre-commit hook..."
cp scripts/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit

echo
echo -e "${GREEN}✓ Git hooks installed successfully!${NC}"
echo
echo "Installed hooks:"
echo "  • pre-commit - Enforces README/lib.rs sync and doc tests"
echo
echo "The pre-commit hook will:"
echo "  1. Run './scripts/check-readme-sync.sh' on doc file changes"
echo "  2. Fail the commit if sync check fails"
echo "  3. Show detailed output to help you fix issues"
echo
echo "To skip hooks for a commit (not recommended):"
echo "  git commit --no-verify"
echo
echo "To uninstall:"
echo "  rm .git/hooks/pre-commit"
