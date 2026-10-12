"""Prints what mutagen reads in the ID3v2 tag of a file, for tests/interop_test.odin.

One line per frame: its key, a tab, then its text values joined by "; ", or for a picture its MIME
type (or ID3v2.2 image format) and its size. The first line gives the version. Frames are kept in
the version of the file (no translation to ID3v2.4).
"""

import sys

from mutagen.id3 import ID3

tag = ID3(sys.argv[1], translate=False)
print("version\t" + ".".join(str(n) for n in tag.version))
for key, frame in sorted(tag.items()):
    if hasattr(frame, "mime"):
        print(f"{key}\t{frame.mime} {len(frame.data)}")
    elif hasattr(frame, "text"):
        print(f"{key}\t" + "; ".join(str(value) for value in frame.text))
