package odid3

// The frames odid3 knows, named after their ID3v2.3 or 2.4 ID: those of the ID3v2.2, 2.3 and 2.4
// specs, the chapters addendum's (CHAP, CTOC) and iTunes' own. CRM and LNK are ID3v2.2's alone,
// LNK because it names the frame it links to by an ID3v2.2 ID, where LINK names one of ID3v2.3 or
// 2.4. frame_id gives a kind's ID in each version; frames of any other ID are kept all the same,
// under their Frame.id. Kinds added later may renumber the others: store IDs, not kind values.
Frame_Kind :: enum u8 {
	AENC,
	APIC,
	ASPI,
	CHAP,
	COMM,
	COMR,
	CRM,
	CTOC,
	ENCR,
	EQU2,
	EQUA,
	ETCO,
	GEOB,
	GRID,
	GRP1,
	IPLS,
	LINK,
	LNK,
	MCDI,
	MLLT,
	MVIN,
	MVNM,
	OWNE,
	PCNT,
	PCST,
	POPM,
	POSS,
	PRIV,
	RBUF,
	RVA2,
	RVAD,
	RVRB,
	SEEK,
	SIGN,
	SYLT,
	SYTC,
	TALB,
	TBPM,
	TCAT,
	TCMP,
	TCOM,
	TCON,
	TCOP,
	TDAT,
	TDEN,
	TDES,
	TDLY,
	TDOR,
	TDRC,
	TDRL,
	TDTG,
	TENC,
	TEXT,
	TFLT,
	TGID,
	TIME,
	TIPL,
	TIT1,
	TIT2,
	TIT3,
	TKEY,
	TKWD,
	TLAN,
	TLEN,
	TMCL,
	TMED,
	TMOO,
	TOAL,
	TOFN,
	TOLY,
	TOPE,
	TORY,
	TOWN,
	TPE1,
	TPE2,
	TPE3,
	TPE4,
	TPOS,
	TPRO,
	TPUB,
	TRCK,
	TRDA,
	TRSN,
	TRSO,
	TSIZ,
	TSO2,
	TSOA,
	TSOC,
	TSOP,
	TSOT,
	TSRC,
	TSSE,
	TSST,
	TXXX,
	TYER,
	UFID,
	USER,
	USLT,
	WCOM,
	WCOP,
	WFED,
	WOAF,
	WOAR,
	WOAS,
	WORS,
	WPAY,
	WPUB,
	WXXX,
}

// A kind's ID in a version; ok is false when the version does not have the frame: ID3v2.2 has no
// CTOC, ID3v2.3 no TDRC, ID3v2.4 no TYER. iTunes' frames count in the versions iTunes writes them
// in: TCMP in ID3v2.3 and 2.4, TCP in ID3v2.2, and ID3v2.4's TSOP in ID3v2.3 too.
frame_id :: proc(kind: Frame_Kind, version: V2_Version) -> (id: string, ok: bool) {
	switch version {
	case .V2_2:
		id = FRAME_IDS[kind].v22
	case .V2_3:
		id = FRAME_IDS[kind].v23
	case .V2_4:
		id = FRAME_IDS[kind].v24
	case .None:
	}
	return id, id != ""
}

// The kind of a frame ID read in a tag of a version; ok is false for an ID odid3 does not know,
// and for one of the wrong length: 3 letters in an ID3v2.2 tag, 4 in ID3v2.3 and 2.4 tags, which
// share their 4 letter IDs (a TDRC read in an ID3v2.3 tag, which that version does not have, is
// still .TDRC). No ID has a kind in a tag of version .None.
frame_kind :: proc(id: string, version: V2_Version) -> (kind: Frame_Kind, ok: bool) {
	switch version {
	case .V2_2:
		if len(id) != 3 {
			return
		}
		for ids, k in FRAME_IDS {
			if ids.v22 == id {
				return k, true
			}
		}
	case .V2_3, .V2_4:
		if len(id) != 4 {
			return
		}
		// The kinds are in the order of their names, their 4 letter IDs but for CRM and LNK, which
		// keep their place among them: a 4 letter ID is found by bisection.
		low, high := 0, len(Frame_Kind)
		for low < high {
			middle := (low + high) / 2
			ids := FRAME_IDS[Frame_Kind(middle)]
			name := ids.v23 if ids.v23 != "" else ids.v24 if ids.v24 != "" else ids.v22
			switch {
			case id == name:
				return Frame_Kind(middle), true
			case id < name:
				high = middle
			case:
				low = middle + 1
			}
		}
	case .None:
	}
	return
}

