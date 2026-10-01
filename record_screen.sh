#!/bin/bash
set -euo pipefail

# Save recordings in videos/<student_id>_<quiz><quiz_id>_<video_number>.mp4

install_commands=()
if ! command -v brew >/dev/null 2>&1; then
  install_commands+=( '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' )
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  install_commands+=( 'brew install ffmpeg' )
elif ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -Eq '[[:space:]]libx264([[:space:]]|$)'; then
  install_commands+=( 'brew reinstall ffmpeg' )
fi
if [[ ${#install_commands[@]} -gt 0 ]]; then
  echo >&2
  echo "SETUP NEEDED" >&2
  echo "1. Open the Terminal app on your Mac." >&2
  echo "2. Copy each command below, paste it into Terminal, and press Return." >&2
  echo "   Wait for each command to finish before running the next one." >&2
  echo >&2
  for i in "${!install_commands[@]}"; do
    printf 'Command %d:\n%s\n\n' "$((i + 1))" "${install_commands[$i]}" >&2
  done
  echo "3. When finished, come back here and run: ./record_screen.sh" >&2
  echo >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
video_dir="$script_dir/videos"
settings_file="$script_dir/settings.conf"

list_video_devices() {
  local device_output
  device_output="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i '' 2>&1 || true)"
  printf '%s\n' "$device_output" | awk '
    /AVFoundation video devices:/ { in_video = 1; next }
    /AVFoundation audio devices:/ { in_video = 0 }
    in_video && match($0, /\[[0-9]+\]/) {
      device_index = substr($0, RSTART + 1, RLENGTH - 2)
      device_name = substr($0, RSTART + RLENGTH)
      sub(/^[[:space:]]+/, "", device_name)
      printf "%s\t%s\n", device_index, device_name
    }
  '
}

choose_video_device() {
  local video_devices available_index available_name
  video_devices="$(list_video_devices)"
  if [[ -z "$video_devices" ]]; then
    echo "No AVFoundation video devices were found. Check macOS recording permissions." >&2
    return 1
  fi

  echo "Available AVFoundation video devices:"
  while IFS=$'\t' read -r available_index available_name; do
    printf '  %s) %s\n' "$available_index" "$available_name"
  done <<< "$video_devices"

  while true; do
    read -r -p "Enter the device number to use: " device_index
    if [[ "$device_index" =~ ^[0-9]+$ ]] && printf '%s\n' "$video_devices" | cut -f1 | grep -Fxq "$device_index"; then
      return 0
    fi
    echo "Choose one of the device numbers listed above." >&2
  done
}

if [[ ! -f "$settings_file" ]]; then
  echo "First-time setup"
  read -r -p "Student ID: " student_id
  if [[ ! "$student_id" =~ ^[[:alnum:]]+$ ]]; then
    echo "Student ID must contain only letters and numbers." >&2
    exit 2
  fi
  choose_video_device
  {
    printf 'student_id=%s\n' "$student_id"
    printf 'device_index=%s\n' "$device_index"
  } > "$settings_file"
  echo "Settings saved to: $settings_file"
else
  student_id="$(sed -n 's/^student_id=//p' "$settings_file" | head -n 1)"
  device_index="$(sed -n 's/^device_index=//p' "$settings_file" | head -n 1)"
  if [[ ! "$student_id" =~ ^[[:alnum:]]+$ || ! "$device_index" =~ ^[0-9]+$ ]]; then
    echo "Settings file is invalid: $settings_file" >&2
    echo "Delete it and run the script again to repeat first-time setup." >&2
    exit 1
  fi

  read -r -p "Use saved camera $device_index? [Y/n] " use_saved_device
  if [[ "$use_saved_device" =~ ^[Nn]$ ]]; then
    choose_video_device
  fi
fi

read -r -p "Quiz type (e.g. exam): " quiz
read -r -p "Quiz ID (e.g. 1): " quiz_id
if [[ ! "$quiz" =~ ^[[:alnum:]]+$ ]]; then
  echo "Quiz type must contain only letters and numbers (for example, exam1)." >&2
  exit 2
fi
if [[ ! "$quiz_id" =~ ^[[:alnum:]]+$ ]]; then
  echo "Quiz ID must contain only letters and numbers." >&2
  exit 2
fi

mkdir -p "$video_dir"
name_prefix="${student_id}_${quiz}${quiz_id}_"
recording_index=0
while true; do
  output="$video_dir/${name_prefix}${recording_index}.mp4"
  reservation="$video_dir/.${name_prefix}${recording_index}.lock"
  if [[ ! -e "$output" ]] && mkdir "$reservation" 2>/dev/null; then
    break
  fi
  recording_index=$((recording_index + 1))
done
trap 'rmdir "$reservation" 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '\n+------------------------------------------------------------+\n'
printf '|                    RECORDING CURRENT CONFIG               |\n'
printf '+------------------------------------------------------------+\n'
printf '| Camera: %s\n' "$device_index"
printf '| Saving to: %s\n' "$output"
printf '+------------------------------------------------------------+\n'
printf '| To stop and save: press q in this Terminal window.       |\n'
printf '| Keep this window open until FFmpeg finishes saving.      |\n'
printf '+------------------------------------------------------------+\n\n'

printf '+============================================================+\n'
printf '|             PRESS ENTER TO START RECORDING                 |\n'
printf '+============================================================+\n'
read -r -p 'Press Enter when you are ready... ' _

if ffmpeg -f avfoundation -pixel_format uyvy422 -probesize 40M -i "$device_index" \
  -r 2 -vcodec libx264 -b:v 256k -threads 1 "$output"; then
  printf '\n+------------------------------------------------------------+\n'
  printf '| RECORDING SAVED                                           |\n'
  printf '+------------------------------------------------------------+\n'
  printf 'File: %s\n' "$output"
else
  ffmpeg_status=$?
  printf '\nRecording failed (FFmpeg exit code %d).\n' "$ffmpeg_status" >&2
  printf 'Check the FFmpeg messages above. Output, if created: %s\n' "$output" >&2
  exit "$ffmpeg_status"
fi
