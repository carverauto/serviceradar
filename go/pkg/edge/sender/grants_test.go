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

package sender

import (
	"context"
	"crypto/sha256"
	"errors"
	"sync"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

var errGatewayUnavailable = errors.New("gateway unavailable")

// fakeGrantRenewer issues a structurally valid renewal grant for every record
// it is asked about, as core would, unless told to fail or to bind the wrong
// bytes. It records which sequences each request named.
type fakeGrantRenewer struct {
	mu               sync.Mutex
	requested        [][]uint64
	fail             bool
	wrongSHA         bool
	blockUntilCancel bool
	now              time.Time
}

func (f *fakeGrantRenewer) RenewDeliveryGrants(
	ctx context.Context, spoolID []byte, records []spool.Record,
) (map[uint64]*edgev1.EdgeSignedCapabilityV1, error) {
	f.mu.Lock()
	seqs := make([]uint64, 0, len(records))
	for _, rec := range records {
		seqs = append(seqs, rec.Sequence)
	}
	f.requested = append(f.requested, seqs)
	fail, wrong, block, now := f.fail, f.wrongSHA, f.blockUntilCancel, f.now
	f.mu.Unlock()

	if block {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	if fail {
		return nil, errGatewayUnavailable
	}

	granted := make(map[uint64]*edgev1.EdgeSignedCapabilityV1, len(records))
	for _, rec := range records {
		sum := sha256.Sum256(rec.Body)
		if wrong {
			sum[0] ^= 0xFF
		}
		notBefore := now.UnixNano()
		expires := now.Add(15 * time.Minute).UnixNano()
		granted[rec.Sequence] = &edgev1.EdgeSignedCapabilityV1{
			CapabilityVersion: 1,
			IssuerId:          []byte("serviceradar-core"),
			IssuerKeyId:       []byte("test-key-id-0001"),
			Algorithm:         "ed25519",
			NotBeforeUnixNano: notBefore,
			ExpiresAtUnixNano: expires,
			Signature:         make([]byte, 64),
			Claims: &edgev1.EdgeSignedCapabilityV1_Delivery{Delivery: &edgev1.EdgeDeliveryClaimsV1{
				EventId:      rec.EventID,
				RecordSha256: sum[:],
				SpoolId:      spoolID,
				Sequence:     rec.Sequence,
				Transition: &edgev1.EdgeDeliveryClaimsV1_Renewal{Renewal: &edgev1.EdgeDeliveryRenewalV1{
					RenewedNotBeforeUnixNano: notBefore,
					RenewedExpiresUnixNano:   expires,
				}},
			}},
		}
	}
	return granted, nil
}

func (f *fakeGrantRenewer) requests() [][]uint64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([][]uint64(nil), f.requested...)
}

// appendRecord spools an EdgeRecordV1 whose production grant expires at expires.
func appendRecord(t *testing.T, sp *spool.Spool, expires time.Time) {
	t.Helper()
	eventID := mustEventID(t)
	body, err := proto.MarshalOptions{Deterministic: true}.Marshal(&edgev1.EdgeRecordV1{
		EventId:              eventID,
		ProductionCapability: &edgev1.EdgeSignedCapabilityV1{ExpiresAtUnixNano: expires.UnixNano()},
	})
	if err != nil {
		t.Fatalf("marshal record: %v", err)
	}
	if _, err := sp.Append(eventID, body); err != nil {
		t.Fatalf("append: %v", err)
	}
}

func grantSender(t *testing.T, sp *spool.Spool, srv *fakeIngestServer, renewer GrantRenewer, now time.Time) *Sender {
	t.Helper()
	cfg := testConfig(t)
	cfg.Grants = renewer
	cfg.Now = func() time.Time { return now }
	s, err := New(sp, dialFakeIngest(t, srv), cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return s
}

// The sender persists no acknowledgement (testConfig), so the spool keeps every
// record and the next run sends the same ones again.
func acceptingServer() *fakeIngestServer {
	return &fakeIngestServer{
		grantedByteCredits:  1 << 20,
		grantedFrameCredits: 100,
		dispositionKind:     edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE,
		decodeEventIDs:      true,
	}
}

// A record whose production grant lapsed while the agent was disconnected can
// only drain under a delivery grant; one still under its production grant
// needs none, and a grant obtained once is reused while it is current.
func TestRunOnceAttachesDeliveryGrantsOnlyToRecordsWhoseAuthorityLapsed(t *testing.T) {
	now := time.Now()
	sp := newTestSpool(t)
	appendRecord(t, sp, now.Add(-2*time.Hour))
	appendRecord(t, sp, now.Add(2*time.Hour))

	srv := acceptingServer()
	renewer := &fakeGrantRenewer{now: now}
	s := grantSender(t, sp, srv, renewer, now)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	for run := 0; run < 2; run++ {
		result, err := s.RunOnce(ctx)
		if err != nil {
			t.Fatalf("RunOnce %d: %v", run, err)
		}
		if result.GrantRenewal != nil {
			t.Fatalf("RunOnce %d GrantRenewal = %v", run, result.GrantRenewal)
		}
	}

	if got := renewer.requests(); len(got) != 1 || !equalSeqs(got[0], []uint64{1}) {
		t.Fatalf("grant requests = %v, want one request for sequence 1 only", got)
	}

	frames := srv.framesReceived()
	if len(frames) != 4 {
		t.Fatalf("server received %d frames, want 4 (two runs of two)", len(frames))
	}
	for _, frame := range frames {
		dc := frame.GetDeliveryCapability()
		switch frame.GetSequence() {
		case 1:
			if dc == nil || dc.GetDelivery().GetSequence() != 1 {
				t.Fatalf("lapsed record sent without its delivery grant: %v", dc)
			}
		case 2:
			if dc != nil {
				t.Fatalf("record under current authority was sent with a delivery grant")
			}
		}
	}
}

// A renewal that fails, or returns a grant for other bytes, never holds the
// backlog back: the record is sent as it stands and the failure is reported.
func TestRunOnceSendsWithoutAGrantItCouldNotObtain(t *testing.T) {
	for _, tc := range []struct {
		name    string
		renewer *fakeGrantRenewer
		want    error
	}{
		{name: "renewal fails", renewer: &fakeGrantRenewer{fail: true}, want: errGatewayUnavailable},
		{name: "grant binds other bytes", renewer: &fakeGrantRenewer{wrongSHA: true}, want: errGrantMismatch},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			tc.renewer.now = now
			sp := newTestSpool(t)
			appendRecord(t, sp, now.Add(-2*time.Hour))

			srv := acceptingServer()
			s := grantSender(t, sp, srv, tc.renewer, now)

			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()

			result, err := s.RunOnce(ctx)
			if err != nil {
				t.Fatalf("RunOnce: %v", err)
			}
			if !errors.Is(result.GrantRenewal, tc.want) {
				t.Fatalf("GrantRenewal = %v, want %v", result.GrantRenewal, tc.want)
			}
			frames := srv.framesReceived()
			if len(frames) != 1 || frames[0].GetDeliveryCapability() != nil {
				t.Fatalf("frames = %v, want the record sent once without a grant", frames)
			}
		})
	}
}

