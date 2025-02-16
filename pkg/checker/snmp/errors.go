package snmp

import "errors"

var (
	// Client error types.

	ErrNotImplemented         = errors.New("not implemented")
	ErrInvalidTargetConfig    = errors.New("invalid target configuration")
	ErrNilTargetConfig        = errors.New("target configuration is nil")
	ErrTargetHostRequired     = errors.New("target host is required")
	ErrUnsupportedSNMPVersion = errors.New("unsupported SNMP version")
	ErrSNMPConnect            = errors.New("SNMP connect failed")
	ErrSNMPGet                = errors.New("SNMP get failed")
	ErrSNMPConvert            = errors.New("SNMP convert failed")
	ErrSNMPNoSuchObject       = errors.New("SNMP NoSuchObject")
	ErrSNMPNoSuchInstance     = errors.New("SNMP NoSuchInstance")
	ErrSNMPEndOfMibView       = errors.New("SNMP EndOfMibView")
	ErrSNMPEndOfContents      = errors.New("SNMP EndOfContents")
	ErrSNMPUnknownType        = errors.New("SNMP UnknownType")
	ErrUnsupportedSNMPType    = errors.New("unsupported SNMP type")

	// Collector error types.

	ErrNoOIDConfig         = errors.New("no configuration found for OID")
	ErrCollectorStopped    = errors.New("collector stopped")
	ErrUnsupportedDataType = errors.New("unsupported data type")
	ErrInvalidCounterType  = errors.New("expected uint64 for counter")
	ErrInvalidGaugeType    = errors.New("unexpected type for gauge")
	ErrInvalidBooleanType  = errors.New("unexpected type for boolean")
	ErrInvalidBytesType    = errors.New("expected uint64 for bytes")
	ErrInvalidStringType   = errors.New("unexpected type for string")
)
