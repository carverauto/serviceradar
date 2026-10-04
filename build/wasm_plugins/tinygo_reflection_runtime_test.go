package main

import (
	"testing"
)

// Guards the toolchain for every first-party plugin, not one plugin's code
// path: a probe that links errors.As and reflective encoding/json, built with
// the pinned TinyGo and run without WASI _start, must answer correctly.
func TestTinyGoInterfaceReflectionUnderAgentLifecycle(t *testing.T) {
	host := &wasmHost{config: []byte(`{}`)}
	host.run(t, loadBuiltWasm(t, "tinygo_reflection_probe.wasm"), "run_check")

	result := host.results[0]
	details, _ := result["details"].(map[string]any)
	if result["status"] != "OK" || details == nil {
		t.Fatalf("probe result = %v", result)
	}
	if details["level"] != "level-2" {
		t.Fatalf("json.Marshaler was not honored: level = %v", details["level"])
	}
	if details["errors_as_matched"] != true || details["errors_as_code"] != float64(-6) {
		t.Fatalf("errors.As did not unwrap the target: %v", details)
	}
}
