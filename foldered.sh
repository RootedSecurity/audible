#!/usr/bin/env bash
# Sort .m4b files into Author/Title folders using the tags inside each file,
# moving the matching .jpg alongside as cover.jpg.
#
#   ./foldered.sh [-n] [-f] [--keep-jpg-name] <dir>
#
#   -n              dry run -- print what would happen, change nothing
#   -f              flat: one folder per book instead of Author/Title
#   --keep-jpg-name leave the jpg named after the book, not cover.jpg
#
# Default:   dir/Andy Weir/Project Hail Mary/Project Hail Mary.m4b + cover.jpg
# With -f:   dir/Andy Weir Project Hail Mary/<same name>.m4b + cover.jpg
#
# Author and title come from the file's own artist/title tags, not the
# filename, so names with stripped punctuation still sort correctly.
# Falls back to the filename if a tag is missing.
#
# Safe to re-run: books already in place are skipped.

set -uo pipefail

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe not found (install ffmpeg)" >&2
  exit 1
fi

dry=0
flat=0
keep_jpg=0
target=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) dry=1; shift ;;
    -f) flat=1; shift ;;
    --keep-jpg-name) keep_jpg=1; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \?//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) target="$1"; shift ;;
  esac
done

if [[ -z "$target" ]]; then
  echo "Usage: ./foldered.sh [-n] [-f] [--keep-jpg-name] <dir>" >&2
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

# strip characters that upset SMB / ext4 / Plex, collapse spaces, trim,
# and refuse to end in a dot (Windows shares choke on that)
sanitize() {
  sed -e 's#[/\\]# #g' -e 's/[:*?"<>|]//g' -e 's/  */ /g' \
      -e 's/^ *//' -e 's/ *$//' -e 's/\.*$//' \
    | cut -c1-120
}

tag() {
  ffprobe -v quiet -show_entries "format_tags=$2" -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1
}

moved=0; skipped=0; nocover=0; notag=0

shopt -s nullglob
for m4b in "$target"/*.m4b; do
  base=$(basename "$m4b" .m4b)
  jpg="$target/$base.jpg"

  author=$(tag "$m4b" artist | sanitize)
  title=$(tag "$m4b" title | sanitize)

  if [[ -z "$author" || -z "$title" ]]; then
    echo "[tags?] $base -- missing artist/title tag, using filename"
    notag=$((notag+1))
    author=""
    title="$base"
  fi

  if [[ $flat -eq 1 || -z "$author" ]]; then
    dest="$target/$base"
    newname="$base.m4b"
  else
    dest="$target/$author/$title"
    newname="$title.m4b"
  fi

  if [[ -e "$dest/$newname" ]]; then
    echo "[skip] $base"
    skipped=$((skipped+1))
    continue
  fi

  if [[ $flat -eq 1 || -z "$author" ]]; then
    echo "[move] $base"
  else
    echo "[move] $author / $title"
  fi

  run mkdir -p "$dest"
  run mv -n "$m4b" "$dest/$newname"

  if [[ -f "$jpg" ]]; then
    if [[ $keep_jpg -eq 1 ]]; then
      run mv -n "$jpg" "$dest/${newname%.m4b}.jpg"
    else
      run mv -n "$jpg" "$dest/cover.jpg"
    fi
  else
    echo "    (no cover jpg)"
    nocover=$((nocover+1))
  fi

  moved=$((moved+1))
done
shopt -u nullglob

echo
if [[ $dry -eq 1 ]]; then
  echo "DRY RUN -- nothing changed."
fi
echo "moved=$moved skipped=$skipped without_cover=$nocover untagged=$notag"

if [[ $dry -eq 0 ]]; then
  leftover=$(find "$target" -maxdepth 1 -type f \( -name '*.jpg' -o -name '*.m4b' \) 2>/dev/null | wc -l)
  if [[ "$leftover" -gt 0 ]]; then
    echo "note: $leftover loose file(s) still in $target"
  fi
fi

exit 0
