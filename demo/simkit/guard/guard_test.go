package guard

import "testing"

func TestCheckJSON(t *testing.T) {
	doc := `{
	  "devices": [
	    {"ip": "10.20.1.2", "hostname": "ap-0001.site.test", "mac": "00:1a:1e:00:00:01"},
	    {"ip": "192.0.2.10", "hostname": "ctl01"},
	    {"ip": "8.8.8.8", "hostname": "dns.google"},
	    {"ip": "2001:db8::5", "fqdn": "ap.example.com"},
	    {"ip": "2606:4700::1111"}
	  ],
	  "camera": {"rtsp_url": "rtsp://replayer.demo.svc.cluster.local:8554/drone-1"},
	  "leak": {"source_url": "https://api.example-vendor.io/v1"},
	  "title": "Channel saturation on concourse B",
	  "targets": ["8.8.8.8:53", "1.1.1.1:443", "[2606:4700::1111]:443", "192.0.2.7:8080", "[2001:db8::5]:443"],
	  "peer": "dns.google",
	  "endpoint": "dns.google:443",
	  "note": "github.com",
	  "metrics": [{"name": "demo.fault.active", "value": 1}]
	}`
	vs, err := CheckJSON([]byte(doc))
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{
		"$.devices[2].ip":       true,
		"$.devices[2].hostname": true,
		"$.devices[4].ip":       true,
		"$.leak.source_url":     true,
		"$.targets[0]":          true,
		"$.targets[1]":          true,
		"$.targets[2]":          true,
		"$.peer":                true,
		"$.endpoint":            true,
		"$.note":                true,
	}
	if len(vs) != len(want) {
		t.Fatalf("got %d violations, want %d: %v", len(vs), len(want), vs)
	}
	for _, v := range vs {
		if !want[v.Path] {
			t.Fatalf("unexpected violation %s", v)
		}
	}
}

func TestSafeHost(t *testing.T) {
	for _, h := range []string{"ap-01", "ap.site.test", "x.internal", "x.example.net", "example.com", "10.1.2.3"} {
		if !SafeHost(h) {
			t.Errorf("%s should be safe", h)
		}
	}
	for _, h := range []string{"github.com", "ap.corp.example-airport.aero", "1.1.1.1"} {
		if SafeHost(h) {
			t.Errorf("%s should be rejected", h)
		}
	}
}
