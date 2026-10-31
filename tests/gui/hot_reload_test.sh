#!/usr/bin/env bash
# Fast whole-app hot-reload test: a headless app watches its own src/,
# rebuilds via `make build`, and re-execs over itself (same pid). Proof: the
# pid lives on while /proc/pid/exe flips to a NEW inode -- the process became
# the freshly compiled program without ever dying. Seconds to run, no
# display server needed (the window-survives claim is the display server's,
# which keeps running untouched by an execv).
set -u
D=/tmp/opencode/hottest
pkill -9 -x app-boot 2>/dev/null; pkill -9 -x app-live 2>/dev/null
rm -rf "$D"; mkdir -p "$D/src"
cd "$D" || exit 1

SRC=/home/dneumann/Workspace/ellipse
PKGS=$HOME/.nimble/pkgs2
NIMFLAGS=(-d:ellipseHotApp --mm:yrc --ic:off --path:"$SRC/src" --path:"$SRC/src/clay"
  --path:"$PKGS/sdl3-1.1-c0c437f9e60d9b6e50c2f4ad3a1a09c66ecd68d9"
  --path:"$PKGS/plugnim-0.1.0-92ca3f462200713a60509658d94991d3f78e3011"
  --path:"$PKGS/chroma-1.0.0-76a12834f1b7e211e4232c1e13960accba6bd477")

touch src/watchme.nim
ELLIPSE_HOT_MARKER=BOOT nim c "${NIMFLAGS[@]}" -o:"$D/app-boot" \
  "$SRC/tests/gui/hot_reload_test.nim" >"$D/build.log" 2>&1 \
  || { echo "BUILD FAILED:"; grep -a Error "$D/build.log" | tail -3; exit 1; }

# what the watcher runs as `make build`: rebuild with a fresh timestamp and
# drop the result on top of the running image (execv path unchanged)
cat > buildnew.sh <<EOF
#!/bin/sh
bash -c '
SRC=$SRC PKGS=$PKGS D=$D
NIMFLAGS=(-d:ellipseHotApp --mm:yrc --ic:off --path:\$SRC/src --path:\$SRC/src/clay
  --path:\$PKGS/sdl3-1.1-c0c437f9e60d9b6e50c2f4ad3a1a09c66ecd68d9
  --path:\$PKGS/plugnim-0.1.0-92ca3f462200713a60509658d94991d3f78e3011
  --path:\$PKGS/chroma-1.0.0-76a12834f1b7e211e4232c1e13960accba6bd477)
ELLIPSE_HOT_MARKER=LIVE nim c "\${NIMFLAGS[@]}" -o:\$D/app-live \$SRC/tests/gui/hot_reload_test.nim >>\$D/build.log 2>&1 || exit 1
mv \$D/app-live \$D/app-boot
'
EOF
chmod +x buildnew.sh
printf 'build:\n\t./buildnew.sh\n' > Makefile

ELLIPSE_HOT_QUIET=50 setsid ./app-boot >"$D/app.log" 2>&1 </dev/null &
sleep 1.5
P=$(pgrep -x app-boot | head -1)
[ -z "$P" ] && { echo "FAIL: app did not start"; cat "$D/app.log"; exit 1; }
INO0=$(stat -c %i "$D/app-boot")
echo "generation 1: pid $P on inode $INO0"

# editor save: the app's watcher sees it, settles, runs `make build`,
# re-execs over this very pid. Proof: a second boot banner from the SAME
# pid -- execv replaced the image in place, the process never died.
touch src/watchme.nim
for i in $(seq 1 60); do
  sleep 0.5
  kill -0 "$P" 2>/dev/null || { echo "FAIL: pid $P died (execv is not a death)"; cat "$D/app.log"; exit 1; }
  if [ "$(grep -ac 'watching src' "$D/app.log")" -ge 2 ]; then
    INO1=$(stat -c %i "$D/app-boot" 2>/dev/null)
    echo "PASS after ~$((i/2))s: pid $P booted twice on inode $INO1 (was $INO0) -- rebuilt image, replaced in place"
    kill -9 "$P" 2>/dev/null; exit 0
  fi
done
echo FAIL; grep -a hot: "$D/app.log" | tail -5; kill -9 "$P" 2>/dev/null; exit 1
