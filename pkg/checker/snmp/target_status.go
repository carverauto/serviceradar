// Package snmp pkg/checker/snmp/target_status.go
package snmp

const (
	defaultUnknown = "unknown"
)

// GetDataType returns the data type for the given OID.
func (ts *TargetStatus) GetDataType(oidName string) string {
	if ts.Target == nil {
		return defaultUnknown
	}

	for _, oid := range ts.Target.OIDs {
		if oid.Name == oidName {
			return string(oid.DataType)
		}
	}

	return defaultUnknown
}

// GetScale returns the scale factor for the given OID.
func (ts *TargetStatus) GetScale(oidName string) float64 {
	if ts.Target == nil {
		return 1.0
	}

	for _, oid := range ts.Target.OIDs {
		if oid.Name == oidName {
			return oid.Scale
		}
	}

	return 1.0
}

// GetDelta returns whether the OID is configured as a delta value.
func (ts *TargetStatus) GetDelta(oidName string) bool {
	if ts.Target == nil {
		return false
	}

	for _, oid := range ts.Target.OIDs {
		if oid.Name == oidName {
			return oid.Delta
		}
	}

	return false
}

// SetTarget sets the target configuration.
func (ts *TargetStatus) SetTarget(target *Target) {
	ts.Target = target
}
