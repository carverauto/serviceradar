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

// The SHARED sweep-join corpus (task 1.3-f, item iii).
//
// The inventory is NORMATIVE and lives in the spec's two matrix requirements. It is
// REQUIREMENT-complete, not label-complete: covering all fifteen frozen labels once proves
// each label is reachable, but the spec requires vectors PER SOURCE ROW, PER DISPOSITION
// ROW, and on BOTH SIDES of every time window. A label-complete corpus and a
// requirement-complete one can agree on every assertion while the second is four times the
// size, which is exactly the gap `sweepCorpusVectors` closes.
package edgev1_test

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// sweepRow is one row of the frozen source matrix: which authorization kind the source maps
// to, which body field is the SIGNED CONTEXT OPERAND, and whether `source_run_id` is
// required or forbidden.
type sweepRow struct {
	name     string
	src      edgev1.SweepExecutionSource
	kind     edgev1.EdgeSourceAuthorizationKind
	runIDReq bool // true => operand is source_run_id; false => operand is execution_id
}

func sweepRows() []sweepRow {
	return []sweepRow{
		{
			"scheduled_sweep",
			edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP,
			edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
			false,
		},
		{
			"sweep_profile",
			edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SWEEP_PROFILE,
			edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SWEEP_PROFILE,
			false,
		},
		{
			"ad_hoc",
			edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_AD_HOC,
			edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
			true,
		},
		{
			"on_demand",
			edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_ON_DEMAND,
			edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_ON_DEMAND,
			true,
		},
		{
			"scheduled_check",
			edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
			edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
			true,
		},
	}
}

// recordForRow builds a CORRELATING record for one source row: the body carries that
// source, `source_run_id` is present or absent as the row dictates, the signed kind is the
// mapped one, and the signed context is the row's SELECTED operand.
//
// `rebuildRecord` re-syncs the outer mirror from the signed claims, re-signs both
// capabilities and recomputes the semantic envelope, so every vector below is a
// signature-valid record refused for the reason it names and not for a stale digest.
func recordForRow(t *testing.T, row sweepRow) *edgev1.EdgeRecordV1 {
	t.Helper()

	r := canonicalRecord(t)

	mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
		b.Source = row.src
		if row.runIDReq {
			b.SourceRunId = uuidv7(0x23)
		} else {
			b.SourceRunId = nil
		}
	})

	claims := r.GetSourceAuthorization().GetCapability().GetSource()
	claims.Kind = row.kind
	claims.ContextId = rowOperand(t, r, row)
	rebuildRecord(r)

	return r
}

// rowOperand returns the body field this row SELECTS as the signed context operand.
func rowOperand(t *testing.T, r *edgev1.EdgeRecordV1, row sweepRow) []byte {
	t.Helper()

	var b edgev1.SweepObservationBatchV1
	if err := proto.Unmarshal(r.GetPayload(), &b); err != nil {
		t.Fatalf("payload is not a sweep batch: %v", err)
	}

	if row.runIDReq {
		return b.GetSourceRunId()
	}

	return b.GetExecutionId()
}

// corpusVector is one shared vector: the bytes, and the verdict BOTH runtimes must reach.
type corpusVector struct {
	file  string
	label string // "" when the gate freezes no label
	gate  string // accept | correlation | body | enum_admission | recovery_lane
	build func(*testing.T) *edgev1.EdgeRecordV1
}

// mutate builds a record for a row and applies one change to it, rebuilding afterwards.
func mutate(row sweepRow, f func(*testing.T, *edgev1.EdgeRecordV1)) func(*testing.T) *edgev1.EdgeRecordV1 {
	return func(t *testing.T) *edgev1.EdgeRecordV1 {
		t.Helper()
		r := recordForRow(t, row)
		f(t, r)
		rebuildRecord(r)

		return r
	}
}

