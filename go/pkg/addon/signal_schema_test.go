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

package addon

import (
	"testing"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
)

func TestAttachSignalSchemaRef(t *testing.T) {
	record := &addonpb.TelemetryRecord{}

	AttachSignalSchemaRef(record, SignalSchemaRef{
		ProducerID:             "powerdns",
		ProducerVersion:        "0.1.0",
		SchemaID:               "com.carverauto.powerdns.dns_activity",
		SchemaVersion:          "1.0.0",
		DisplayContractID:      "com.carverauto.powerdns.dns_activity.display",
		DisplayContractVersion: "1.0.0",
		DisplayContract:        "display/dns_activity.display.json",
		SignalType:             "event",
		PayloadKind:            "ocsf_event",
	})

	if got := record.GetMetadata()[SignalSchemaMetadataSchemaID]; got != "com.carverauto.powerdns.dns_activity" {
		t.Fatalf("schema id metadata = %q", got)
	}
	if got := record.GetMetadata()[SignalSchemaMetadataDisplayContract]; got != "display/dns_activity.display.json" {
		t.Fatalf("display contract metadata = %q", got)
	}
}

func TestAttachSignalSchemaRefHandlesNilRecord(t *testing.T) {
	if got := AttachSignalSchemaRef(nil, SignalSchemaRef{SchemaID: "x"}); got != nil {
		t.Fatalf("nil record returned %#v", got)
	}
}
