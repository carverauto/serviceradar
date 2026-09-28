/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package spool

// Segment rotation bounds (task 2.24 of
// openspec/changes/unify-sweep-results-proto): the ALTERNATING-attribution
// test proving the run bound binds where a distinct-key bound alone would
// not, the key and manifest-size legs, restart persistence, and the proof
// that any admitted segment's worst-case manifest fits the recovery
// grammar's page and byte ceilings.
//
// Every digest, UUID, and identity below is synthetic: sha256 over a label or
// repeated bytes with the required version/variant bits set. Nothing is
// captured from a live system.

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"math"
	"strings"
	"testing"

	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// attrKey returns a synthetic 32-byte attribution binding digest.
func attrKey(seed string) []byte {
	sum := sha256.Sum256([]byte("spool-segment-test:" + seed))
	return sum[:]
}

// openBoundedSpool opens a spool whose rotation limits are replaced with the
// test's, so each bound can be proven to bind without thousands of commits.
// Limits only: bounds state always rebuilds from the commit evidence.
func openBoundedSpool(t *testing.T, dir string, lim segmentLimits) *Spool {
	t.Helper()
	s, err := Open(dir)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	s.segBounds.limits = lim
	return s
}

func mustBoundCommit(t *testing.T, s *Spool, ev byte, key []byte) CommitReceipt {
	t.Helper()
	r, err := s.Commit(evid(ev), []byte{ev}, Bindings{AttributionSHA256: key})
	if err != nil {
		t.Fatalf("Commit: %v", err)
	}
	return r
}

// boundsStats snapshots the open segment's rotation accounting under the spool
// mutex, the way the removed exported SegmentBoundsStats method did.
func boundsStats(t *testing.T, s *Spool) segmentBoundsStats {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.segBounds.stats()
}

// TestAlternatingAttributionTripsRunBoundNotKeyBound is task 2.24's witnesses:
// keys A,B,A,B,... hold the distinct-key count at 2 while opening one run per
// record, so the run bound -- and only the run bound -- refuses the next
// append as ROTATION_REQUIRED.
func TestAlternatingAttributionTripsRunBoundNotKeyBound(t *testing.T) {
	const maxRuns = 16
	s := openBoundedSpool(t, t.TempDir(), segmentLimits{maxKeys: 64, maxRuns: maxRuns, maxManifestBytes: 1 << 30})
	a, b := attrKey("A"), attrKey("B")

	for i := 0; i < maxRuns; i++ {
		key := a
		if i%2 == 1 {
			key = b
		}
		mustBoundCommit(t, s, byte(i), key)
	}
	stats := boundsStats(t, s)
	if stats.Keys != 2 {
		t.Fatalf("distinct keys = %d, want 2: the key bound alone would never bind here", stats.Keys)
	}
	if stats.Runs != maxRuns {
		t.Fatalf("runs = %d, want %d", stats.Runs, maxRuns)
	}

	_, err := s.Commit(evid(0xA0), []byte("one-too-many"), Bindings{AttributionSHA256: a})
	requireRetryable(t, err, ErrRotationRequired)
	if !strings.Contains(err.Error(), "runs") {
		t.Fatalf("refusal = %v; want the runs leg named", err)
	}
	// The refusal wrote nothing and allocated no sequence: the producer's
	// retry after rotation lands exactly where the refused append would have.
	if got := s.NextSequence(); got != maxRuns+1 {
		t.Fatalf("NextSequence after refusal = %d, want %d", got, maxRuns+1)
	}
}

