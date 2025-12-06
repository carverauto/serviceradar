package registry

import (
	"strings"

	"github.com/carverauto/serviceradar/pkg/models"
)

func getStrongIdentity(update *models.DeviceUpdate) (string, string) {
	if update == nil {
		return "", ""
	}
	if update.Metadata != nil {
		if id := strings.TrimSpace(update.Metadata["armis_device_id"]); id != "" {
			return "armis_device_id", id
		}
		if id := strings.TrimSpace(update.Metadata["integration_id"]); id != "" {
			return "integration_id", id
		}
		if id := strings.TrimSpace(update.Metadata["netbox_device_id"]); id != "" {
			return "netbox_device_id", id
		}
	}
	if update.MAC != nil {
		if mac := strings.TrimSpace(*update.MAC); mac != "" {
			return "mac", mac
		}
	}
	return "", ""
}

func getStrongIdentityFromDevice(device *models.UnifiedDevice) (string, string) {
	if device == nil {
		return "", ""
	}
	if device.Metadata != nil {
		if id := strings.TrimSpace(device.Metadata.Value["armis_device_id"]); id != "" {
			return "armis_device_id", id
		}
		if id := strings.TrimSpace(device.Metadata.Value["integration_id"]); id != "" {
			return "integration_id", id
		}
		if id := strings.TrimSpace(device.Metadata.Value["netbox_device_id"]); id != "" {
			return "netbox_device_id", id
		}
	}
	if device.MAC != nil {
		if mac := strings.TrimSpace(device.MAC.Value); mac != "" {
			return "mac", mac
		}
	}
	return "", ""
}
