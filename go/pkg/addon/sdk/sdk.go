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

// Package sdk is the first-party authoring SDK for native ServiceRadar agent
// add-ons. An add-on author implements the addon.Addon interface and calls
// Serve from main; the SDK wraps HashiCorp go-plugin so the add-on runs as a
// supervised subprocess speaking gRPC over a restricted Unix-domain socket with
// AutoMTLS, negotiated by the agent (the go-plugin client).
//
// Native metrics:
//
// Add-ons that collect ServiceRadar-native metrics should emit them through
// AddonService.StreamTelemetry with ServiceRadarMetricRecord. The telemetry
// record payload is an encoded serviceradar.metric.v1.MetricBatch; it is not a
// JSON metrics array and it is published upstream through the normal
// JetStream metrics.* path.
//
// Minimal add-on:
//
//	func main() { sdk.Serve(&myAddon{}) }
//
// where *myAddon implements addon.Addon (Info/Configure/Health).
package sdk

import (
	"github.com/carverauto/serviceradar/go/pkg/addon"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	goplugin "github.com/hashicorp/go-plugin"
)

type SignalSchemaRef = addon.SignalSchemaRef
type AdvisoryFeedBatch = addon.AdvisoryFeedBatch
type AdvisorySource = addon.AdvisorySource
type AdvisorySnapshot = addon.AdvisorySnapshot
type AdvisoryRecord = addon.AdvisoryRecord
type AffectedCoordinate = addon.AffectedCoordinate
type ProducerScheduleContract = addon.ProducerScheduleContract
type ScannerTarget = addon.ScannerTarget
type ScannerSourceDiagnostic = addon.ScannerSourceDiagnostic
type ScannerInventoryArtifact = addon.ScannerInventoryArtifact
type ScannerScanActivity = addon.ScannerScanActivity
type ScannerFinding = addon.ScannerFinding
type ArtifactMetadata = addon.ArtifactMetadata
type ArtifactUploadChunk = addon.ArtifactUploadChunk
type MetricFeedFrame = addon.MetricFeedFrame
type MetricFeedAck = addon.MetricFeedAck
type CredentialBrokerGrant = addon.CredentialBrokerGrant
type CredentialBrokerMaterial = addon.CredentialBrokerMaterial
type CredentialMaterial = addon.CredentialMaterial
type CredentialBundle = addon.CredentialBundle

const (
	CapabilityAdvisoryFeedV1     = addon.CapabilityAdvisoryFeedV1
	CapabilityProducerScheduleV1 = addon.CapabilityProducerScheduleV1
	CapabilityScannerV1          = addon.CapabilityScannerV1
	CapabilityArtifactStagingV1  = addon.CapabilityArtifactStagingV1
	CapabilityMetricFeedV1       = addon.CapabilityMetricFeedV1

	AdvisoryFeedContractVersion = addon.AdvisoryFeedContractVersion

	ProducerScheduleRunSchemaV1            = addon.ProducerScheduleRunSchemaV1
	ProducerScheduleCommandPluginRunAction = addon.ProducerScheduleCommandPluginRunAction
	CapabilityActionResultIngestV1         = addon.CapabilityActionResultIngestV1
	ProducerScheduleTypeInterval           = addon.ProducerScheduleTypeInterval
	ProducerScheduleTypeCron               = addon.ProducerScheduleTypeCron
	ProducerScheduleTypeManual             = addon.ProducerScheduleTypeManual
	ProducerScheduleDispatchAssignment     = addon.ProducerScheduleDispatchAssignment
	ProducerScheduleDispatchPackage        = addon.ProducerScheduleDispatchPackage
	ProducerScheduleDispatchTargetQuery    = addon.ProducerScheduleDispatchTargetQuery

	CoordinateTypePURL          = addon.CoordinateTypePURL
	CoordinateTypeCPE           = addon.CoordinateTypeCPE
	CoordinateTypeVendorProduct = addon.CoordinateTypeVendorProduct

	ScannerContractVersion = addon.ScannerContractVersion

	ScannerSignalScanActivity      = addon.ScannerSignalScanActivity
	ScannerSignalFinding           = addon.ScannerSignalFinding
	ScannerSignalInventoryArtifact = addon.ScannerSignalInventoryArtifact

	ScannerStateSucceeded = addon.ScannerStateSucceeded
	ScannerStatePartial   = addon.ScannerStatePartial
	ScannerStateFailed    = addon.ScannerStateFailed
	ScannerStateSkipped   = addon.ScannerStateSkipped

	ScannerCoverageComplete    = addon.ScannerCoverageComplete
	ScannerCoveragePartial     = addon.ScannerCoveragePartial
	ScannerCoverageFailed      = addon.ScannerCoverageFailed
	ScannerCoverageNotScanned  = addon.ScannerCoverageNotScanned
	ScannerCoverageUnsupported = addon.ScannerCoverageUnsupported
)

// Serve runs the add-on as a go-plugin gRPC server. It blocks until the agent
// terminates the plugin. AutoMTLS is driven by the agent-side client; the server
// honors it automatically.
func Serve(impl addon.Addon) {
	goplugin.Serve(&goplugin.ServeConfig{
		HandshakeConfig: addon.Handshake,
		Plugins:         addon.ServerPluginSet(impl),
		GRPCServer:      goplugin.DefaultGRPCServer,
	})
}

// AttachSignalSchemaRef stores a bounded signal schema/display reference on a
// telemetry record's metadata map.
func AttachSignalSchemaRef(record *addonpb.TelemetryRecord, ref SignalSchemaRef) *addonpb.TelemetryRecord {
	return addon.AttachSignalSchemaRef(record, ref)
}

func NewProducerScheduleContract(scheduleID, label, actionID string) ProducerScheduleContract {
	return addon.NewProducerScheduleContract(scheduleID, label, actionID)
}

func CredentialBundleFromConfig(configJSON []byte) (CredentialBundle, error) {
	return addon.CredentialBundleFromConfig(configJSON)
}
