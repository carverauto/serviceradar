package spireadmin

import "errors"

var (
	ErrServerAddressRequired         = errors.New("spire admin: server address is required")
	ErrServerSPIFFEIDRequired        = errors.New("spire admin: server SPIFFE ID is required")
	ErrDownstreamParentIDRequired    = errors.New("spire admin: downstream parent ID is required")
	ErrDownstreamSPIFFEIDRequired    = errors.New("spire admin: downstream spiffe_id is required")
	ErrDownstreamEntryEmptyResponse  = errors.New("spire admin: unexpected empty response creating downstream entry")
	ErrDownstreamEntryMissingStatus  = errors.New("spire admin: missing status in downstream entry response")
	ErrDownstreamEntryMissingPayload = errors.New("spire admin: downstream entry missing entry payload in response")
	ErrDownstreamEntryCreateFailed   = errors.New("spire admin: downstream entry create failed")
	ErrEmptySelector                 = errors.New("empty selector")
	ErrInvalidSelectorFormat         = errors.New("invalid selector format")
	ErrBundleClientUnavailable       = errors.New("spire admin: bundle client not initialized")
	ErrBundleEmpty                   = errors.New("spire admin: bundle contains no x509 authorities")
	ErrBundleEncodeFailed            = errors.New("spire admin: bundle encode failed")
	ErrDeleteEntryEmptyResult        = errors.New("spire admin: delete entry returned empty result")
	ErrDeleteEntryMissingStatus      = errors.New("spire admin: delete entry missing status in response")
	ErrDeleteEntryFailed             = errors.New("spire admin: delete entry failed")
)
