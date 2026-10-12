package odid3

// The version of an ID3v1 tag. None means there is no tag.
V1_Version :: enum u8 {
	None,
	V1_0,
	V1_1,
}

// An ID3v1 tag: the last 128 bytes of a file.
V1_Tag :: struct {
	version: V1_Version,
}

@(private)
V1_SIZE :: 128
@(private)
V1_ENHANCED_SIZE :: 227

// ID3v1.1 takes the last two bytes of the comment for a zero and the track number.
@(private)
v1_version :: proc(tag: []u8) -> V1_Version {
	if len(tag) < V1_SIZE {
		return .None
	}
	if tag[125] == 0 && tag[126] != 0 {
		return .V1_1
	}
	return .V1_0
}
