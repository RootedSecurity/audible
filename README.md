# audible-m4b

Converts audiobooks from your own Audible account into tagged, chaptered
`.m4b` files with cover art, ready for Audiobookshelf, Plex, Apple Books,
or anything else that plays m4b.

One deploy script sets up a fresh Ubuntu box and installs the converter.

## Requirements

- Ubuntu (22.04 or newer; tested on 24.04)
- A normal user account with sudo
- An Audible account — this only works on books you own
- ~350MB of disk per 6-hour book (a 75-book library runs about 50GB)

## What's here

- `deploy-audible.sh` — sets up a fresh box and installs the converter
- `foldered.sh` — sorts converted files into `Author/Title/` folders

## Install

```
chmod +x deploy-audible.sh
./deploy-audible.sh
```

Run it as your normal user, **not** as root. audible-cli keeps its
credentials in `$HOME`, and running as root puts them in `/root`.

The script will:

- update the system
- install ffmpeg, jq, atomicparsley, pipx, tmux
- install `audible-cli` via pipx, with the `cryptography` backend injected
  (without it, every audible command falls back to pure-Python crypto and
  crawls)
- create `~/bin`, `~/.audible` (mode 700), and `~/audiobooks`
- write `convert.sh` to `~/bin/convert.sh`, backing up any existing copy
  to `convert.sh.bak`
- verify every binary and syntax-check the installed script

## Authenticate

This part can't be scripted — it needs your Amazon login.

```
audible quickstart
```

Answers that matter:

- **profile name** — anything; this is what `--profile` takes later
- **country code** — your Audible marketplace (`us`, `uk`, `de`, ...)
- **encrypt auth file** — say **no** if you want unattended runs; yes means
  a password prompt on every single command
- **external browser** — say **yes** on a headless box

It prints an Amazon sign-in URL. Open it in a browser on any machine, log
in, and when the final page fails to load, copy that full URL out of the
address bar and paste it back at the prompt. The failing page is expected —
the authorization code is in the URL, which is what gets exchanged for
tokens.

The browser does not need to be on the same machine or network as the
server.

Then verify and lock down:

```
audible library list
chmod 600 ~/.audible/*.json
```

Those JSON files are a long-lived session for your Amazon account. Don't
back them up, don't copy them off the box, don't commit them.

## Usage

Open a new shell first so `~/bin` and `~/.local/bin` are on PATH.

**One book:**

```
convert.sh <ASIN> ~/audiobooks/book.m4b
```

ASINs come from `audible library list` — the code in the first column.

**Whole library:**

```
tmux new -s audible
convert.sh --all ~/audiobooks
```

Use tmux or screen. The download step is slow and an SSH drop would kill
the run otherwise.

Re-running skips anything already converted, so it's safe to interrupt and
resume.

**Multiple accounts:**

```
convert.sh --profile <name> <ASIN> out.m4b
convert.sh --profile <name> --all ~/audiobooks
```

**Older titles:** if a download fails, add `--aax` as the last argument to
fall back to the older AAX format and activation-bytes decryption.

## Output

Files land as `Author Title.m4b` with a matching `.jpg` alongside.
Characters that upset SMB, ext4, or Plex are stripped from names, and
length is capped at 150 chars.

Each file carries:

- title, author (artist), narrator (composer), year, copyright, language
- the full chapter list with real timestamps
- series name and number, when the book is part of one
- the book description and ASIN
- cover art at 1215x1215, embedded in the `covr` atom

Audio is **copied, not re-encoded**. Audible already ships AAC, so the
conversion is lossless and takes seconds rather than minutes.

## Sorting into folders

`convert.sh` writes everything flat into one directory. `foldered.sh` sorts
it into `Author/Title/` folders, which is what Audiobookshelf and Plex
expect:

```
chmod +x foldered.sh
./foldered.sh -n ~/audiobooks    # dry run, change nothing
./foldered.sh ~/audiobooks       # do it
```

Result:

```
Dennis E. Taylor/
  We Are Legion (We Are Bob)/
    We Are Legion (We Are Bob).m4b
    cover.jpg
  Heaven's River/
    ...
```

Author and title come from each file's own `artist` and `title` tags, not
from the filename. That matters: filenames have had `:` and other
characters stripped for filesystem safety, so parsing them gives you
`Frank Herbert Dune, The Dune Sequence Dune` with no reliable way to find
the boundary. The tags have the real values — `Frank Herbert` / `Dune` —
including any Unicode the filename lost.

Options:

- `-n` — dry run
- `-f` — flat: one folder per book instead of `Author/Title`
- `--keep-jpg-name` — leave the jpg named after the book instead of
  `cover.jpg`

Safe to re-run; books already in place are skipped, and it never
overwrites. Anything missing tags falls back to its filename and is
counted as `untagged` in the summary so you can spot it.

## Skipping podcasts

Audible podcast and subscription entries show up in `library list` but have
no single audio file or chapter data, so they fail in confusing ways. Four
common ones are skipped by default. Add your own without editing the
script:

```
AUDIBLE_SKIP_ASINS="B0XXXXXXXX B0YYYYYYYY" convert.sh --all ~/audiobooks
```

## How it works

1. `audible download` pulls the encrypted `.aaxc`, the cover, the chapter
   JSON, and a `.voucher` holding the per-book decryption key
2. `audible api` fetches metadata (authors, narrators, series, summary)
3. the chapter JSON is flattened into FFMETADATA format — Audible nests
   chapters under parts on some titles
4. ffmpeg remuxes audio + chapters into the m4b, copying the audio stream
5. AtomicParsley writes the cover art

**Why the cover is a separate step:** the ipod/mov muxer drops an
`attached_pic` stream when a chapter text track is present and faststart
runs its second pass. ffmpeg reports writing the cover and it silently
isn't there. Writing the `covr` atom afterward is both reliable and what
audiobook players actually read.

## Troubleshooting

**`mp4art: command not found`** — mp4v2-utils was dropped from Ubuntu after
22.04. This uses AtomicParsley instead; the deploy script installs it.

**Crypto warning on every command** — the `cryptography` package didn't get
injected. Run `pipx inject audible-cli cryptography`.

**`convert.sh: command not found`** — open a new shell, or
`export PATH="$HOME/.local/bin:$HOME/bin:$PATH"`.

**No cover in your player** — check it's actually in the file first:

```
AtomicParsley file.m4b -t | grep -i covr
```

If it's there, the player is the issue. Audiobookshelf and Plex often
prefer the `.jpg` sidecar, which is written alongside each file. Plex also
wants m4b files in an `Artist/Album/` folder structure.

**`is not downloadable`** — the title is in your library via an Audible
Plus / subscription catalog rather than purchased. Those are streaming-only
and carry no download license, so there's nothing to fix; buying the title
outright makes it convert normally. The cover and chapter JSON still
download, which is why the failure can look partial.

**A single book fails in `--all` mode** — the run logs it and continues.
Re-run the single-book command for that ASIN to see the real error; `--all`
suppresses download output.

**`Unsupported codec with id 98314`** from ffprobe — harmless. That's
ffprobe complaining about the chapter text track, not a problem with the
file.

## Notes

- Only works on books in your own account. The decryption keys come from
  your own credentials.
- Converted files are DRM-free. Keep them for yourself; redistributing them
  is a different thing entirely and not what this is for.
