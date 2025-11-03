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
	"errors"
	"fmt"

	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	// ErrPackageDownloadNotImplemented is returned when package download is attempted.
	ErrPackageDownloadNotImplemented = errors.New("not implemented: package download")
	// ErrPackageNotDownloaded is returned when package validation is attempted before download.
	ErrPackageNotDownloaded = errors.New("package not downloaded")
	// ErrDownloadResultNotAvailable is returned when download result is missing.
	ErrDownloadResultNotAvailable = errors.New("download result not available")
	// ErrPackageIDEmpty is returned when package_id is empty.
	ErrPackageIDEmpty = errors.New("package_id is empty")
	// ErrComponentIDEmpty is returned when component_id is empty.
	ErrComponentIDEmpty = errors.New("component_id is empty")
	// ErrComponentTypeNotSet is returned when component_type is not set.
	ErrComponentTypeNotSet = errors.New("component_type is not set")
	// ErrDownstreamSPIFFEIDEmpty is returned when downstream_spiffe_id is empty.
	ErrDownstreamSPIFFEIDEmpty = errors.New("downstream_spiffe_id is empty")
	// ErrJoinTokenEmpty is returned when join token is empty.
	ErrJoinTokenEmpty = errors.New("join token is empty")
	// ErrBundlePEMEmpty is returned when bundle PEM is empty.
	ErrBundlePEMEmpty = errors.New("bundle PEM is empty")
	// ErrPackageRevoked is returned when package has been revoked.
	ErrPackageRevoked = errors.New("package has been revoked")
	// ErrPackageExpired is returned when package has expired.
	ErrPackageExpired = errors.New("package has expired")
	// ErrPackageDeleted is returned when package has been deleted.
	ErrPackageDeleted = errors.New("package has been deleted")
	// ErrPackageNotDelivered is returned when package is still in issued state.
	ErrPackageNotDelivered = errors.New("package has not been delivered yet")
)

// downloadPackage downloads the onboarding package from Core using the token.
// This contacts the Core API to deliver the package, which validates the token
// and marks the package as delivered.
func (b *Bootstrapper) downloadPackage(ctx context.Context) error {
	_ = ctx

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
	return ErrPackageDownloadNotImplemented
}

// validatePackage validates the downloaded package contents.
func (b *Bootstrapper) validatePackage(ctx context.Context) error {
	_ = ctx

	if b.pkg == nil {
		return ErrPackageNotDownloaded
	}

	if b.downloadResult == nil {
		return ErrDownloadResultNotAvailable
	}

	// Validate package fields
	if b.pkg.PackageID == "" {
		return ErrPackageIDEmpty
	}

	if b.pkg.ComponentID == "" {
		return ErrComponentIDEmpty
	}

	if b.pkg.ComponentType == models.EdgeOnboardingComponentTypeNone {
		return ErrComponentTypeNotSet
	}

	if b.pkg.DownstreamSPIFFEID == "" {
		return ErrDownstreamSPIFFEIDEmpty
	}

	// Validate SPIRE credentials
	if b.downloadResult.JoinToken == "" {
		return ErrJoinTokenEmpty
	}

	if len(b.downloadResult.BundlePEM) == 0 {
		return ErrBundlePEMEmpty
	}

	// Validate package status
	switch b.pkg.Status {
	case models.EdgeOnboardingStatusDelivered, models.EdgeOnboardingStatusActivated:
		// Valid statuses for onboarding
	case models.EdgeOnboardingStatusIssued:
		return fmt.Errorf("%w: id %s", ErrPackageNotDelivered, b.pkg.PackageID)
	case models.EdgeOnboardingStatusRevoked:
		return ErrPackageRevoked
	case models.EdgeOnboardingStatusExpired:
		return ErrPackageExpired
	case models.EdgeOnboardingStatusDeleted:
		return ErrPackageDeleted
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
	if err := ctx.Err(); err != nil {
		return err
	}

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
