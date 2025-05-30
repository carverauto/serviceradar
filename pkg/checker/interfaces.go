/*
 * Copyright 2025 Carver Automation Corporation.
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

package checker

import (
	"context"
	"encoding/json"

	"github.com/carverauto/serviceradar/proto"
)

// Checker defines how to check a service's status.
type Checker interface {
	Check(ctx context.Context, req *proto.StatusRequest) (bool, json.RawMessage)
}

// StatusProvider allows plugins to provide detailed status data.
type StatusProvider interface {
	GetStatusData() json.RawMessage
}

// HealthChecker combines basic checking with detailed status.
type HealthChecker interface {
	Checker
	StatusProvider
}

// Context key for StatusRequest
type contextKey string

const StatusRequestKey contextKey = "statusRequest"
