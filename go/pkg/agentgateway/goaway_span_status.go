/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package agentgateway

import (
	"context"
	"strings"

	"go.opentelemetry.io/otel/attribute"
	otelcodes "go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/stats"
	"google.golang.org/grpc/status"
)

// gracefulGoAwayMarker is how grpc-go reports an RPC cut off by a transport the
// server had already closed with GOAWAY NO_ERROR: the status is Unavailable and
// the message ends "received prior goaway: code: NO_ERROR", optionally followed
// by the GOAWAY debug data. grpc-go exposes the GOAWAY code to callers only in
// this message.
const gracefulGoAwayMarker = "received prior goaway: code: NO_ERROR"

// goAwaySpanAttributeKey marks a client span whose RPC ended because the
// server drained the connection; its value is the GOAWAY code.
const goAwaySpanAttributeKey = "rpc.grpc.goaway"

// drainAwareClientHandler wraps the OpenTelemetry client stats handler so an
// RPC that ends because the server announced a graceful shutdown (GOAWAY
// NO_ERROR, as in an agent-gateway rollout) is not recorded as an error span.
// The span keeps its Unavailable status code attribute and gains
// rpc.grpc.goaway=NO_ERROR; its status is Ok. Any other failure, including an
// Unavailable without that GOAWAY, is left to the wrapped handler and stays an
// error.
type drainAwareClientHandler struct {
	stats.Handler
}

// HandleRPC marks a gracefully drained RPC's span before the wrapped handler
// ends it. Ok is final for an OpenTelemetry span status, so the Error the
// wrapped handler records for the Unavailable code does not replace it.
func (h drainAwareClientHandler) HandleRPC(ctx context.Context, rs stats.RPCStats) {
	if end, ok := rs.(*stats.End); ok && endedByGracefulGoAway(end.Error) {
		span := trace.SpanFromContext(ctx)
		span.SetAttributes(attribute.String(goAwaySpanAttributeKey, "NO_ERROR"))
		span.SetStatus(otelcodes.Ok, "")
	}

	h.Handler.HandleRPC(ctx, rs)
}

func endedByGracefulGoAway(err error) bool {
	if err == nil {
		return false
	}

	st, ok := status.FromError(err)

	return ok && st.Code() == codes.Unavailable && strings.Contains(st.Message(), gracefulGoAwayMarker)
}
