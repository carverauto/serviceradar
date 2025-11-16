package dbeventwriter

import "errors"

var (
	errDBServiceNotDB          = errors.New("db.Service is not *db.DB")
	errCNPGEventsNotConfigured = errors.New("cnpg storage is not configured for events ingestion")
)
