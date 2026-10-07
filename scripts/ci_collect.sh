#!/usr/bin/env bash
# Collects render output produced by the demos into devlog/ so that the
# build report can carry real rendered frames with it.
# Every step is optional: missing binaries or tools are skipped.
set -u

OUT=devlog
SHOTS=$OUT/frames
mkdir -p "$SHOTS"

have() { command -v "$1" >/dev/null 2>&1; }

log() { echo "[collect] $*"; }

# --- headless frames from the terminal demo -------------------------------
if [ -x bin/demo_terminal ]; then
  log "terminal demo: headless text frames"
  bin/demo_terminal --headless --frames 8 --scene 1 --dump-text "$SHOTS/tui" \
    > "$OUT/terminal_demo.log" 2>&1
  echo "exit=$?" >> "$OUT/terminal_demo.log"

  log "terminal demo: pixel frames -> png"
  bin/demo_terminal --headless --frames 3 --size 160x100 --scene 1 \
    --dump-ppm "$SHOTS/demo" >> "$OUT/terminal_demo.log" 2>&1
  echo "exit=$?" >> "$OUT/terminal_demo.log"

  log "terminal demo: run inside a pty for 60 frames"
  if have script; then
    script -q -c "bin/demo_terminal --frames 60 --scene 1 --stats-out $OUT/tui_stats.txt" /dev/null \
      > "$SHOTS/pty_capture.out" 2>&1
    log "pty run exit=$?"
  fi
fi

# --- frames from the SDL demo (dummy video driver) ------------------------
if [ -x bin/demo_sdl ]; then
  log "sdl demo: offscreen frames"
  SDL_VIDEODRIVER=dummy bin/demo_sdl --frames 3 --size 320x200 --scene 1 \
    --dump-ppm "$SHOTS/sdl" > "$OUT/sdl_demo.log" 2>&1
  echo "exit=$?" >> "$OUT/sdl_demo.log"
fi

# --- ppm -> png ----------------------------------------------------------
if have convert; then
  for f in "$SHOTS"/*.ppm; do
    [ -e "$f" ] || continue
    convert "$f" "${f%.ppm}.png" 2>/dev/null && log "converted $(basename "$f")"
  done
fi

ls -la "$SHOTS" 2>/dev/null || true
