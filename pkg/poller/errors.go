package poller

import (
	"errors"
	"fmt"
)

var (
	ErrInvalidDuration      = fmt.Errorf("invalid duration")
	ErrNoConnectionForAgent = fmt.Errorf("no connection found for agent")
	ErrAgentUnhealthy       = fmt.Errorf("agent is unhealthy")
	errClosing              = errors.New("error closing")
)
