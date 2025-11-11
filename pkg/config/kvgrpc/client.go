package kvgrpc

import (
	"context"
	"errors"
	"io"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/carverauto/serviceradar/proto"
)

// Client adapts a proto.KVServiceClient to the pkg/config/kv.KVStore interface.
type Client struct {
	c      proto.KVServiceClient
	closer func() error
}

const (
	watchBackoffInitial = time.Second
	watchBackoffMax     = 30 * time.Second
)

// Ensure Client implements kv.KVStore
var _ kv.KVStore = (*Client)(nil)

// New creates a new KV adapter client.
func New(c proto.KVServiceClient, closer func() error) *Client {
	return &Client{c: c, closer: closer}
}

func (k *Client) Get(ctx context.Context, key string) ([]byte, bool, error) {
	resp, err := k.c.Get(ctx, &proto.GetRequest{Key: key})
	if err != nil {
		return nil, false, err
	}
	return resp.Value, resp.Found, nil
}

func (k *Client) Put(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	_, err := k.c.Put(ctx, &proto.PutRequest{Key: key, Value: value, TtlSeconds: int64(ttl / time.Second)})
	return err
}

func (k *Client) Delete(ctx context.Context, key string) error {
	_, err := k.c.Delete(ctx, &proto.DeleteRequest{Key: key})
	return err
}

func (k *Client) Watch(ctx context.Context, key string) (<-chan []byte, error) {
	stream, err := k.c.Watch(ctx, &proto.WatchRequest{Key: key})
	if err != nil {
		return nil, err
	}
	ch := make(chan []byte, 1)
	go k.watchStream(ctx, key, stream, ch)
	return ch, nil
}

func (k *Client) Close() error {
	if k.closer != nil {
		return k.closer()
	}
	return nil
}

func (k *Client) watchStream(ctx context.Context, key string, stream proto.KVService_WatchClient, out chan<- []byte) {
	defer close(out)

	backoff := watchBackoffInitial
	current := stream

	for {
		if current == nil {
			var ok bool
			current, backoff, ok = k.establishStream(ctx, key, backoff)
			if !ok {
				return
			}
			continue
		}

		resp, err := current.Recv()
		if err != nil {
			if !shouldRetryWatch(ctx, err) {
				return
			}
			if !waitFor(ctx, backoff) {
				return
			}
			backoff = nextBackoff(backoff)
			current = nil
			continue
		}

		backoff = watchBackoffInitial

		select {
		case out <- resp.Value:
		case <-ctx.Done():
			return
		}
	}
}

func (k *Client) establishStream(ctx context.Context, key string, backoff time.Duration) (proto.KVService_WatchClient, time.Duration, bool) {
	delay := backoff
	for {
		stream, err := k.c.Watch(ctx, &proto.WatchRequest{Key: key})
		if err == nil {
			return stream, watchBackoffInitial, true
		}
		if !shouldRetryWatch(ctx, err) {
			return nil, backoff, false
		}
		if !waitFor(ctx, delay) {
			return nil, backoff, false
		}
		delay = nextBackoff(delay)
	}
}

func nextBackoff(current time.Duration) time.Duration {
	if current <= 0 {
		current = watchBackoffInitial
	}
	next := current * 2
	if next > watchBackoffMax {
		return watchBackoffMax
	}
	return next
}

func waitFor(ctx context.Context, delay time.Duration) bool {
	if delay <= 0 {
		return true
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func shouldRetryWatch(ctx context.Context, err error) bool {
	if err == nil {
		return true
	}
	if ctx.Err() != nil {
		return false
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return false
	}
	if errors.Is(err, io.EOF) {
		return true
	}
	if st, ok := status.FromError(err); ok {
		switch st.Code() {
		case codes.Canceled,
			codes.DeadlineExceeded,
			codes.PermissionDenied,
			codes.Unauthenticated,
			codes.InvalidArgument,
			codes.FailedPrecondition,
			codes.Unimplemented:
			return false
		}
	}
	return true
}
