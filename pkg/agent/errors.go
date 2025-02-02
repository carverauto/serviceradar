package agent

import "errors"

var (
	errInvalidPort          = errors.New("invalid port")
	errDetailsRequired      = errors.New("details field is required for port checks")
	errInvalidDetailsFormat = errors.New("invalid details format: expected 'host:port'")
)
