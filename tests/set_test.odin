package odid3_tests

import "core:mem"
import "core:testing"

import odid3 "../"

expect_set :: proc(
	t: ^testing.T,
	tag: ^odid3.Tag,
	field: odid3.Field,
	value: string,
	loc := #caller_location,
) {
	testing.expect_value(t, odid3.set(tag, field, value), nil, loc = loc)
	testing.expect_value(t, tag_field(tag, field), value, loc = loc)
}

@(test)
set_every_field_in_every_version :: proc(t: ^testing.T) {
	for name in ([]string{"v22.mp3", "v23_full.mp3", "v24_full.mp3"}) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		tag := &tags.v2
		expect_set(t, tag, .Title, "Nouveau titre")
		expect_set(t, tag, .Artist, "坂本龍一")
		expect_set(t, tag, .Album_Artist, "Various")
		expect_set(t, tag, .Album, "Ελληνικά")
		expect_set(t, tag, .Date, "2021-06-15T08:30")
		expect_set(t, tag, .Track, "5")
		expect_set(t, tag, .Track_Total, "9")
		expect_set(t, tag, .Disc, "2")
		expect_set(t, tag, .Disc_Total, "3")
		expect_set(t, tag, .Genre, "Jazz")
		expect_set(t, tag, .Comment, "Écrit par odid3")
		number, total := odid3.track(tag)
		testing.expect(t, number == 5 && total == 9)

		rendered, err := odid3.render(tag, {}, context.temp_allocator)
		testing.expectf(t, err == nil, "%s: %v", name, err)
		again := read(t, rendered)
		defer odid3.destroy(&again)
		testing.expect_value(t, field(&again, .Artist), "坂本龍一")
		testing.expect_value(t, field(&again, .Date), "2021-06-15T08:30")
		testing.expect_value(t, field(&again, .Comment), "Écrit par odid3")
	}
}

@(test)
encodings_chosen_on_set :: proc(t: ^testing.T) {
	v23 := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&v23)
	odid3.set(&v23.v2, .Title, "Plain")
	index, _ := odid3.find_frame(&v23.v2, "TIT2")
	testing.expect_value(t, v23.v2.frames[index].data[0], 0)
	testing.expect_value(t, index, 0)
	odid3.set(&v23.v2, .Title, "Ελληνικά")
	testing.expect_value(t, v23.v2.frames[index].data[0], 1)

	v24 := read(t, fixture(t, "v24_full.mp3"))
	defer odid3.destroy(&v24)
	odid3.set(&v24.v2, .Title, "Plain")
	index, _ = odid3.find_frame(&v24.v2, "TIT2")
	testing.expect_value(t, v24.v2.frames[index].data[0], 3)

	latin1 := read(t, tag_file(4, 0, frame(4, "TIT2", text("\x00Old"))))
	defer odid3.destroy(&latin1)
	odid3.set(&latin1.v2, .Title, "New")
	testing.expect_value(t, latin1.v2.frames[0].data[0], 0)
	odid3.set(&latin1.v2, .Title, "Ελληνικά")
	testing.expect_value(t, latin1.v2.frames[0].data[0], 3)
}

@(test)
removing_fields :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&tags)
	count := len(tags.v2.frames)
	for f in odid3.Field {
		testing.expect_value(t, odid3.set(&tags.v2, f, ""), nil)
		testing.expectf(
			t,
			tag_field(&tags.v2, f) == "",
			"%v still holds %q",
			f,
			tag_field(&tags.v2, f),
		)
	}
	testing.expectf(
		t,
		len(tags.v2.frames) == 0,
		"%d of %d frames left",
		len(tags.v2.frames),
		count,
	)
}