func sweepCorpusVectors() []corpusVector {
	rows := sweepRows()
	out := make([]corpusVector, 0, 48)

	for _, row := range rows {
		// PER SOURCE -- the POSITIVE control. Every negative for this row differs from it
		// in exactly one comparison, which is only meaningful if the control is committed.
		out = append(out, corpusVector{
			file:  "sweep_join_positive_" + row.name + ".bin",
			gate:  verdictAccept,
			build: func(t *testing.T) *edgev1.EdgeRecordV1 { t.Helper(); return recordForRow(t, row) },
		})

		// PER SOURCE -- the SELECTED-CONTEXT mismatch. Constructed so it does NOT also
		// break the disposition, which would prove whichever rule runs first:
		//   execution_id rows: source_run_id stays ABSENT, execution_id moves away;
		//   source_run_id rows: the signed context points at the NON-SELECTED execution_id.
		out = append(out, corpusVector{
			file:  "sweep_join_context_" + row.name + ".bin",
			label: string(edgerecord.SweepLabelContextID),
			gate:  "correlation",
			build: mutate(row, func(t *testing.T, r *edgev1.EdgeRecordV1) {
				t.Helper()
				if row.runIDReq {
					var b edgev1.SweepObservationBatchV1
					if err := proto.Unmarshal(r.GetPayload(), &b); err != nil {
						t.Fatal(err)
					}
					r.GetSourceAuthorization().GetCapability().GetSource().ContextId = b.GetExecutionId()

					return
				}

				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.ExecutionId = uuidv7(0x7E)
				})
			}),
		})

		// PER SOURCE -- the KIND mismatch: the signed kind is the one mapped from a
		// DIFFERENT source. Five points on a 5x7 reject matrix; the pinned single lookup
		// is what makes the inventory's coverage the behaviour's coverage.
		other := rows[(indexOfRow(rows, row)+1)%len(rows)]
		out = append(out, corpusVector{
			file:  "sweep_join_kind_" + row.name + ".bin",
			label: string(edgerecord.SweepLabelSourceKind),
			gate:  "correlation",
			build: mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				r.GetSourceAuthorization().GetCapability().GetSource().Kind = other.kind
			}),
		})

		// PER DISPOSITION ROW. Presence on the forbidden rows, absence AND malformedness on
		// the required ones -- per row, because a sampled row leaves the others unenforced.
		if row.runIDReq {
			out = append(out,
				corpusVector{
					file:  "sweep_join_runid_absent_" + row.name + ".bin",
					label: string(edgerecord.SweepLabelSourceRunIDDisposition),
					gate:  "body",
					build: mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
						mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) { b.SourceRunId = nil })
					}),
				},
				corpusVector{
					file:  "sweep_join_runid_malformed_" + row.name + ".bin",
					label: string(edgerecord.SweepLabelSourceRunIDDisposition),
					gate:  "body",
					build: mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
						// Canonical-UUID failure: the all-zero UUID.
						mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
							b.SourceRunId = make([]byte, 16)
						})
					}),
				},
			)

			continue
		}

		out = append(out, corpusVector{
			file:  "sweep_join_runid_present_" + row.name + ".bin",
			label: string(edgerecord.SweepLabelSourceRunIDDisposition),
			gate:  "body",
			build: mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.SourceRunId = uuidv7(0x23)
				})
			}),
		})
	}

	return append(out, sweepCorpusRelationVectors()...)
}

func indexOfRow(rows []sweepRow, row sweepRow) int {
	for i, r := range rows {
		if r.name == row.name {
			return i
		}
	}

	return 0
}

func TestSweepCorpusRowsMatchTheFrozenMatrix(t *testing.T) {
	// The rows here drive every per-source vector, so a drift from the frozen matrix would
	// silently change what the corpus covers.
	rows := sweepRows()
	if len(rows) != 5 {
		t.Fatalf("matrix has %d rows, want 5", len(rows))
	}

	for _, row := range rows {
		r := recordForRow(t, row)
		if err := edgerecord.ValidateSweepRecord(r, r.GetOutputContract(), goldenPolicy()); err != nil {
			t.Fatalf("%s: the row's POSITIVE control must correlate: %v", row.name, err)
		}
	}
}

