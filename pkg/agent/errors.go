package agent

import "errors"

var (
	errShutdown             = errors.New("error while shutting down")
	errInvalidPort          = errors.New("invalid port")
	errDetailsRequired      = errors.New("details field is required for port checks")
	errInvalidDetailsFormat = errors.New("invalid details format: expected 'host:port'")
)
