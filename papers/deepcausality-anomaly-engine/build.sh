#!/usr/bin/env bash
# Build the paper PDF with MacTeX (TeX Live). Self-contained: prepends texbin to PATH.
set -euo pipefail
cd "$(dirname "$0")"

export PATH="/Library/TeX/texbin:$PATH"

DOC=main
echo ">> latexmk ($(latexmk --version 2>/dev/null | head -1))"
# -pdf: pdflatex; latexmk runs bibtex + reruns as needed.
latexmk -pdf -interaction=nonstopmode -halt-on-error -file-line-error "$DOC.tex"

echo ">> built: $(pwd)/$DOC.pdf"
