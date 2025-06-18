package devices

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/nats-io/nats.go/jetstream"
)

type Consumer struct {
	js           jetstream.JetStream
	streamName   string
	consumerName string
	consumer     jetstream.Consumer
}

func NewConsumer(ctx context.Context, js jetstream.JetStream, streamName, consumerName, subject string) (*Consumer, error) {
	log.Printf("Creating/getting pull consumer: stream=%s, consumer=%s", streamName, consumerName)
	consumer, err := js.Consumer(ctx, streamName, consumerName)
	if err != nil {
		cfg := jetstream.ConsumerConfig{
			Durable:       consumerName,
			AckPolicy:     jetstream.AckExplicitPolicy,
			AckWait:       30 * time.Second,
			MaxDeliver:    3,
			MaxAckPending: 1000,
		}
		if subject != "" {
			cfg.FilterSubject = subject
		}
		consumer, err = js.CreateConsumer(ctx, streamName, cfg)
		if err != nil {
			log.Printf("Failed to create consumer: stream=%s, consumer=%s, err=%v", streamName, consumerName, err)
			return nil, fmt.Errorf("failed to create consumer: %w", err)
		}
	}
	return &Consumer{js: js, streamName: streamName, consumerName: consumerName, consumer: consumer}, nil
}

const (
	defaultMaxPullMessages = 10
	defaultPullExpiry      = 30 * time.Second
	defaultMaxRetries      = 3
)

func (*Consumer) handleMessage(ctx context.Context, msg jetstream.Msg, processor *Processor) {
	metadata, _ := msg.Metadata()
	log.Printf("Processing message: subject=%s, seq=%d, tries=%d", msg.Subject(), metadata.Sequence.Stream, metadata.NumDelivered)
	if err := processor.Process(ctx, msg); err != nil {
		log.Printf("Failed to process message: %v", err)
		if metadata.NumDelivered >= defaultMaxRetries {
			log.Printf("Max retries reached, acknowledging message")
			_ = msg.Ack()
			return
		}
		_ = msg.Nak()
		return
	}
	_ = msg.Ack()
}

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
			for msg := range msgs.Messages() {
				c.handleMessage(ctx, msg, processor)
			}
			if fetchErr := msgs.Error(); fetchErr != nil {
				log.Printf("Fetch error: %v", fetchErr)
			}
		}
	}
}
