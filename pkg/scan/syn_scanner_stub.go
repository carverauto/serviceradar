//go:build !linux
// +build !linux

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

package scan

import (
	"context"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// SYNScanner is a stub implementation for non-Linux platforms
type SYNScanner struct{}

var _ Scanner = (*SYNScanner)(nil)

// NewSYNScanner creates a new SYN scanner stub that returns an error on non-Linux platforms
func NewSYNScanner(_ time.Duration, _ int, _ logger.Logger) (*SYNScanner, error) {
	return nil, fmt.Errorf("SYN scanning is only supported on Linux")
}

// Scan returns an error indicating SYN scanning is not supported on this platform
func (*SYNScanner) Scan(_ context.Context, _ []models.Target) (<-chan models.Result, error) {
	return nil, fmt.Errorf("SYN scanning is only supported on Linux")
}

// Stop returns an error indicating SYN scanning is not supported on this platform
func (*SYNScanner) Stop(_ context.Context) error {
	return fmt.Errorf("SYN scanning is only supported on Linux")
}
