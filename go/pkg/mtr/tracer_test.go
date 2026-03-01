package mtr

import (
	"testing"
	"time"
)

func TestExpireTimedOutProbes_DecrementsInFlight(t *testing.T) {
	t.Parallel()

	tracer := &Tracer{
		opts: Options{
			Timeout: 100 * time.Millisecond,
		},
		hops: []*HopResult{
			NewHopResult(1, DefaultRingBufferSize),
		},
		probes: map[int]*probeRecord{
			1: {
				hopIndex: 0,
				seq:      1,
				sentAt:   time.Now().Add(-200 * time.Millisecond),
			},
		},
	}

	tracer.hops[0].InFlight = 1
	tracer.expireTimedOutProbes(time.Now())

	if got := tracer.hops[0].InFlight; got != 0 {
		t.Fatalf("expected InFlight=0 after timeout sweep, got %d", got)
	}

	if got := len(tracer.probes); got != 0 {
		t.Fatalf("expected no in-flight probes after timeout sweep, got %d", got)
	}
}
