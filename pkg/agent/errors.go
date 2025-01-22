package agent

import "errors"

var (
	errGrpcAddressRequired = errors.New("address is required for gRPC checker")
	errUnknownCheckerType  = errors.New("unknown checker type")
	errGrpcMissingConfig   = errors.New("no configuration or address provided for gRPC checker")
	errShutdown            = errors.New("error while shutting down")
)
