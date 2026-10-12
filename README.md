# odid3

[![CI](https://github.com/OpenMediaStack/odid3/actions/workflows/ci.yml/badge.svg)](https://github.com/OpenMediaStack/odid3/actions/workflows/ci.yml)

An ID3 library for [Odin](https://odin-lang.org), part of Open Media Stack. It reads and writes the tags of MP3 files, every version of them: ID3v1, ID3v1.1 and the Enhanced TAG, ID3v2.2, ID3v2.3 and ID3v2.4.

> **Status:** 1.0.0. odid3 follows semantic versioning: the API does not break before 2.0.0.

## What it does

- **Reads** every version, with the four text encodings, extended headers, unsynchronisation (whole tag or per frame), the data length indicator, grouping, footers, appended ID3v2.4 tags, compressed frames, encrypted frames kept as they are, and chapters (`CHAP`, `CTOC`).
- **Keeps every frame.** A tag is a list of frames with their flags and bytes, unknown ones included: an untouched frame is written back with the same bytes when the version is unchanged (a compressed one with the same content), and an unchanged ID3v1 tag keeps its bytes. Only the extended header and ID3v2.4's `SEEK`, whose offset to a next tag no longer holds once the tag is rewritten, are not written.
- **Typed accessors** for the common fields: title, artist, album artist, album, date, track and total, disc and total, genre (with ID3v1 genre references), comment, pictures, user text.
- **A raw frame view**: each frame's ID, offset in the file, size, flags and decoded value.
- **Writes** every version, with options for the text encoding of each frame, the padding, unsynchronisation and compression, and converts between versions with a list of what a conversion drops.
- **Safe writing.** The new file is written next to the original and renamed over it; the audio bytes, and the APE and Lyrics3 tags around them, are copied untouched, and a failed write leaves the original as it was.
- **Robust and thread safe.** Damaged files give partial results and warnings, never a crash. Reading works on bytes in memory or on a file without loading it whole, from any number of threads.
- **No dependency** beyond Odin's `core:` library.

The MPEG audio stream itself (duration, bitrate) is out of scope: `Layout.audio` says where it is.

## Installing

odid3 is one Odin package. Add the repository to your project, as a git submodule pinned to a tag for example, and import it by its path, here from a package at your project's root:

```bash
git submodule add https://github.com/OpenMediaStack/odid3 libs/odid3
git -C libs/odid3 checkout v1.0.0
git add libs/odid3
```

Then commit: your repository records the tag's commit.

```odin
import id3 "libs/odid3"
```

## Usage

The reference is in the doc comments: `odin doc libs/odid3` prints them. It leaves out the comments on struct fields and enum values (what each `Warning`, `Format_Error`, `Frame` and `Write_Options` field means), which are in the source and in OLS's hover.

What a procedure returns is allocated with its `allocator` parameter (the context allocator by default) and freed with the same allocator: strings and byte slices with `delete`, everything else with `destroy`. The setters, `set_encoding`, `convert` and `sync_v1` change a tag in place with the tag's own allocator, the one it was read or cloned with.

### Reading

`read_file` reads only the head and the tail of a file; `read_bytes` does the same on bytes in memory.

```odin
print_tags :: proc(path: string) -> id3.Error {
	tags := id3.read_file(path) or_return
	defer id3.destroy(&tags)

	title := id3.get(&tags, .Title) // from ID3v2, else from ID3v1
	defer delete(title)
	number, total := id3.track(&tags) // from ID3v2, else from ID3v1.1
	fmt.printfln("%s, track %d of %d", title, number, total)

	if cover, found := id3.front_cover(&tags.v2) or_return; found {
		defer id3.destroy(&cover)
		fmt.printfln("cover: %s, %d bytes", cover.mime, len(cover.data))
	}
	if tags.warnings != {} {
		fmt.println("damaged:", tags.warnings)
	}
	return nil
}
```

A damaged file is not an error: `read_file` returns what it could read, and `tags.warnings` says what was wrong. `Frame_Problems` means some frames were damaged: each frame's `problem` says how, and a decoded chapter has its own `warnings` for the frames inside it. For a fast scan, `id3.Read_Options{skip_picture_data = true}` leaves the pictures' data unread; tags read so cannot be written.

Reading is thread safe: any number of threads can read files at once. A tag keeps using the allocator it was read with when it is edited later, so read with an allocator every thread may use, or `clone` the tags to another allocator before handing them over.

### The raw frame view

Each frame has its `id`, its `offset` in the file (-1 for a frame added or rebuilt since), the `size` its header gives, its `status` and `format` flags, its `data`, and a `problem` when the data is not its content (encrypted, badly compressed).

```odin
for &frame in tags.v2.frames {
	content, err := id3.decode_frame(&frame, tags.v2.version)
	defer id3.destroy(&content)
	#partial switch c in content {
	case id3.Text:
		fmt.println(frame.id, frame.offset, frame.size, frame.format, c.values)
	case:
		fmt.println(frame.id, frame.offset, frame.size, frame.format, len(frame.data), "bytes", err)
	}
}
```

### Editing and writing

```odin
retitle :: proc(path, cover_path: string) -> id3.Error {
	tags := id3.read_file(path) or_return
	defer id3.destroy(&tags)

	if tags.v2.version == .None {
		tags.v2.version = .V2_4 // the file had no ID3v2 tag
	}
	id3.set(&tags.v2, .Title, "Paper Satellites") or_return
	id3.set_track(&tags.v2, 3, 12) or_return
	png := os.read_entire_file(cover_path, context.allocator) or_return
	defer delete(png)
	id3.set_picture(&tags.v2, {mime = "image/png", type = .Front_Cover, data = png}) or_return

	overflow := id3.sync_v1(&tags, .Keep) // rewrite ID3v1 where the file has one
	if .Title in overflow {
		fmt.println("the ID3v1 title is cut, or loses characters Latin-1 lacks")
	}
	return id3.write_file(path, &tags)
}
```

`write_file` writes the new file next to the original, with its permissions, and renames it over it; through a symbolic link, the file it points to is rewritten. On any error the original is untouched. A read-only file is refused. The tags are located again in the file as it is when writing, so its audio is never taken from an old read, but tags another program wrote since `read_file` are replaced; a file that changes during the write itself gives `File_Changed`. `write_bytes` rebuilds a file in memory.

A tag read with damage warnings (`DAMAGE_WARNINGS`), or a file holding a second ID3v2 tag, is only rewritten with `Write_Options.replace_damaged`, since what could not be read would be lost: `Damaged_Tag` is the cue to ask. `Error` is a union of `Format_Error`, `os.Error` and `runtime.Allocator_Error`.

An ID3v1 tag whose values are unchanged keeps its bytes, so text some taggers write in UTF-8 survives a write. A changed one is written from `tags.v1` in Latin-1, the only encoding ID3v1 has, with `?` for what Latin-1 lacks. `sync_v1` rebuilds it from the fields and returns those that do not fit; on a `clone` of the tags, it previews them.

### Versions and developer options

A tag is written in its own version: `tags.v2.version` and `tags.v1.version`. `convert` changes the ID3v2 version and lists the frames it drops or carries only in part; on a `clone`, it previews them.

```odin
preview := id3.clone(&tags.v2) or_return
defer id3.destroy(&preview)
lost := id3.convert(&preview, .V2_2) or_return
defer id3.destroy(&lost)
for frame in lost {
	fmt.printfln("ID3v2.2 would drop or cut %s: %v", frame.id, frame.reason)
}

dropped := id3.convert(&tags.v2, .V2_3) or_return
defer id3.destroy(&dropped)
id3.set_encoding(&tags.v2, .UTF16) or_return
id3.sync_v1(&tags, .Always, id3.V1_Version.V1_1)
options := id3.Write_Options {
	padding           = 0,
	unsynchronisation = true,
	compression       = true,
}
id3.write_file(path, &tags, options) or_return
```

The options apply to every frame; one frame can ask for its own instead: `id3.set_encoding(&frame, tags.v2.version, .UTF16BE)` re-encodes its text, and `frame.format += {.Compression}` (ID3v2.3 and 2.4) or `{.Unsynchronisation}` (ID3v2.4) asks `write_file` to apply it to this frame. To remove a tag, set `tags.v2.version = .None` (or `convert` to `.None`), and `id3.sync_v1(&tags, .Never)` for ID3v1.

## Development

Needs Odin `dev-2026-10`. The checks the CI runs:

```bash
odin check . -no-entry-point -vet -strict-style
odin test tests -vet -strict-style -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
odin test . -vet -strict-style -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
odinfmt -path:. -w
```

The interoperability tests read the files odid3 writes with ffprobe and mutagen, so they need both:

```bash
odin test tests -define:ODID3_INTEROP=true -define:ODID3_PYTHON=path/to/python3
```

`odinfmt` comes with [OLS](https://github.com/DanielGavin/ols); the CI builds it from the commit pinned in `.github/workflows/ci.yml`.

`ols.json` makes OLS check the package and its tests with the CI's `-vet -strict-style` flags. OLS formats with odinfmt and the repository's `odinfmt.json` on its own.

How the project is run, its conventions and its roadmap are in [AGENTS.md](AGENTS.md).

## License

MIT, see [LICENSE](LICENSE).
