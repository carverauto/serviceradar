package cli

import (
	"errors"
	"fmt"
)

var (
	errConfigReadFailed     = errors.New("failed to read config file")
	errConfigMarshalFailed  = errors.New("failed to serialize config")
	errConfigWriteFailed    = errors.New("failed to write config file")
	errInvalidAuthFormat    = errors.New("invalid auth configuration format")
	errEmptyPassword        = fmt.Errorf("password cannot be empty")
	errInvalidCost          = fmt.Errorf("cost must be a number between %d and %d", minCost, maxCost)
	errHashFailed           = fmt.Errorf("failed to generate hash")
	errRequiresFileAndHash  = errors.New("update-config requires -file and -admin-hash")
	errUpdatingConfig       = errors.New("failed to update config file")
	errRequiresPollerFile   = errors.New("update-poller requires -file")
	errUpdatingPollerConfig = errors.New("failed to update poller config file")
	errAgentNotFound        = errors.New("specified agent not found in poller configuration")
	errUnsupportedAction    = errors.New("unsupported action (supported: add, remove)")
	errNoDefaultDetails     = errors.New("no default details for service type %s")
	errServiceTypeRequired  = errors.New("service type is required (use -type)")
	errCheckerNotFound      = errors.New("checker %s no found for agent %s")
)