// TestDistinctKeysTripKeyBound proves the keys leg binds first for a workload
// the run and manifest legs would admit: few runs, cheap spans, but more
// distinct attributions than the segment may index.
func TestDistinctKeysTripKeyBound(t *testing.T) {
	const maxKeys = 4
	s := openBoundedSpool(t, t.TempDir(), segmentLimits{maxKeys: maxKeys, maxRuns: 1 << 20, maxManifestBytes: 1 << 30})

	// One append per key would also grow runs, so reuse two keys to hold the
	// run count down, then introduce fresh keys one at a time.
	a := attrKey("A")
	mustBoundCommit(t, s, 1, a)
	mustBoundCommit(t, s, 2, a)
	for i := uint(0); i < maxKeys-1; i++ {
		mustBoundCommit(t, s, byte(3+i), attrKey(string(rune('B'+i))))
	}
	if got := boundsStats(t, s).Keys; got != maxKeys {
		t.Fatalf("distinct keys = %d, want %d", got, maxKeys)
	}
	_, err := s.Commit(evid(0xB0), []byte("one-too-many"), Bindings{AttributionSHA256: attrKey("fresh")})
	requireRetryable(t, err, ErrRotationRequired)
	if !strings.Contains(err.Error(), "keys") {
		t.Fatalf("refusal = %v; want the keys leg named", err)
	}
}

// TestManifestBytesBindFirst proves the manifest-size leg binds first for a
// heavily attributed segment: few keys, few runs, but worst-case spans whose
// projected pages would exceed the byte ceiling.
func TestManifestBytesBindFirst(t *testing.T) {
	const maxBytes = 2000
	s := openBoundedSpool(t, t.TempDir(), segmentLimits{maxKeys: 1 << 20, maxRuns: 1 << 20, maxManifestBytes: maxBytes})
	a, b := attrKey("A"), attrKey("B")

	committed := 0
	for i := 0; i < 100; i++ {
		key := a
		if i%2 == 1 {
			key = b
		}
		if _, err := s.Commit(evid(byte(i)), []byte{byte(i)}, Bindings{AttributionSHA256: key}); err != nil {
			requireRetryable(t, err, ErrRotationRequired)
			if !strings.Contains(err.Error(), "manifest") {
				t.Fatalf("refusal = %v; want the manifest leg named", err)
			}
			break
		}
		committed++
	}
	stats := boundsStats(t, s)
	if committed == 100 {
		t.Fatalf("100 attributed appends admitted under a %dB budget; the manifest leg never bound", maxBytes)
	}
	if stats.Runs >= 1<<20 || stats.Keys >= 1<<20 {
		t.Fatalf("stats = %+v; the run/key legs must not have bound first", stats)
	}
	if stats.ProjectedBytes > maxBytes {
		t.Fatalf("projected = %dB over the %dB budget: admission leaked past the bound", stats.ProjectedBytes, maxBytes)
	}
}

// TestUnattributedAppendsNeverShareRuns pins the conservative nil handling:
// an append declaring no binding opens its own run even beside another
// unattributed append, because their future corruption reasons are unknowable
// at append time.
func TestUnattributedAppendsNeverShareRuns(t *testing.T) {
	const maxRuns = 4
	s := openBoundedSpool(t, t.TempDir(), segmentLimits{maxKeys: 64, maxRuns: maxRuns, maxManifestBytes: 1 << 30})

	for i := 0; i < maxRuns; i++ {
		if _, err := s.Append(evid(byte(i)), []byte{byte(i)}); err != nil {
			t.Fatalf("Append: %v", err)
		}
	}
	if stats := boundsStats(t, s); stats.Runs != maxRuns || stats.Keys != 0 {
		t.Fatalf("stats = %+v; want %d runs and no keys", stats, maxRuns)
	}
	_, err := s.Append(evid(0xC0), []byte("one-too-many"))
	requireRetryable(t, err, ErrRotationRequired)
}

