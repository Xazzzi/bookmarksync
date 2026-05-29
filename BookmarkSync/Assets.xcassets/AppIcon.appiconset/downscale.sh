#!/bin/bash
SOURCE=$1
DIR=$(dirname "$SOURCE")
SIZES=(16 32 64 128 256 512 1024)
if [ ! -f "$SOURCE" ]; then
  echo "Error: Source file $SOURCE not found."
  exit 1
fi
for SIZE in "${SIZES[@]}"; do
  TARGET="$DIR/icon_${SIZE}x${SIZE}.png"
  magick "$SOURCE" -colorspace sRGB -filter Lanczos -resize "${SIZE}x${SIZE}" "$TARGET"
done
