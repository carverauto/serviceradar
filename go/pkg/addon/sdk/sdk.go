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