func TestSweepSharedCorpus(t *testing.T) {
	vectors := sweepCorpusVectors()
	lines := make([]string, 0, len(vectors))
	seen := map[string]bool{}

	for _, v := range vectors {
		if seen[v.file] {
			t.Fatalf("duplicate vector file %s", v.file)
		}
		seen[v.file] = true

		record := v.build(t)
		_ = golden(t, v.file, record)

		err := edgerecord.ValidateSweepRecord(record, record.GetOutputContract(), goldenPolicy())
		assertCorpusGate(t, v, err)

		if v.label != "" {
			got, ok := edgerecord.SweepLabelOf(err)
			if !ok || string(got) != v.label {
				t.Fatalf("%s: label = %q (present=%v), want %q", v.file, got, ok, v.label)
			}
		}

		lines = append(lines, fmt.Sprintf("%s %s %s", v.file, orNone(v.label), v.gate))
	}

	sort.Strings(lines)
	goldenText(t, "sweep_join_corpus.txt", strings.Join(lines, "\n")+"\n")
}

// assertCorpusGate pins the OWNING GATE before the manifest records it. A gate name written
// without being checked is a claim Elixir then derives its expectation from.
func assertCorpusGate(t *testing.T, v corpusVector, err error) {
	t.Helper()

	pair := func(want, other error) {
		if !errors.Is(err, want) {
			t.Fatalf("%s: gate = %v, want errors.Is %v", v.file, err, want)
		}

		if other != nil && errors.Is(err, other) {
			t.Fatalf("%s: matched BOTH gates: %v", v.file, err)
		}
	}

	switch v.gate {
	case verdictAccept:
		if err != nil {
			t.Fatalf("%s: must be ACCEPTED: %v", v.file, err)
		}
	case "correlation":
		pair(edgerecord.ErrSweepJoin, edgerecord.ErrSweepSourceRunID)
	case "body":
		pair(edgerecord.ErrSweepSourceRunID, edgerecord.ErrSweepJoin)
	case "enum_admission":
		pair(edgerecord.ErrSweepSource, edgerecord.ErrSweepJoin)
	case "recovery_lane":
		pair(edgerecord.ErrRecoveryLane, nil)
	default:
		t.Fatalf("%s: unknown gate %q", v.file, v.gate)
	}
}

func orNone(s string) string {
	if s == "" {
		return "-"
	}

	return s
}

// The representative row for source-INDEPENDENT relations. Crossing them with source would
// restate one rule five times.
func representativeRow() sweepRow { return sweepRows()[4] } // scheduled_check

// A window wide enough that an OVERFLOWING host sum wraps INSIDE it.
//
// The spec requires each overflow vector's naively wrapped value to land inside the window,
// because an overflow that falls outside is refused either way and cannot distinguish a
// checked implementation from an unchecked one. With the canonical +/-1h window that is
// arithmetically unreachable for the HOST path: the base is ~1.78e18 ns, so an overflowing
// int64 sum wraps to about -7.4e18, and returning to +1.78e18 would need a delta near 2^64.
// So this vector carries its OWN committed positive control with a signed window that spans
// the negative range, and differs from THAT control in exactly one comparison: the delta.
const (
	wideNotBefore = int64(-9_000_000_000_000_000_000)
	wideExpires   = int64(9_000_000_000_000_000_000)
)

// widenEnvelope makes the capability's own validity envelope STRICTLY WIDER than the
// collection window it carries, so an observation on a collection endpoint is unambiguously
// inside the envelope.
func widenEnvelope(r *edgev1.EdgeRecordV1) {
	cap := r.GetSourceAuthorization().GetCapability()
	cap.NotBeforeUnixNano = winNotBefore - 3_600_000_000_000
	cap.ExpiresAtUnixNano = winExpires + 3_600_000_000_000
}

func widenWindow(r *edgev1.EdgeRecordV1) {
	c := r.GetSourceAuthorization().GetCapability().GetSource()
	c.CollectionNotBeforeUnixNano = wideNotBefore
	c.CollectionExpiresUnixNano = wideExpires
}

