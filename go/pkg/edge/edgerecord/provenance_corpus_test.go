package edgerecord

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// Task 1.5-h: THE SHARED TRANSPORT-PROVENANCE GUARD CORPUS.
//
// ONE BOUND, ONE TESTABLE SITE. `MaxTransportProvenanceHeaderBytes` bounds one encoded header
// on RECEIVED bytes before decode. The receive path is the only site that can fail for its own
// reason; the emit-side check is defence in depth over output the same function just built and
// gets no row.
//
// A GUARD, NOT AN ATTAINABLE MAXIMUM. No conforming producer emits a header at the ceiling --
// the largest this package can build is 468 bytes -- so the corpus never claims "512 accepted".
// It claims the largest CONFORMING header decodes, and that one over the ceiling is refused
// BEFORE the parser runs.
//
// THE STAGE IS THE OBLIGATION. Both an oversize and a malformed header are refused, so a
// verdict pair proves nothing about which ran first. The witness uses the decoder's OWN typed
// error, which this package already wraps with `%w`: at the ceiling a malformed header carries
// a `base64.CorruptInputError` (the parser ran), and one byte over it does not (the parser was
// never entered). That typed error is WHITE-BOX STAGE EVIDENCE ONLY -- it is not a normative
// refusal class, and no diagnostic text is frozen.

func provenanceCorpus(t *testing.T) map[string]int {
	t.Helper()

	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}

	f, err := os.Open(filepath.Join(wd, "..", "..", "..", "..", "proto", "edge", "v1", "testdata", "provenance_corpus.txt"))
	if err != nil {
		t.Fatalf("open provenance corpus: %v", err)
	}
	defer func() { _ = f.Close() }()

	out := map[string]int{}

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) < 2 {
			t.Fatalf("provenance corpus row %q needs a field and a value", line)
		}

		v, err := strconv.Atoi(fields[1])
		if err != nil {
			t.Fatalf("row %q: %v", line, err)
		}

		if _, dup := out[fields[0]]; dup {
			t.Fatalf("%s appears twice in the corpus", fields[0])
		}

		out[fields[0]] = v
	}

	if err := sc.Err(); err != nil {
		t.Fatalf("scan provenance corpus: %v", err)
	}

	want := []string{"bound", "largest_conforming", "witness_parser_ran", "witness_parser_skipped"}
	if len(out) != len(want) {
		t.Fatalf("corpus has %d fields, inventory has %d", len(out), len(want))
	}

	for _, k := range want {
		if _, ok := out[k]; !ok {
			t.Fatalf("corpus is missing field %q", k)
		}
	}

	return out
}

// TestProvenanceCorpusInventory pins the relationships the rows depend on, so a value cannot
// drift into a shape that still parses but proves something else.
func TestProvenanceCorpusInventory(t *testing.T) {
	c := provenanceCorpus(t)

	if c["bound"] != MaxTransportProvenanceHeaderBytes {
		t.Fatalf("MaxTransportProvenanceHeaderBytes is %d, the corpus freezes %d",
			MaxTransportProvenanceHeaderBytes, c["bound"])
	}

	if c["witness_parser_ran"] != c["bound"] {
		t.Fatalf("the live witness must sit AT the ceiling, not %d", c["witness_parser_ran"])
	}

	if c["witness_parser_skipped"] != c["bound"]+1 {
		t.Fatalf("the skipped witness must sit ONE over, not %d", c["witness_parser_skipped"])
	}

	// A GUARD: the largest conforming header must be STRICTLY under the ceiling. If it ever
	// reached it, the bound would be an attainable maximum and would owe a different pair.
	if c["largest_conforming"] >= c["bound"] {
		t.Fatalf("largest conforming header %d is not below the ceiling %d -- this is no longer a guard",
			c["largest_conforming"], c["bound"])
	}
}

// largestConformingProvenance builds the largest header this package can EMIT: an edge slot
// carrying a maximum-length principal, a delivery proof, and valid fixed-width numeric
// fields -- the numeric MAGNITUDE does not affect the length, since each is fixed-width.
func largestConformingProvenance(t *testing.T) string {
	t.Helper()

	slot := EdgeSlot{
		NetworkScopeID:       mustUUID(t),
		AuthenticatedAgentID: bytes.Repeat([]byte("x"), MaxPrincipalBytes),
		SpoolID:              mustUUID(t),
		Sequence:             1 << 62,
	}

	h, err := TransportProvenance(TransportProvenanceInput{
		Edge:            &slot,
		RecordSha256:    d32(0x01),
		DeliveryMode:    DeliveryModeRenewal,
		DeliveryProof:   bytes.Repeat([]byte{1}, sha256Len),
		RouteMapVersion: 1 << 62,
	})
	if err != nil {
		t.Fatalf("build largest conforming provenance: %v", err)
	}

	return h
}

func TestProvenanceLargestConformingDecodes(t *testing.T) {
	c := provenanceCorpus(t)
	h := largestConformingProvenance(t)

	// THE FROZEN LENGTH IS ASSERTED, not merely "under the ceiling". Without it a change that
	// shrank the envelope would leave the guard claim resting on a header that no longer
	// represents the maximum, and the corpus would stop describing the real headroom.
	if len(h) != c["largest_conforming"] {
		t.Fatalf("the largest conforming header is %d bytes, the corpus freezes %d",
			len(h), c["largest_conforming"])
	}

	if _, err := DecodeTransportProvenance(h); err != nil {
		t.Fatalf("the largest conforming header must decode: %v", err)
	}
}

// TestProvenanceGuardRunsBeforeTheParser is the stage witness.
//
// BOTH INPUTS ARE MALFORMED IN THE SAME WAY and differ only in length, so the only thing that
// can explain a difference in whether the parser ran is the guard.
func TestProvenanceGuardRunsBeforeTheParser(t *testing.T) {
	c := provenanceCorpus(t)

	// A trailing byte outside the base64url alphabet. Everything before it is valid, so the
	// decoder must reach the end to object -- which is what makes "the parser ran" observable.
	at := strings.Repeat("A", c["witness_parser_ran"]-1) + "!"
	over := strings.Repeat("A", c["witness_parser_ran"]-1) + "!!"

	if len(at) != c["witness_parser_ran"] || len(over) != c["witness_parser_skipped"] {
		t.Fatalf("witness lengths are %d/%d, want %d/%d",
			len(at), len(over), c["witness_parser_ran"], c["witness_parser_skipped"])
	}

	var corrupt base64.CorruptInputError

	_, atErr := DecodeTransportProvenance(at)
	if !errors.Is(atErr, ErrTransportProvenance) {
		t.Fatalf("a malformed header at the ceiling = %v, want ErrTransportProvenance", atErr)
	}

	// THE LIVE-WITNESS CONTROL. Without it, "the parser did not run" below is also what a
	// broken observation reports -- a renamed decoder, a swallowed error, a wrapper that stops
	// using %w. This row proves the observation can see the parser at all.
	if !errors.As(atErr, &corrupt) {
		t.Fatalf("at the ceiling the parser MUST run and surface its own error; got %v", atErr)
	}

	_, overErr := DecodeTransportProvenance(over)
	if !errors.Is(overErr, ErrTransportProvenance) {
		t.Fatalf("a malformed header one over = %v, want ErrTransportProvenance", overErr)
	}

	if errors.As(overErr, &corrupt) {
		t.Fatalf("one byte over the ceiling the parser was ENTERED -- the guard did not run "+
			"first, which is the work the bound exists to prevent; got %v", overErr)
	}
}
