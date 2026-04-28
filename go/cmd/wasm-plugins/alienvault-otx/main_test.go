package main

import "testing"

func TestBuildCTIPageNormalizesSupportedIndicators(t *testing.T) {
	resp := subscribedPulsesResponse{
		Count: 1,
		Next:  "https://otx.alienvault.com/api/v1/pulses/subscribed?page=2",
		Results: []otxPulse{
			{
				ID:         "pulse-1",
				Name:       "Test Pulse",
				AuthorName: "otx-user",
				Created:    "2026-04-27T10:00:00.000000",
				Modified:   "2026-04-27T11:00:00.000000",
				Indicators: []otxIndicator{
					{Indicator: "192.0.2.10", Type: "IPv4"},
					{Indicator: "2001:db8::1", Type: "IPv6"},
					{Indicator: "198.51.100.0/24", Type: "CIDR"},
					{Indicator: "example.invalid", Type: "domain"},
				},
			},
		},
	}

	page := buildCTIPage(resp, Config{MaxIndicators: 10})

	if page.Provider != sourceAlienVaultOTX {
		t.Fatalf("provider = %q, want %q", page.Provider, sourceAlienVaultOTX)
	}
	if page.Counts.Indicators != 3 {
		t.Fatalf("indicators = %d, want 3", page.Counts.Indicators)
	}
	if page.Counts.Skipped != 1 {
		t.Fatalf("skipped = %d, want 1", page.Counts.Skipped)
	}
	if page.Counts.SkippedByType["domain"] != 1 {
		t.Fatalf("skipped_by_type[domain] = %d, want 1", page.Counts.SkippedByType["domain"])
	}
	if page.Indicators[0].SourceObject != "pulse-1" {
		t.Fatalf("source object = %q, want pulse-1", page.Indicators[0].SourceObject)
	}
}

func TestSubscribedPulsesURL(t *testing.T) {
	got, err := subscribedPulsesURL(Config{
		BaseURL:       "https://otx.alienvault.com/",
		Limit:         25,
		Page:          3,
		ModifiedSince: "2026-04-27T10:00:00Z",
	})
	if err != nil {
		t.Fatalf("subscribedPulsesURL returned error: %v", err)
	}

	want := "https://otx.alienvault.com/api/v1/pulses/subscribed?limit=25&modified_since=2026-04-27T10%3A00%3A00Z&page=3"
	if got != want {
		t.Fatalf("url = %q, want %q", got, want)
	}
}
