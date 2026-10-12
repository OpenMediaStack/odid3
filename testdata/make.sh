#!/bin/bash
# Regenerates odid3's fixtures and what ffprobe reads in them. Run from anywhere: ./testdata/make.sh
# Needs ffmpeg, ffprobe and Python 3 (standard library only).
#
# Every fixture holds 0.1 s of generated silence, so no fixture carries third party content. The
# bitexact flags keep ffmpeg's version out of the files. Files that ffmpeg cannot write are built
# byte by byte around the audio of no_tag.mp3, so a test can check that the audio found between
# the tags is exactly that file. Each fixture.mp3 that ffprobe can read gets ffprobe/fixture.txt
# (-of flat), which the parity tests compare with what odid3 reads.
#
# ffmpeg writes ID3v1 bytes as given: UTF-8 text stays UTF-8, a raw byte stays raw. With
# -id3v2_version 0, ffmpeg only fills ID3v1 from ID3v2 frame names (TIT2, TPE1, TALB, TYER, TRCK,
# TCON) plus "comment" for the comment field.
#
# ID3v1 layout (last 128 bytes): "TAG", title 30, artist 30, album 30, year 4, comment 30, genre 1.
# In ID3v1.1, comment byte 28 (offset 125) is 0 and byte 29 (offset 126) is the track number.

set -euo pipefail
cd "$(dirname "$0")"

