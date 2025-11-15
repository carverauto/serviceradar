package db

import (
	"database/sql"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestDecodeJSONIntSlice(t *testing.T) {
	values, err := decodeJSONIntSlice([]byte(`[1,2,3]`))
	require.NoError(t, err)
	assert.Equal(t, []int{1, 2, 3}, values)

	values, err = decodeJSONIntSlice(nil)
	require.NoError(t, err)
	assert.Nil(t, values)

	_, err = decodeJSONIntSlice([]byte(`invalid`))
	assert.Error(t, err)
}

func TestDecodeJSONPortResults(t *testing.T) {
	raw := []byte(`[{"port":80,"available":true,"response_time":1000000,"service":"http"}]`)
	results, err := decodeJSONPortResults(raw)
	require.NoError(t, err)
	require.Len(t, results, 1)
	assert.Equal(t, 80, results[0].Port)
	assert.True(t, results[0].Available)

	results, err = decodeJSONPortResults(nil)
	require.NoError(t, err)
	assert.Nil(t, results)
}

func TestDecodeJSONMetadata(t *testing.T) {
	raw := []byte(`{"foo":"bar"}`)
	metadata, err := decodeJSONMetadata(raw)
	require.NoError(t, err)
	require.Equal(t, map[string]string{"foo": "bar"}, metadata)

	metadata, err = decodeJSONMetadata(nil)
	require.NoError(t, err)
	assert.Nil(t, metadata)
}

func TestNullPointerHelpers(t *testing.T) {
	strVal := stringPtrFromNull(sql.NullString{String: "value", Valid: true})
	require.NotNil(t, strVal)
	assert.Equal(t, "value", *strVal)

	assert.Nil(t, stringPtrFromNull(sql.NullString{}))

	intVal := int64PtrFromNull(sql.NullInt64{Int64: 42, Valid: true})
	require.NotNil(t, intVal)
	assert.EqualValues(t, 42, *intVal)

	assert.Nil(t, int64PtrFromNull(sql.NullInt64{}))

	floatVal := float64PtrFromNull(sql.NullFloat64{Float64: 1.5, Valid: true})
	require.NotNil(t, floatVal)
	assert.InDelta(t, 1.5, *floatVal, 0.0001)

	assert.Nil(t, float64PtrFromNull(sql.NullFloat64{}))
}

func TestDecodeJSONPortResultsInvalid(t *testing.T) {
	_, err := decodeJSONPortResults([]byte(`invalid`))
	assert.Error(t, err)
}

func TestDecodeJSONMetadataInvalid(t *testing.T) {
	_, err := decodeJSONMetadata([]byte(`invalid`))
	assert.Error(t, err)
}
