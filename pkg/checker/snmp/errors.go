package snmp

import (
	"errors"
	"fmt"
)

var (
	errInvalidDuration  = errors.New("invalid duration")
	ErrInvalidFloatType = errors.New("invalid float type")

	// Config error types.
	errOIDNameTooLong      = errors.New("OID name is too long")
	errOIDDuplicate        = errors.New("duplicate OID name")
	errNodeAddressRequired = fmt.Errorf("node_address is required")
	errListenAddrRequired  = fmt.Errorf("listen_addr is required")
	errNoTargets           = fmt.Errorf("at least one target must be configured")
	errNoOIDs              = fmt.Errorf("at least one OID must be configured")
	errInvalidOID          = fmt.Errorf("invalid OID format")
	errInvalidTargetName   = fmt.Errorf("invalid target name")
	errDuplicateTargetName = fmt.Errorf("duplicate target name")
	errInvalidHostAddress  = fmt.Errorf("invalid host address")
	errInvalidDataType     = fmt.Errorf("invalid data type")
	errInvalidScale        = fmt.Errorf("scale factor must be greater than 0")
	errEmptyOIDName        = fmt.Errorf("OID name cannot be empty")

	// Service error types.

	ErrStoppingCollectors       = errors.New("errors stopping collectors")
	ErrTargetExists             = errors.New("target already exists")
	ErrTargetNotFound           = errors.New("target not found")
	ErrInvalidServiceType       = errors.New("invalid service type")
	errFailedToCreateCollector  = errors.New("failed to create collector")
	errFailedToCreateAggregator = errors.New("failed to create aggregator")
	errFailedToStartCollector   = errors.New("failed to start collector")
	errFailedToStopCollector    = errors.New("failed to stop collector")
	errInvalidConfig            = errors.New("invalid configuration")
	errFailedToInitTarget       = errors.New("failed to initialize target")

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

	// Aggregator error types.
	errUnsupportedAggregateType = errors.New("unsupported aggregate type")
	errNoDataFound              = errors.New("no data found for OID")
	errNoDataPointsInterval     = errors.New("no data points in interval for OID")
	errNoPointsAggregate        = errors.New("no points to aggregate")
)
