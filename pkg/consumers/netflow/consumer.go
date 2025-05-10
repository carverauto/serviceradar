package netflow

import (
	"context"
	"errors"
	"log"
	"time"

	"github.com/nats-io/nats.go"
)

// Consumer manages the NATS JetStream pull consumer.
type Consumer struct {
	js           nats.JetStreamContext
	streamName   string
	consumerName string
}

// NewConsumer creates or retrieves a durable pull consumer.
func NewConsumer(js nats.JetStreamContext, streamName, consumerName string) (*Consumer, error) {
	// Check if consumer exists
	_, err := js.ConsumerInfo(streamName, consumerName)
	if err != nil {
		if errors.Is(err, nats.ErrConsumerNotFound) {
			// Create consumer
			_, err = js.AddConsumer(streamName, &nats.ConsumerConfig{
				Durable:       consumerName,
				DeliverPolicy: nats.DeliverAllPolicy,
				AckPolicy:     nats.AckExplicitPolicy,
				Description:   "NetFlow message consumer",
				MaxDeliver:    3,
				AckWait:       30 * time.Second,
			})
			if err != nil {
				return nil, err
			}

			log.Printf("Created consumer %s for stream %s", consumerName, streamName)
		} else {
			return nil, err
		}
	} else {
		log.Printf("Using existing consumer %s for stream %s", consumerName, streamName)
	}

	return &Consumer{
		js:           js,
		streamName:   streamName,
		consumerName: consumerName,
	}, nil
}

// ProcessMessages fetches and processes messages using the provided processor.
func (c *Consumer) ProcessMessages(ctx context.Context, processor *Processor) {
	for {
		select {
		case <-ctx.Done():
			log.Println("Stopping message processing due to context cancellation")

			return
		default:
			// Subscribe to the stream with pull consumer
			msgs, err := c.js.PullSubscribe(c.streamName+".>", c.consumerName, nats.PullMaxWaiting(10))
			if err != nil {
				log.Printf("Failed to subscribe: %v", err)
				time.Sleep(5 * time.Second)

				continue
			}

			for {
				// Fetch messages with a 30-second timeout
				fetchCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
				msgs, err := msgs.Fetch(10, nats.Context(fetchCtx))
				cancel()

				if err != nil {
					if errors.Is(err, context.DeadlineExceeded) {
						continue // No messages available, retry
					}

					log.Printf("Failed to fetch messages: %v", err)
					time.Sleep(5 * time.Second)

					break
				}

				for _, msg := range msgs {
					if err := processor.Process(msg); err != nil {
						log.Printf("Failed to process message: %v", err)
						// Nak to retry later
						if err := msg.Nak(); err != nil {
							log.Printf("Failed to Nak message: %v", err)
						}
					} else {
						// Ack successful processing
						if err := msg.Ack(); err != nil {
							log.Printf("Failed to Ack message: %v", err)
						}
					}
				}
			}
		}
	}
}
