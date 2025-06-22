package dbeventwriter

import (
	"context"
	"fmt"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/timeplus-io/proton-go-driver/v2"
)

// Processor writes JetStream messages to a Proton table.
type Processor struct {
	conn  proton.Conn
	table string
}

// NewProcessor creates a Processor using the provided db.Service.
func NewProcessor(dbService db.Service, table string) (*Processor, error) {
	dbImpl, ok := dbService.(*db.DB)
	if !ok {
		return nil, errDBServiceNotDB
	}

	return &Processor{conn: dbImpl.Conn, table: table}, nil
}

// ProcessBatch writes a batch of messages to the table and returns the processed messages.
func (p *Processor) ProcessBatch(ctx context.Context, msgs []jetstream.Msg) ([]jetstream.Msg, error) {
	if len(msgs) == 0 {
		return nil, nil
	}

	query := fmt.Sprintf("INSERT INTO %s (message) VALUES (?)", p.table)
	batch, err := p.conn.PrepareBatch(ctx, query)
	if err != nil {
		return nil, err
	}

	processed := make([]jetstream.Msg, 0, len(msgs))

	for _, msg := range msgs {
		if err := batch.Append(string(msg.Data())); err != nil {
			return processed, err
		}
		processed = append(processed, msg)
	}

	if err := batch.Send(); err != nil {
		return processed, err
	}

	return processed, nil
}
