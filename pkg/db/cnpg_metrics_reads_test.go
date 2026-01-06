package db

import (
	"database/sql"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var (
	errFakeRowScanMismatch          = errors.New("fake row scan mismatch")
	errFakeRowUnsupportedNullString = errors.New("unsupported NullString source")
	errFakeRowUnsupportedNullInt32  = errors.New("unsupported NullInt32 source")
	errFakeRowUnsupportedDest       = errors.New("unsupported destination type")
)

type fakeRow struct {
	values []interface{}
}

func (r *fakeRow) Scan(dest ...interface{}) error {
	if len(dest) != len(r.values) {
		return fmt.Errorf("%w: dest=%d values=%d", errFakeRowScanMismatch, len(dest), len(r.values))
	}

	for i, d := range dest {
		switch ptr := d.(type) {
		case *string:
			val, _ := r.values[i].(string)
			*ptr = val
		case *float64:
			val, _ := r.values[i].(float64)
			*ptr = val
		case *[]byte:
			switch v := r.values[i].(type) {
			case []byte:
				*ptr = append((*ptr)[:0], v...)
			case string:
				*ptr = []byte(v)
			case nil:
				*ptr = nil
			}
		case *time.Time:
			val, _ := r.values[i].(time.Time)
			*ptr = val
		case *sql.NullString:
			switch v := r.values[i].(type) {
			case sql.NullString:
				*ptr = v
			case string:
				*ptr = sql.NullString{String: v, Valid: true}
			case nil:
				*ptr = sql.NullString{}
			default:
				return fmt.Errorf("%w: %T", errFakeRowUnsupportedNullString, v)
			}
		case *sql.NullInt32:
			switch v := r.values[i].(type) {
			case sql.NullInt32:
				*ptr = v
			case int32:
				*ptr = sql.NullInt32{Int32: v, Valid: true}
			case nil:
				*ptr = sql.NullInt32{}
			default:
				return fmt.Errorf("%w: %T", errFakeRowUnsupportedNullInt32, v)
			}
		default:
			return fmt.Errorf("%w: %T", errFakeRowUnsupportedDest, d)
		}
	}

	return nil
}

func TestScanCNPGTimeseriesMetric(t *testing.T) {
	now := time.Now().UTC()
	row := &fakeRow{
		values: []interface{}{
			"ifHCInOctets",
			"snmp",
			123.45,
			[]byte(`{"foo":"bar"}`),
			now,
			sql.NullString{String: "1.2.3.4", Valid: true},
			sql.NullInt32{Int32: 7, Valid: true},
			sql.NullString{String: "default:1.2.3.4", Valid: true},
			sql.NullString{String: "default", Valid: true},
			sql.NullString{String: "gateway-1", Valid: true},
		},
	}

	metric, err := scanCNPGTimeseriesMetric(row)
	require.NoError(t, err)
	require.NotNil(t, metric)
	assert.Equal(t, "ifHCInOctets", metric.Name)
	assert.Equal(t, "snmp", metric.Type)
	assert.Equal(t, "123.45", metric.Value)
	assert.Equal(t, "1.2.3.4", metric.TargetDeviceIP)
	assert.EqualValues(t, 7, metric.IfIndex)
	assert.Equal(t, "default:1.2.3.4", metric.DeviceID)
	assert.Equal(t, "default", metric.Partition)
	assert.Equal(t, "gateway-1", metric.GatewayID)
	assert.JSONEq(t, `{"foo":"bar"}`, metric.Metadata)
	assert.WithinDuration(t, now, metric.Timestamp, time.Second)
}

func TestScanCNPGTimeseriesMetricHandlesNulls(t *testing.T) {
	row := &fakeRow{
		values: []interface{}{
			"metric",
			"icmp",
			0.0,
			nil,
			time.Unix(0, 0).UTC(),
			sql.NullString{},
			sql.NullInt32{},
			sql.NullString{},
			sql.NullString{},
			sql.NullString{},
		},
	}

	metric, err := scanCNPGTimeseriesMetric(row)
	require.NoError(t, err)
	require.NotNil(t, metric)
	assert.Empty(t, metric.Metadata)
	assert.EqualValues(t, 0, metric.IfIndex)
	assert.Empty(t, metric.DeviceID)
}

func TestBuildTimeseriesFilterClause(t *testing.T) {
	start := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	end := start.Add(time.Hour)
	filters := map[string]string{
		"device_id":   "default:1.2.3.4",
		"metric_type": "snmp",
	}

	where, args, err := buildTimeseriesFilterClause(filters, start, end)
	require.NoError(t, err)
	assert.Equal(t, "timestamp BETWEEN $1 AND $2 AND device_id = $3 AND metric_type = $4", where)
	require.Len(t, args, 4)
	assert.Equal(t, start, args[0])
	assert.Equal(t, end, args[1])
	assert.Equal(t, "default:1.2.3.4", args[2])
	assert.Equal(t, "snmp", args[3])

	_, _, err = buildTimeseriesFilterClause(map[string]string{"unknown": "value"}, start, end)
	assert.Error(t, err)
}

func TestSanitizeTimeseriesColumn(t *testing.T) {
	col, err := sanitizeTimeseriesColumn("metric_type")
	require.NoError(t, err)
	assert.Equal(t, "metric_type", col)

	_, err = sanitizeTimeseriesColumn("DROP TABLE")
	assert.Error(t, err)
}

func TestFormatTimeseriesValue(t *testing.T) {
	assert.Equal(t, "12.34", formatTimeseriesValue(12.34))
	assert.Equal(t, "0", formatTimeseriesValue(0))
}

func TestUintFromNullInt64(t *testing.T) {
	assert.EqualValues(t, 5, uintFromNullInt64(sql.NullInt64{Int64: 5, Valid: true}))
	assert.EqualValues(t, 0, uintFromNullInt64(sql.NullInt64{}))
	assert.EqualValues(t, 0, uintFromNullInt64(sql.NullInt64{Int64: -1, Valid: true}))
}
