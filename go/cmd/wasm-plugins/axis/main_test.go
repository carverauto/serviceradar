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
