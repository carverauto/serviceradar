package main

import "testing"

func TestBuildRTSPURL(t *testing.T) {
	url := buildRTSPURL("10.0.0.5", map[string]string{"resolution": "1280x720", "videocodec": "h264"})
	wantA := "rtsp://10.0.0.5/axis-media/media.amp?resolution=1280x720&videocodec=h264"
	wantB := "rtsp://10.0.0.5/axis-media/media.amp?videocodec=h264&resolution=1280x720"
	if url != wantA && url != wantB {
		t.Fatalf("unexpected URL: %s", url)
	}
}

func TestMapAxisWSEvent(t *testing.T) {
	payload := []byte(`{"params":{"notification":{"topic":"tns1:Device/IO/VirtualInput"}}}`)
	evt := mapAxisWSEvent(payload)
	if evt == nil {
		t.Fatalf("expected event, got nil")
	}
	if evt.Message == "" {
		t.Fatalf("expected non-empty event message")
	}
	if evt.Unmapped == nil {
		t.Fatalf("expected unmapped payload")
	}
}

func TestBuildCameraDescriptors(t *testing.T) {
	descriptors := buildCameraDescriptors(ResultDetails{
		CameraHost: "10.0.0.5",
		DeviceInfo: map[string]string{
			"SerialNumber":    "axis-serial-5",
			"ProductFullName": "AXIS Q1808-LE",
		},
		Streams: []StreamInfo{
			{
				ID:       "main",
				Protocol: "rtsp",
				URL:      "rtsp://10.0.0.5/axis-media/media.amp?videocodec=h264",
				AuthMode: "basic_or_digest",
				Source:   "streamprofile.cgi",
			},
		},
	})

	if len(descriptors) != 1 {
		t.Fatalf("expected 1 descriptor, got %d", len(descriptors))
	}

	descriptor := descriptors[0]
	if descriptor.DeviceUID != "axis-serial-5" {
		t.Fatalf("unexpected device uid: %s", descriptor.DeviceUID)
	}
	if descriptor.Vendor != "axis" {
		t.Fatalf("unexpected vendor: %s", descriptor.Vendor)
	}
	if descriptor.CameraID != "axis-serial-5" {
		t.Fatalf("unexpected camera id: %s", descriptor.CameraID)
	}
	if descriptor.SourceURL != "rtsp://10.0.0.5/axis-media/media.amp?videocodec=h264" {
		t.Fatalf("unexpected source url: %s", descriptor.SourceURL)
	}
	if len(descriptor.StreamProfiles) != 1 {
		t.Fatalf("expected 1 stream profile, got %d", len(descriptor.StreamProfiles))
	}
	if descriptor.StreamProfiles[0].CodecHint != "h264" {
		t.Fatalf("unexpected codec hint: %s", descriptor.StreamProfiles[0].CodecHint)
	}
	if descriptor.Metadata["plugin_id"] != "axis-camera" {
		t.Fatalf("unexpected plugin_id metadata: %#v", descriptor.Metadata["plugin_id"])
	}
}

func TestWithWebSocketCredentials(t *testing.T) {
	rawURL := "wss://camera.local/vapix/ws-data-stream?sources=events"
	got := withWebSocketCredentials(rawURL, "root", "secret")
	want := "wss://root:secret@camera.local/vapix/ws-data-stream?sources=events"

	if got != want {
		t.Fatalf("unexpected websocket url: %s", got)
	}
}
