package dbeventwriter

import (
	"context"
	"testing"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/logger"
)

type fakePullConsumer struct {
	err error
}

func (f *fakePullConsumer) Fetch(int, ...jetstream.FetchOpt) (jetstream.MessageBatch, error) {
	if f.err != nil {
		return nil, f.err
	}

	ch := make(chan jetstream.Msg)
	close(ch)

	return &fakeMessageBatch{ch: ch}, nil
}

type fakeMessageBatch struct {
	ch  chan jetstream.Msg
	err error
}

func (f *fakeMessageBatch) Messages() <-chan jetstream.Msg {
	return f.ch
}

func (f *fakeMessageBatch) Error() error {
	return f.err
}

func TestConsumerProcessMessagesReturnsFatalError(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	c := &Consumer{
		streamName:   "events",
		consumerName: "writer",
		consumer:     &fakePullConsumer{err: nats.ErrConnectionClosed},
		logger:       logger.NewTestLogger(),
	}

	err := c.ProcessMessages(ctx, nil)
	require.ErrorIs(t, err, nats.ErrConnectionClosed)
}
