package dbeventwriter

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/timeplus-io/proton-go-driver/v2"
)

// Processor writes JetStream messages to a Proton table.
type Processor struct {
	conn  proton.Conn
	table string
}

// eventRow represents a single row in the events stream.
type eventRow struct {
	SpecVersion     string
	ID              string
	Source          string
	Type            string
	DataContentType string
	Subject         string
	RemoteAddr      string
	Host            string
	Level           int32
	Severity        string
	ShortMessage    string
	EventTimestamp  time.Time
	Version         string
	RawData         string
}

// parseCloudEvent attempts to extract the `data` field from a CloudEvent.
// It returns the data as a JSON string and true on success. If the message is
// not a valid CloudEvent or does not contain a `data` field, ok will be false.
func parseCloudEvent(b []byte) (string, bool) {
	var tmp struct {
		Data json.RawMessage `json:"data"`
	}

	if err := json.Unmarshal(b, &tmp); err != nil {
		return "", false
	}

	if len(tmp.Data) == 0 {
		return "", false
	}

	return string(tmp.Data), true
}

// buildEventRow parses a CloudEvent payload and returns an eventRow.
// If parsing fails, the returned row will contain only the raw data and subject.
func buildEventRow(b []byte, subject string) eventRow {
	var ce struct {
		SpecVersion     string          `json:"specversion"`
		ID              string          `json:"id"`
		Source          string          `json:"source"`
		Type            string          `json:"type"`
		DataContentType string          `json:"datacontenttype"`
		Subject         string          `json:"subject"`
		Data            json.RawMessage `json:"data"`
	}

	if err := json.Unmarshal(b, &ce); err != nil {
		return eventRow{RawData: string(b), Subject: subject}
	}

	if ce.Subject == "" {
		ce.Subject = subject
	}

	var payload struct {
		RemoteAddr   string  `json:"_remote_addr"`
		Host         string  `json:"host"`
		Level        int32   `json:"level"`
		Severity     string  `json:"severity"`
		ShortMessage string  `json:"short_message"`
		Timestamp    float64 `json:"timestamp"`
		Version      string  `json:"version"`
	}

	if len(ce.Data) > 0 {
		if err := json.Unmarshal(ce.Data, &payload); err != nil {
			return eventRow{RawData: string(b), Subject: ce.Subject}
		}
	}

	sec := int64(payload.Timestamp)
	nsec := int64((payload.Timestamp - float64(sec)) * float64(time.Second))
	ts := time.Unix(sec, nsec)

	return eventRow{
		SpecVersion:     ce.SpecVersion,
		ID:              ce.ID,
		Source:          ce.Source,
		Type:            ce.Type,
		DataContentType: ce.DataContentType,
		Subject:         ce.Subject,
		RemoteAddr:      payload.RemoteAddr,
		Host:            payload.Host,
		Level:           payload.Level,
		Severity:        payload.Severity,
		ShortMessage:    payload.ShortMessage,
		EventTimestamp:  ts,
		Version:         payload.Version,
		RawData:         string(b),
	}
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

	query := fmt.Sprintf("INSERT INTO %s (specversion, id, source, type, datacontenttype, subject, remote_addr, host, level, severity, short_message, event_timestamp, version, raw_data) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", p.table)

	batch, err := p.conn.PrepareBatch(ctx, query)
	if err != nil {
		return nil, err
	}

	processed := make([]jetstream.Msg, 0, len(msgs))

	for _, msg := range msgs {
		row := buildEventRow(msg.Data(), msg.Subject())

		if err := batch.Append(
			row.SpecVersion,
			row.ID,
			row.Source,
			row.Type,
			row.DataContentType,
			row.Subject,
			row.RemoteAddr,
			row.Host,
			row.Level,
			row.Severity,
			row.ShortMessage,
			row.EventTimestamp,
			row.Version,
			row.RawData,
		); err != nil {
			return processed, err
		}

		processed = append(processed, msg)
	}

	if err := batch.Send(); err != nil {
		return processed, err
	}

	return processed, nil
}
