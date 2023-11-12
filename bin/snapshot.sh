#!/bin/sh

#
# Snapshot utility
#

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"; exit 1
fi

_main() {
  local device=""
  local subvolume=""
  local retention=""
  local tag=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -d|--device) device="$2"; shift 2 ;;
      -s|--subvolume) subvolume="$2"; shift 2 ;;
      -r|--retention) retention="$2"; shift 2 ;;
      -t|--tag) tag="$2"; shift 2 ;;

      --device=*) device="${1#*=}"; shift 1 ;;
      --subvolume=*) subvolume="${1#*=}"; shift 1 ;;
      --retention=*) retention="${1#*=}"; shift 1 ;;
      --tag=*) tag="${1#*=}"; shift 1 ;;

      *) echo "Unknown argument: $1"; exit 1 ;;
    esac
  done

  [ -z "$device" ] && { echo "Device missing"; exit 1; }
  [ -z "$subvolume" ] && { echo "Subvolume missing"; exit 1; }
  [ -z "$retention" ] && { echo "Retention missing"; exit 1; }
  [ -z "$tag" ] && { echo "Tag missing"; exit 1; }

  case $retention in
    ''|*[!0-9]*) echo "Error: Retention must be a positive integer." ; exit 1 ;;
  esac

  directory="$(mktemp -d)"

  _cleanup() {
    umount "$directory"
    rm -rf "$directory"
  }

  trap _cleanup INT TERM EXIT

  mount -o noatime,compress=zstd "/dev/disk/by-uuid/$device" "$directory" || {
    sudo -u caretakr \
      DISPLAY=:0 \
      DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
      notify-send -u critical "Snapshot failed" \
      "Cannot mount ${device} on ${directory}"
    
    exit 1
  }

  btrfs subvolume snapshot -r "${directory}/${subvolume}@live" \
    "${directory}/${subvolume}+snapshots/$(date --utc +%Y%m%dT%H%M%SZ)@${tag}" || {
    sudo -u caretakr \
      DISPLAY=:0 \
      DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
      notify-send -u critical "Snapshot failed" \
      "Cannot snapshot ${subvolume} [${tag}]"
    
    exit 2
  }

  local count=1

  for s in $(find "${directory}/${subvolume}+snapshots/*@${tag}" -maxdepth 0 -type d -printf "%f\n" | sort -nr); do
    if [ "$count" -gt "$retention" ]; then
      btrfs subvolume delete "${directory}/${subvolume}@snapshots/${s}" || {
        sudo -u caretakr \
          DISPLAY=:0 \
          DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
          notify-send -u critical "Snapshot failed" \
          "Cannot delete ${subvolume} [${tag}] (retention)"

        exit 3
      }
    fi

    count=$(($count+1))
  done

  sudo -u caretakr \
    DISPLAY=:0 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    notify-send -u low "Snapshot completed" \
    "Created snapshot for ${subvolume} [${tag}]"

  exit 0
}

_main $@
