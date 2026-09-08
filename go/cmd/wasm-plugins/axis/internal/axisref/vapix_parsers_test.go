package axisref

import "testing"

func TestParseKeyValueBody(t *testing.T) {
	kv, err := ParseKeyValueBody("foo=bar\nanswer=42\n")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if kv["foo"] != "bar" {
		t.Fatalf("expected foo=bar, got %q", kv["foo"])
	}
	if kv["answer"] != "42" {
		t.Fatalf("expected answer=42, got %q", kv["answer"])
	}
}

func TestParseStreamProfiles(t *testing.T) {
	input := map[string]string{
		"root.StreamProfile.S0.Name":       "Quality",
		"root.StreamProfile.S0.Parameters": "videocodec=h264&resolution=1920x1080",
		"root.StreamProfile.S1.Name":       "Mobile",
		"root.StreamProfile.S1.Parameters": "videocodec=h264&resolution=640x360",
	}

	profiles := ParseStreamProfiles(input)
	if len(profiles) != 2 {
		t.Fatalf("expected 2 profiles, got %d", len(profiles))
	}
	if profiles[0].ID != "S0" || profiles[0].Name != "Quality" {
		t.Fatalf("unexpected first profile: %+v", profiles[0])
	}
	if profiles[0].Parameters["videocodec"] != "h264" {
		t.Fatalf("expected videocodec=h264, got %q", profiles[0].Parameters["videocodec"])
	}
}
