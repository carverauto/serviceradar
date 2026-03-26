package dbeventwriter

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

func TestServiceRunReconnectsAfterFatalError(t *testing.T) {
	t.Parallel()

	svc := &Service{
		cfg: &DBEventWriterConfig{
			StreamName:   "events",
			ConsumerName: "writer",
		},
		logger:     logger.NewTestLogger(),
		retryDelay: time.Millisecond,
	}

	var (
		connectCalls int
		mu           sync.Mutex
	)

	svc.connectFactory = func(context.Context) (*nats.Conn, jetstream.JetStream, *Consumer, error) {
		mu.Lock()
		defer mu.Unlock()

		connectCalls++

		err := nats.ErrConnectionClosed
		if connectCalls > 1 {
			err = context.Canceled
		}

		return nil, nil, &Consumer{
			streamName:   "events",
			consumerName: "writer",
			consumer:     &fakePullConsumer{err: err},
			logger:       logger.NewTestLogger(),
		}, nil
	}

	require.NoError(t, svc.Start(context.Background()))

	done := make(chan struct{})
	go func() {
		svc.wg.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("service did not stop within timeout")
	}

	mu.Lock()
	callCount := connectCalls
	mu.Unlock()

	require.GreaterOrEqual(t, callCount, 2, "expected at least one reconnect attempt")

	require.NoError(t, svc.Stop(context.Background()))
}

func TestServiceSubjectsExpandsDerivedMetricFilter(t *testing.T) {
	t.Parallel()

	svc := &Service{
		cfg: &DBEventWriterConfig{
			Streams: []StreamConfig{
				{Subject: "logs.otel.processed", Table: "logs"},
				{Subject: "otel.metrics", Table: "otel_metrics"},
				{Subject: "otel.traces.raw", Table: "otel_traces"},
			},
		},
	}

	require.Equal(t,
		[]string{"logs.otel.processed", "otel.metrics", "otel.metrics.>", "otel.traces", "otel.traces.raw"},
		svc.subjects(),
	)
}

func TestServiceSubjectsExpandsLegacyTraceSubject(t *testing.T) {
	t.Parallel()

	svc := &Service{
		cfg: &DBEventWriterConfig{
			Subject: "otel.traces",
		},
	}

	require.Equal(t, []string{"otel.traces", "otel.traces.raw"}, svc.subjects())
}

func TestServiceSubjectsDeduplicatesTraceSubjects(t *testing.T) {
	t.Parallel()

	svc := &Service{
		cfg: &DBEventWriterConfig{
			Streams: []StreamConfig{
				{Subject: "otel.traces", Table: "otel_traces"},
				{Subject: "otel.traces.raw", Table: "otel_traces"},
			},
		},
	}

	require.Equal(t, []string{"otel.traces", "otel.traces.raw"}, svc.subjects())
}

func TestServiceSubjectsExpandsLegacyMetricSubject(t *testing.T) {
	t.Parallel()

	svc := &Service{
		cfg: &DBEventWriterConfig{
			Subject: "otel.metrics",
		},
	}

	require.Equal(t, []string{"otel.metrics", "otel.metrics.>"}, svc.subjects())
}

func TestServiceSubjectsDeduplicatesMetricSubjects(t *testing.T) {
	t.Parallel()

	svc := &Service{
		cfg: &DBEventWriterConfig{
			Streams: []StreamConfig{
				{Subject: "otel.metrics", Table: "otel_metrics"},
				{Subject: "otel.metrics.raw", Table: "otel_metrics"},
			},
		},
	}

	require.Equal(t, []string{"otel.metrics", "otel.metrics.>"}, svc.subjects())
}
