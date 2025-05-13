package common

import (
	"context"
)

// contextKey is a private type for context keys used in this package
type contextKey string

// Keys for context values
const (
	agentIDKey  contextKey = "agent_id"
	pollerIDKey contextKey = "poller_id"
)

// WithAgentID returns a new context with the given agent ID
func WithAgentID(ctx context.Context, agentID string) context.Context {
	return context.WithValue(ctx, agentIDKey, agentID)
}

// GetAgentID retrieves the agent ID from the context
// Returns the agent ID and a boolean indicating if it was found
func GetAgentID(ctx context.Context) (string, bool) {
	agentID, ok := ctx.Value(agentIDKey).(string)
	return agentID, ok
}

// WithPollerID returns a new context with the given poller ID
func WithPollerID(ctx context.Context, pollerID string) context.Context {
	return context.WithValue(ctx, pollerIDKey, pollerID)
}

// GetPollerID retrieves the poller ID from the context
// Returns the poller ID and a boolean indicating if it was found
func GetPollerID(ctx context.Context) (string, bool) {
	pollerID, ok := ctx.Value(pollerIDKey).(string)
	return pollerID, ok
}
