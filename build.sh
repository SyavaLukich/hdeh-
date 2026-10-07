#!/bin/sh
# Сборка одной командой, без make.
set -e
mkdir -p build/units
fpc -O3 -OoFASTMATH -Xs -XX -CX -Fu src -FU build/units -FE build -oengine3d src/main.pas
echo "готово: build/engine3d"
