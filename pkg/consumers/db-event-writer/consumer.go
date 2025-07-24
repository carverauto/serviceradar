package dbeventwriter

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/nats-io/nats.go/jetstream"
)

// Consumer wraps a JetStream pull consumer.
type Consumer struct {
	js           jetstream.JetStream
	streamName   string
	consumerName string
	consumer     jetstream.Consumer
}

// NewConsumer creates or retrieves a pull consumer for the given stream.
func NewConsumer(ctx context.Context, js jetstream.JetStream, streamName, consumerName string, subjects []string) (*Consumer, error) {
	log.Printf("Creating/getting pull consumer: stream=%s, consumer=%s, subjects=%v", streamName, consumerName, subjects)

	consumer, err := js.Consumer(ctx, streamName, consumerName)
	if err != nil {
		cfg := jetstream.ConsumerConfig{
			Durable:       consumerName,
			AckPolicy:     jetstream.AckExplicitPolicy,
			AckWait:       30 * time.Second,
			MaxDeliver:    3,
			MaxAckPending: 1000,
		}

		if len(subjects) == 1 {
			cfg.FilterSubject = subjects[0]
		} else if len(subjects) > 1 {
			cfg.FilterSubjects = subjects
		}

		consumer, err = js.CreateConsumer(ctx, streamName, cfg)
		if err != nil {
			log.Printf("Failed to create consumer: stream=%s, consumer=%s, err=%v", streamName, consumerName, err)
			return nil, fmt.Errorf("failed to create consumer: %w", err)
		}
	}

	log.Println("Pull consumer created or retrieved successfully")

	return &Consumer{js: js, streamName: streamName, consumerName: consumerName, consumer: consumer}, nil
}

const (
	defaultMaxPullMessages = 50
	defaultPullExpiry      = 30 * time.Second
	defaultMaxRetries      = 3
)

func (*Consumer) handleBatch(ctx context.Context, msgs []jetstream.Msg, processor *Processor) {
	processed, err := processor.ProcessBatch(ctx, msgs)
	if err != nil {
		log.Printf("Failed to process message batch: %v", err)

		for _, msg := range processed {
			metadata, _ := msg.Metadata()

			if metadata.NumDelivered >= defaultMaxRetries {
				_ = msg.Ack()
			} else {
				_ = msg.Nak()
			}
		}

		return
	}

	for _, msg := range processed {
		log.Println("Message processed successfully:", msg.Subject())

		_ = msg.Ack()
	}
}

// ProcessMessages continuously fetches and processes messages.
func (c *Consumer) ProcessMessages(ctx context.Context, processor *Processor) {
	log.Printf("Starting pull consumer for stream %s, consumer %s", c.streamName, c.consumerName)

	for {
		select {
		case <-ctx.Done():
			log.Println("Stopping message processing due to context cancellation")
			return
		default:
			msgs, err := c.consumer.Fetch(defaultMaxPullMessages, jetstream.FetchMaxWait(defaultPullExpiry))
			if err != nil {
				log.Printf("Failed to fetch messages: %v", err)
				time.Sleep(time.Second)

				continue
			}

			log.Printf("Fetched %d messages from stream %s, consumer %s",
				len(msgs.Messages()), c.streamName, c.consumerName)

			batch := make([]jetstream.Msg, 0, defaultMaxPullMessages)
			for msg := range msgs.Messages() {
				batch = append(batch, msg)
			}

			if len(batch) > 0 {
				log.Printf("Processing batch of %d messages", len(batch))

				c.handleBatch(ctx, batch, processor)
			}

			if fetchErr := msgs.Error(); fetchErr != nil {
				log.Printf("Fetch error: %v", fetchErr)
			}
		}
	}
}
