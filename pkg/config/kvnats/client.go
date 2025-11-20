package kvnats

import (
	"context"
	"errors"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"github.com/carverauto/serviceradar/pkg/config/kv"
)

type Client struct {
	nc     *nats.Conn
	js     jetstream.JetStream
	kv     jetstream.KeyValue
	bucket string
}

// Ensure Client implements kv.KVStore
var _ kv.KVStore = (*Client)(nil)

func New(nc *nats.Conn, bucket string) (*Client, error) {
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, err
	}

	// Ensure bucket exists
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	kvStore, err := js.CreateKeyValue(ctx, jetstream.KeyValueConfig{
		Bucket: bucket,
	})
	if err != nil {
		return nil, err
	}

	return &Client{
		nc:     nc,
		js:     js,
		kv:     kvStore,
		bucket: bucket,
	}, nil
}

func (c *Client) Get(ctx context.Context, key string) ([]byte, bool, error) {
	entry, err := c.kv.Get(ctx, key)
	if err != nil {
		if errors.Is(err, jetstream.ErrKeyNotFound) {
			return nil, false, nil
		}
		return nil, false, err
	}
	return entry.Value(), true, nil
}

func (c *Client) Put(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	// NATS KV doesn't support per-key TTL easily in Put, usually bucket level.
	// But standard Put is fine.
	_, err := c.kv.Put(ctx, key, value)
	return err
}

func (c *Client) Create(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	_, err := c.kv.Create(ctx, key, value)
	if err != nil {
		if errors.Is(err, jetstream.ErrKeyExists) {
			return kv.ErrKeyExists
		}
		return err
	}
	return nil
}

func (c *Client) Delete(ctx context.Context, key string) error {
	return c.kv.Delete(ctx, key)
}

func (c *Client) Watch(ctx context.Context, key string) (<-chan []byte, error) {
	watcher, err := c.kv.Watch(ctx, key)
	if err != nil {
		return nil, err
	}

	ch := make(chan []byte, 1)
	go func() {
		defer close(ch)
		defer watcher.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case update, ok := <-watcher.Updates():
				if !ok {
					return
				}
				if update == nil {
					continue
				}
				// NATS KV Watch sends nil value for delete? Or operation type?
				// update.Value() is nil if delete?
				// update.Operation() == jetstream.KeyValueDelete
				if update.Operation() == jetstream.KeyValueDelete || update.Operation() == jetstream.KeyValuePurge {
					// Send nil or handle delete?
					// Interface says "receives the new value (or nil if deleted)"
					ch <- nil
				} else {
					ch <- update.Value()
				}
			}
		}
	}()
	return ch, nil
}

func (c *Client) Close() error {
	c.nc.Close()
	return nil
}
