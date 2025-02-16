package snmp

import "errors"

var (
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
)
