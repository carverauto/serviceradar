package grpc

import (
	"errors"
)

var (
	errUnknownSecurityMode      = errors.New("unknown security mode")
	errSecurityConfigRequired   = errors.New("security config required for mTLS")
	errInvalidServiceRole       = errors.New("invalid service role")
	errFailedToLoadClientCreds  = errors.New("failed to load client credentials")
	errFailedToLoadServerCreds  = errors.New("failed to load server credentials")
	errFailedToLoadClientCert   = errors.New("failed to load client certificate")
	errFailedToReadCACert       = errors.New("failed to read CA certificate")
	errFailedToAppendCACert     = errors.New("failed to append CA certificate")
	errFailedToLoadServerCert   = errors.New("failed to load server certificate")
	errServiceNotClient         = errors.New("service is not configured as a client")
	errServiceNotServer         = errors.New("service is not configured as a server")
	errFailedWorkloadAPIClient  = errors.New("failed to create workload API client")
	errFailedToCreateX509Source = errors.New("failed to create X.509 source")
	errInvalidServerSPIFFEID    = errors.New("invalid server SPIFFE ID")
	errInvalidTrustDomain       = errors.New("invalid trust domain")
)