// The ID a frame of this kind has in a tag of a version, whether the version has the frame or not:
// a 4 letter ID in ID3v2.3 and 2.4 tags, which can hold one another's frames, "" in an ID3v2.2 tag
// for a frame it has no ID for.
@(private)
id_in_tag :: proc(kind: Frame_Kind, version: V2_Version) -> string {
	ids := FRAME_IDS[kind]
	switch version {
	case .V2_2:
		return ids.v22
	case .V2_3, .V2_4:
		return ids.v23 if ids.v23 != "" else ids.v24
	case .None:
	}
	return ""
}

@(private)
Frame_Kinds :: bit_set[Frame_Kind;u128]

// The kind of a frame ID from its length alone, 3 letters being ID3v2.2's and 4 ID3v2.3's and
// 2.4's, as a set: empty for an ID odid3 does not know.
@(private)
kinds_of :: proc(id: string) -> Frame_Kinds {
	kind, ok := frame_kind(id, .V2_2 if len(id) == 3 else .V2_3)
	return {kind} if ok else {}
}

// Whether an ID is that of one of these kinds in either form, as kinds_of would find it.
@(private)
is_kind :: proc(id: string, kinds: Frame_Kinds) -> bool {
	if id == "" {
		return false
	}
	for kind in kinds {
		ids := FRAME_IDS[kind]
		if id == ids.v22 || id == ids.v23 || id == ids.v24 {
			return true
		}
	}
	return false
}

// Whether an ID is that of one of these kinds in the form of a version, as frame_kind reads it.
@(private)
is_kind_in :: proc(id: string, kinds: Frame_Kinds, version: V2_Version) -> bool {
	for kind in kinds {
		if form := id_in_tag(kind, version); form != "" && id == form {
			return true
		}
	}
	return false
}

@(private = "file")
Frame_Ids :: struct {
	v22, v23, v24: string,
}

