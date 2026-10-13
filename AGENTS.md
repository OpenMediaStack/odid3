# odid3

An ID3 library written in Odin, part of Open Media Stack. It reads and writes the tags of MP3 files: ID3v1, ID3v1.1 and the Enhanced TAG, ID3v2.2, ID3v2.3 and ID3v2.4. Every frame of a tag is kept, unknown ones as raw bytes, so nothing is lost on a round trip; typed accessors cover the common fields (title, artist, album, date, track, disc, genre, comment, pictures, user text); a raw frame view gives each frame's ID, offset, size, flags and decoded value. Writing is safe (a temporary file renamed over the original) and never touches the audio. Only Odin's `core:` library is used. Open source under the MIT license.

Its first user is Colophon (`OpenMediaStack/colophon`, cloned in `~/Code/colophon`), the MP3 tag editor, whose Odin and SDL3 rewrite lives on the `odin-migration` branch of that repository. Colophon's needs drive this library: see [Colophon's needs](#colophons-needs).

**Scope.** v1 reads and writes every ID3 version above, with options for the text encoding, the padding, unsynchronisation and compression. The MPEG audio stream (duration, bitrate), APE tags and Lyrics3 tags are out of scope: their bytes are found and kept, never parsed. A command line tool comes in v2, after the v1 tag (see [Roadmap](#roadmap)).

**Not to be confused with** `~/Code/odin/odid3` (`florentsorel/odid3`), Florent's own learning project with the same name, where Florent writes every line by hand. Agents never edit it, never run tools that change it, and only answer questions about it when asked.

## How we work

Florent decides, the agents build.

- **Florent** sets the direction, writes or approves the spec of each change, defines what "done" means, and reviews every change after it is merged.
- **The agents** plan, implement, test and verify. They propose; they never decide product questions alone. When a choice is genuinely Florent's (a behaviour, a dependency, an API trade-off), ask, and record each answer in [Decisions](#decisions).
- **Small slices.** One change does one thing and can be reviewed in a few minutes. A larger feature is cut into slices first, and the plan is shown before any code. Each slice ends on something that runs and is tested.
- **Plan first** for anything that changes the public API, adds a dependency, or touches how a file is written: a short plan with the files involved, the approach, and how it will be verified.
- **One branch and one pull request per change, as we go.** Branches are named after the Conventional Commits type and the change, in English (`feat/v1-tags`, `fix/...`, `docs/...`, `chore/...`, `test/...`, `ci/...`), and are never renamed. `main` only takes squash merges, so the pull request title, a Conventional Commit, becomes the commit on `main`. Nothing is pushed to `main` directly, except the initial commit that starts the repository.
- **The CI runs on every pull request**: build checks, tests, formatting and lint on macOS, Windows and Linux (see [Definition of done](#definition-of-done)).
- **A second agent reviews every pull request.** Once a pull request is open, the agent that opened it has another agent review the diff against this file (correctness, [Rules that are never bent](#rules-that-are-never-bent), tests, code comments). The agent that opened it applies the review comments it agrees with, pushes them to the same pull request, and lists in the description the ones it set aside, with the reason.
- **The agent merges once the CI is green.** After the review, when every check of its pull request passes, the agent that opened it squash-merges it and deletes its branch; the next slice starts from the updated `origin/main`. A pull request waiting on a question for Florent is not merged until he answers. Florent reviews the merged changes and asks for fixes, which come as new pull requests. Tagging a release is still Florent's call: pushing a `v*` tag runs `.github/workflows/release.yml`, which checks that `VERSION` in `odid3.odin` matches the tag, runs the checks and tests, and publishes the GitHub release with notes git-cliff writes from the squash-merged titles since the previous tag (`cliff.toml`). The CI shows the notes of the next release on every pull request.
- **Start from the prototype.** `~/Code/colophon-odin/tags/` (not a git repository) already reads ID3v1, ID3v2.2, 2.3 and 2.4 and writes 2.3 and 2.4, with 25 tests and fixtures from `~/Code/colophon-odin/testdata/make.sh`. Port, restructure and extend that code rather than rewrite it from zero. Its MPEG audio code (`mpeg.odin`) stays out of odid3.
- **Florent keeps learning.** When a change relies on a concept that is not obvious (unsynchronisation, syncsafe integers, the data length indicator, a deflate block, a UTF-16 surrogate pair), the summary explains it in two or three sentences with a link to the spec (see [References](#references)). No lectures, just enough to review with understanding.
- Talk to Florent in French. Everything written in the repository or on GitHub is in English: code, comments, docs, the README, commit messages, pull request titles and descriptions, review comments.
- No em dashes or en dashes anywhere: code, comments, docs, commits, pull requests. Use a comma, a colon, parentheses or a new sentence. The CI checks it.

## Code style

- **Names.** Types in `Ada_Case`, procedures and variables in `snake_case`, constants in `SCREAMING_SNAKE_CASE`, enum values in `Ada_Case`. Frame IDs and spec terms keep the spec's spelling (`TIT2`, `unsynchronisation`).
- **Public and private.** Only what Colophon and the future command line tool need is public. Every helper is `@(private)` (package) or `@(private = "file")`.
- **Errors** are values: the package's `Error` union, propagated with `or_return`. A damaged tag is not an error: reading gives a partial result and warnings (see [Rules that are never bent](#rules-that-are-never-bent)).
- **Allocators.** Every procedure that allocates takes `allocator := context.allocator`, and its doc comment says what the caller owns and how to free it. The library never relies on `context.temp_allocator`: scratch memory comes from the given allocator and is freed before returning.
- **No global mutable state.** Tables (genres, frame ID conversions) are `@(rodata)` constants.
- **Small procedures** that are easy to test, rather than long ones with flags.
- **Comments.** The code reads without comments: clear names, small procedures, types that carry the meaning. A comment, in English, only says what the code cannot: a quirk of the spec with its reference (why unsynchronisation is undone before the frames are split in ID3v2.3 but per frame in ID3v2.4, why some ID3v2.4 frame sizes are not syncsafe), or why a workaround exists. Never what the next line does.
- **Doc comments** on every public declaration, for `odin doc`: one or two sentences on what the caller must know (ownership, errors, the versions concerned), not a restatement of the name.
- **Formatting.** `odinfmt` with the repository's `odinfmt.json`; the CI checks that it changes nothing.

## Definition of done

A change is done when all of this holds, and the summary says which checks ran:

- `odin check . -no-entry-point -vet -strict-style` passes.
- `odin test tests -vet -strict-style -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true` passes, with new tests for the new behaviour, and no leak or bad free reported. Internal tests, when there are any, pass too (`odin test . -vet -strict-style -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).
- `odinfmt` leaves every file unchanged.
- The public API it adds has doc comments, and `odin doc .` shows them.
- The CI passes on the pull request: checks and tests on macOS, Windows and Linux, formatting, YAML lint, and the dash check.
- Anything not verified is named as such. Never claim a check that did not run.

## Rules that are never bent

- **User files are sacred.** Writing tags never changes the audio bytes, nor the APE, Lyrics3 or unknown bytes around them: they are copied byte for byte. A write goes to a temporary file in the same directory, is flushed and synced, then renamed over the original; any failure removes the temporary file and leaves the original untouched. Tests never write to a real user file: they copy fixtures into a temporary directory.
- **No panic on untrusted input.** Files are untrusted: truncated, damaged or lying ones (sizes larger than the file, bad syncsafe bytes, invalid UTF-16) give an error or a partial result with warnings, never a panic. Every length read from a file is checked against the bytes left before slicing; size arithmetic cannot overflow; no `assert`, `panic` or `unreachable` depends on file data. A size claimed by a file never decides an allocation on its own: it is bounded by the file size and by the spec's limits.
- **Nothing is lost silently.** Every frame is kept, unknown and encrypted ones as raw bytes. Reading problems are reported as warnings. A version conversion that drops a frame lists it, and the caller can preview the list before writing.
- **Reads are thread safe.** Any number of threads can read files at once: no global state, no shared buffers.
- **The public API is enough.** The tests in `tests/` use only the public API, and so will the command line tool. If a test needs a private detail, the API is missing something, or the test belongs next to the code.
- **Only `core:`.** No `vendor:` package, no C library and no other dependency without Florent's agreement.

## Architecture

The repository root is the `odid3` package. Colophon imports it by path; the recommendation is a git submodule pinned to a tag, decided in Colophon.

| Path | Role |
| --- | --- |
| `odid3.odin` | Package documentation: what the library does, ownership and threading rules; and `VERSION`. |
| `errors.odin` | `Error`, `Format_Error`, `Warning`. |
| `layout.odin` | Finding where each part of a file is: the leading ID3v2 tag, an appended ID3v2.4 tag, the audio, APE and Lyrics3 tags, the Enhanced TAG, ID3v1. |
| `read.odin` | `Tags`, `read_bytes`, `read_file` and `destroy`. |
| `source.odin` | Reading bytes at an offset from memory or from an open file, so the same code reads both without loading a whole file. |
| `v1.odin` | ID3v1, ID3v1.1 and the Enhanced TAG, reading and writing. |
| `genres.odin` | The ID3v1 genre table and `TCON` genre references. |
| `v2_header.odin` | The ID3v2 header, extended header and footer. |
| `v2_frames.odin` | Splitting a tag into frames: frame headers, flags, unsynchronisation, data length indicator, grouping, compression, encryption. |
| `content.odin` | Decoding and encoding frame contents (text, URLs, comments, pictures, chapters...). |
| `text.odin` | The four text encodings, Latin-1 and UTF-16 conversions. |
| `fields.odin` | Typed accessors: the common fields, pictures, user text. |
| `convert.odin` | Converting a tag between ID3v2.2, 2.3 and 2.4. |
| `render.odin` | Building the bytes of an ID3v2 tag from the model, with the write options. |
| `write.odin` | Rebuilding a file in memory or on disk, safely; `write_posix.odin` and `write_windows.odin` hold what differs between systems (the owner, syncing the directory). |
| `inflate.odin` | Inflating compressed frames (zlib and deflate), within the size they declare. Our own, since `core:compress/zlib` asserts on some damaged streams. |
| `deflate.odin` | The deflate encoder for compressed frames (see [Decisions](#decisions)). |
| `tests/` | The `odid3_tests` package: tests through the public API. |
| `testdata/` | Fixtures, the script that makes them, and ffprobe's output for each one. |
| `docs/api.md` | A pointer to `odin doc`: the API reference is the doc comments. |
| `cmd/odid3/` | v2 only: the command line tool. |

Add a file only when a real boundary appears, never upfront. Throwaway experiments live in `spikes/`, ignored locally through `.git/info/exclude`, never committed.

## Colophon's needs

From Colophon's design brief (`docs/design/brief.md`, "Tag versions and developer mode") and its roadmap (steps 4, 5 and 11):

- Write ID3v2.4 by default, or ID3v2.3 when the settings say so.
- ID3v1: keep it where it exists (rewritten from the new values), always write it, or never write it. Report the values that do not fit (30 Latin-1 characters, 28 for the comment of an ID3v1.1 tag) before saving.
- Developer mode writes any version on demand to produce test files: ID3v2 none, 2.2, 2.3 or 2.4; ID3v1 none, 1.0 or 1.1. A conversion says what it will lose.
- Advanced developer tools set the text encoding of each frame (ISO-8859-1, UTF-16 and, in ID3v2.4, UTF-16BE and UTF-8), the padding size, unsynchronisation and compression, and show a raw frame view: each frame's ID, offset, size, flags and decoded value.
- Reading many files from worker threads, without loading whole files.

## References

- ID3v2.4: [structure](https://mutagen-specs.readthedocs.io/en/latest/id3/id3v2.4.0-structure.html) and [frames](https://mutagen-specs.readthedocs.io/en/latest/id3/id3v2.4.0-frames.html).
- [ID3v2.3](https://mutagen-specs.readthedocs.io/en/latest/id3/id3v2.3.0.html).
- [ID3v2.2](https://mutagen-specs.readthedocs.io/en/latest/id3/id3v2.2.html).
- [ID3v2 chapters](https://mutagen-specs.readthedocs.io/en/latest/id3/id3v2-chapters-1.0.html) (`CHAP`, `CTOC`).
- [ID3v1](https://id3.org/ID3v1), and the Enhanced TAG in [Wikipedia's ID3 article](https://en.wikipedia.org/wiki/ID3), which has no official spec.
- [Lyrics3v2](https://id3.org/Lyrics3v2) and [APEv2](https://wiki.hydrogenaud.io/index.php?title=APEv2_specification), only to find their bytes.
- [RFC 1950](https://www.rfc-editor.org/rfc/rfc1950) (zlib) and [RFC 1951](https://www.rfc-editor.org/rfc/rfc1951) (deflate), for compressed frames.

The mutagen-specs pages mirror the original id3.org documents, which are often unreachable.

## Testing

- **Where tests live.** Behaviour is tested in `tests/` (the `odid3_tests` package), through the public API only. A private detail the API cannot reach on its own (the deflate encoder, corner cases of the UTF-16 decoder) is tested in a `<file>_test.odin` file of the `odid3` package.
- **Fixtures.** `testdata/make.sh` generates them, ported from the prototype: MP3 files made by ffmpeg (`-id3v2_version 3` or `4`, `-write_id3v1 1`) from a generated sine or silence, never third-party audio, plus files built byte by byte for what ffmpeg cannot write (ID3v2.2, unsynchronisation, compressed frames, extended headers, footers, appended tags, the Enhanced TAG, APE and Lyrics3 tags, damaged sizes). Compressed frames are made with Python's standard `zlib` module, so the reader is never tested against our own encoder only. The script documents what each file holds. The files are committed with ffprobe's output for each one (`testdata/ffprobe/`), so reading them needs neither ffmpeg nor Python: rerun the script after changing it.
- **Parity.** The values read from the fixtures match ffprobe's output.
- **Interoperability.** Files written by odid3, in every version and with every option, are read back by ffprobe and by mutagen (Python). These tests need both tools, so they only run with `-define:ODID3_INTEROP=true` (and `-define:ODID3_PYTHON=path` when mutagen lives in a virtual environment); the CI installs the tools and runs them on Linux. Where ffmpeg itself misreads a file (unsynchronised ID3v2.2 and 2.3 tags, compressed ID3v2.3 frames, Latin-1 text in ID3v1), only odid3 and mutagen check it.
- **Round trips.** Reading then writing a tag without changes keeps every frame byte for byte when the version is unchanged (except ID3v2.4's `SEEK`, which is not written), and ID3v1's bytes; a compressed frame keeps its content, compressed again by odid3's encoder. An edit changes only what was edited. A hash of the audio bytes is the same before and after every write.
- **Robustness.** Every fixture cut at every length, mutated bytes (driven by the test runner's random seed, so a failure can be replayed with `-define:ODIN_TEST_RANDOM_SEED=n`), and sizes that lie: no panic, no leak, and allocations bounded by the input size.
- **Threads.** Several threads read the fixtures at once and get the same results as one thread.
- **Memory.** The test runner tracks allocations; a leak or a bad free fails the run.

## Roadmap

The order is Florent's: reading, then writing, then the v1 tag, then the command line tool. Each slice below is one branch and one pull request, ends on something that runs and is tested, and passes the CI. A slice that turns out larger than expected is cut again before it starts.

### 0. Bootstrap

1. **Initial commit**, pushed to `main` directly, the only time: `AGENTS.md`, `CLAUDE.md` as a symbolic link to it, `README.md`, `docs/api.md` and the MIT `LICENSE`. Locally, `.git/info/exclude` lists `spikes/`.
2. **`chore: repository basics and CI`**: `odinfmt.json`, `.gitignore`, `.editorconfig`, the package file `odid3.odin` and one smoke test so every check has something to run, and the GitHub Actions workflow: `laytan/setup-odin` pinned to the Odin release in use (`dev-2026-10`) on macOS, Windows and Linux running `odin check` and `odin test` as in [Definition of done](#definition-of-done); `odinfmt` built from a pinned OLS commit; YAML lint; a check that no file holds an em dash or an en dash.

### 1. Reading

1. **`feat: find the tags of a file in memory`**: `Layout` and `read_bytes` for a byte slice: the leading ID3v2 header (version, flags, size), ID3v1 and the Enhanced TAG at the end, APE and Lyrics3 tags found and skipped, the audio range in between, a second ID3v2 tag right after the first reported as a warning. The prototype's fixtures and `make.sh` move here.
2. **`feat: read a file without loading it`**: `read_file` reads only the head and the tail of a file through `source.odin`; every fixture gives the same result as `read_bytes`, and a test counts the bytes read on a large file.
3. **`feat: ID3v1, ID3v1.1 and the Enhanced TAG`**: `V1_Tag`, the genre table, Latin-1 text (and UTF-8 written by some taggers in ID3v1 fields), the longer title, artist and album of the Enhanced TAG.
4. **`feat: ID3v2.3 and 2.4 frames`**: the frame model (`Frame` with its ID, status and format flags, data, and its offset and size in the file), the extended header, padding, ID3v2.4 frame sizes written as plain integers by old iTunes versions, warnings for damaged frames, and the read option that leaves picture data unread for fast scans. Frame contents stay bytes in this slice.
5. **`feat: unsynchronisation, data length indicator and grouping`**: tag level unsynchronisation (ID3v2.2, 2.3, 2.4), frame level unsynchronisation (ID3v2.4), the data length indicator and the grouping byte, with frame offsets that stay exact in the file when unsynchronisation removed bytes.
6. **`feat: compressed and encrypted frames`**: compressed frames inflated by a decoder of our own (`core:compress/zlib` asserts on some damaged streams), the output bounded by the declared size; encrypted frames kept as stored and marked.
7. **`feat: ID3v2.2 tags`**: three-character IDs and six-byte frame headers, the `PIC` frame's image format, a compressed ID3v2.2 tag reported (no compression scheme was ever defined for it) and kept unread.
8. **`feat: appended ID3v2.4 tags`**: the footer, and a tag found from its footer at the end of the file, before ID3v1 and around an APE tag.
9. **`feat: decode frame contents`**: `decode_frame` and the `Frame_Content` union: text frames in the four encodings with ID3v2.4's multiple values, `TXXX`, URLs, `WXXX`, `COMM` and `USLT`, `APIC` and `PIC`, `UFID`, `POPM`, `PCNT`, `PRIV`, and raw bytes for the rest. This is the decoded value of the raw frame view.
10. **`feat: chapters`**: `CHAP` and `CTOC` decoded, with their embedded frames.
11. **`feat: typed accessors for reading`**: `get` for the common fields on an ID3v2 tag and on a file (falling back to ID3v1), the date in each version (`TDRC`; `TYER`, `TDAT`, `TIME`; `TYE`, `TDA`, `TIM`), track, disc and their totals as numbers, genres with ID3v1 references (`(17)`, `17`, `(RX)`, `(CR)`, refinements, ID3v2.4's multiple values), the comment (empty description first, iTunes' own comments skipped, ffmpeg's `TXXX` comment), pictures (front cover first), user text. Values match ffprobe on every fixture.
12. **`test: damaged files and concurrent reads`**: the systematic corpus of [Robustness](#testing) over every fixture, allocations bounded by the input, and the threaded reads.

Each slice already tests its own damaged inputs; the last one adds the systematic corpus.

### 2. Writing

1. **`feat: write ID3v1 and the Enhanced TAG`**: ID3v1.0 and 1.1 bytes from a `V1_Tag`, the Enhanced TAG when the values need it and the caller wants it, `v1_from_tag` with the fields that do not fit, and the three ID3v1 policies (keep where it exists, always, never).
2. **`feat: render ID3v2.3 and 2.4 tags`**: `render` builds a tag from the model: unchanged frames byte for byte, the padding option, the ID3v2.4 footer option, the size limits, an error for an encoding the version does not have (UTF-8 in ID3v2.3), and the extended header dropped (see [Decisions](#decisions)).
3. **`feat: write files safely`**: `write_bytes` and `write_file`: the new tags around the kept bytes (audio, APE, Lyrics3, anything unknown), a single leading ID3v2 tag in place of two (see [Decisions](#decisions)), a temporary file in the same directory, flushed, synced and renamed, the original's permissions kept; failures (a read-only directory, a path that is a folder, a write that fails half way) leave the original untouched. A file whose tag was damaged is only rewritten when the caller allows it.
4. **`feat: typed accessors for writing`**: `set` for the common fields, numbers, pictures (add, replace, remove), user text and comments, removing a field with an empty value; new frames take the version's default encoding (UTF-8 in ID3v2.4, Latin-1 in ID3v2.3 when the text fits, else UTF-16), an existing frame keeps its encoding when it can hold the new text.
5. **`feat: convert between ID3v2.3 and 2.4`**: `convert` renames and merges frames (`TDRC` and `TYER`, `TDAT`, `TIME`; `TDOR` and `TORY`; `TIPL`, `TMCL` and `IPLS`), re-encodes text the target version cannot hold, translates frame flags, and returns the frames it drops with the reason. `clone` lets a caller preview a conversion.
6. **`feat: write ID3v2.2`**: conversion to and from ID3v2.2 (the frame ID table, `PIC` and its image format, 24-bit frame sizes), with the frames it drops.
7. **`feat: per frame text encoding`**: `set_encoding` re-encodes one frame, or every text frame of a tag; text that Latin-1 cannot hold is an error, never replaced silently.
8. **`feat: unsynchronisation on write`**: the whole tag in ID3v2.2 and 2.3 (with the rule for a last byte of `0xFF`), each frame in ID3v2.4 (and the header flag when every frame is), as an option or per frame.
9. **`feat: deflate encoder`**: compressing bytes in the zlib format (LZ77 with hash chains and fixed Huffman codes), tested by inflating with `core:compress/zlib` and, in the interoperability tests, with Python's `zlib`.
10. **`feat: compressed frames on write`**: ID3v2.3 (with the decompressed size) and ID3v2.4 (with the data length indicator), as an option or per frame.
11. **`feat: keep encrypted and grouped frames on write`**: written back as stored when the version is unchanged, their flags translated between ID3v2.3 and 2.4, dropped and listed for ID3v2.2.
12. **`test: interoperability and write robustness`**: every version and option written, then read back by odid3, ffprobe and mutagen; writing over every damaged fixture never panics and never changes the original when it fails.

### 3. The v1 tag

1. **`docs: usage and API reference`**: the README with examples for reading, editing and writing, `docs/api.md` replaced by a pointer to `odin doc`, and every public declaration documented.
2. **`chore: version 1.0.0`**, then the `v1.0.0` tag once Florent approves it. Colophon then pins it.

### 4. v2, after the v1 tag

Nothing of this starts before the v1 tag. The shape to propose when the time comes:

- A separate `main` package in `cmd/odid3`, built on the public API only, which proves the API is enough.
- Read commands: `odid3 dump <file>` (versions, fields, pictures) and `odid3 frames <file>` (the raw frame view: ID, offset, size, flags, decoded value), each with a `--json` output.
- Write commands: `set`, `convert` (ID3v2 and ID3v1 versions), the developer options (encoding, padding, unsynchronisation, compression), `extract-cover`, and a `--dry-run` that prints what would change.
- Documented exit codes, tested by running the built binary on the fixtures.

## Decisions

Florent's answers to the questions the plan raised:

1. **Compressed frames on write** use a small deflate encoder of our own in `deflate.odin`, rather than `vendor:zlib`: the library stays free of C, its allocations go through Odin's allocators (so the test runner sees them), and it keeps compiling for targets without a C zlib, such as a future web build of Colophon.
2. **The MPEG audio code** of the prototype (duration, bitrate, Xing and VBRI headers) goes into a package inside Colophon, fed by odid3's `Layout` (which says where the audio starts and ends). It moves to its own library only if another Odin program needs it.
3. **Two ID3v2 tags in one file** (a leading tag and an appended one, or two leading tags left by a broken tagger): the first is read, the other is reported as a warning, and writing puts a single leading tag in place of both. This departs from section 5 of the ID3v2.4 structure, where a later tag updates the earlier one; TagLib, mutagen and ffmpeg do not read appended tags at all.
4. **The extended header** is read but dropped on write in v1. A CRC option can come later if developer mode wants it.
5. **A pre-release for Colophon**: if Colophon wants to start on the reading API before the v1 tag, Florent tags `v0.1.0` after the reading slices.
6. **One package**, not `v1` and `v2` subpackages: both share the layout, the errors, the text encodings and `Tags`, which subpackages would have to make public. File names carry the split instead (`v1.odin`, `v2_header.odin`, `v2_frames.odin`).
7. **ID3v2.4's `SEEK` is not written**: it gives the offset to a next tag, which no longer holds once the tag is rewritten, and writing leaves a single tag (decision 3). It is the one frame a round trip leaves out.
8. **ID3v1's encoding**: an unchanged ID3v1 tag keeps its bytes on write. A changed one keeps the encoding it was read in (`V1_Tag.encoding`: UTF-8 when its text was, as ffmpeg writes it, else Latin-1, the spec's), and `Write_Options.v1_encoding` forces Latin-1 or UTF-8; `sync_v1` and `v1_from_tag` take an encoding too, to report what does not fit in it. A tag edited by taggers of both kinds (some fields UTF-8, others Latin-1) is Latin-1 when every field fits it.
9. **ID3v2 text encodings on write**: each frame keeps the encoding it was read in, and `Write_Options.encoding` writes every text frame in one the version has, on a copy, so the tags do not change; `set_encoding` does the same in place, for a tag or one frame.
10. **UTF-16 byte order**: the spec allows both orders after a byte order mark. A frame keeps the order it was read in, even when a setter changes its value; new and re-encoded frames are little endian, and `Write_Options.utf16_byte_order` or `set_encoding`'s `byte_order` asks for either, chosen by the caller.
11. **Text a conversion cannot carry whole**: when `convert` re-encodes a frame whose text does not decode whole (bytes other than NULs after the text of a comment or lyrics, or after the URL of a `WXXX`; a UTF-16 surrogate without its pair; an odd last byte of UTF-16 text other than a NUL), it keeps the converted frame, without those bytes and with U+FFFD for the surrogate, and lists it as `Partly_Converted`, rather than dropping the frame (`Not_Encodable`) or failing the conversion (`.Bad_Content`): the readable text stays, and the list says the frame lost something. `set_encoding` and `Write_Options.encoding` refuse such a frame with `.Bad_Content`, since they have no list to report it in.
12. **NULs alone after the text**: NULs that follow the final terminator of a comment or lyrics, or the URL of a `WXXX` (such as a doubled terminator), hold no text, so leaving them out loses nothing: `convert` does not list such a frame, and `set_encoding` and `Write_Options.encoding` re-encode it. An odd last byte of UTF-16 text, which decoding drops, is a loss unless it is a NUL, the half terminator some writers end UTF-16 text with.
13. **ID3v2.2 IDs in a conversion's list**: converting an ID3v2.2 tag lists its frames under their 3 letter IDs (`TYE`, not the `TYER` it passes through on the way to ID3v2.4), as it lists the frames it drops while renaming (`PIC`): the list says what the caller's file loses, in the IDs that file has.
14. **Encodings in a conversion**: `convert` re-encodes only the text the target version cannot hold. A frame it rebuilds for another reason (values joined with "/" before ID3v2.4, a picture between `APIC` and `PIC`, people, dates) keeps its encoding and UTF-16 byte order when the target has that encoding and it holds the text (people merged from several frames take the first one's); otherwise the text is written in Latin-1 when it fits, else in UTF-16 little endian, as decision 10 wants for re-encoded frames.
