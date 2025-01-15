package checker

import (
	"context"
	"encoding/json"
)

// Checker defines how to check a service's status.
type Checker interface {
	Check(ctx context.Context) (bool, string)
}

// StatusProvider allows plugins to provide detailed status data.
type StatusProvider interface {
	GetStatusData() json.RawMessage
}

// HealthChecker combines basic checking with detailed status.
type HealthChecker interface {
	Checker
	StatusProvider
}
