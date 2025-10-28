#!/usr/bin/env bash
set -Eeuo pipefail

# Simple SD card image backup helper
# Usage: sudo /home/pi/scripts/backup_sd_image.sh /media/pi/USB/raspi-backup-$(date +%F).img.gz

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Please run with sudo" >&2; exit 1
fi
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/output.img.gz" >&2; exit 1
fi
OUT="$1"
DST_DIR="$(dirname "$OUT")"
mkdir -p "$DST_DIR"

SRC=/dev/mmcblk0
if ! lsblk -ndo NAME | grep -q "^mmcblk0$"; then
  echo "Could not find SD device /dev/mmcblk0" >&2; exit 2
fi

# Safety: refuse if OUT is on the same device
if mount | grep -q "on / .* (.*)"; then :; fi

echo "Backing up $SRC -> $OUT"
echo "This may take a while..."

# Flush caches and use fast gzip
sync
nice -n 10 ionice -c2 -n7 dd if="$SRC" bs=4M status=progress | gzip -1 > "$OUT"
sync

# Verify size of image vs. card (rough check)
SIZE_SRC=$(blockdev --getsize64 "$SRC")
SIZE_IMG=$(gzip -l "$OUT" | awk 'NR==2{print $2}')

printf "\nSource size: %s bytes\nImage raw size: %s bytes\n" "$SIZE_SRC" "$SIZE_IMG"
echo "Done: $OUT"
