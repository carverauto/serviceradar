//go:build tinygo
// +build tinygo

package main

import (
	"strings"
	"unsafe"
)

const (
	logDebug uint32 = 0
	logInfo  uint32 = 1
	logWarn  uint32 = 2
	logError uint32 = 3
)

//go:wasmimport env submit_result
func hostSubmitResult(ptr uint32, size uint32) int32

//go:wasmimport env log
func hostLog(level uint32, ptr uint32, size uint32)

//go:wasmimport env get_config
func hostGetConfig(ptr uint32, size uint32) int32

//export run_check
func run_check() {
	logMsg(logInfo, "hello plugin starting")

	cfgStatus := readConfig()
	summary := "hello from wasm"
	if cfgStatus > 0 {
		summary = "hello from wasm (config received)"
	}

	summaryEscaped := escapeJSONString(summary)
	configLabel := "no"
	if cfgStatus > 0 {
		configLabel = "yes"
	}

	payload := []byte(
		`{"schema_version":1,` +
			`"status":"OK",` +
			`"summary":"` + summaryEscaped + `",` +
			`"display":[` +
			`{"widget":"status_badge","label":"Service","status":"OK","uptime":"just now"},` +
			`{"widget":"stat_card","label":"Greeting","value":"` + summaryEscaped + `","tone":"success"},` +
			`{"widget":"table","data":{"Plugin":"Hello Wasm","Runtime":"WASI","Config loaded":"` + configLabel + `"}},` +
			`{"widget":"sparkline","label":"Sample trend","data":[5,9,3,8,12,7]},` +
			`{"widget":"markdown","content":"Hello from **ServiceRadar** plugin UI."}` +
			`]}`,
	)
	if len(payload) == 0 {
		return
	}
	ptr := uint32(uintptr(unsafe.Pointer(&payload[0])))
	hostSubmitResult(ptr, uint32(len(payload)))
}

func readConfig() int32 {
	buf := make([]byte, 512)
	ptr := uint32(uintptr(unsafe.Pointer(&buf[0])))
	result := hostGetConfig(ptr, uint32(len(buf)))
	if result > 0 {
		logMsg(logDebug, "config read")
	} else if result < 0 {
		logMsg(logWarn, "config read failed")
	}
	return result
}

func logMsg(level uint32, msg string) {
	if msg == "" {
		return
	}
	b := []byte(msg)
	ptr := uint32(uintptr(unsafe.Pointer(&b[0])))
	hostLog(level, ptr, uint32(len(b)))
}

func escapeJSONString(value string) string {
	if value == "" {
		return ""
	}
	var b strings.Builder
	b.Grow(len(value))
	for i := 0; i < len(value); i++ {
		switch value[i] {
		case '\\', '"':
			b.WriteByte('\\')
			b.WriteByte(value[i])
		case '\n':
			b.WriteString("\\n")
		case '\r':
			b.WriteString("\\r")
		case '\t':
			b.WriteString("\\t")
		default:
			b.WriteByte(value[i])
		}
	}
	return b.String()
}

func main() {}