// A renewal that does not answer is one bounded attempt. Records whose
// production grants are still valid are sent without waiting out the caller's
// deadline, and the next cycle asks again.
func TestRenewalTimeoutDoesNotDelayRecordsUnderCurrentAuthority(t *testing.T) {
	now := time.Now()
	sp := newTestSpool(t)
	appendRecord(t, sp, now.Add(-2*time.Hour))
	appendRecord(t, sp, now.Add(2*time.Hour))

	srv := acceptingServer()
	renewer := &fakeGrantRenewer{now: now, blockUntilCancel: true}
	s := grantSender(t, sp, srv, renewer, now)

	parent, cancel := context.WithTimeout(context.Background(), renewalAttemptTimeout+5*time.Second)
	defer cancel()

	start := time.Now()
	result, err := s.RunOnce(parent)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if elapsed >= renewalAttemptTimeout+2*time.Second {
		t.Fatalf("RunOnce took %s; a timed-out renewal held the delivery session", elapsed)
	}
	if !errors.Is(result.GrantRenewal, context.DeadlineExceeded) {
		t.Fatalf("GrantRenewal = %v, want deadline exceeded", result.GrantRenewal)
	}
	frames := srv.framesReceived()
	if len(frames) != 2 {
		t.Fatalf("server received %d frames, want both records sent", len(frames))
	}
	for _, frame := range frames {
		if frame.GetDeliveryCapability() != nil {
			t.Fatalf("sequence %d carried a grant after renewal timed out", frame.GetSequence())
		}
	}

	renewer.mu.Lock()
	renewer.blockUntilCancel = false
	renewer.mu.Unlock()

	result, err = s.RunOnce(parent)
	if err != nil {
		t.Fatalf("second RunOnce: %v", err)
	}
	if result.GrantRenewal != nil {
		t.Fatalf("second GrantRenewal = %v, want the retry to succeed", result.GrantRenewal)
	}
	got := renewer.requests()
	if len(got) != 2 || !equalSeqs(got[0], []uint64{1}) || !equalSeqs(got[1], []uint64{1}) {
		t.Fatalf("grant requests = %v, want the lapsed record asked once per cycle", got)
	}
	var renewed bool
	for _, frame := range srv.framesReceived()[len(frames):] {
		if frame.GetSequence() == 1 && frame.GetDeliveryCapability().GetDelivery().GetSequence() == 1 {
			renewed = true
		}
	}
	if !renewed {
		t.Fatal("second cycle did not send the lapsed record with the grant it retried for")
	}
}

// One failed batch ends the renewal phase. Later batches wait for the next
// cycle instead of spending the session deadline on more RPCs.
func TestRunOnceStopsGrantRenewalAfterTheFirstRPCError(t *testing.T) {
	now := time.Now()
	sp := newTestSpool(t)
	for i := 0; i < maxGrantRecordsPerRequest+1; i++ {
		appendRecord(t, sp, now.Add(-2*time.Hour))
	}

	srv := acceptingServer()
	srv.grantedFrameCredits = maxGrantRecordsPerRequest + 1
	renewer := &fakeGrantRenewer{now: now, fail: true}

	cfg := testConfig(t)
	cfg.Grants = renewer
	cfg.Now = func() time.Time { return now }
	cfg.RequestedFrameCredits = maxGrantRecordsPerRequest + 1
	cfg.RequestedByteCredits = 8 << 20
	s, err := New(sp, dialFakeIngest(t, srv), cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	result, err := s.RunOnce(ctx)
	if err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if !errors.Is(result.GrantRenewal, errGatewayUnavailable) {
		t.Fatalf("GrantRenewal = %v, want %v", result.GrantRenewal, errGatewayUnavailable)
	}
	got := renewer.requests()
	if len(got) != 1 || len(got[0]) != maxGrantRecordsPerRequest {
		t.Fatalf("grant requests = %v, want one batch of %d and no second RPC", got, maxGrantRecordsPerRequest)
	}
	if len(srv.framesReceived()) != maxGrantRecordsPerRequest+1 {
		t.Fatalf("sent %d frames, want every record in the window", len(srv.framesReceived()))
	}
}
