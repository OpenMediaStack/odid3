package odid3_tests

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:testing"

import odid3 "../"

@(test)
every_kind_has_an_id :: proc(t: ^testing.T) {
	versions := [?]odid3.V2_Version{.V2_2, .V2_3, .V2_4}
	for kind in odid3.Frame_Kind {
		found := false
		for version in versions {
			id, ok := odid3.frame_id(kind, version)
			if !ok {
				continue
			}
			found = true
			testing.expectf(t, len(id) == (3 if version == .V2_2 else 4), "%v: %q", kind, id)
			back, known := odid3.frame_kind(id, version)
			testing.expectf(t, known && back == kind, "%q in %v is %v", id, version, back)
		}
		testing.expectf(t, found, "%v has no ID", kind)
		_, none := odid3.frame_id(kind, .None)
		testing.expect(t, !none)
	}
}

@(test)
the_frames_of_each_version :: proc(t: ^testing.T) {
	// The ID3v2.2 IDs, the frames ID3v2.4 dropped and those it added: every other kind has its own
	// name as ID in ID3v2.3 and 2.4.
	v22 := [?]struct {
		kind: odid3.Frame_Kind,
		id:   string,
	} {
		{.AENC, "CRA"},
		{.APIC, "PIC"},
		{.COMM, "COM"},
		{.CRM, "CRM"},
		{.EQUA, "EQU"},
		{.ETCO, "ETC"},
		{.GEOB, "GEO"},
		{.GRP1, "GP1"},
		{.IPLS, "IPL"},
		{.LNK, "LNK"},
		{.MCDI, "MCI"},
		{.MLLT, "MLL"},
		{.MVIN, "MVI"},
		{.MVNM, "MVN"},
		{.PCNT, "CNT"},
		{.POPM, "POP"},
		{.RBUF, "BUF"},
		{.RVAD, "RVA"},
		{.RVRB, "REV"},
		{.SYLT, "SLT"},
		{.SYTC, "STC"},
		{.TALB, "TAL"},
		{.TBPM, "TBP"},
		{.TCMP, "TCP"},
		{.TCOM, "TCM"},
		{.TCON, "TCO"},
		{.TCOP, "TCR"},
		{.TDAT, "TDA"},
		{.TDLY, "TDY"},
		{.TENC, "TEN"},
		{.TEXT, "TXT"},
		{.TFLT, "TFT"},
		{.TIME, "TIM"},
		{.TIT1, "TT1"},
		{.TIT2, "TT2"},
		{.TIT3, "TT3"},
		{.TKEY, "TKE"},
		{.TLAN, "TLA"},
		{.TLEN, "TLE"},
		{.TMED, "TMT"},
		{.TOAL, "TOT"},
		{.TOFN, "TOF"},
		{.TOLY, "TOL"},
		{.TOPE, "TOA"},
		{.TORY, "TOR"},
		{.TPE1, "TP1"},
		{.TPE2, "TP2"},
		{.TPE3, "TP3"},
		{.TPE4, "TP4"},
		{.TPOS, "TPA"},
		{.TPUB, "TPB"},
		{.TRCK, "TRK"},
		{.TRDA, "TRD"},
		{.TSIZ, "TSI"},
		{.TSO2, "TS2"},
		{.TSOA, "TSA"},
		{.TSOC, "TSC"},
		{.TSOP, "TSP"},
		{.TSOT, "TST"},
		{.TSRC, "TRC"},
		{.TSSE, "TSS"},
		{.TXXX, "TXX"},
		{.TYER, "TYE"},
		{.UFID, "UFI"},
		{.USLT, "ULT"},
		{.WCOM, "WCM"},
		{.WCOP, "WCP"},
		{.WOAF, "WAF"},
		{.WOAR, "WAR"},
		{.WOAS, "WAS"},
		{.WPUB, "WPB"},
		{.WXXX, "WXX"},
	}
	v23_only := [?]odid3.Frame_Kind{.EQUA, .IPLS, .RVAD, .TDAT, .TIME, .TORY, .TRDA, .TSIZ, .TYER}
	v24_only := [?]odid3.Frame_Kind {
		.ASPI,
		.EQU2,
		.RVA2,
		.SEEK,
		.SIGN,
		.TDEN,
		.TDOR,
		.TDRC,
		.TDRL,
		.TDTG,
		.TIPL,
		.TMCL,
		.TMOO,
		.TPRO,
		.TSST,
	}
	in_v22: [odid3.Frame_Kind]string
	for p in v22 {
		in_v22[p.kind] = p.id
	}
	for kind in odid3.Frame_Kind {
		name := fmt.tprint(kind)
		v22_alone := kind == .CRM || kind == .LNK
		want := [3]string {
			in_v22[kind],
			"" if v22_alone || slice.contains(v24_only[:], kind) else name,
			"" if v22_alone || slice.contains(v23_only[:], kind) else name,
		}
		for version, i in ([?]odid3.V2_Version{.V2_2, .V2_3, .V2_4}) {
			id, _ := odid3.frame_id(kind, version)
			testing.expectf(t, id == want[i], "%v in %v: %q, want %q", kind, version, id, want[i])
		}
	}
}

