"""Prints what mutagen reads in the ID3 tags of a file, for tests/interop_test.odin.

Each line holds a key, its text encoding (0 to 3, or - for none) and its value, separated by tabs.
The first lines give the version and whether the header says the tag is unsynchronised. Then one
line per frame, in the version of the file (no translation to ID3v2.4): text values joined by
"; ", a picture's MIME type (or ID3v2.2 image format), type, size and CRC-32, or else mutagen's
own summary on one line. Frames mutagen does not know are listed as "unknown".
"""

import sys
import zlib

from mutagen.id3 import ID3

sys.stdout.reconfigure(encoding="utf-8")
tag = ID3(sys.argv[1], translate=False)
print("version\t-\t" + ".".join(str(n) for n in tag.version))
print(f"unsynchronisation\t-\t{bool(tag.f_unsynch)}")
for key, frame in sorted(tag.items()):
    encoding = str(int(frame.encoding)) if hasattr(frame, "encoding") else "-"
    if hasattr(frame, "mime"):
        value = f"{frame.mime} {int(frame.type)} {len(frame.data)} {zlib.crc32(frame.data):08x}"
    elif hasattr(frame, "text") and not isinstance(frame.text, str):
        value = "; ".join(str(text) for text in frame.text)
    else:
        value = " ".join(line.strip() for line in frame.pprint().splitlines())
    print(f"{key}\t{encoding}\t{value}")
for raw in tag.unknown_frames:
    print(f"unknown {raw[:4].decode('latin-1')}\t-\t{raw.hex()}")
