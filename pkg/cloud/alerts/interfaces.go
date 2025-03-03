/*-
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

// Package alerts pkg/cloud/alerts/interfaces.go

//go:generate mockgen -destination=mock_alerts.go -package=alerts github.com/carverauto/serviceradar/pkg/cloud/alerts AlertService

package alerts

import (
	"context"
)

// AlertService defines the interface for alert implementations.
type AlertService interface {
	// Alert sends an alert through the service
	Alert(ctx context.Context, alert *WebhookAlert) error

	// IsEnabled returns whether the alerter is enabled
	IsEnabled() bool
}
