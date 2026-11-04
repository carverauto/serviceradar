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

package agent

import (
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Conversion of netprobe discovery updates into NetprobeDiscoveryBatchV1.
// The update's metadata map is what core's fingerprint, DPI and process
// payload schemas read today, so it rides verbatim and the projector
// rebuilds the legacy update from it; the promoted fields are read out of
// the same metadata for typed consumers. The typed observation oneof is
// left unset: decomposing the metadata here and recomposing it in the
// projector would add a second place for the two to drift, and the
// verbatim map already carries every key.

func netprobeDiscoveryRecord(update map[string]interface{}) *edgev1.NetprobeDiscoveryRecordV1 {
	metadata := updateStringMap(update["metadata"])
	record := &edgev1.NetprobeDiscoveryRecordV1{
		Ip:                payloadString(update, "ip"),
		AgentId:           payloadString(update, "agent_id"),
		GatewayId:         payloadString(update, "gateway_id"),
		Partition:         payloadString(update, "partition"),
		Source:            payloadString(update, "source"),
		DiscoverySource:   metadataString(metadata, "discovery_source"),
		CollectorIp:       metadataString(metadata, "_alias_collector_ip"),
		AliasLastSeenIp:   metadataString(metadata, "_alias_last_seen_ip"),
		TimestampUnixNano: payloadTimeNano(update, "timestamp"),
		Metadata:          metadata,
	}
	if text := metadataString(metadata, "_alias_last_seen_at"); text != "" {
		record.AliasLastSeenAtUnixNano = payloadTimeNano(
			map[string]interface{}{"t": text}, "t")
	}
	return record
}