//nolint:funlen // a flat vector inventory; splitting it would hide the shape of the corpus
func sweepCorpusRelationVectors() []corpusVector {
	row := representativeRow()
	claims := func(r *edgev1.EdgeRecordV1) *edgev1.EdgeSourceClaimsV1 {
		return r.GetSourceAuthorization().GetCapability().GetSource()
	}

	return []corpusVector{
		// --- source-independent relations, one representative row ---
		{"sweep_join_absent_authority.bin", string(edgerecord.SweepLabelSourceAuthorityAbsent), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) { r.SourceAuthorization = nil })},
		{"sweep_join_range_id.bin", string(edgerecord.SweepLabelRangeID), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) { claims(r).ScopeId = uuidv7(0x7D) })},
		{"sweep_join_scope_digest.bin", string(edgerecord.SweepLabelScopeDigest), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) { claims(r).ScopeSha256 = digest32(0x7C) })},
		{"sweep_join_target_range_digest.bin", string(edgerecord.SweepLabelTargetRangeDigest), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) { claims(r).TargetRangeSha256 = digest32(0x7B) })},
		{"sweep_join_plan_digest.bin", string(edgerecord.SweepLabelPlanDigest), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) { claims(r).ExecutionPlanSha256 = digest32(0x7A) })},
		{"sweep_join_execution_shard.bin", string(edgerecord.SweepLabelExecutionShard), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) { b.ExecutionShard = 99 })
			})},
		{"sweep_join_assignment_epoch.bin", string(edgerecord.SweepLabelAssignmentEpoch), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) { b.AssignmentEpoch = 4242 })
			})},

		// --- unreachable kinds: refused by DIFFERENT gates, so not a matching pair ---
		{"sweep_join_kind_integration_run.bin", string(edgerecord.SweepLabelSourceKind), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				claims(r).Kind = edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_INTEGRATION_RUN
			})},
		{"sweep_join_kind_recovery_control.bin", "", "recovery_lane",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				claims(r).Kind = edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL
			})},

		// --- explicitly inventoried rather than left implied ---
		{"sweep_join_unspecified_source.bin", "", "enum_admission",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.Source = edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_UNSPECIFIED
				})
			})},

		// --- TIME: eight negatives, BOTH sides of all three windows ---
		// THE HOST DELTA IS COUNTER-ADJUSTED. The host absolute time is batch time PLUS the
		// delta, so moving the batch time with a zero delta moves the host time with it and
		// breaks TWO comparisons: delete the batch predicate and the host predicate still
		// rejects, so the vector would prove neither. Holding the host absolute time at the
		// canonical instant leaves exactly one comparison different.
		{"sweep_join_batch_time_before.bin", string(edgerecord.SweepLabelBatchTimeWindow), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.ObservedAtUnixNano = winNotBefore - 1
					b.GetHosts()[0].ObservedAtDeltaNano = fixedNanos - b.GetObservedAtUnixNano()
				})
			})},
		{"sweep_join_batch_time_after.bin", string(edgerecord.SweepLabelBatchTimeWindow), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.ObservedAtUnixNano = winExpires + 1
					b.GetHosts()[0].ObservedAtDeltaNano = fixedNanos - b.GetObservedAtUnixNano()
				})
			})},
		// A NEGATIVE delta is what reaches the before-start side.
		{"sweep_join_host_time_before.bin", string(edgerecord.SweepLabelHostTimeWindow), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.GetHosts()[0].ObservedAtDeltaNano = winNotBefore - fixedNanos - 1
				})
			})},
		{"sweep_join_host_time_after.bin", string(edgerecord.SweepLabelHostTimeWindow), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.GetHosts()[0].ObservedAtDeltaNano = winExpires - fixedNanos + 1
				})
			})},
		// The WIDE-WINDOW control for the host overflow vector below, committed so the
		// overflow vector differs from a real positive in exactly one comparison.
		{"sweep_join_positive_wide_window.bin", "", verdictAccept,
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) { widenWindow(r) })},
		// OVERFLOW that wraps INSIDE the wide window: 1.784e18 + MaxInt64 wraps to about
		// -7.44e18, which that window contains. An UNCHECKED implementation therefore
		// ACCEPTS this record, so the vector distinguishes checked from unchecked by
		// VERDICT and not merely by label.
		{"sweep_join_host_time_overflow.bin", string(edgerecord.SweepLabelHostTimeOverflow), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				widenWindow(r)
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.GetHosts()[0].ObservedAtDeltaNano = math.MaxInt64
				})
			})},
		{"sweep_join_trace_time_before.bin", string(edgerecord.SweepLabelTraceTimeWindow), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.GetHosts()[0].GetMtr().TraceId = uuidv7At(fixedMillis - 7_200_000)
				})
			})},
		{"sweep_join_trace_time_after.bin", string(edgerecord.SweepLabelTraceTimeWindow), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.GetHosts()[0].GetMtr().TraceId = uuidv7At(fixedMillis + 7_200_000)
				})
			})},
		// OVERFLOW that wraps INSIDE the CANONICAL window: 20_230_744_073_710 ms times 1e6
		// wraps to 1_784_000_000_000_448_384 ns, which the +/-1h window contains. Unlike the
		// host path this needs no wider window, because the overflow happens in the
		// MULTIPLICATION and a 48-bit ms field has room to reach any wrapped value.
		{"sweep_join_trace_time_overflow.bin", string(edgerecord.SweepLabelTraceTimeOverflow), "correlation",
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.GetHosts()[0].GetMtr().TraceId = uuidv7At(20_230_744_073_710)
				})
			})},

		// --- ENDPOINT CONTROLS: both collection endpoints are INSIDE, on ALL THREE paths ---
		//
		// Each widens the CAPABILITY ENVELOPE strictly beyond the collection window. With
		// the two equal, an observation exactly on a collection endpoint also sits exactly
		// on an envelope endpoint, so the control cannot show which window admitted it --
		// and a half-open envelope would refuse the expiry case for the wrong reason.
		{"sweep_join_positive_batch_at_not_before.bin", "", verdictAccept,
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				widenEnvelope(r)
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.ObservedAtUnixNano = winNotBefore
					b.GetHosts()[0].ObservedAtDeltaNano = fixedNanos - b.GetObservedAtUnixNano()
				})
			})},
		{"sweep_join_positive_batch_at_expires.bin", "", verdictAccept,
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				widenEnvelope(r)
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.ObservedAtUnixNano = winExpires
					b.GetHosts()[0].ObservedAtDeltaNano = fixedNanos - b.GetObservedAtUnixNano()
				})
			})},
		{"sweep_join_positive_host_at_not_before.bin", "", verdictAccept,
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				widenEnvelope(r)
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.GetHosts()[0].ObservedAtDeltaNano = winNotBefore - fixedNanos
				})
			})},
		{"sweep_join_positive_host_at_expires.bin", "", verdictAccept,
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				widenEnvelope(r)
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.GetHosts()[0].ObservedAtDeltaNano = winExpires - fixedNanos
				})
			})},
		{"sweep_join_positive_trace_at_not_before.bin", "", verdictAccept,
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				widenEnvelope(r)
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.GetHosts()[0].GetMtr().TraceId = uuidv7At(winNotBefore / 1_000_000)
				})
			})},
		{"sweep_join_positive_trace_at_expires.bin", "", verdictAccept,
			mutate(row, func(_ *testing.T, r *edgev1.EdgeRecordV1) {
				widenEnvelope(r)
				mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) {
					b.GetHosts()[0].GetMtr().TraceId = uuidv7At(winExpires / 1_000_000)
				})
			})},

		// --- NONCANONICAL payload: protobuf-equivalent, different BYTES ---
		{"sweep_join_noncanonical_payload.bin", "", verdictAccept,
			func(t *testing.T) *edgev1.EdgeRecordV1 {
				t.Helper()
				r := recordForRow(t, row)
				dup := append([]byte{0x6A, 0x08}, []byte("policy-1")...)
				payload := append(append([]byte{}, r.GetPayload()...), dup...)
				sum := sha256.Sum256(payload)
				r.Payload = payload
				r.PayloadSha256 = sum[:]
				r.EncodedSize = uint32(len(payload))
				r.UncompressedSize = uint32(len(payload))
				rebuildRecord(r)

				return r
			}},
	}
}
