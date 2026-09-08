package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestArmisSearchHandlerRequiresAQL(t *testing.T) {
	req := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/api/v1/search/?length=1", nil)
	rr := httptest.NewRecorder()

	searchHandler(rr, req)

	require.Equal(t, http.StatusBadRequest, rr.Code)
	require.Contains(t, rr.Body.String(), "missing required aql")
}

func TestArmisSearchHandlerRejectsExplicitZeroFrom(t *testing.T) {
	req := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/api/v1/search/?aql=in%3Adevices&from=0&length=1", nil)
	rr := httptest.NewRecorder()

	searchHandler(rr, req)

	require.Equal(t, http.StatusBadRequest, rr.Code)
	require.Contains(t, rr.Body.String(), "from must be positive")
}

func TestArmisSearchHandlerSupportsFirstAndNextPageContract(t *testing.T) {
	originalTotal := totalDevices
	originalGenerator := deviceGen
	t.Cleanup(func() {
		totalDevices = originalTotal
		deviceGen = originalGenerator
	})

	totalDevices = 2
	deviceGen = &DeviceGenerator{
		allDevices: []ArmisDevice{
			{ID: 1, IPAddress: "10.0.0.1", Name: "device-1", LastSeen: time.Now().UTC()},
			{ID: 2, IPAddress: "10.0.0.2", Name: "device-2", LastSeen: time.Now().UTC()},
		},
	}

	first := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/api/v1/search/?aql=in%3Adevices&length=1", nil)
	firstRecorder := httptest.NewRecorder()
	searchHandler(firstRecorder, first)
	require.Equal(t, http.StatusOK, firstRecorder.Code)

	var firstPage SearchResponse
	require.NoError(t, json.Unmarshal(firstRecorder.Body.Bytes(), &firstPage))
	require.True(t, firstPage.Success)
	require.Equal(t, 1, firstPage.Data.Count)
	require.Equal(t, 1, firstPage.Data.Next)
	require.Len(t, firstPage.Data.Results, 1)
	require.Equal(t, 1, firstPage.Data.Results[0].ID)

	next := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/api/v1/search/?aql=in%3Adevices&from=1&length=1", nil)
	nextRecorder := httptest.NewRecorder()
	searchHandler(nextRecorder, next)
	require.Equal(t, http.StatusOK, nextRecorder.Code)

	var nextPage SearchResponse
	require.NoError(t, json.Unmarshal(nextRecorder.Body.Bytes(), &nextPage))
	require.True(t, nextPage.Success)
	require.Equal(t, 1, nextPage.Data.Count)
	require.Zero(t, nextPage.Data.Next)
	require.Len(t, nextPage.Data.Results, 1)
	require.Equal(t, 2, nextPage.Data.Results[0].ID)
}
