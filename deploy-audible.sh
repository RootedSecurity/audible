#!/usr/bin/env bash
# ============================================================================
# deploy-audible.sh
#
# One-shot deploy for a fresh Ubuntu box: installs everything audible-cli
# conversion needs and drops convert.sh into ~/bin.
#
# Run as your normal user with sudo rights. Do NOT run as root --
# audible-cli stores its credentials in $HOME.
#
#   chmod +x deploy-audible.sh
#   ./deploy-audible.sh
# ============================================================================

set -euo pipefail

INSTALL_DIR="$HOME/bin"
CONVERT="$INSTALL_DIR/convert.sh"

if [[ $EUID -eq 0 ]]; then
  echo "Run as your normal user, not root. audible-cli config lives in \$HOME." >&2
  exit 1
fi

if ! sudo -v; then
  echo "This script needs sudo." >&2
  exit 1
fi

echo "==> Updating system"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade

echo "==> Installing packages"
sudo DEBIAN_FRONTEND=noninteractive apt-get -y install \
  ffmpeg \
  jq \
  atomicparsley \
  python3 \
  python3-pip \
  python3-venv \
  pipx \
  ca-certificates \
  tmux

echo "==> Installing audible-cli"
pipx ensurepath
pipx install audible-cli 2>/dev/null || pipx upgrade audible-cli
# fast crypto backend -- without this every audible call falls back to
# pure-python pyaes/rsa and crawls
pipx inject audible-cli cryptography 2>/dev/null || true

export PATH="$HOME/.local/bin:$PATH"

echo "==> Preparing directories"
mkdir -p "$INSTALL_DIR" "$HOME/.audible" "$HOME/audiobooks"
chmod 700 "$HOME/.audible"

echo "==> Installing convert.sh"
if [[ -f "$CONVERT" ]]; then
  cp -p "$CONVERT" "$CONVERT.bak"
  echo "  backed up existing to $CONVERT.bak"
fi

cat > "$CONVERT" <<'CONVERT_SCRIPT_EOF'
#!/usr/bin/env bash
# Convert Audible titles to tagged, chaptered .m4b with cover art.
#
#   convert.sh [--profile <name>] <ASIN> <outFile> [--aax]
#   convert.sh [--profile <name>] --all <outDir> [--aax]
#
# --all walks the whole library, names files "Author - Title.m4b",
# skips anything already converted, and keeps going past failures.

for b in ffmpeg ffprobe audible jq AtomicParsley; do
  if ! command -v "$b" >/dev/null 2>&1; then
    echo "Error: missing $b (needs ffmpeg, audible-cli, jq, atomicparsley)" >&2
    exit 1
  fi
done

usage() {
  cat >&2 <<'USAGE_EOF'
Usage:
  convert.sh [--profile <name>] <ASIN> <outFile> [--aax]
  convert.sh [--profile <name>] --all <outDir> [--aax]
USAGE_EOF
}

# --- args ------------------------------------------------------------------
if [[ "${1-}" == "--profile" ]]; then
  profile="${2-}"; arg1="${3-}"; arg2="${4-}"; ext="${5-}"
  cmd=(audible --profile "$profile")
  [[ -z "$profile" ]] && { usage; audible library list; exit 1; }
else
  arg1="${1-}"; arg2="${2-}"; ext="${3-}"
  cmd=(audible)
fi

if [[ -z "$arg1" || -z "$arg2" ]]; then
  usage
  "${cmd[@]}" library list
  exit 1
fi

set -uo pipefail

if [[ "$ext" == "--aax" ]]; then
  aax="--aax-fallback"
else
  aax="--aaxc"
fi

# Podcast / subscription ASINs have no single audio file or chapter data and
# fail in confusing ways. Skipped in --all mode. Add your own here, or set
# AUDIBLE_SKIP_ASINS="B0XXXX B0YYYY" in the environment.
SKIP_ASINS=(B08JJ6FDVQ B08JJN85V9 B08K56YL1R B08K5835MG ${AUDIBLE_SKIP_ASINS-})

sanitize() {
  sed -e 's#[/\\]# #g' -e 's/[:*?"<>|]//g' -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//' \
    | cut -c1-150
}

# FFMETADATA requires \ escaping on = ; # \ and newlines
esc() { sed -e 's/[\\=;#]/\\&/g' -e 's/$/\\/' -e '$ s/\\$//'; }

