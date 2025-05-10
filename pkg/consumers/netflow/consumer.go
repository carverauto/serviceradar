package netflow

import (
	"context"
	"errors"
	"log"
	"time"

	"github.com/nats-io/nats.go/jetstream"
)

// Consumer manages the NATS JetStream pull consumer.
type Consumer struct {
	js           jetstream.JetStream
	streamName   string
	consumerName string
}

// NewConsumer creates or retrieves a durable pull consumer.
func NewConsumer(ctx context.Context, js jetstream.JetStream, streamName, consumerName string) (*Consumer, error) {
	// Check if consumer exists
	_, err := js.Consumer(ctx, streamName, consumerName)
	if err == nil {
		log.Printf("Using existing consumer %s for stream %s", consumerName, streamName)
		return &Consumer{
			js:           js,
			streamName:   streamName,
			consumerName: consumerName,
		}, nil
	}

	// Return error if it's not a "consumer not found" error
	if !errors.Is(err, jetstream.ErrConsumerNotFound) {
		return nil, err
	}

	// Create consumer
	_, err = js.CreateOrUpdateConsumer(ctx, streamName, jetstream.ConsumerConfig{
		Durable:       consumerName,
		AckPolicy:     jetstream.AckExplicitPolicy,
		DeliverPolicy: jetstream.DeliverAllPolicy,
		Description:   "NetFlow message consumer",
		MaxDeliver:    3,
		AckWait:       30 * time.Second,
	})
	if err != nil {
		return nil, err
	}

	log.Printf("Created consumer %s for stream %s", consumerName, streamName)
	return &Consumer{
		js:           js,
		streamName:   streamName,
		consumerName: consumerName,
	}, nil
}

// ProcessMessages fetches and processes messages using the provided processor.
func (c *Consumer) ProcessMessages(ctx context.Context, processor *Processor) {
	// Get consumer handle
	cons, err := c.js.Consumer(ctx, c.streamName, c.consumerName)
	if err != nil {
		log.Printf("Failed to get consumer: %v", err)

		return
	}

	// Start consuming messages
	consCtx, err := cons.Consume(func(msg jetstream.Msg) {
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
	}, jetstream.PullMaxMessages(10), jetstream.PullExpiry(30*time.Second))
	if err != nil {
		log.Printf("Failed to start consumer: %v", err)

		return
	}
	defer consCtx.Stop()

	// Wait for context cancellation
	<-ctx.Done()
	log.Println("Stopping message processing due to context cancellation")
}