@(test)
dates_split_before_v24 :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&tags)
	odid3.set(&tags.v2, .Date, "2021-06-15T08:30")
	for c in ([]struct {
			id, value: string,
		}{{"TYER", "2021"}, {"TDAT", "1506"}, {"TIME", "0830"}}) {
		index, ok := odid3.find_frame(&tags.v2, c.id)
		testing.expectf(t, ok, "no %s", c.id)
		if ok {
			testing.expect_value(t, string(tags.v2.frames[index].data[1:]), c.value)
		}
	}
	odid3.set(&tags.v2, .Date, "1999")
	_, has_tdat := odid3.find_frame(&tags.v2, "TDAT")
	testing.expect(t, !has_tdat)
	testing.expect_value(t, tag_field(&tags.v2, .Date), "1999")
}

@(test)
ffmpeg_comment_becomes_comm :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&tags)
	odid3.set(&tags.v2, .Comment, "Rewritten")
	_, found, _ := odid3.user_text(&tags.v2, "comment", context.temp_allocator)
	testing.expect(t, !found)
	testing.expect_value(t, len(odid3.comments(&tags.v2, context.temp_allocator)), 1)
}

@(test)
pictures_user_text_and_numbers :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v23_cover.mp3"))
	defer odid3.destroy(&tags)
	back := odid3.Picture {
		mime        = "image/jpeg",
		type        = .Back_Cover,
		description = "Dos",
		data        = text("\xFF\xD8back"),
	}
	testing.expect_value(t, odid3.set_picture(&tags.v2, back), nil)
	testing.expect_value(t, len(odid3.pictures(&tags.v2, context.temp_allocator)), 2)
	front := back
	front.type = .Front_Cover
	front.data = text("\xFF\xD8front")
	odid3.set_picture(&tags.v2, front)
	all := odid3.pictures(&tags.v2, context.temp_allocator)
	testing.expect_value(t, len(all), 2)
	cover, _, _ := odid3.front_cover(&tags.v2, context.temp_allocator)
	testing.expect_value(t, string(cover.data), "\xFF\xD8front")
	odid3.remove_pictures(&tags.v2, odid3.Picture_Type.Back_Cover)
	testing.expect_value(t, len(odid3.pictures(&tags.v2, context.temp_allocator)), 1)
	odid3.remove_pictures(&tags.v2)
	testing.expect_value(t, len(odid3.pictures(&tags.v2, context.temp_allocator)), 0)

	odid3.set_user_text(&tags.v2, "MOOD", "Calm")
	odid3.set_user_text(&tags.v2, "mood", "Bright")
	value, found, _ := odid3.user_text(&tags.v2, "Mood", context.temp_allocator)
	testing.expect(t, found && value == "Bright")
	odid3.set_user_text(&tags.v2, "mood", "")
	_, found, _ = odid3.user_text(&tags.v2, "mood", context.temp_allocator)
	testing.expect(t, !found)

	odid3.set_track(&tags.v2, 4, 10)
	testing.expect_value(t, tag_field(&tags.v2, .Track), "4")
	testing.expect_value(t, tag_field(&tags.v2, .Track_Total), "10")
	odid3.set_disc(&tags.v2, 1, 0)
	testing.expect_value(t, tag_field(&tags.v2, .Disc), "1")
	odid3.set_genres(&tags.v2, {"Jazz", "Folk"})
	testing.expect_value(t, tag_field(&tags.v2, .Genre), "Jazz/Folk")
}