// TestBoundsSurviveReopen proves a restart never resets the bounds: the
// rebuilt accounting refuses at exactly the point the pre-crash accounting
// would have.
func TestBoundsSurviveReopen(t *testing.T) {
	lim := segmentLimits{maxKeys: 64, maxRuns: 8, maxManifestBytes: 1 << 30}
	dir := t.TempDir()
	a, b := attrKey("A"), attrKey("B")

	s := openBoundedSpool(t, dir, lim)
	for i := 0; i < 6; i++ {
		key := a
		if i%2 == 1 {
			key = b
		}
		mustBoundCommit(t, s, byte(i), key)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	reopened, err := Open(dir)
	if err != nil {
		t.Fatalf("re-Open: %v", err)
	}
	t.Cleanup(func() { _ = reopened.Close() })
	reopened.segBounds.limits = lim

	stats := boundsStats(t, reopened)
	if stats.Runs != 6 || stats.Keys != 2 {
		t.Fatalf("rebuilt stats = %+v; want 6 runs and 2 keys", stats)
	}
	mustBoundCommit(t, reopened, 6, a)
	mustBoundCommit(t, reopened, 7, b)
	if _, err := reopened.Commit(evid(8), []byte{8}, Bindings{AttributionSHA256: a}); !errors.Is(err, ErrRotationRequired) {
		t.Fatalf("post-reopen refusal = %v; want ROTATION_REQUIRED at 9 runs", err)
	}
}

// TestLaneSetRotatesOnSegmentBounds proves the lane-level contract: the
// bounds refusal surfaces as retryable ROTATION_REQUIRED, Rotate opens a
// successor with fresh bounds, and the retried append lands there at sequence
// 1 while the full generation stays retained and readable.
func TestLaneSetRotatesOnSegmentBounds(t *testing.T) {
	ls := openLanes(t, t.TempDir(), sessionA)
	lim := segmentLimits{maxKeys: 64, maxRuns: 8, maxManifestBytes: 1 << 30}
	ls.testSegBounds = &lim
	a, b := attrKey("A"), attrKey("B")

	var last Receipt
	for i := 0; i < 8; i++ {
		key := a
		if i%2 == 1 {
			key = b
		}
		var err error
		last, err = ls.AppendWithBindings(bulkLane, sessionA, evid(byte(i)), []byte{byte(i)}, Bindings{AttributionSHA256: key})
		if err != nil {
			t.Fatalf("AppendWithBindings(%d): %v", i, err)
		}
	}
	if last.Sequence != 8 {
		t.Fatalf("last sequence = %d, want 8", last.Sequence)
	}
	_, err := ls.AppendWithBindings(bulkLane, sessionA, evid(8), []byte{8}, Bindings{AttributionSHA256: a})
	requireRetryable(t, err, ErrRotationRequired)

	next, err := ls.Rotate(bulkLane)
	if err != nil {
		t.Fatalf("Rotate: %v", err)
	}
	if next.Ordinal != 2 {
		t.Fatalf("successor ordinal = %d, want 2", next.Ordinal)
	}
	retry, err := ls.AppendWithBindings(bulkLane, sessionA, evid(8), []byte{8}, Bindings{AttributionSHA256: a})
	if err != nil {
		t.Fatalf("retry after Rotate: %v", err)
	}
	if retry.Sequence != 1 {
		t.Fatalf("retry sequence = %d, want 1 in the fresh generation", retry.Sequence)
	}
	gens := ls.Generations(bulkLane)
	if len(gens) != 2 || !gens[0].Closed() || gens[1].Closed() {
		t.Fatalf("generations after rotation = %d; want one closed retained and one open", len(gens))
	}
	if got := bodies(t, gens[0]); len(got) != 8 {
		t.Fatalf("retained generation holds %d records, want 8", len(got))
	}
}

// TestSegmentBoundConstantsCoverWorstCase is the tripwire under the
// projection: it marshals the largest span and page the grammar accepts and
// asserts every projection constant covers the true encoding.
func TestSegmentBoundConstantsCoverWorstCase(t *testing.T) {
	if got := len(mustMarshal(t, maxAttributedSpan())); got > maxAttributedSpanBytes {
		t.Fatalf("max attributed span = %dB, over the %dB projection constant", got, maxAttributedSpanBytes)
	}
	if got := len(mustMarshal(t, maxUnattributableSpan())); got > maxUnattributableSpanBytes {
		t.Fatalf("max unattributable span = %dB, over the %dB projection constant", got, maxUnattributableSpanBytes)
	}
	// Page framing with the costly predecessor digest present and no spans.
	overhead := &edgev1.EdgeLossManifestPageV1{
		RecoveryId:     uuid7("page-overhead"),
		PageIndex:      math.MaxUint32,
		PageCount:      math.MaxUint32,
		PrevPageSha256: bytes.Repeat([]byte{0xAB}, 32),
		PageSha256:     bytes.Repeat([]byte{0xCD}, 32),
		Terminal:       true,
		DigestVersion:  math.MaxUint32,
	}
	if got := len(mustMarshal(t, overhead)); got > manifestPageOverheadBytes {
		t.Fatalf("max page overhead = %dB, over the %dB projection constant", got, manifestPageOverheadBytes)
	}
}

// TestWorstCaseSegmentManifestFitsGrammarCeilings proves task 2.24's ceiling
// claim through the REAL grammar validator: fill a segment to each bound with
// maximally sized spans, page the resulting worst-case manifest exactly as the
// coordinator would, and require ValidateManifestChainFromRaw to accept it
// within MaxManifestPages and MaxManifestBytes.
func TestWorstCaseSegmentManifestFitsGrammarCeilings(t *testing.T) {
	t.Run("attributed", func(t *testing.T) {
		// Admit maximally costly records until the production rule refuses,
		// then build that many maximum spans (one per record): this is the
		// largest manifest any admitted attributed segment can need, even when
		// a single run fragments into one span per record.
		b := segmentBounds{limits: defaultSegmentLimits(), keys: make(map[[32]byte]struct{})}
		key := attrKey("single-key")
		records := 0
		for {
			if b.refusalFor(key) != "" {
				break
			}
			b.observe(key)
			records++
		}
		if records == 0 {
			t.Fatal("no attributed record admitted; the byte bound misfires on the first append")
		}
		if records != 817 {
			t.Fatalf("attributed records admitted = %d, want 817 (MaxManifestBytes/maxAttributedSpanBytes with page framing)", records)
		}
		assertManifestWithinCeilings(t, makeMaxSpans(records, true))
	})
	t.Run("unattributed", func(t *testing.T) {
		// The cheapest spans run to the run bound; even there the manifest
		// must fit.
		b := segmentBounds{limits: defaultSegmentLimits(), keys: make(map[[32]byte]struct{})}
		records := 0
		for b.refusalFor(nil) == "" {
			b.observe(nil)
			records++
		}
		if uint64(records) != MaxSegmentRuns {
			t.Fatalf("unattributed records admitted = %d, want exactly MaxSegmentRuns %d", records, MaxSegmentRuns)
		}
		assertManifestWithinCeilings(t, makeMaxSpans(records, false))
	})
}

// makeMaxSpans builds n worst-case single-sequence spans: one span per record,
// each with maximum encoding size and a grammar-valid body.
func makeMaxSpans(n int, attributed bool) []*edgev1.EdgeClassificationSpanV1 {
	// Base keeps every sequence varint at its 10-byte maximum while ascending.
	base := uint64(math.MaxUint64 - uint64(n) - 1)
	spans := make([]*edgev1.EdgeClassificationSpanV1, 0, n)
	for i := 0; i < n; i++ {
		seq := base + uint64(i) + 1
		if attributed {
			spans = append(spans, maxAttributedSpanAt(seq))
		} else {
			spans = append(spans, &edgev1.EdgeClassificationSpanV1{
				FromSequence:    seq,
				ThroughSequence: seq,
				Classification: &edgev1.EdgeClassificationSpanV1_Unattributable{
					Unattributable: &edgev1.EdgeUnattributableV1{
						Reason: edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT,
					},
				},
			})
		}
	}
	return spans
}

// assertManifestWithinCeilings pages spans at MaxSpansPerPage, digests and
// chains them, and requires the raw-byte grammar entry point to accept the
// manifest within both ceilings.
func assertManifestWithinCeilings(t *testing.T, spans []*edgev1.EdgeClassificationSpanV1) {
	t.Helper()
	recoveryID := uuid7("manifest-ceiling")
	pages := make([]*edgev1.EdgeLossManifestPageV1, 0, (len(spans)+edgerecord.MaxSpansPerPage-1)/edgerecord.MaxSpansPerPage)
	for start := 0; start < len(spans); start += edgerecord.MaxSpansPerPage {
		end := min(start+edgerecord.MaxSpansPerPage, len(spans))
		pages = append(pages, &edgev1.EdgeLossManifestPageV1{
			RecoveryId:          recoveryID,
			PageIndex:           uint32(len(pages)),
			PageCount:           0, // fixed up below
			Terminal:            end == len(spans),
			DigestVersion:       edgerecord.RecoveryDigestVersion,
			ClassificationSpans: spans[start:end],
		})
	}
	for _, p := range pages {
		p.PageCount = uint32(len(pages))
	}
	for i, p := range pages {
		if i > 0 {
			p.PrevPageSha256 = pages[i-1].PageSha256
		}
		p.PageSha256 = edgerecord.ManifestPageDigest(p)
	}
	raw := make([][]byte, 0, len(pages))
	var total uint64
	for _, p := range pages {
		b, err := proto.Marshal(p)
		if err != nil {
			t.Fatalf("marshal page: %v", err)
		}
		raw = append(raw, b)
		total += uint64(len(b))
	}
	if len(raw) > edgerecord.MaxManifestPages {
		t.Fatalf("worst-case manifest needs %d pages, over the %d page ceiling", len(raw), edgerecord.MaxManifestPages)
	}
	if total > uint64(edgerecord.MaxManifestBytes) {
		t.Fatalf("worst-case manifest is %dB, over the %dB byte ceiling", total, edgerecord.MaxManifestBytes)
	}
	if err := edgerecord.ValidateManifestChainFromRaw(raw, edgerecord.ManifestRoot(pages)); err != nil {
		t.Fatalf("worst-case manifest rejected by the recovery grammar: %v", err)
	}
}

// uuid7 returns a synthetic canonical UUIDv7: random-looking bytes from a
// label with the version and variant bits set.
func uuid7(seed string) []byte {
	sum := sha256.Sum256([]byte("spool-segment-test-uuid7:" + seed))
	id := sum[:16]
	id[6] = 0x70 | (id[6] & 0x0F)
	id[8] = 0x80 | (id[8] & 0x3F)
	return id
}

// maxAttributedSpan returns the largest ACTIVE span the grammar accepts: every
// varint maxed, every fixed field present including the source identity.
func maxAttributedSpan() *edgev1.EdgeClassificationSpanV1 {
	return maxAttributedSpanAt(math.MaxUint64 - 1)
}

func maxAttributedSpanAt(seq uint64) *edgev1.EdgeClassificationSpanV1 {
	digest := bytes.Repeat([]byte{0xAB}, 32)
	uuid := func(seed string) []byte {
		sum := sha256.Sum256([]byte("spool-segment-test-span:" + seed))
		id := sum[:16]
		id[6] = 0x40 | (id[6] & 0x0F)
		id[8] = 0x80 | (id[8] & 0x3F)
		return id
	}
	return &edgev1.EdgeClassificationSpanV1{
		FromSequence:    seq,
		ThroughSequence: seq,
		Classification: &edgev1.EdgeClassificationSpanV1_AttributedActive{
			AttributedActive: &edgev1.EdgeAttributedActiveV1{
				Identity: &edgev1.EdgeAttributedSpanIdentityV1{
					ProducerAssignmentId: uuid("assignment"),
					RunId:                uuid("run"),
					RunShard:             math.MaxUint32,
					AuthorityEpoch:       math.MaxUint64,
					ProductionScopeId:    uuid("scope"),
					ScopeSha256:          digest,
					ContractBundleSha256: digest,
					Source: &edgev1.EdgeSourceSpanIdentityV1{
						Kind:              edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
						ContextId:         uuid("context"),
						SourceScopeId:     uuid("source-scope"),
						SourceScopeSha256: digest,
					},
				},
				RangeSha256: digest,
			},
		},
	}
}

func maxUnattributableSpan() *edgev1.EdgeClassificationSpanV1 {
	return &edgev1.EdgeClassificationSpanV1{
		FromSequence:    math.MaxUint64 - 1,
		ThroughSequence: math.MaxUint64 - 1,
		Classification: &edgev1.EdgeClassificationSpanV1_Unattributable{
			Unattributable: &edgev1.EdgeUnattributableV1{
				Reason: edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT,
			},
		},
	}
}

func mustMarshal(t *testing.T, m proto.Message) []byte {
	t.Helper()
	b, err := proto.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}