# --- single book -----------------------------------------------------------
convert_one() {
  local asin="$1" outFile="$2"
  local dir info chapter_txt series_info decrypt key iv copyright cover

  if [[ -e "$outFile" ]]; then
    echo "  exists, skipping: $outFile"
    return 0
  fi

  dir=$(mktemp -d)
  # shellcheck disable=2064
  trap "rm -rf '$dir'" RETURN

  if ! "${cmd[@]}" download -a "$asin" "$aax" --cover --cover-size 1215 \
        --chapter -o "$dir" >/dev/null 2>&1; then
    echo "  FAILED: download" >&2
    return 1
  fi

  if ! compgen -G "$dir"/*.aax* > /dev/null; then
    echo "  FAILED: no audio file (podcast or unavailable title?)" >&2
    return 1
  fi

  info=$("${cmd[@]}" api -p response_groups="media,contributors,series,category_ladders" \
    /1.0/library/"$asin" 2>/dev/null | jq '.item')
  if [[ -z "$info" || "$info" == "null" ]]; then
    echo "  FAILED: could not fetch metadata" >&2
    return 1
  fi

  chapter_txt="$dir/chapters.txt"
  series_info=$(echo "$info" | jq '.series | if (length > 0) then sort_by(.sequence | if . != "" then tonumber else 0 end) | .[-1] else "" end')

  # --- decryption ---
  decrypt=""
  if compgen -G "$dir"/*.voucher > /dev/null; then
    key=$(jq -r '.content_license.license_response.key' < "$dir"/*.voucher)
    iv=$(jq -r '.content_license.license_response.iv' < "$dir"/*.voucher)
    [[ -n "$key" && "$key" != "null" ]] && decrypt="-audible_key $key -audible_iv $iv"
  fi
  if [[ -z "$decrypt" ]]; then
    decrypt="-activation_bytes $("${cmd[@]}" activation-bytes 2>/dev/null)"
  fi

  # shellcheck disable=2086
  copyright=$(ffprobe $decrypt "$dir"/*.aax* 2>&1 | grep -m1 '^ *copyright' | sed 's/^.*: //' || echo "")

  # --- metadata ---
  {
    echo ";FFMETADATA1"
    echo "title=$(echo "$info" | jq -r '.title' | esc)"
    echo "artist=$(echo "$info" | jq -r '.authors | [.[].name] | join(", ")' | esc)"
    echo "composer=$(echo "$info" | jq -r '.narrators | [.[].name] | join(", ")' | esc)"
    echo "year=$(echo "$info" | jq -r '.release_date | sub("-[0-9][0-9]-[0-9][0-9]"; "")')"
    echo "copyright=$(echo "$copyright" | esc)"
    echo "language=$(echo "$info" | jq -r '.language')"
    echo "description=$(echo "$info" | jq -r '.merchandising_summary | gsub("</?[a-z]+>"; "")' | esc)"
    echo "asin=$asin"
    echo "genre=Audiobook"
  } > "$chapter_txt"

  if [[ "$series_info" != '""' ]]; then
    {
      echo "series=$(echo "$series_info" | jq -r '.title' | esc)"
      echo "series-part=$(echo "$series_info" | jq -r '.sequence')"
    } >> "$chapter_txt"
  fi

  jq -r 'def flat:
    reduce .[] as $c ([]; if $c.chapters? then .+[$c | del(.chapters)]+[$c.chapters | flat] else .+[$c] end) | flatten;
      .content_metadata.chapter_info.chapters
      | flat
      | .[] |
"[CHAPTER]
TIMEBASE=1/1000
START=\((.start_offset_ms))
END=\((.start_offset_ms + .length_ms))
title=\((.title))
"' < "$dir"/*.json >> "$chapter_txt" 2>/dev/null

  # --- remux: audio + chapters only ---
  # Do NOT map the cover here. The ipod muxer drops attached_pic when a
  # chapter text track is present and faststart runs its second pass.
  # AtomicParsley writes the covr atom afterward instead, which is what
  # audiobook players actually read.
  # shellcheck disable=2086
  if ! ffmpeg -nostdin -loglevel error -y $decrypt \
      -i "$dir"/*.aax* -i "$chapter_txt" \
      -map 0:a -map_metadata 1 -map_chapters 1 \
      -c:a copy \
      -movflags +faststart+use_metadata_tags \
      -metadata:s:a language="$(echo "$info" | jq -r '.language[0:3]')" \
      "$outFile"; then
    echo "  FAILED: ffmpeg" >&2
    rm -f "$outFile"
    return 1
  fi

  # --- cover art ---
  cover=$(ls "$dir"/*.jpg 2>/dev/null | head -n1)
  if [[ -n "$cover" ]]; then
    if AtomicParsley "$outFile" --artwork "$cover" --overWrite >/dev/null 2>&1; then
      cp "$cover" "${outFile%.*}.jpg"
    else
      echo "  WARN: cover embed failed" >&2
    fi
  else
    echo "  WARN: no cover downloaded" >&2
  fi

  local chaps art
  chaps=$(ffprobe -hide_banner -show_chapters -of json "$outFile" 2>/dev/null | jq '.chapters | length')
  art="no"
  AtomicParsley "$outFile" -t 2>/dev/null | grep -qi 'covr' && art="yes"
  echo "  ok: $(du -h "$outFile" | cut -f1), ${chaps} chapters, cover=${art}"
}

# --- dispatch --------------------------------------------------------------
if [[ "$arg1" == "--all" ]]; then
  outDir="$arg2"
  mkdir -p "$outDir"

  echo "Fetching library..."
  mapfile -t lines < <("${cmd[@]}" library list 2>/dev/null)
  echo "${#lines[@]} titles found"
  echo

  ok=0; skip=0; fail=0
  for line in "${lines[@]}"; do
    asin="${line%%:*}"
    rest="${line#*: }"
    [[ -z "$asin" || "$asin" == "$line" ]] && continue

    if [[ " ${SKIP_ASINS[*]} " == *" $asin "* ]]; then
      echo "[$asin] skipping (podcast/subscription)"
      skip=$((skip+1)); continue
    fi

    name=$(echo "$rest" | sanitize)
    outFile="$outDir/${name}.m4b"

    if [[ -e "$outFile" ]]; then
      skip=$((skip+1)); continue
    fi

    echo "[$asin] $name"
    if convert_one "$asin" "$outFile"; then
      ok=$((ok+1))
    else
      fail=$((fail+1))
    fi
  done

  echo
  echo "Done. converted=$ok skipped=$skip failed=$fail"
  echo "Output: $outDir"
else
  case "$arg2" in
    *.m4b|*.m4a|*.mp4) ;;
    *) echo "Error: outFile should end in .m4b (got: $arg2)" >&2; exit 1 ;;
  esac
  echo "[$arg1]"
  convert_one "$arg1" "$arg2"
fi
CONVERT_SCRIPT_EOF

chmod +x "$CONVERT"
echo "  installed $CONVERT"

echo "==> Verifying"
fail=0
for b in ffmpeg ffprobe jq AtomicParsley audible; do
  if command -v "$b" >/dev/null 2>&1; then
    printf '  ok   %-14s %s\n' "$b" "$(command -v "$b")"
  else
    printf '  MISS %s\n' "$b"
    fail=1
  fi
done
[[ -x "$CONVERT" ]] && printf '  ok   %-14s %s\n' "convert.sh" "$CONVERT"

if [[ $fail -ne 0 ]]; then
  echo
  echo "Some tools are missing -- check the apt/pipx output above." >&2
  exit 1
fi

if ! bash -n "$CONVERT"; then
  echo "convert.sh failed syntax check" >&2
  exit 1
fi

cat <<'NEXT_EOF'

============================================================
Install complete.
============================================================

1. Open a new shell (or: export PATH="$HOME/.local/bin:$HOME/bin:$PATH")

2. Authenticate -- needs your Amazon login, cannot be scripted:

     audible quickstart

   - profile name: anything; this is what --profile takes
   - country code: your Audible marketplace (us, uk, de, ...)
   - encrypt auth file: NO, if you want unattended runs
   - external browser: YES on a headless box

   It prints an Amazon sign-in URL. Open it in a browser anywhere,
   log in, and when the final page fails to load copy that full URL
   from the address bar and paste it back at the prompt.

3. Verify:

     audible library list
     chmod 600 ~/.audible/*.json

   Those files are a long-lived session for your Amazon account.
   Don't back them up or copy them off this box.

4. Test one short title first:

     convert.sh <ASIN> ~/audiobooks/test.m4b

5. Then the whole library, inside tmux so an SSH drop doesn't kill it:

     tmux new -s audible
     convert.sh --all ~/audiobooks

   Re-running skips anything already converted, so it is safe to
   interrupt and resume.

Output lands in ~/audiobooks as "Author - Title.m4b" plus a matching
.jpg sidecar. Budget roughly 350MB per 6-hour book.
NEXT_EOF
