package main

import (
	"sort"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

const (
	pluginVersion = "0.1.0"

	// alertLogName distinguishes Starlink alert events from other plugin
	// events for alert-rule subject matching.
	alertLogName = "starlink.alert"

	alertSignalSchemaID                     = "com.carverauto.starlink.alert"
	alertSignalSchemaVersion                = "1.0.0"
	alertSignalSchemaDisplayContractID      = "com.carverauto.starlink.alert.display"
	alertSignalSchemaDisplayContractVersion = "1.0.0"
	alertSignalSchemaDisplayContractPath    = "display/alert_event.display.json"
)

func alertSignalSchemaRef(producerID string) sdk.SignalSchemaRef {
	return sdk.SignalSchemaRef{
		ProducerID:             producerID,
		ProducerVersion:        pluginVersion,
		SchemaID:               alertSignalSchemaID,
		SchemaVersion:          alertSignalSchemaVersion,
		DisplayContractID:      alertSignalSchemaDisplayContractID,
		DisplayContractVersion: alertSignalSchemaDisplayContractVersion,
		DisplayContract:        alertSignalSchemaDisplayContractPath,
		SignalType:             sdk.SignalSchemaSignalTypeEvent,
		PayloadKind:            sdk.SignalSchemaPayloadKindOCSFEvent,
	}
}

// alertScope names the condition scope covering every alert of one account.
func alertScope(instance string) string {
	return sourceName + ":" + instance + ":alerts"
}

func alertConditionKey(deviceRef, alert string) string {
	return deviceRef + ":" + alert
}

// buildAlertRecords turns an alert snapshot into condition events, one per
// active alert, plus the scope-complete marker when the snapshot is complete.
// Only active alerts are emitted: the agent synthesizes clears for alerts that
// disappear from a complete scope, so healthy devices produce no events.
func buildAlertRecords(snap alertSnapshot, instance, producerID string) []sdk.TelemetryRecord {
	return buildScopedAlertRecords(snap, alertScope(instance), instance, producerID)
}

func buildScopedAlertRecords(snap alertSnapshot, scope, instance, producerID string) []sdk.TelemetryRecord {
	ref := alertSignalSchemaRef(producerID)

	var records []sdk.TelemetryRecord
	active := []string{}
	for _, device := range snap.Devices {
		for _, alert := range device.Active {
			key := alertConditionKey(device.DeviceRef, alert)
			active = append(active, key)

			severity := severityFor(alert)
			event := sdk.NewOCSFEventLogActivity("Starlink "+device.Kind+" alert: "+alert, severity)
			event.LogProvider = producerID
			event.LogName = alertLogName
			// device.uid is the same reference the discovery record uses as its
			// integration identifier; core resolves it to the canonical device.
			event.Device = map[string]any{"uid": device.DeviceRef, "type": device.Kind}
			unmapped := map[string]any{
				"condition_key":   key,
				"condition_scope": scope,
				"level":           conditionLevel(severity),
				"alert":           alert,
				"starlink_kind":   device.Kind,
				"source_instance": instance,
			}
			if desc := alertDescription[alert]; desc != "" {
				unmapped["alert_description"] = desc
			}
			event.Unmapped = unmapped
			records = append(records, sdk.NewOCSFTelemetryRecord(event).WithSignalSchemaRef(ref))
		}
	}

	if snap.Complete {
		sort.Strings(active)
		marker := sdk.NewOCSFEventLogActivity("Starlink alert condition scope snapshot", sdk.SeverityInfo)
		marker.LogProvider = producerID
		marker.LogName = "starlink.condition_scope"
		marker.Unmapped = map[string]any{
			"condition_scope_complete": scope,
			"active_condition_keys":    active,
			"source_instance":          instance,
		}
		records = append(records, sdk.NewOCSFTelemetryRecord(marker).WithSignalSchemaRef(ref))
	}
	return records
}
