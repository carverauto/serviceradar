package cloud

import "errors"

var (
	errEmptyPollerID      = errors.New("empty poller ID")
	errDatabaseError      = errors.New("database error")
	errInvalidSweepData   = errors.New("invalid sweep data")
	errFailedToSendAlerts = errors.New("failed to send alerts")
)
