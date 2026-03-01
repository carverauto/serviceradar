package mtr

import (
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
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

func TestNewTracer_TCPSupported(t *testing.T) {
	t.Parallel()

	opts := DefaultOptions("localhost")
	opts.Protocol = ProtocolTCP

	tracer, err := NewTracer(t.Context(), opts, logger.NewTestLogger())
	if err != nil {
		t.Fatalf("expected TCP tracer to initialize, got error: %v", err)
	}

	if tracer == nil {
		t.Fatal("expected non-nil tracer")
	}
}
