// Command tinygo_reflection_probe is the toolchain half of plugin_runtime_test.
//
// Every first-party plugin relies on reflection asking whether a type satisfies
// an interface with methods: encoding/json asks it of each type it encodes
// (json.Marshaler, encoding.TextMarshaler) and errors.As asks it of its target.
// TinyGo up to 0.40.x panicked on that question once a binary linked both, so
// this probe links both, from the standard library alone, and is run the way the
// agent runs a plugin: an exported entrypoint, without WASI _start.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"unsafe"
)

//go:wasmimport env submit_result
func submitResult(ptr uint32, size uint32) int32

type hostError struct{ code int32 }

func (e hostError) Error() string { return fmt.Sprintf("host error %d", e.code) }

// level implements json.Marshaler with a value receiver, so encoding it proves
// the encoder found the method rather than falling back to the int kind.
type level int

func (l level) MarshalJSON() ([]byte, error) { return []byte(fmt.Sprintf(`"level-%d"`, int(l))), nil }

type probeDetails struct {
	Level   level          `json:"level"`
	Extras  map[string]any `json:"extras"`
	Matched bool           `json:"errors_as_matched"`
	Code    int32          `json:"errors_as_code"`
}

func main() {}

//export run_check
func runCheck() {
	var target hostError
	matched := errors.As(fmt.Errorf("wrapped: %w", hostError{code: -6}), &target)

	payload, err := json.Marshal(map[string]any{
		"status":  "OK",
		"summary": "tinygo reflection probe",
		"details": probeDetails{
			Level:   2,
			Extras:  map[string]any{"ratio": 0.5, "name": "probe", "number": json.Number("7")},
			Matched: matched,
			Code:    target.code,
		},
	})
	if err != nil {
		payload = []byte(`{"status":"CRITICAL","summary":"marshal failed"}`)
	}
	submitResult(uint32(uintptr(unsafe.Pointer(&payload[0]))), uint32(len(payload)))
}
