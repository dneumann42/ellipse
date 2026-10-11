#!/usr/bin/env bash
set -euo pipefail

OUT="ellipse-gui-tutorial.pdf"
INFILES=(
    "documentation/README.md"
    "documentation/nim-tutorial.md"
    "documentation/owl-tutorial.md"
    "documentation/reference-widgets.md"
)

pandoc "${INFILES[@]}" \
    --pdf-engine=pdflatex \
    --table-of-contents \
    --toc-depth=3 \
    --number-sections \
    --metadata title="Ellipse GUI Tutorial (Nim and Owl)" \
    --metadata author="Ellipse Documentation" \
    --metadata date="$(date +%Y-%m-%d)" \
    -V colorlinks=true \
    -V geometry:margin=1in \
    --highlight-style tango \
    -o "$OUT"
echo "Wrote $OUT"
