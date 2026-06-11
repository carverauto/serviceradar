package dbeventwriter

// Ingest attribution headers (refactor-otel-signal-correlation, 10.6).
//
// Edge-relayed OTEL signals republished to JetStream carry the ingesting
// agent's identity as NATS message headers. The db-event-writer threads them
// into the attribution columns shared with the Elixir EventWriter:
//
//	Sr-Ingest-Identity -> ingest_identity
//	Sr-Agent-Id        -> ingest_agent_id
//	Sr-Partition       -> ingest_partition
//
// Headers are per-message, so attribution is stamped on the rows of each
// parsed message (never per-batch); an absent header maps to "" matching the
// TEXT NOT NULL DEFAULT '' columns.

import (
	"github.com/nats-io/nats.go/jetstream"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

const (
	headerIngestIdentity  = "Sr-Ingest-Identity"
	headerIngestAgentID   = "Sr-Agent-Id"
	headerIngestPartition = "Sr-Partition"
)

// ingestAttribution carries one message's ingest attribution header values.
type ingestAttribution struct {
	identity  string
	agentID   string
	partition string
}

// ingestAttributionFromMsg reads the Sr-* attribution headers from a consumed
// JetStream message. Messages without headers (or without the Sr-* keys)
// yield the zero value, i.e. "" for every field.
func ingestAttributionFromMsg(msg jetstream.Msg) ingestAttribution {
	headers := msg.Headers()
	if headers == nil {
		return ingestAttribution{}
	}

	return ingestAttribution{
		identity:  headers.Get(headerIngestIdentity),
		agentID:   headers.Get(headerIngestAgentID),
		partition: headers.Get(headerIngestPartition),
	}
}

func stampLogRows(rows []models.OTELLogRow, attribution ingestAttribution) {
	for i := range rows {
		rows[i].IngestIdentity = attribution.identity
		rows[i].IngestAgentID = attribution.agentID
		rows[i].IngestPartition = attribution.partition
	}
}

func stampMetricRows(rows []models.OTELMetricRow, attribution ingestAttribution) {
	for i := range rows {
		rows[i].IngestIdentity = attribution.identity
		rows[i].IngestAgentID = attribution.agentID
		rows[i].IngestPartition = attribution.partition
	}
}

func stampMetricPointRows(rows []models.OTELMetricPointRow, attribution ingestAttribution) {
	for i := range rows {
		rows[i].IngestIdentity = attribution.identity
		rows[i].IngestAgentID = attribution.agentID
		rows[i].IngestPartition = attribution.partition
	}
}

func stampTraceRows(rows []models.OTELTraceRow, attribution ingestAttribution) {
	for i := range rows {
		rows[i].IngestIdentity = attribution.identity
		rows[i].IngestAgentID = attribution.agentID
		rows[i].IngestPartition = attribution.partition
	}
}
