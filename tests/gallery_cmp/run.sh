#!/bin/sh
# Gallery parity: apps/gallery.nim and apps/owl-gallery run the same
# interaction script (script.nim) headless, in a window tall enough to show
# the whole page, and every screenshot must be byte-identical.
# Run from the repo root: make gallery_parity
set -e
root=$(pwd)
work=${TMPDIR:-/tmp}/ellipse-gallery-parity
rm -rf "$work"
mkdir -p "$work/nim" "$work/owl" "$work/build"
cp -r apps/gallery "$work/build/"
sed -e 's|^import gallery/memberform$|import gallery/memberform\nimport std/envvars\ninclude "'"$root"'/tests/gallery_cmp/script.nim"|' \
    -e 's|  run App(window: WindowConfig(title: "Widget Gallery"), prepare: prepare,|  try:\n    shotDir = getEnv("GALLERY_SHOTS")\n  except:\n    discard\n  run(App(window: WindowConfig(title: "Widget Gallery", height: 2700), prepare: prepare,|' \
    -e 's|          setup: setup, view: view)$|          setup: setup, view: view), sequence)|' \
    apps/gallery.nim > "$work/build/gallery_cmp.nim"
cp -r apps/owl-gallery "$work/owlg"
sed -i 's/^run-app (title = "Widget Gallery"):/run-app (title = "Widget Gallery") (height = 2700):/' "$work/owlg/src/main.owl"
./build/nimony/bin/nimony --outdir:"$work/build/out" -p:src -p:src/clay c "$work/build/gallery_cmp.nim" > /dev/null
./build/nimony/bin/nimony --outdir:bin/ -p:src c ./tests/gallery_cmp/owl_driver.nim > /dev/null
GALLERY_SHOTS="$work/nim" SDL_VIDEODRIVER=offscreen "$work/build/out/gallery_cmp" > /dev/null 2>&1
GALLERY_PROJECT="$work/owlg" GALLERY_SHOTS="$work/owl" SDL_VIDEODRIVER=offscreen ./bin/owl_driver > /dev/null 2>&1
fail=0
count=0
for f in "$work"/nim/*.bmp; do
  n=$(basename "$f")
  count=$((count + 1))
  if ! cmp -s "$f" "$work/owl/$n"; then
    echo "DIFFERS: $n"
    fail=1
  fi
done
if [ "$count" -eq 0 ]; then
  echo "gallery parity: no screenshots were taken"
  exit 1
fi
if [ "$fail" -eq 0 ]; then
  echo "gallery parity OK ($count states identical)"
else
  exit 1
fi
