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

package edgeonboarding

import (
	"context"
	"fmt"

	"github.com/carverauto/serviceradar/pkg/models"
)

// downloadPackage downloads the onboarding package from Core using the token.
// This contacts the Core API to deliver the package, which validates the token
// and marks the package as delivered.
func (b *Bootstrapper) downloadPackage(ctx context.Context) error {
	b.logger.Debug().
		Str("token_prefix", b.cfg.Token[:min(8, len(b.cfg.Token))]).
		Msg("Downloading onboarding package from Core")

	// TODO: Implement actual download logic
	// This will involve:
	// 1. Determining the Core endpoint (from config or discovery)
	// 2. Calling the Core API /api/admin/edge-packages/deliver endpoint
	// 3. Providing the download token
	// 4. Receiving the package with decrypted join token and bundle

	// For now, return an error to indicate not implemented
	return fmt.Errorf("not implemented: package download")
}

// validatePackage validates the downloaded package contents.
func (b *Bootstrapper) validatePackage(ctx context.Context) error {
	if b.pkg == nil {
		return fmt.Errorf("package not downloaded")
	}

	if b.downloadResult == nil {
		return fmt.Errorf("download result not available")
	}

	// Validate package fields
	if b.pkg.PackageID == "" {
		return fmt.Errorf("package_id is empty")
	}

	if b.pkg.ComponentID == "" {
		return fmt.Errorf("component_id is empty")
	}

	if b.pkg.ComponentType == models.EdgeOnboardingComponentTypeNone {
		return fmt.Errorf("component_type is not set")
	}

	if b.pkg.DownstreamSPIFFEID == "" {
		return fmt.Errorf("downstream_spiffe_id is empty")
	}

	// Validate SPIRE credentials
	if b.downloadResult.JoinToken == "" {
		return fmt.Errorf("join token is empty")
	}

	if len(b.downloadResult.BundlePEM) == 0 {
		return fmt.Errorf("bundle PEM is empty")
	}

	// Validate package status
	switch b.pkg.Status {
	case models.EdgeOnboardingStatusDelivered, models.EdgeOnboardingStatusActivated:
		// Valid statuses for onboarding
	case models.EdgeOnboardingStatusRevoked:
		return fmt.Errorf("package has been revoked")
	case models.EdgeOnboardingStatusExpired:
		return fmt.Errorf("package has expired")
	case models.EdgeOnboardingStatusDeleted:
		return fmt.Errorf("package has been deleted")
	default:
		b.logger.Warn().
			Str("status", string(b.pkg.Status)).
			Msg("Package has unexpected status, proceeding anyway")
	}

	b.logger.Debug().
		Str("package_id", b.pkg.PackageID).
		Str("component_id", b.pkg.ComponentID).
		Str("spiffe_id", b.pkg.DownstreamSPIFFEID).
		Msg("Package validation successful")

	return nil
}

// markActivated notifies Core that the package has been activated.
// This is done by the service when it successfully starts up with the credentials.
func (b *Bootstrapper) markActivated(ctx context.Context) error {
	// TODO: Implement activation notification
	// This could be done via:
	// 1. Direct gRPC call to Core (requires Core to expose this endpoint)
	// 2. Automatic detection when service first connects with SPIFFE ID
	// 3. KV update that Core monitors

	// For now, we'll log and continue - Core will detect activation when
	// the service first reports status with the SPIFFE ID
	b.logger.Debug().
		Str("package_id", b.pkg.PackageID).
		Msg("Package activation will be detected by Core on first status report")

	return nil
}

// min returns the minimum of two integers.
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
