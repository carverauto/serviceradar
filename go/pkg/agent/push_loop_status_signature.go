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

package agent

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"sort"
	"time"

	"github.com/carverauto/serviceradar/proto"
)

type statusPushReason string

const (
	statusPushReasonInitial   statusPushReason = "initial"
	statusPushReasonChange    statusPushReason = "change"
	statusPushReasonHeartbeat statusPushReason = "heartbeat"
)

type statusPushDecision struct {
	shouldPush bool
	reason     statusPushReason
	signature  string
}

// evaluateStatusPush decides whether to push regular statuses based on change detection and heartbeat.
func (p *PushLoop) evaluateStatusPush(statuses []*proto.GatewayServiceStatus, now time.Time) statusPushDecision {
	if len(statuses) == 0 {
		return statusPushDecision{}
	}

	signature := buildStatusSignature(statuses)
	lastSignature, lastPush := p.getStatusTrackingState()

	if lastSignature == "" {
		return statusPushDecision{shouldPush: true, reason: statusPushReasonInitial, signature: signature}
	}

	if signature != lastSignature {
		return statusPushDecision{shouldPush: true, reason: statusPushReasonChange, signature: signature}
	}

	debounce := p.getStatusDebounceInterval()
	if debounce > 0 && now.Sub(lastPush) < debounce {
		return statusPushDecision{}
	}

	heartbeat := p.getStatusHeartbeatInterval()
	if heartbeat <= 0 {
		heartbeat = defaultStatusHeartbeatInterval
	}
	if now.Sub(lastPush) >= heartbeat {
		return statusPushDecision{shouldPush: true, reason: statusPushReasonHeartbeat, signature: signature}
	}

	return statusPushDecision{}
}

type statusSignatureEntry struct {
	serviceName string
	serviceType string
	source      string
	available   bool
	messageHash string
}

func buildStatusSignature(statuses []*proto.GatewayServiceStatus) string {
	entries := make([]statusSignatureEntry, 0, len(statuses))
	for _, status := range statuses {
		if status == nil {
			continue
		}
		entries = append(entries, statusSignatureEntry{
			serviceName: status.ServiceName,
			serviceType: status.ServiceType,
			source:      status.Source,
			available:   status.Available,
			messageHash: hashStatusMessage(status.Message),
		})
	}

	sort.Slice(entries, func(i, j int) bool {
		if entries[i].serviceName != entries[j].serviceName {
			return entries[i].serviceName < entries[j].serviceName
		}
		if entries[i].serviceType != entries[j].serviceType {
			return entries[i].serviceType < entries[j].serviceType
		}
		if entries[i].source != entries[j].source {
			return entries[i].source < entries[j].source
		}
		if entries[i].available != entries[j].available {
			return !entries[i].available && entries[j].available
		}
		return entries[i].messageHash < entries[j].messageHash
	})

	hasher := sha256.New()
	for _, entry := range entries {
		hasher.Write([]byte(entry.serviceName))
		hasher.Write([]byte{0})
		hasher.Write([]byte(entry.serviceType))
		hasher.Write([]byte{0})
		hasher.Write([]byte(entry.source))
		hasher.Write([]byte{0})
		if entry.available {
			hasher.Write([]byte{1})
		} else {
			hasher.Write([]byte{0})
		}
		hasher.Write([]byte{0})
		hasher.Write([]byte(entry.messageHash))
		hasher.Write([]byte{0})
	}

	return base64.StdEncoding.EncodeToString(hasher.Sum(nil))
}

func hashStatusMessage(message []byte) string {
	if len(message) == 0 {
		return ""
	}

	raw := bytes.TrimSpace(message)
	if len(raw) == 0 {
		return ""
	}

	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()

	var payload interface{}
	if err := dec.Decode(&payload); err != nil {
		return hashBytes(raw)
	}
	if err := dec.Decode(&struct{}{}); err == nil {
		return hashBytes(raw)
	} else if !errors.Is(err, io.EOF) {
		return hashBytes(raw)
	}

	scrubVolatileFields(payload)
	canonical, err := marshalCanonicalJSON(payload)
	if err != nil {
		return hashBytes(raw)
	}

	return hashBytes(canonical)
}

func hashBytes(data []byte) string {
	sum := sha256.Sum256(data)
	return base64.StdEncoding.EncodeToString(sum[:])
}

func scrubVolatileFields(value interface{}) {
	switch typed := value.(type) {
	case map[string]interface{}:
		for key, entry := range typed {
			if isStatusSignatureScrubKey(key) {
				delete(typed, key)
				continue
			}
			scrubVolatileFields(entry)
		}
	case []interface{}:
		for _, entry := range typed {
			scrubVolatileFields(entry)
		}
	}
}

func isStatusSignatureScrubKey(key string) bool {
	switch key {
	case "response_time", "response_time_ns":
		return true
	default:
		return false
	}
}

func marshalCanonicalJSON(value interface{}) ([]byte, error) {
	var buf bytes.Buffer
	if err := writeCanonicalJSON(&buf, value); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func writeCanonicalJSON(buf *bytes.Buffer, value interface{}) error {
	switch typed := value.(type) {
	case map[string]interface{}:
		keys := make([]string, 0, len(typed))
		for key := range typed {
			keys = append(keys, key)
		}
		sort.Strings(keys)

		buf.WriteByte('{')
		for i, key := range keys {
			if i > 0 {
				buf.WriteByte(',')
			}
			keyBytes, err := json.Marshal(key)
			if err != nil {
				return err
			}
			buf.Write(keyBytes)
			buf.WriteByte(':')
			if err := writeCanonicalJSON(buf, typed[key]); err != nil {
				return err
			}
		}
		buf.WriteByte('}')
		return nil
	case []interface{}:
		buf.WriteByte('[')
		for i, entry := range typed {
			if i > 0 {
				buf.WriteByte(',')
			}
			if err := writeCanonicalJSON(buf, entry); err != nil {
				return err
			}
		}
		buf.WriteByte(']')
		return nil
	case json.Number:
		buf.WriteString(typed.String())
		return nil
	case string:
		encoded, err := json.Marshal(typed)
		if err != nil {
			return err
		}
		buf.Write(encoded)
		return nil
	case bool:
		if typed {
			buf.WriteString("true")
		} else {
			buf.WriteString("false")
		}
		return nil
	case nil:
		buf.WriteString("null")
		return nil
	case float64:
		encoded, err := json.Marshal(typed)
		if err != nil {
			return err
		}
		buf.Write(encoded)
		return nil
	default:
		encoded, err := json.Marshal(typed)
		if err != nil {
			return err
		}
		buf.Write(encoded)
		return nil
	}
}
