/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package db pkg/db/interfaces.go
package db

import (
	"context"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

//go:generate mockgen -source=interfaces.go -destination=mock_db.go -package=db

// Service represents the CNPG-backed database operations used by consumers.
type Service interface {
	Close() error
	StoreNetflowMetrics(ctx context.Context, metrics []*models.NetflowMetric) error
}