@(test)
what_each_version_has :: proc(t: ^testing.T) {
	cases := []struct {
		kind:    odid3.Frame_Kind,
		version: odid3.V2_Version,
		id:      string,
	} {
		{.TIT2, .V2_2, "TT2"},
		{.APIC, .V2_2, "PIC"},
		{.TYER, .V2_2, "TYE"},
		{.TYER, .V2_3, "TYER"},
		{.TYER, .V2_4, ""},
		{.TDRC, .V2_3, ""},
		{.TDRC, .V2_4, "TDRC"},
		{.CTOC, .V2_2, ""},
		{.CTOC, .V2_3, "CTOC"},
		{.TSOP, .V2_2, "TSP"},
		{.TSOP, .V2_3, "TSOP"},
		{.LNK, .V2_2, "LNK"},
		{.LNK, .V2_3, ""},
		{.LINK, .V2_2, ""},
	}
	for c in cases {
		id, ok := odid3.frame_id(c.kind, c.version)
		testing.expectf(t, id == c.id && ok == (c.id != ""), "%v in %v: %q", c.kind, c.version, id)
	}

	// A frame read in a tag of a version that does not have it still has its kind.
	kind, known := odid3.frame_kind("TDRC", .V2_3)
	testing.expect(t, known && kind == .TDRC)
	_, known = odid3.frame_kind("TIT2", .V2_2)
	testing.expect(t, !known)
	_, known = odid3.frame_kind("XYZW", .V2_4)
	testing.expect(t, !known)
}

@(test)
frames_found_by_kind :: proc(t: ^testing.T) {
	for name in fixture_names(t) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		for f, i in tags.v2.frames {
			kind, known := odid3.frame_kind(f.id, tags.v2.version)
			if !known {
				continue
			}
			first, _ := odid3.find_frame(&tags.v2, f.id)
			index, ok := odid3.find_frame(&tags.v2, kind)
			testing.expectf(t, ok && index == first, "%s: %s found at %d", name, f.id, index)
			again, next := odid3.find_frame(&tags.v2, kind, i)
			testing.expectf(t, next && again == i, "%s: %s from %d", name, f.id, i)
		}
	}

	v22 := read(t, tag_file(2, 0, frame22("TT2", text("\x00Title"))))
	defer odid3.destroy(&v22)
	index, ok := odid3.find_frame(&v22.v2, .CTOC)
	testing.expect(t, index == -1 && !ok)
	index, ok = odid3.find_frame(&v22.v2, .TIT2)
	testing.expect(t, index == 0 && ok)

	date := read(t, tag_file(3, 0, frame(3, "TDRC", text("\x002019"))))
	defer odid3.destroy(&date)
	index, ok = odid3.find_frame(&date.v2, .TDRC)
	testing.expect(t, index == 0 && ok)
}

@(test)
frames_made_from_a_kind :: proc(t: ^testing.T) {
	title, err := odid3.make_frame(.TIT2, text("\x00Title"), .V2_2)
	defer odid3.destroy(&title)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, title.id, "TT2")
	testing.expect_value(t, string(title.data), "\x00Title")
	testing.expect_value(t, title.offset, -1)

	not_in_version := odid3.Error(odid3.Format_Error.Not_In_Version)
	refused := []struct {
		kind:    odid3.Frame_Kind,
		version: odid3.V2_Version,
	}{{.CTOC, .V2_2}, {.TYER, .V2_4}, {.TDRC, .V2_3}, {.LNK, .V2_4}}
	for c in refused {
		_, refused_err := odid3.make_frame(c.kind, text("\x00x"), c.version)
		testing.expectf(
			t,
			refused_err == not_in_version,
			"%v in %v: %v",
			c.kind,
			c.version,
			refused_err,
		)
	}
	_, none_err := odid3.make_frame(.TIT2, nil, .None)
	testing.expect_value(t, none_err, odid3.Error(odid3.Format_Error.No_Version))

	failing := Failing{context.allocator, 0}
	_, alloc_err := odid3.make_frame(.TIT2, text("\x00x"), .V2_4, failing_allocator(&failing))
	testing.expect_value(t, alloc_err, odid3.Error(mem.Allocator_Error.Out_Of_Memory))
}