rm -f ./*.mp3 ffprobe/*.txt zlib/*
mkdir -p ffprobe

# The bitexact flags go after the input: before it, they would only apply to reading the input.
silence=(-v error -y -f lavfi -i anullsrc=r=44100:cl=mono -t 0.1
	-fflags +bitexact -flags:a +bitexact -write_xing 0)
v1_only=(-id3v2_version 0 -write_id3v1 1)
no_tags=(-id3v2_version 0 -write_id3v1 0)

# field TEXT SIZE: ASCII TEXT padded with NUL bytes to SIZE bytes.
field() {
	printf '%s' "$1"
	if (($2 > ${#1})); then
		head -c $(($2 - ${#1})) /dev/zero
	fi
}

# le32 N: N as a 32-bit little-endian number, as APE writes its sizes.
le32() {
	local n=$1
	printf "\\x$(printf %02x $((n & 255)))\\x$(printf %02x $((n >> 8 & 255)))"
	printf "\\x$(printf %02x $((n >> 16 & 255)))\\x$(printf %02x $((n >> 24 & 255)))"
}

# ape_item KEY VALUE: an APEv2 item: the value's size, flags 0 (UTF-8 text), the key, a NUL, the
# value. Values are ASCII here, so their length in characters is their length in bytes.
ape_item() {
	le32 "${#2}"
	le32 0
	printf '%s\0%s' "$1" "$2"
}

# ape_tag COUNT: an APEv2 tag around the COUNT items read from standard input, with a header and a
# footer of 32 bytes each, as MP3Gain and foobar2000 write it: "APETAGEX", version 2000, the size
# of the items and the footer, the item count, the flags, 8 reserved bytes. Both flags say the tag
# has a header (bit 31); the header's also say it is the header (bit 29).
ape_tag() {
	local items size
	items=$(mktemp)
	cat >"$items"
	size=$(($(wc -c <"$items") + 32))
	printf 'APETAGEX'
	le32 2000
	le32 "$size"
	le32 "$1"
	le32 $((0xa0000000))
	printf '\0\0\0\0\0\0\0\0'
	cat "$items"
	printf 'APETAGEX'
	le32 2000
	le32 "$size"
	le32 "$1"
	le32 $((0x80000000))
	printf '\0\0\0\0\0\0\0\0'
	rm "$items"
}

every_field=(
	-metadata title="Paper Satellites"
	-metadata artist="Marlowe Kite"
	-metadata album_artist="Various Artists"
	-metadata album="Small Hours"
	-metadata date=2019
	-metadata track=3/12
	-metadata disc=1/2
	-metadata genre=Folk
	-metadata comment="Recorded in one take."
)

# no_tag.mp3: audio only, no tag at all.
ffmpeg "${silence[@]}" "${no_tags[@]}" no_tag.mp3

# v23_full.mp3: ID3v2.3 with the common fields. ffmpeg writes the comment in a TXXX frame described
# "comment", not in a COMM frame.
# Expect: title "Paper Satellites", artist "Marlowe Kite", album artist "Various Artists",
#   album "Small Hours", year 2019, track 3 of 12, disc 1 of 2, genre "Folk",
#   comment "Recorded in one take.".
ffmpeg "${silence[@]}" -id3v2_version 3 -write_id3v1 0 "${every_field[@]}" v23_full.mp3

# v24_full.mp3: the same fields in ID3v2.4, where the year is a TDRC timestamp, plus a publisher
# (TPUB) and a TXXX frame described "mood", which no accessor reads.
# Expect: the values of v23_full.mp3, publisher "Colophon Records", user text mood "Calm".
ffmpeg "${silence[@]}" -id3v2_version 4 -write_id3v1 0 "${every_field[@]}" \
	-metadata publisher="Colophon Records" \
	-metadata mood=Calm \
	v24_full.mp3

# v23_comm.mp3: an ID3v2.3 tag with a real COMM frame (ffmpeg cannot write one). Frame sizes are
# plain 32-bit numbers in ID3v2.3, the tag size is syncsafe (7 bits per byte). TIT2 is 10 + 18
# bytes, COMM 10 + 26 (Latin-1, language "eng", empty description): the tag holds 64 bytes (0x40).
# Expect: title "A real COMM frame", comment "Recorded in one take.".
{
	printf 'ID3\x03\x00\x00\x00\x00\x00\x40'
	printf 'TIT2\x00\x00\x00\x12\x00\x00\x00A real COMM frame'
	printf 'COMM\x00\x00\x00\x1a\x00\x00\x00eng\x00Recorded in one take.'
	cat no_tag.mp3
} >v23_comm.mp3

# v22.mp3: an ID3v2.2 tag (ffmpeg only writes ID3v2.3 and 2.4). ID3v2.2 frames have 3 letter IDs
# and a 6 byte header: the ID, then the size as a plain 24-bit number, no flags. Each frame starts
# with its text encoding, 0 for Latin-1. TT2 is 6 + 17 bytes, TP1 6 + 13, TAL 6 + 12, TYE and TRK
# 6 + 5, TCO 6 + 5, COM 6 + 26: the tag holds 125 bytes (0x7d).
# Expect: title "Paper Satellites", artist "Marlowe Kite", album "Small Hours", year 2019,
#   track 3 of 12, genre "Rock" (the ID3v1 genre reference "(17)"), comment "Recorded in one take.".
{
	printf 'ID3\x02\x00\x00\x00\x00\x00\x7d'
	printf 'TT2\x00\x00\x11\x00Paper Satellites'
	printf 'TP1\x00\x00\x0d\x00Marlowe Kite'
	printf 'TAL\x00\x00\x0c\x00Small Hours'
	printf 'TYE\x00\x00\x05\x002019'
	printf 'TRK\x00\x00\x05\x003/12'
	printf 'TCO\x00\x00\x05\x00(17)'
	printf 'COM\x00\x00\x1a\x00eng\x00Recorded in one take.'
	cat no_tag.mp3
} >v22.mp3

# v22_pic.mp3: an ID3v2.2 tag with a title and an 8 by 8 red PNG in a PIC frame, whose image
# format is 3 characters ("PNG") rather than a MIME type.
# Expect: title "With a picture", one front cover picture (image/png).
ffmpeg -v error -y -f lavfi -i color=c=red:s=8x8 -frames:v 1 -flags:v +bitexact cover.png
python3 - cover.png no_tag.mp3 v22_pic.mp3 <<'PY'
import sys
picture = open(sys.argv[1], 'rb').read()
def frame(frame_id, data):
    return frame_id + len(data).to_bytes(3, 'big') + data
frames = frame(b'TT2', b'\x00With a picture') + frame(b'PIC', b'\x00PNG\x03\x00' + picture)
n = len(frames)
size = bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])
open(sys.argv[3], 'wb').write(b'ID3\x02\x00\x00' + size + frames + open(sys.argv[2], 'rb').read())
PY
rm cover.png

# v23_cover.mp3: ID3v2.3 with a title, a publisher (TPUB) and an 8 by 8 red PNG as front cover
# (APIC).
# Expect: title "With a cover", one front cover picture (image/png), publisher "Colophon Records".
ffmpeg -v error -y -f lavfi -i anullsrc=r=44100:cl=mono -f lavfi -i color=c=red:s=8x8 -t 0.1 \
	-map 0:a -map 1:v -frames:v 1 -c:v png -disposition:v attached_pic \
	-metadata:s:v comment="Cover (front)" \
	-fflags +bitexact -flags:a +bitexact -flags:v +bitexact -write_xing 0 \
	-id3v2_version 3 -write_id3v1 0 \
	-metadata title="With a cover" -metadata publisher="Colophon Records" \
	v23_cover.mp3

# v23_v1_long_title.mp3: ID3v2.3 and ID3v1.1 written from the same values, with a title longer
# than ID3v1's 30 bytes.
# Expect: ID3v2.3 title "A title longer than thirty characters", ID3v1.1 title
#   "A title longer than thirty cha", track 3 in both.
ffmpeg "${silence[@]}" -id3v2_version 3 -write_id3v1 1 \
	-metadata title="A title longer than thirty characters" \
	-metadata artist="Marlowe Kite" \
	-metadata track=3 \
	v23_v1_long_title.mp3

# v23_unicode.mp3: text outside Latin-1, which ID3v2.3 stores in UTF-16 with a byte order mark.
# Expect: title "Café", artist "坂本龍一", album "Ελληνικά".
ffmpeg "${silence[@]}" -id3v2_version 3 -write_id3v1 0 \
	-metadata title="Café" \
	-metadata artist="坂本龍一" \
	-metadata album="Ελληνικά" \
	v23_unicode.mp3

# v24_unicode.mp3: the same text in ID3v2.4, which stores it in UTF-8.
# Expect: the values of v23_unicode.mp3.
ffmpeg "${silence[@]}" -id3v2_version 4 -write_id3v1 0 \
	-metadata title="Café" \
	-metadata artist="坂本龍一" \
	-metadata album="Ελληνικά" \
	v24_unicode.mp3

# v1_0_ascii.mp3: ID3v1.0, every field filled, the comment uses all 30 bytes. Offset 125 is not 0,
# so this is ID3v1.0 and there is no track number.
# Expect: title "Plain ASCII title", artist "Plain ASCII artist", album "Plain ASCII album",
#   year 1999, comment "A comment of exactly 30 bytes.", genre "Rock", no track.
ffmpeg "${silence[@]}" "${v1_only[@]}" \
	-metadata TIT2="Plain ASCII title" \
	-metadata TPE1="Plain ASCII artist" \
	-metadata TALB="Plain ASCII album" \
	-metadata TYER=1999 \
	-metadata comment="A comment of exactly 30 bytes." \
	-metadata TCON=Rock \
	v1_0_ascii.mp3

# v1_1_ascii.mp3: ID3v1.1, track number set, genre from the Winamp extension.
# Expect: title "Track seven", artist "Plain ASCII artist", album "Plain ASCII album", year 2004,
#   comment "Short comment", track 7, genre "Folk-Rock" (number 81, Winamp extension).
ffmpeg "${silence[@]}" "${v1_only[@]}" \
	-metadata TIT2="Track seven" \
	-metadata TPE1="Plain ASCII artist" \
	-metadata TALB="Plain ASCII album" \
	-metadata TYER=2004 \
	-metadata comment="Short comment" \
	-metadata TRCK=7 \
	-metadata TCON=Folk-Rock \
	v1_1_ascii.mp3

# v1_latin1.mp3: ID3v1.0 text in ISO-8859-1, as the spec intends.
# Raw bytes: title 43 61 66 e9, artist 42 6a f6 72 6b, album 53 65 f1 6f 72.
# Expect: title "Café", artist "Björk", album "Señor", comment "Latin-1", no genre.
ffmpeg "${silence[@]}" "${v1_only[@]}" \
	-metadata TIT2=$'Caf\xe9' \
	-metadata TPE1=$'Bj\xf6rk' \
	-metadata TALB=$'Se\xf1or' \
	-metadata comment="Latin-1" \
	v1_latin1.mp3

# v1_utf8.mp3: the same text in UTF-8, as ffmpeg writes it, against the spec.
# Raw bytes: title 43 61 66 c3 a9, artist 42 6a c3 b6 72 6b, album 53 65 c3 b1 6f 72.
# Expect: UTF-8 read as UTF-8 when its bytes are valid, as ffprobe does: the values of
#   v1_latin1.mp3, comment "UTF-8".
ffmpeg "${silence[@]}" "${v1_only[@]}" \
	-metadata TIT2="Café" \
	-metadata TPE1="Björk" \
	-metadata TALB="Señor" \
	-metadata comment="UTF-8" \
	v1_utf8.mp3

# v1_utf8_cut.mp3: a UTF-8 title cut by the 30 byte limit inside a character. The title given is
# 29 ASCII letters then "é" (c3 a9). Only c3 fits.
# Expect: title "ABCDEFGHIJKLMNOPQRSTUVWXYZabcÃ" (the field is not valid UTF-8, so Latin-1),
#   artist "Cut in the middle".
ffmpeg "${silence[@]}" "${v1_only[@]}" \
	-metadata TIT2="ABCDEFGHIJKLMNOPQRSTUVWXYZabcé" \
	-metadata TPE1="Cut in the middle" \
	v1_utf8_cut.mp3

# v1_utf8_cut_accents.mp3: a UTF-8 title with accents, cut by the 30 byte limit inside its last
# character: "Crème brûlée, à la françé" leaves c3 of the final "é".
# Expect: title "Crème brûlée, à la franç" (the cut character dropped).
ffmpeg "${silence[@]}" "${v1_only[@]}" \
	-metadata TIT2="Crème brûlée, à la françé" \
	v1_utf8_cut_accents.mp3

# v1_genre_out_of_range.mp3: genre byte 200, past the end of every genre list. ffmpeg cannot write
# it, so the last byte is patched.
# Expect: title "Unknown genre", genre number 200 with no name.
ffmpeg "${silence[@]}" "${v1_only[@]}" \
	-metadata TIT2="Unknown genre" \
	v1_genre_out_of_range.mp3
size=$(wc -c <v1_genre_out_of_range.mp3)
printf '\310' | dd of=v1_genre_out_of_range.mp3 bs=1 seek=$((size - 1)) conv=notrunc 2>/dev/null

# v1_enhanced.mp3: an Enhanced TAG ("TAG+", 227 bytes) before an ID3v1.0 tag. TAG+ holds the next
# 60 characters of the title, artist and album, a speed, a free genre and a start and end time.
# Expect: title "A title that needs the Enhanced TAG to fit" (30 characters in ID3v1, 12 in TAG+),
#   artist "Marlowe Kite", album "Small Hours", year 2019, speed 2 (medium), genre text
#   "Chamber Folk", start time "000:05", end time "001:30".
{
	cat no_tag.mp3
	printf 'TAG+'
	field "d TAG to fit" 60
	field "" 60
	field "" 60
	printf '\x02'
	field "Chamber Folk" 30
	printf '000:05001:30'
	printf 'TAG'
	field "A title that needs the Enhance" 30
	field "Marlowe Kite" 30
	field "Small Hours" 30
	printf '2019'
	field "" 30
	printf '\xff'
} >v1_enhanced.mp3

# lyrics3v1_v1.mp3: a Lyrics3 v1 tag ("LYRICSBEGIN", the lyrics, "LYRICSEND") before the ID3v1.0
# tag of v1_0_ascii.mp3, which Lyrics3 v1 requires.
# Expect: the ID3v1 values of v1_0_ascii.mp3; the Lyrics3 bytes found and kept, not read.
{
	cat no_tag.mp3
	printf 'LYRICSBEGIN[00:01]First line\r\n[00:05]Second lineLYRICSEND'
	tail -c 128 v1_0_ascii.mp3
} >lyrics3v1_v1.mp3

# lyrics3v2_v1.mp3: a Lyrics3 v2 tag before the ID3v1.0 tag of v1_0_ascii.mp3. After
# "LYRICSBEGIN" come fields (a 3 letter ID, a 5 digit size, the data): IND says lyrics and
# timestamps are present, LYR holds them. Then the size of everything from "LYRICSBEGIN" on in 6
# digits, then "LYRICS200".
# Expect: the ID3v1 values of v1_0_ascii.mp3; the Lyrics3 bytes found and kept, not read.
lyrics3v2='LYRICSBEGININD0000211LYR00017[00:01]First line'
{
	cat no_tag.mp3
	printf '%s%06dLYRICS200' "$lyrics3v2" "${#lyrics3v2}"
	tail -c 128 v1_0_ascii.mp3
} >lyrics3v2_v1.mp3

# ape.mp3: an APEv2 tag after the audio of no_tag.mp3 (ffmpeg cannot write APE tags).
# Expect: no ID3 tag; the APE bytes found and kept, not read.
{
	cat no_tag.mp3
	{
		ape_item Title "Paper Satellites"
		ape_item Artist "Marlowe Kite"
		ape_item Album "Small Hours"
	} | ape_tag 3
} >ape.mp3

# ape_v1.mp3: what MP3Gain leaves on a file with an ID3v1 tag: its APEv2 tag between the audio
# and ID3v1.
# Expect: the ID3v1 values of v1_0_ascii.mp3; the APE bytes found and kept, not read.
{
	cat no_tag.mp3
	{
		ape_item MP3GAIN_MINMAX 120,180
		ape_item Title "Title from APE"
	} | ape_tag 2
	tail -c 128 v1_0_ascii.mp3
} >ape_v1.mp3

# v23_extended.mp3, v24_extended.mp3, v24_itunes.mp3: frame level details, around the audio of
# no_tag.mp3.
# v23_extended.mp3: ID3v2.3 with an extended header (CRC 0x1234ABCD, padding size 5000), a title,
#   then 5000 bytes of padding.
#   Expect: title "Extended", the extended header's values, 5000 bytes of padding.
# v24_extended.mp3: ID3v2.4 with an extended header holding the update flag, a CRC (0x0BADF00D, in 5
#   syncsafe bytes) and the restrictions byte 0x21, then a title.
#   Expect: title "Extended", the extended header's values.
# v24_itunes.mp3: ID3v2.4 whose frame sizes are plain integers, as old iTunes wrote them: a TIT2
#   frame of 256 bytes in UTF-16 (read as syncsafe, its size would be 128), then a TPE1 frame.
#   Expect: both frames, a warning for plain frame sizes.
python3 - no_tag.mp3 <<'PY'
import sys
audio = open(sys.argv[1], 'rb').read()
def syncsafe(n):
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])
def write(name, header, body):
    open(name, 'wb').write(b'ID3' + header + syncsafe(len(body)) + body + audio)
title3 = b'\x00Extended'
title3_frame = b'TIT2' + len(title3).to_bytes(4, 'big') + b'\x00\x00' + title3
extended3 = (10).to_bytes(4, 'big') + b'\x80\x00' + (5000).to_bytes(4, 'big') + (0x1234ABCD).to_bytes(4, 'big')
write('v23_extended.mp3', b'\x03\x00\x40', extended3 + title3_frame + bytes(5000))
crc = 0x0BADF00D
crc_bytes = bytes([(crc >> 28) & 0x7F, (crc >> 21) & 0x7F, (crc >> 14) & 0x7F, (crc >> 7) & 0x7F, crc & 0x7F])
extended4 = syncsafe(15) + b'\x01\x70' + b'\x00' + b'\x05' + crc_bytes + b'\x01\x21'
title4 = b'\x03Extended'
write('v24_extended.mp3', b'\x04\x00\x40', extended4 + b'TIT2' + syncsafe(len(title4)) + b'\x00\x00' + title4)
text = '\ufeff' + 'Paper Satellites, a title long enough for 256 bytes. ' * 3
title = b'\x01' + text.encode('utf-16-le')[:255]
assert len(title) == 256
artist = b'\x01' + '\ufeffMarlowe Kite'.encode('utf-16-le')
body = b'TIT2' + len(title).to_bytes(4, 'big') + b'\x00\x00' + title
body += b'TPE1' + len(artist).to_bytes(4, 'big') + b'\x00\x00' + artist
write('v24_itunes.mp3', b'\x04\x00\x00', body + bytes(100))
PY

# v23_unsync.mp3: v23_unicode.mp3 with its whole tag unsynchronised, as ID3v2.3 does it: a 0x00 is
# inserted after every 0xFF followed by 0x00 or a byte of 0xE0 or more (the UTF-16 byte order marks
# are FF FE), and the tag header gets the unsynchronisation flag and the new size.
# Expect: the values of v23_unicode.mp3. ffmpeg reads the frame sizes against the stored bytes rather
#   than the decoded ones, so ffprobe only finds the title.
python3 - v23_unicode.mp3 v23_unsync.mp3 <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
size = (data[6] << 21) | (data[7] << 14) | (data[8] << 7) | data[9]
body, audio = data[10:10 + size], data[10 + size:]
out = bytearray()
for i, c in enumerate(body):
    out.append(c)
    if c == 0xFF and (i + 1 == len(body) or body[i + 1] >= 0xE0 or body[i + 1] == 0):
        out.append(0)
n = len(out)
header = b'ID3\x03\x00\x80' + bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])
open(sys.argv[2], 'wb').write(header + out + audio)
PY

# v24_unsync.mp3: an ID3v2.4 tag whose TIT2 frame, "Café" in UTF-16 (FF FE byte order mark), is
# unsynchronised on its own: its flags say unsynchronisation (0x02) and data length indicator
# (0x01), the indicator holds the size before unsynchronisation, the frame size the size after. A
# TPE1 frame in UTF-8 follows, untouched.
# Expect: title "Café", artist "Marlowe Kite".
python3 - no_tag.mp3 v24_unsync.mp3 <<'PY'
import sys
def syncsafe(n):
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])
def unsync(b):
    out = bytearray()
    for i, c in enumerate(b):
        out.append(c)
        if c == 0xFF and (i + 1 == len(b) or b[i + 1] >= 0xE0 or b[i + 1] == 0):
            out.append(0)
    return bytes(out)
title = b'\x01' + '\ufeffCafé'.encode('utf-16-le')
stored = syncsafe(len(title)) + unsync(title)
frames = b'TIT2' + syncsafe(len(stored)) + b'\x00\x03' + stored
artist = b'\x03Marlowe Kite'
frames += b'TPE1' + syncsafe(len(artist)) + b'\x00\x00' + artist
tag = b'ID3\x04\x00\x00' + syncsafe(len(frames)) + frames
open(sys.argv[2], 'wb').write(tag + open(sys.argv[1], 'rb').read())
PY

# v23_compressed.mp3, v24_compressed.mp3, v24_compression_bomb.mp3: compressed frames, made with
# Python's zlib so that the reader is never tested against odid3's own encoder.
# v23_compressed.mp3: ID3v2.3, a TIT2 frame compressed (format flag 0x80, then the decompressed size
#   in 4 bytes, then the zlib stream) and a plain TPE1 frame.
#   Expect: title "Compressed title, then la la la..." (repeated), artist "Marlowe Kite".
# v24_compressed.mp3: ID3v2.4, a TIT2 frame compressed with a data length indicator (0x09), and a
#   PRIV frame compressed then unsynchronised (0x0B), whose zlib stream holds 0xFF bytes.
#   Expect: the same title; PRIV content "odid3", a NUL, then 600 pseudo random bytes.
# v24_compression_bomb.mp3: ID3v2.4, a TIT2 frame whose zlib stream inflates to 16 MiB of zeros
#   while its data length indicator says 10 bytes.
#   Expect: the frame kept as stored, marked as badly compressed, without allocating 16 MiB.
python3 - no_tag.mp3 <<'PY'
import sys, zlib
audio = open(sys.argv[1], 'rb').read()
def syncsafe(n):
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])
def unsync(b):
    out = bytearray()
    for i, c in enumerate(b):
        out.append(c)
        if c == 0xFF and (i + 1 == len(b) or b[i + 1] >= 0xE0 or b[i + 1] == 0):
            out.append(0)
    return bytes(out)
def write(name, major, frames):
    size = syncsafe(len(frames))
    open(name, 'wb').write(b'ID3' + bytes([major, 0, 0]) + size + frames + audio)
title = b'\x00Compressed title, then' + b' la' * 40
compressed = zlib.compress(title, 9)
artist = b'\x00Marlowe Kite'
write('v23_compressed.mp3', 3,
    b'TIT2' + (4 + len(compressed)).to_bytes(4, 'big') + b'\x00\x80'
    + len(title).to_bytes(4, 'big') + compressed
    + b'TPE1' + len(artist).to_bytes(4, 'big') + b'\x00\x00' + artist)
# The first seed whose zlib stream holds a 0xFF that unsynchronisation must protect.
for seed in range(1, 1000):
    x = seed
    noise = bytearray()
    for _ in range(600):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        noise.append((x >> 16) & 0xFF)
    private = b'odid3\x00' + bytes(noise)
    private_stream = zlib.compress(private, 9)
    if unsync(private_stream) != private_stream:
        break
stored_private = unsync(private_stream)
stored_title = syncsafe(len(title)) + compressed
stored_private = syncsafe(len(private)) + stored_private
write('v24_compressed.mp3', 4,
    b'TIT2' + syncsafe(len(stored_title)) + b'\x00\x09' + stored_title
    + b'PRIV' + syncsafe(len(stored_private)) + b'\x00\x0b' + stored_private)
bomb = syncsafe(10) + zlib.compress(b'\x00' * (16 << 20), 9)
write('v24_compression_bomb.mp3', 4, b'TIT2' + syncsafe(len(bomb)) + b'\x00\x09' + bomb)
PY

# zlib/dynamic.z: 1500 bytes of skewed pseudo random letters (zlib/dynamic.txt), compressed by
# Python's zlib into a block with dynamic Huffman codes, for the tests of odid3's inflater.
mkdir -p zlib
python3 - zlib/dynamic.txt zlib/dynamic.z <<'PY'
import sys, zlib
x = 7
text = bytearray()
for _ in range(1500):
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF
    r = (x >> 16) % 100
    text.append(ord('e') if r < 30 else ord('t') if r < 50 else ord(' ') if r < 65 else ord('a') + r % 20)
stream = zlib.compress(bytes(text), 9)
assert (stream[2] >> 1) & 3 == 2, 'the block must use dynamic Huffman codes'
open(sys.argv[1], 'wb').write(bytes(text))
open(sys.argv[2], 'wb').write(stream)
PY

# truncated_tag.mp3: the first 150 bytes of v23_cover.mp3, cut inside the APIC frame.
# Expect: a partial tag (title "With a cover") and a warning, no crash.
head -c 150 v23_cover.mp3 >truncated_tag.mp3

# tiny_tag.mp3: a 3 byte file that is only "TAG".
# Expect: no tag (shorter than an ID3v1 tag), no crash.
printf 'TAG' >tiny_tag.mp3

# garbage.mp3: 10 bytes that are not an MP3.
# Expect: no tag, no crash.
printf 'not an mp3' >garbage.mp3

for fixture in ./*.mp3; do
	probe="ffprobe/$(basename "$fixture" .mp3).txt"
	if ! ffprobe -v error -show_format -show_streams -of flat "$fixture" >"$probe" 2>/dev/null; then
		rm -f "$probe"
	fi
done
