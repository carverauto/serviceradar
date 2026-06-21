package main

import (
	"fmt"
	"strings"
)

func buildProtectStreams(cfg Config, cameras []ProtectCamera) []StreamInfo {
	streams := make([]StreamInfo, 0, len(cameras))
	for _, camera := range cameras {
		for _, channel := range camera.Channels {
			url := buildProtectStreamURL(cfg, camera, channel)
			if url == "" {
				continue
			}
			streamID := strings.TrimSpace(channel.Name)
			if streamID == "" {
				streamID = firstNonEmpty(channel.ID, camera.ID)
			}
			streams = append(streams, StreamInfo{
				ID:                 streamID,
				Protocol:           "rtsp",
				URL:                url,
				AuthMode:           "controller_alias",
				Source:             "protect-bootstrap",
				InsecureSkipVerify: cfg.InsecureSkipVerify,
			})
		}
	}
	return streams
}

func buildProtectCameraDescriptors(
	cfg Config,
	cameras []ProtectCamera,
	networkClients map[string]UniFiNetworkClient,
) []CameraDescriptor {
	descriptors := make([]CameraDescriptor, 0, len(cameras))
	for _, camera := range cameras {
		deviceUID := firstNonEmpty(camera.MAC, camera.ID)
		cameraID := firstNonEmpty(camera.ID, camera.MAC)
		networkClient := networkClients[normalizeMACKey(camera.MAC)]
		cameraHost := firstNonEmpty(
			protectCameraInventoryHost(cfg, camera),
			uniFiNetworkClientInventoryHost(networkClient),
		)
		availabilityStatus, availabilityReason := protectCameraAvailability(camera)
		if deviceUID == "" || cameraID == "" {
			continue
		}

		descriptor := CameraDescriptor{
			DeviceUID:          deviceUID,
			Vendor:             "ubiquiti",
			CameraID:           cameraID,
			IP:                 cameraHost,
			DisplayName:        firstNonEmpty(camera.DisplayName, camera.Name, camera.MarketName, camera.ModelKey, cameraID),
			AvailabilityStatus: availabilityStatus,
			AvailabilityReason: availabilityReason,
			Identity: map[string]interface{}{
				"mac": strings.TrimSpace(camera.MAC),
			},
			Metadata: map[string]interface{}{
				"controller_host":      cfg.Host,
				"plugin_id":            "unifi-protect-camera",
				"camera_state":         camera.State,
				"firmware_version":     camera.FirmwareVersion,
				"is_connected":         camera.IsConnected,
				"insecure_skip_verify": cfg.InsecureSkipVerify,
			},
		}
		if cameraHost != "" {
			descriptor.Metadata["camera_host"] = cameraHost
		}
		if networkClient.ID != "" {
			descriptor.Metadata["network_client_id"] = strings.TrimSpace(networkClient.ID)
		}
		if networkClient.Name != "" || networkClient.DisplayName != "" {
			descriptor.Metadata["network_client_name"] = firstNonEmpty(
				networkClient.DisplayName,
				networkClient.Name,
			)
		}

		for _, channel := range camera.Channels {
			sourceURL := buildProtectStreamURL(cfg, camera, channel)
			if descriptor.SourceURL == "" {
				descriptor.SourceURL = sourceURL
			}
			profileName := strings.TrimSpace(channel.Name)
			if profileName == "" {
				profileName = firstNonEmpty(channel.ID, "default")
			}
			descriptor.StreamProfiles = append(descriptor.StreamProfiles, CameraStreamProfile{
				ProfileName:       profileName,
				VendorProfileID:   strings.TrimSpace(channel.ID),
				SourceURLOverride: sourceURL,
				RTSPTransport:     "tcp",
				CodecHint:         "h264",
				Metadata: map[string]interface{}{
					"source":               "protect-bootstrap",
					"width":                channel.Width,
					"height":               channel.Height,
					"fps":                  channel.FPS,
					"bitrate":              channel.Bitrate,
					"rtsp_alias":           channel.RTSPAlias,
					"rtsps_alias":          channel.RTSPSAlias,
					"insecure_skip_verify": cfg.InsecureSkipVerify,
				},
			})
		}

		descriptors = append(descriptors, descriptor)
	}
	return descriptors
}

func protectCameraAvailability(camera ProtectCamera) (string, string) {
	state := strings.ToUpper(strings.TrimSpace(camera.State))

	switch {
	case state == "CONNECTED" || (state == "" && camera.IsConnected):
		return "available", "UniFi Protect state CONNECTED"
	case state == "DISCONNECTED" || (!camera.IsConnected && state == ""):
		return "unavailable", "UniFi Protect state DISCONNECTED"
	case state == "":
		return "degraded", "UniFi Protect camera state is unknown"
	default:
		return "degraded", fmt.Sprintf("UniFi Protect state %s", state)
	}
}

func protectCameraInventoryHost(cfg Config, camera ProtectCamera) string {
	host := firstNonEmpty(
		strings.TrimSpace(camera.ConnectionHost),
		strings.TrimSpace(camera.Host),
	)
	controllerHost := strings.TrimSpace(cfg.Host)

	if host == "" || strings.EqualFold(host, controllerHost) {
		return ""
	}

	return host
}
