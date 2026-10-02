package main

import (
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

const (
	vendorName    = "SpaceX"
	terminalModel = "Starlink user terminal"
	routerModel   = "Starlink router"
)

// buildDiscovery maps an account snapshot to one DeviceDiscovery envelope.
// The vendor device ID is emitted as both device_id and integration_id: core
// matches on integration_id, and signals reference the same value so they
// land on the device this record creates.
func buildDiscovery(snap *inventorySnapshot, observedAt time.Time) *sdk.DeviceDiscovery {
	instance := sourceInstance(snap.Account.Number)

	discovery := sdk.NewDeviceDiscovery(sourceName)
	discovery.ObservedAt = observedAt.UTC().Format(time.RFC3339Nano)
	discovery.ReferenceHash = snap.contentHash()
	discovery.CollectionID = instance + "-" + discovery.ReferenceHash[:12]
	discovery.Metadata = map[string]any{
		"source_instance":   instance,
		"snapshot_complete": snap.Complete,
		"page_count":        snap.Pages,
		"invalid_rows":      snap.InvalidRows,
		"duplicate_rows":    snap.DuplicateRows,
	}

	seenRouters := map[string]bool{}
	for _, t := range snap.Terminals {
		deviceID := terminalIDPrefix + t.ID
		sl, hasLine := snap.ServiceLines[t.ServiceLine]

		metadata := map[string]any{
			"integration_id":      deviceID,
			"starlink_kind":       "user_terminal",
			"starlink_account":    snap.Account.Number,
			"starlink_terminal":   t.ID,
			"kit_serial":          t.KitSerial,
			"dish_serial":         t.DishSerial,
			"nickname":            t.Nickname,
			"service_line_number": t.ServiceLine,
			"l2vpn_circuit_count": len(t.L2VPNCircuitIDs),
			"source_instance":     instance,
		}
		if hasLine {
			metadata["service_line_nickname"] = sl.Nickname
			metadata["service_line_active"] = sl.Active
			metadata["product_reference_id"] = sl.Product
			metadata["public_ip_enabled"] = sl.PublicIP
			metadata["data_pool_id"] = sl.DataPoolID
			if sl.AviationIATA != "" {
				metadata["aviation_iata"] = sl.AviationIATA
			}
			if sl.AviationICAO != "" {
				metadata["aviation_icao"] = sl.AviationICAO
			}
			if sl.TailNumber != "" {
				metadata["tail_number"] = sl.TailNumber
			}
			if sl.SeatCount > 0 {
				metadata["seat_count"] = sl.SeatCount
			}
		}
		routerIDs := make([]string, 0, len(t.Routers))
		for _, r := range t.Routers {
			routerIDs = append(routerIDs, routerIDPrefix+stripRouterPrefix(r.ID))
		}
		if len(routerIDs) > 0 {
			metadata["router_device_ids"] = routerIDs
		}

		status := terminalStatus(t, sl, hasLine)
		discovery.AddDevice(sdk.DiscoveredDevice{
			DeviceID:    deviceID,
			Hostname:    t.Nickname,
			Serial:      t.KitSerial,
			VendorName:  vendorName,
			Model:       terminalModel,
			Type:        "satellite_terminal",
			Status:      status,
			IsAvailable: terminalAvailability(status),
			Labels:      discoveryLabels(instance),
			Metadata:    compactMetadata(metadata),
		})

		for _, r := range t.Routers {
			routerID := routerIDPrefix + stripRouterPrefix(r.ID)
			if seenRouters[routerID] {
				continue
			}
			seenRouters[routerID] = true
			discovery.AddDevice(sdk.DiscoveredDevice{
				DeviceID:   routerID,
				Hostname:   r.Nickname,
				VendorName: vendorName,
				Model:      routerModel,
				Type:       "router",
				Labels:     discoveryLabels(instance),
				Metadata: compactMetadata(map[string]any{
					"integration_id":              routerID,
					"starlink_kind":               "router",
					"starlink_account":            snap.Account.Number,
					"starlink_router":             r.ID,
					"nickname":                    r.Nickname,
					"hardware_version":            r.HardwareVersion,
					"router_config_id":            r.ConfigID,
					"last_bonded":                 r.LastBonded,
					"attached_terminal_device_id": terminalIDPrefix + r.TerminalID,
					"source_instance":             instance,
				}),
			})
		}
	}
	return discovery
}

func boolPtr(v bool) *bool {
	return &v
}

// terminalAvailability returns nil for unknown states, true only when the
// service line reports active.
func terminalAvailability(status string) *bool {
	return boolPtr(status == "active")
}

// terminalStatus is display state from the service line, not reachability:
// reachability comes from telemetry.
func terminalStatus(t terminal, sl serviceLine, hasLine bool) string {
	switch {
	case t.ServiceLine == "":
		return "no_service_line"
	case !hasLine:
		return "service_line_unknown"
	case sl.Active:
		return "active"
	default:
		return "inactive"
	}
}

func discoveryLabels(instance string) map[string]string {
	return map[string]string{
		"discovery_source": sourceName,
		"inventory_source": sourceName,
		"source_instance":  instance,
	}
}

func stripRouterPrefix(id string) string {
	if rest, ok := cutPrefixFold(id, "router-"); ok {
		return rest
	}
	return id
}

// compactMetadata drops empty values so a blank field never overwrites a
// value another run or source already recorded.
func compactMetadata(in map[string]any) map[string]any {
	out := make(map[string]any, len(in))
	for key, value := range in {
		switch v := value.(type) {
		case string:
			if v == "" {
				continue
			}
		case nil:
			continue
		}
		out[key] = value
	}
	return out
}
