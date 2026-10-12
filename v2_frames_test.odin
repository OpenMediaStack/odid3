package odid3

import "core:slice"
import "core:testing"

@(test)
undo_unsynchronisation_takes_out_the_zero_after_each_0xFF :: proc(t: ^testing.T) {
	cases := []struct {
		input, output: []u8,
		removed:       []i64,
	} {
		{{0xFF, 0x00, 0xE0}, {0xFF, 0xE0}, {1}},
		{{0xFF, 0x00, 0x00}, {0xFF, 0x00}, {1}},
		{{1, 0xFF, 0x00, 2, 0xFF, 0x00}, {1, 0xFF, 2, 0xFF}, {2, 4}},
		{{0xFF, 0xFF, 0x00}, {0xFF, 0xFF}, {2}},
		{{0xFF}, {0xFF}, {}},
		{{0x00, 0xFF, 0xE0}, {0x00, 0xFF, 0xE0}, {}},
	}
	for c in cases {
		data := make([]u8, len(c.input))
		defer delete(data)
		copy(data, c.input)
		removed: [dynamic]i64
		defer delete(removed)
		out, err := undo_unsynchronisation(data, &removed)
		testing.expect_value(t, err, nil)
		testing.expectf(t, string(out) == string(c.output), "%v gave %v", c.input, out)
		testing.expectf(
			t,
			slice.equal(removed[:], c.removed),
			"%v removed %v",
			c.input,
			removed[:],
		)
	}
}