@(test)
encode_and_decode_agree :: proc(t: ^testing.T) {
	contents := []struct {
		id:      string,
		content: odid3.Frame_Content,
	} {
		{"TIT2", odid3.Text{.UTF16, {"Café"}}},
		{"TXXX", odid3.User_Text{.Latin1, "mood", {"Calm"}}},
		{"WOAR", odid3.Url{"https://example.com"}},
		{"WXXX", odid3.User_Url{.UTF16, "Shop", "https://example.com"}},
		{"COMM", odid3.Comment{.Latin1, {'f', 'r', 'a'}, "Note", "Bonjour"}},
		{"APIC", odid3.Picture{.UTF16, "image/png", .Front_Cover, "Face", text("\x89PNG")}},
		{"UFID", odid3.Unique_File_Id{"http://musicbrainz.org", text("id")}},
		{"POPM", odid3.Popularimeter{"me@example.com", 196, 300}},
		{"PCNT", odid3.Play_Counter{12}},
		{"PRIV", odid3.Private{"owner", text("\x01\x02")}},
		{"MCDI", odid3.Binary{text("\x01\x02\x03")}},
	}
	for version in ([]odid3.V2_Version{.V2_3, .V2_4}) {
		for c in contents {
			f, err := odid3.encode_frame(c.content, c.id, version)
			testing.expectf(t, err == nil, "%s: %v", c.id, err)
			defer odid3.destroy(&f)
			decoded, decode_err := odid3.decode_frame(&f, version, context.temp_allocator)
			testing.expectf(t, decode_err == nil, "%s: %v", c.id, decode_err)
			testing.expectf(
				t,
				contents_equal(c.content, decoded),
				"%s: %v gave %v",
				c.id,
				c.content,
				decoded,
			)
		}
	}
	_, err := odid3.encode_frame(odid3.Text{.UTF8, {"Café"}}, "TIT2", .V2_3)
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Encoding_Not_In_Version))
	_, err = odid3.encode_frame(odid3.Text{.Latin1, {"坂本"}}, "TIT2", .V2_4)
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Not_Encodable))
	_, err = odid3.encode_frame(odid3.Text{.Latin1, {"x"}}, "TIT2", .V2_2)
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Bad_Frame_Id))
}

contents_equal :: proc(a, b: odid3.Frame_Content) -> bool {
	switch x in a {
	case odid3.Text:
		y := b.(odid3.Text) or_return
		return x.encoding == y.encoding && strings_equal(x.values, y.values)
	case odid3.User_Text:
		y := b.(odid3.User_Text) or_return
		return x.description == y.description && strings_equal(x.values, y.values)
	case odid3.Url:
		return x.url == (b.(odid3.Url) or_return).url
	case odid3.User_Url:
		y := b.(odid3.User_Url) or_return
		return x.description == y.description && x.url == y.url
	case odid3.Comment:
		y := b.(odid3.Comment) or_return
		return x.language == y.language && x.description == y.description && x.text == y.text
	case odid3.Picture:
		y := b.(odid3.Picture) or_return
		return(
			x.mime == y.mime &&
			x.type == y.type &&
			x.description == y.description &&
			string(x.data) == string(y.data) \
		)
	case odid3.Unique_File_Id:
		y := b.(odid3.Unique_File_Id) or_return
		return x.owner == y.owner && string(x.identifier) == string(y.identifier)
	case odid3.Popularimeter:
		y := b.(odid3.Popularimeter) or_return
		return x.email == y.email && x.rating == y.rating && x.counter == y.counter
	case odid3.Play_Counter:
		return x.counter == (b.(odid3.Play_Counter) or_return).counter
	case odid3.Private:
		y := b.(odid3.Private) or_return
		return x.owner == y.owner && string(x.data) == string(y.data)
	case odid3.Binary:
		return string(x.data) == string((b.(odid3.Binary) or_return).data)
	case odid3.Chapter, odid3.Table_Of_Contents:
	}
	return false
}

strings_equal :: proc(a, b: []string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for s, i in a {
		if s != b[i] {
			return false
		}
	}
	return true
}

@(test)
setting_fails_cleanly_without_memory :: proc(t: ^testing.T) {
	data := fixture(t, "v24_full.mp3")
	for budget in 0 ..< 80 {
		failing := Failing{context.allocator, budget}
		allocator := failing_allocator(&failing)
		tags, err := odid3.read_bytes(data, {}, allocator)
		if err != nil {
			continue
		}
		set_err := odid3.set(&tags.v2, .Title, "Une autre valeur")
		odid3.destroy(&tags)
		if set_err == nil {
			return
		}
		testing.expect_value(t, set_err, odid3.Error(mem.Allocator_Error.Out_Of_Memory))
	}
}
