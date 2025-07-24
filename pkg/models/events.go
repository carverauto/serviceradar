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

package models

import (
	"fmt"
	"time"
)

// NATSConfig configures NATS connectivity
type NATSConfig struct {
	URL      string          `json:"url"`
	Domain   string          `json:"domain,omitempty"`
	Security *SecurityConfig `json:"security,omitempty"`
}

// Validate ensures the NATS configuration is valid
func (c *NATSConfig) Validate() error {
	if c.URL == "" {
		return fmt.Errorf("nats url is required")
	}

	return nil
}

// EventsConfig configures the event publishing system
type EventsConfig struct {
	Enabled    bool     `json:"enabled"`
	StreamName string   `json:"stream_name"`
	Subjects   []string `json:"subjects"`
}

// Validate ensures the events configuration is valid
func (c *EventsConfig) Validate() error {
	if !c.Enabled {
		return nil
	}

	if c.StreamName == "" {
		c.StreamName = "events" // Default stream name
	}

	if len(c.Subjects) == 0 {
		// Default subjects for events stream
		c.Subjects = []string{"events.poller.*", "events.syslog.*", "events.snmp.*"}
	}

	return nil
}

// CloudEvent represents a CloudEvents v1.0 compliant event.
type CloudEvent struct {
	SpecVersion     string      `json:"specversion"`
	ID              string      `json:"id"`
	Source          string      `json:"source"`
	Type            string      `json:"type"`
	DataContentType string      `json:"datacontenttype"`
	Subject         string      `json:"subject,omitempty"`
	Time            *time.Time  `json:"time,omitempty"`
	Data            interface{} `json:"data,omitempty"`
}

// EventRow represents a single row in the events database table.
type EventRow struct {
	SpecVersion     string
	ID              string
	Source          string
	Type            string
	DataContentType string
	Subject         string
	RemoteAddr      string
	Host            string
	Level           int32
	Severity        string
	ShortMessage    string
	EventTimestamp  time.Time
	Version         string
	RawData         string
}

// PollerHealthEventData represents the data payload for poller health events.
type PollerHealthEventData struct {
	PollerID       string    `json:"poller_id"`
	PreviousState  string    `json:"previous_state"`
	CurrentState   string    `json:"current_state"`
	Timestamp      time.Time `json:"timestamp"`
	LastSeen       time.Time `json:"last_seen"`
	Host           string    `json:"host,omitempty"`
	RemoteAddr     string    `json:"remote_addr,omitempty"`
	SourceIP       string    `json:"source_ip,omitempty"`
	Partition      string    `json:"partition,omitempty"`
	AlertSent      bool      `json:"alert_sent"`
	RecoveryReason string    `json:"recovery_reason,omitempty"`
}