// From the specs, the chapters addendum and the frames iTunes writes; "" where a version has no
// such frame.
@(private = "file", rodata)
FRAME_IDS := [Frame_Kind]Frame_Ids {
	.AENC = {v22 = "CRA", v23 = "AENC", v24 = "AENC"},
	.APIC = {v22 = "PIC", v23 = "APIC", v24 = "APIC"},
	.ASPI = {v24 = "ASPI"},
	.CHAP = {v23 = "CHAP", v24 = "CHAP"},
	.COMM = {v22 = "COM", v23 = "COMM", v24 = "COMM"},
	.COMR = {v23 = "COMR", v24 = "COMR"},
	.CRM = {v22 = "CRM"},
	.CTOC = {v23 = "CTOC", v24 = "CTOC"},
	.ENCR = {v23 = "ENCR", v24 = "ENCR"},
	.EQU2 = {v24 = "EQU2"},
	.EQUA = {v22 = "EQU", v23 = "EQUA"},
	.ETCO = {v22 = "ETC", v23 = "ETCO", v24 = "ETCO"},
	.GEOB = {v22 = "GEO", v23 = "GEOB", v24 = "GEOB"},
	.GRID = {v23 = "GRID", v24 = "GRID"},
	.GRP1 = {v22 = "GP1", v23 = "GRP1", v24 = "GRP1"},
	.IPLS = {v22 = "IPL", v23 = "IPLS"},
	.LINK = {v23 = "LINK", v24 = "LINK"},
	.LNK = {v22 = "LNK"},
	.MCDI = {v22 = "MCI", v23 = "MCDI", v24 = "MCDI"},
	.MLLT = {v22 = "MLL", v23 = "MLLT", v24 = "MLLT"},
	.MVIN = {v22 = "MVI", v23 = "MVIN", v24 = "MVIN"},
	.MVNM = {v22 = "MVN", v23 = "MVNM", v24 = "MVNM"},
	.OWNE = {v23 = "OWNE", v24 = "OWNE"},
	.PCNT = {v22 = "CNT", v23 = "PCNT", v24 = "PCNT"},
	.PCST = {v23 = "PCST", v24 = "PCST"},
	.POPM = {v22 = "POP", v23 = "POPM", v24 = "POPM"},
	.POSS = {v23 = "POSS", v24 = "POSS"},
	.PRIV = {v23 = "PRIV", v24 = "PRIV"},
	.RBUF = {v22 = "BUF", v23 = "RBUF", v24 = "RBUF"},
	.RVA2 = {v24 = "RVA2"},
	.RVAD = {v22 = "RVA", v23 = "RVAD"},
	.RVRB = {v22 = "REV", v23 = "RVRB", v24 = "RVRB"},
	.SEEK = {v24 = "SEEK"},
	.SIGN = {v24 = "SIGN"},
	.SYLT = {v22 = "SLT", v23 = "SYLT", v24 = "SYLT"},
	.SYTC = {v22 = "STC", v23 = "SYTC", v24 = "SYTC"},
	.TALB = {v22 = "TAL", v23 = "TALB", v24 = "TALB"},
	.TBPM = {v22 = "TBP", v23 = "TBPM", v24 = "TBPM"},
	.TCAT = {v23 = "TCAT", v24 = "TCAT"},
	.TCMP = {v22 = "TCP", v23 = "TCMP", v24 = "TCMP"},
	.TCOM = {v22 = "TCM", v23 = "TCOM", v24 = "TCOM"},
	.TCON = {v22 = "TCO", v23 = "TCON", v24 = "TCON"},
	.TCOP = {v22 = "TCR", v23 = "TCOP", v24 = "TCOP"},
	.TDAT = {v22 = "TDA", v23 = "TDAT"},
	.TDEN = {v24 = "TDEN"},
	.TDES = {v23 = "TDES", v24 = "TDES"},
	.TDLY = {v22 = "TDY", v23 = "TDLY", v24 = "TDLY"},
	.TDOR = {v24 = "TDOR"},
	.TDRC = {v24 = "TDRC"},
	.TDRL = {v24 = "TDRL"},
	.TDTG = {v24 = "TDTG"},
	.TENC = {v22 = "TEN", v23 = "TENC", v24 = "TENC"},
	.TEXT = {v22 = "TXT", v23 = "TEXT", v24 = "TEXT"},
	.TFLT = {v22 = "TFT", v23 = "TFLT", v24 = "TFLT"},
	.TGID = {v23 = "TGID", v24 = "TGID"},
	.TIME = {v22 = "TIM", v23 = "TIME"},
	.TIPL = {v24 = "TIPL"},
	.TIT1 = {v22 = "TT1", v23 = "TIT1", v24 = "TIT1"},
	.TIT2 = {v22 = "TT2", v23 = "TIT2", v24 = "TIT2"},
	.TIT3 = {v22 = "TT3", v23 = "TIT3", v24 = "TIT3"},
	.TKEY = {v22 = "TKE", v23 = "TKEY", v24 = "TKEY"},
	.TKWD = {v23 = "TKWD", v24 = "TKWD"},
	.TLAN = {v22 = "TLA", v23 = "TLAN", v24 = "TLAN"},
	.TLEN = {v22 = "TLE", v23 = "TLEN", v24 = "TLEN"},
	.TMCL = {v24 = "TMCL"},
	.TMED = {v22 = "TMT", v23 = "TMED", v24 = "TMED"},
	.TMOO = {v24 = "TMOO"},
	.TOAL = {v22 = "TOT", v23 = "TOAL", v24 = "TOAL"},
	.TOFN = {v22 = "TOF", v23 = "TOFN", v24 = "TOFN"},
	.TOLY = {v22 = "TOL", v23 = "TOLY", v24 = "TOLY"},
	.TOPE = {v22 = "TOA", v23 = "TOPE", v24 = "TOPE"},
	.TORY = {v22 = "TOR", v23 = "TORY"},
	.TOWN = {v23 = "TOWN", v24 = "TOWN"},
	.TPE1 = {v22 = "TP1", v23 = "TPE1", v24 = "TPE1"},
	.TPE2 = {v22 = "TP2", v23 = "TPE2", v24 = "TPE2"},
	.TPE3 = {v22 = "TP3", v23 = "TPE3", v24 = "TPE3"},
	.TPE4 = {v22 = "TP4", v23 = "TPE4", v24 = "TPE4"},
	.TPOS = {v22 = "TPA", v23 = "TPOS", v24 = "TPOS"},
	.TPRO = {v24 = "TPRO"},
	.TPUB = {v22 = "TPB", v23 = "TPUB", v24 = "TPUB"},
	.TRCK = {v22 = "TRK", v23 = "TRCK", v24 = "TRCK"},
	.TRDA = {v22 = "TRD", v23 = "TRDA"},
	.TRSN = {v23 = "TRSN", v24 = "TRSN"},
	.TRSO = {v23 = "TRSO", v24 = "TRSO"},
	.TSIZ = {v22 = "TSI", v23 = "TSIZ"},
	.TSO2 = {v22 = "TS2", v23 = "TSO2", v24 = "TSO2"},
	.TSOA = {v22 = "TSA", v23 = "TSOA", v24 = "TSOA"},
	.TSOC = {v22 = "TSC", v23 = "TSOC", v24 = "TSOC"},
	.TSOP = {v22 = "TSP", v23 = "TSOP", v24 = "TSOP"},
	.TSOT = {v22 = "TST", v23 = "TSOT", v24 = "TSOT"},
	.TSRC = {v22 = "TRC", v23 = "TSRC", v24 = "TSRC"},
	.TSSE = {v22 = "TSS", v23 = "TSSE", v24 = "TSSE"},
	.TSST = {v24 = "TSST"},
	.TXXX = {v22 = "TXX", v23 = "TXXX", v24 = "TXXX"},
	.TYER = {v22 = "TYE", v23 = "TYER"},
	.UFID = {v22 = "UFI", v23 = "UFID", v24 = "UFID"},
	.USER = {v23 = "USER", v24 = "USER"},
	.USLT = {v22 = "ULT", v23 = "USLT", v24 = "USLT"},
	.WCOM = {v22 = "WCM", v23 = "WCOM", v24 = "WCOM"},
	.WCOP = {v22 = "WCP", v23 = "WCOP", v24 = "WCOP"},
	.WFED = {v23 = "WFED", v24 = "WFED"},
	.WOAF = {v22 = "WAF", v23 = "WOAF", v24 = "WOAF"},
	.WOAR = {v22 = "WAR", v23 = "WOAR", v24 = "WOAR"},
	.WOAS = {v22 = "WAS", v23 = "WOAS", v24 = "WOAS"},
	.WORS = {v23 = "WORS", v24 = "WORS"},
	.WPAY = {v23 = "WPAY", v24 = "WPAY"},
	.WPUB = {v22 = "WPB", v23 = "WPUB", v24 = "WPUB"},
	.WXXX = {v22 = "WXX", v23 = "WXXX", v24 = "WXXX"},
}
