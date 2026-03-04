package trivysidecar

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

func TestNATSPublisherPublishesToJetStream(t *testing.T) {
	t.Parallel()

	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	srv := runJetStreamServer(t, &server.Options{Host: "127.0.0.1", Port: -1, JetStream: true})
	t.Cleanup(func() { srv.Shutdown() })

	nc, err := nats.Connect(srv.ClientURL())
	if err != nil {
		t.Fatalf("connect nats: %v", err)
	}
	t.Cleanup(func() { nc.Close() })

	js, err := jetstream.New(nc)
	if err != nil {
		t.Fatalf("jetstream init: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, err = js.CreateStream(ctx, jetstream.StreamConfig{
		Name:     "trivy_reports",
		Subjects: []string{"trivy.report.>"},
	})
	if err != nil {
		t.Fatalf("create stream: %v", err)
	}

	publisher, err := NewNATSPublisher(Config{
		NATSHostPort:   srv.ClientURL(),
		NATSStreamName: "trivy_reports",
	})
	if err != nil {
		t.Fatalf("new publisher: %v", err)
	}
	defer publisher.Close()

	if err := publisher.Publish(ctx, "trivy.report.vulnerability", []byte(`{"ok":true}`)); err != nil {
		t.Fatalf("publish: %v", err)
	}

	stream, err := js.Stream(ctx, "trivy_reports")
	if err != nil {
		t.Fatalf("load stream: %v", err)
	}

	info, err := stream.Info(ctx)
	if err != nil {
		t.Fatalf("stream info: %v", err)
	}

	if info.State.Msgs < 1 {
		t.Fatalf("expected at least 1 message in stream, got %d", info.State.Msgs)
	}
}

func runJetStreamServer(t *testing.T, opts *server.Options) *server.Server {
	t.Helper()

	srv, err := server.NewServer(opts)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	go srv.Start()

	if !srv.ReadyForConnections(10 * time.Second) {
		srv.Shutdown()
		t.Fatalf("embedded nats server not ready")
	}

	if _, ok := srv.Addr().(*net.TCPAddr); !ok {
		srv.Shutdown()
		t.Fatalf("expected tcp listener")
	}

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if srv.JetStreamEnabled() {
			return srv
		}
		time.Sleep(50 * time.Millisecond)
	}

	srv.Shutdown()
	t.Fatalf("jetstream not enabled in time")
	return nil
}
