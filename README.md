# odid3

[![CI](https://github.com/OpenMediaStack/odid3/actions/workflows/ci.yml/badge.svg)](https://github.com/OpenMediaStack/odid3/actions/workflows/ci.yml)

An ID3 library for [Odin](https://odin-lang.org), part of Open Media Stack. It reads and writes the tags of MP3 files, every version of them: ID3v1, ID3v1.1 and the Enhanced TAG, ID3v2.2, ID3v2.3 and ID3v2.4.

> **Status: in development, not usable yet.** The plan is in [AGENTS.md](AGENTS.md#roadmap) and the planned API in [docs/api.md](docs/api.md).

## What v1 will do

- **Read** every version, with the four text encodings, extended headers, unsynchronisation (whole tag or per frame), the data length indicator, grouping, footers, appended ID3v2.4 tags, compressed frames, encrypted frames kept as they are, and chapters (`CHAP`, `CTOC`).
- **Keep every frame.** A tag is a list of frames with their flags and bytes, unknown ones included, so a round trip loses nothing.
- **Typed accessors** for the common fields: title, artist, album artist, album, date, track and total, disc and total, genre (with ID3v1 genre references), comment, pictures, user text.
- **A raw frame view**: each frame's ID, offset in the file, size, flags and decoded value.
- **Write** every version, with options for the text encoding of each frame, the padding, unsynchronisation and compression, and convert between versions with a list of what a conversion drops.
- **Safe writing.** The new file is written next to the original and renamed over it; the audio bytes, and the APE and Lyrics3 tags around them, are copied untouched, and a failed write leaves the original as it was.
- **Robust and thread safe.** Damaged files give partial results and warnings, never a crash. Reading works on bytes in memory or on a file without loading it whole, from any number of threads.
- **No dependency** beyond Odin's `core:` library.

The MPEG audio stream itself (duration, bitrate) is out of scope.

## Development

Needs Odin `dev-2026-10`. The checks the CI runs:

```bash
odin check . -no-entry-point -vet -strict-style
odin test tests -vet -strict-style -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
odinfmt -path:. -w
```

`odinfmt` comes with [OLS](https://github.com/DanielGavin/ols); the CI builds it from the commit pinned in `.github/workflows/ci.yml`.

How the project is run, its conventions and its roadmap are in [AGENTS.md](AGENTS.md).

## License

MIT, see [LICENSE](LICENSE).
