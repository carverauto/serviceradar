package agent

import (
	"context"
	"testing"

	"github.com/mfreeman451/serviceradar/pkg/checker"
	"github.com/mfreeman451/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestGetCheckerCaching(t *testing.T) {
	// Create a minimal Server instance with an empty checker cache
	// and an initialized registry.
	s := &Server{
		checkers: make(map[string]checker.Checker),
		registry: initRegistry(),
	}

	ctx := context.Background()

	// Create a status request for a port checker with details "127.0.0.1:22".
	req1 := &proto.StatusRequest{
		ServiceName: "SSH",
		ServiceType: "port",
		Details:     "127.0.0.1:22",
	}

	// Create another status request with the same service type/name
	// but with different details "192.168.1.1:22".
	req2 := &proto.StatusRequest{
		ServiceName: "SSH",
		ServiceType: "port",
		Details:     "192.168.1.1:22",
	}

	// Call getChecker twice with req1 and verify that the same instance is returned.
	checker1a, err := s.getChecker(ctx, req1)
	require.NoError(t, err)
	checker1b, err := s.getChecker(ctx, req1)
	require.NoError(t, err)
	assert.Equal(t, checker1a, checker1b, "repeated call with the same request should yield the same checker instance")

	// Call getChecker with req2 and verify that a different instance is returned.
	checker2, err := s.getChecker(ctx, req2)
	require.NoError(t, err)
	assert.NotEqual(t, checker1a, checker2, "requests with different details should yield different checker instances")
}
