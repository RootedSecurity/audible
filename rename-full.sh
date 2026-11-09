#!/usr/bin/env bash
# Rename the .m4b inside each folder back to the full "Author Series Title"
# form, leaving the Author/Title folder structure alone.
#
#   ./rename-full.sh [-n] [--rename-cover] <dir>
#
#   -n              dry run -- print what would happen, change nothing
#   --rename-cover  also rename cover.jpg to match the book
#
# Before:  Dennis E. Taylor/Heaven's River/Heaven's River.m4b
# After:   Dennis E. Taylor/Heaven's River/Dennis E. Taylor Bobiverse Heaven's River.m4b
#
# The new name is rebuilt from the file's own artist / series / title tags,
# so it does not depend on the current filename. Safe to re-run.

set -uo pipefail

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe not found (install ffmpeg)" >&2
  exit 1
fi

dry=0
rename_cover=0
target=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) dry=1; shift ;;
    --rename-cover) rename_cover=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) target="$1"; shift ;;
  esac
done

if [[ -z "$target" ]]; then
  echo "Usage: ./rename-full.sh [-n] [--rename-cover] <dir>" >&2
  exit 1
fi

if [[ ! -d "$target" ]]; then
  echo "Not a directory: $target" >&2
  exit 1
fi

run() {
  if [[ $dry -eq 1 ]]; then
    printf '    %s\n' "$*"
  else
    "$@"
  fi
}

sanitize() {
  sed -e 's#[/\\]# #g' -e 's/[:*?"<>|]//g' -e 's/  */ /g' \
      -e 's/^ *//' -e 's/ *$//' -e 's/\.*$//' \
    | cut -c1-150
}

tag() {
  ffprobe -v quiet -show_entries "format_tags=$2" -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1
}

renamed=0; already=0; notag=0

while IFS= read -r -d '' m4b; do
  dir=$(dirname "$m4b")
  cur=$(basename "$m4b")

  author=$(tag "$m4b" artist)
  series=$(tag "$m4b" series)
  title=$(tag "$m4b" title)

  if [[ -z "$author" || -z "$title" ]]; then
    echo "[tags?] $cur -- missing artist/title, leaving alone"
    notag=$((notag+1))
    continue
  fi

  if [[ -n "$series" ]]; then
    newbase=$(printf '%s %s %s' "$author" "$series" "$title" | sanitize)
  else
    newbase=$(printf '%s %s' "$author" "$title" | sanitize)
  fi

  if [[ "$cur" == "$newbase.m4b" ]]; then
    already=$((already+1))
    continue
  fi

  echo "[rename] $newbase"
  run mv -n "$m4b" "$dir/$newbase.m4b"

  if [[ $rename_cover -eq 1 && -f "$dir/cover.jpg" ]]; then
    run mv -n "$dir/cover.jpg" "$dir/$newbase.jpg"
  fi

  renamed=$((renamed+1))
done < <(find "$target" -type f -name '*.m4b' -print0)

echo
if [[ $dry -eq 1 ]]; then
  echo "DRY RUN -- nothing changed."
fi
echo "renamed=$renamed already_correct=$already untagged=$notag"

exit 0
