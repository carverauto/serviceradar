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

const (
	// CapabilityProducerScheduleV1 marks add-ons or plugins that declare
	// platform-managed producer schedules in their package manifest.
	CapabilityProducerScheduleV1 = "producer-schedule:v1"
	// CapabilityActionResultIngestV1 authorizes an approved package's action
	// result to enter the normal plugin-result ingestion queue.
	CapabilityActionResultIngestV1 = "action-result-ingest:v1"

	// ProducerScheduleRunSchemaV1 is the commandbus payload schema sent to a
	// scheduled producer action.
	ProducerScheduleRunSchemaV1 = "serviceradar.producer_schedule_run.v1"

	ProducerScheduleCommandPluginRunAction = "plugin.run_action"
	ProducerScheduleCommandAddonRunCommand = CommandTypeAddonRunCommand

	ProducerScheduleTypeInterval = "interval"
	ProducerScheduleTypeCron     = "cron"
	ProducerScheduleTypeManual   = "manual"

	ProducerScheduleDispatchAssignment  = "assignment"
	ProducerScheduleDispatchPackage     = "package"
	ProducerScheduleDispatchTargetQuery = "target_query"
)

// ProducerScheduleContract is a package manifest declaration that lets
// ServiceRadar create operator-managed schedule settings without provider
// hardcoding in core.
type ProducerScheduleContract struct {
	ScheduleID             string         `json:"schedule_id"`
	Label                  string         `json:"label"`
	Description            string         `json:"description,omitempty"`
	ActionID               string         `json:"action_id"`
	CommandType            string         `json:"command_type,omitempty"`
	DefaultCadenceSeconds  int            `json:"default_cadence_seconds,omitempty"`
	MinCadenceSeconds      int            `json:"min_cadence_seconds,omitempty"`
	MaxCadenceSeconds      int            `json:"max_cadence_seconds,omitempty"`
	AllowCron              bool           `json:"allow_cron,omitempty"`
	ScheduleType           string         `json:"schedule_type,omitempty"`
	CronExpression         string         `json:"cron_expression,omitempty"`
	JitterSeconds          int            `json:"jitter_seconds,omitempty"`
	SettingsSchema         map[string]any `json:"settings_schema,omitempty"`
	CredentialRequirements map[string]any `json:"credential_requirements,omitempty"`
	PayloadTemplate        map[string]any `json:"payload_template,omitempty"`
	Redaction              map[string]any `json:"redaction,omitempty"`
	DispatchScope          string         `json:"dispatch_scope,omitempty"`
	TimeoutSeconds         int            `json:"timeout_seconds,omitempty"`
}

// NewProducerScheduleContract returns a manifest-ready schedule declaration for
// a package-owned producer action.
func NewProducerScheduleContract(scheduleID, label, actionID string) ProducerScheduleContract {
	return ProducerScheduleContract{
		ScheduleID:            scheduleID,
		Label:                 label,
		ActionID:              actionID,
		CommandType:           ProducerScheduleCommandPluginRunAction,
		ScheduleType:          ProducerScheduleTypeInterval,
		DefaultCadenceSeconds: 86_400,
		MinCadenceSeconds:     300,
		MaxCadenceSeconds:     2_592_000,
		DispatchScope:         ProducerScheduleDispatchAssignment,
		TimeoutSeconds:        300,
	}
}

func (c ProducerScheduleContract) WithDescription(description string) ProducerScheduleContract {
	c.Description = description
	return c
}

func (c ProducerScheduleContract) WithCadence(defaultSeconds, minSeconds, maxSeconds int) ProducerScheduleContract {
	c.DefaultCadenceSeconds = defaultSeconds
	c.MinCadenceSeconds = minSeconds
	c.MaxCadenceSeconds = maxSeconds
	return c
}

func (c ProducerScheduleContract) WithCron(cronExpression string) ProducerScheduleContract {
	c.AllowCron = true
	c.ScheduleType = ProducerScheduleTypeCron
	c.CronExpression = cronExpression

	return c
}

func (c ProducerScheduleContract) WithJitterSeconds(jitterSeconds int) ProducerScheduleContract {
	c.JitterSeconds = jitterSeconds
	return c
}

func (c ProducerScheduleContract) WithSettingsSchema(schema map[string]any) ProducerScheduleContract {
	c.SettingsSchema = schema
	return c
}

func (c ProducerScheduleContract) WithCredentialRequirements(requirements map[string]any) ProducerScheduleContract {
	c.CredentialRequirements = requirements
	return c
}

func (c ProducerScheduleContract) WithPayloadTemplate(template map[string]any) ProducerScheduleContract {
	c.PayloadTemplate = template
	return c
}

func (c ProducerScheduleContract) WithRedaction(redaction map[string]any) ProducerScheduleContract {
	c.Redaction = redaction
	return c
}

func (c ProducerScheduleContract) WithDispatchScope(scope string) ProducerScheduleContract {
	c.DispatchScope = scope
	return c
}

func (c ProducerScheduleContract) WithTimeoutSeconds(timeoutSeconds int) ProducerScheduleContract {
	c.TimeoutSeconds = timeoutSeconds
	return c
}

func (c ProducerScheduleContract) WithCommandType(commandType string) ProducerScheduleContract {
	c.CommandType = commandType
	return c
}
