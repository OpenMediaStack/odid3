#+private
package odid3

import "core:slice"
import "core:testing"

@(test)
undo_unsynchronisation_takes_out_the_zero_after_each_0xFF :: proc(t: ^testing.T) {
	cases := []struct {
		input, output: []u8,
		removed:       []u32,
		valid:         bool,
	} {
		{{0xFF, 0x00, 0xE0}, {0xFF, 0xE0}, {1}, true},
		{{0xFF, 0x00, 0x00}, {0xFF, 0x00}, {1}, true},
		{{1, 0xFF, 0x00, 2, 0xFF, 0x00}, {1, 0xFF, 2, 0xFF}, {2, 4}, true},
		{{0xFF, 0x12}, {0xFF, 0x12}, {}, true},
		{{0xFF}, {0xFF}, {}, false},
		{{0x00, 0xFF, 0xE0}, {0x00, 0xFF, 0xE0}, {}, false},
		{{0xFF, 0xFF, 0x00}, {0xFF, 0xFF, 0x00}, {}, false},
	}
	for c in cases {
		data := make([]u8, len(c.input))
		defer delete(data)
		copy(data, c.input)
		removed: [dynamic]u32
		defer delete(removed)
		out, valid, err := undo_unsynchronisation(data, &removed)
		testing.expect_value(t, err, nil)
		testing.expectf(t, valid == c.valid, "%v: valid %v", c.input, valid)
		testing.expectf(t, slice.equal(out, c.output), "%v gave %v", c.input, out)
		testing.expectf(
			t,
			slice.equal(removed[:], c.removed),
			"%v removed %v",
			c.input,
			removed[:],
		)
	}
}

@(test)
unsynchronised_parts_are_one_stream :: proc(t: ^testing.T) {
	cases := []struct {
		parts: [][]u8,
		want:  []u8,
	} {
		{{{0xFF}, {0x03}}, {0xFF, 0x03}},
		{{{0xFF}, {}, {0xE0}}, {0xFF, 0x00, 0xE0}},
		{{{0x01}, {0xFF}}, {0x01, 0xFF, 0x00}},
		{{{0xFF, 0x00}, {}}, {0xFF, 0x00, 0x00}},
	}
	for c in cases {
		out: [dynamic]u8
		defer delete(out)
		testing.expect_value(t, unsynchronise(&out, ..c.parts), nil)
		testing.expectf(t, string(out[:]) == string(c.want), "%v gave %v", c.parts, out[:])
		testing.expect_value(t, unsynchronised_size(..c.parts), len(c.want))
	}
}
