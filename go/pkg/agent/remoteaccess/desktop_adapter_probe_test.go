/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package remoteaccess

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveRDPAdapterPath(t *testing.T) {
	t.Parallel()

	if got := NormalizeRDPAdapterPath(" "); got != DefaultRDPAdapterBinary {
		t.Fatalf("default adapter path = %q, want %q", got, DefaultRDPAdapterBinary)
	}

	dir := t.TempDir()
	adapterPath := filepath.Join(dir, DefaultRDPAdapterBinary)
	if err := os.WriteFile(adapterPath, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("WriteFile returned error: %v", err)
	}

	resolved, err := ResolveRDPAdapterPath(adapterPath)
	if err != nil {
		t.Fatalf("ResolveRDPAdapterPath returned error: %v", err)
	}
	if resolved != adapterPath {
		t.Fatalf("resolved adapter path = %q, want %q", resolved, adapterPath)
	}
	if !RDPAdapterBinaryAvailable(adapterPath) {
		t.Fatal("RDPAdapterBinaryAvailable returned false for executable helper")
	}

	if _, err := ResolveRDPAdapterPath(filepath.Join(dir, "missing")); !errors.Is(err, ErrDesktopAdapterUnavailable) {
		t.Fatalf("missing adapter error = %v, want %v", err, ErrDesktopAdapterUnavailable)
	}
}

func TestProbeRDPAdapterCapabilitiesRequiresReadyConnector(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	readyPath := writeRDPAdapterProbeScript(t, dir, "ready", true, true)
	resolved, capabilities, err := ProbeRDPAdapterCapabilities(context.Background(), readyPath)
	if err != nil {
		t.Fatalf("ProbeRDPAdapterCapabilities returned error: %v", err)
	}
	if resolved != readyPath || !capabilities.ConnectorReady || !capabilities.IronRDPBackendLinked {
		t.Fatalf("probe result resolved=%q capabilities=%#v", resolved, capabilities)
	}
	if capabilities.ConnectorReadyReason != "" {
		t.Fatalf("ready helper connector reason = %q, want empty", capabilities.ConnectorReadyReason)
	}
	if !RDPAdapterReady(readyPath) {
		t.Fatal("RDPAdapterReady returned false for ready helper")
	}

	unlinkedPath := writeRDPAdapterProbeScript(t, dir, "unlinked", false, true)
	if _, _, err := ProbeRDPAdapterCapabilities(context.Background(), unlinkedPath); !errors.Is(err, ErrDesktopAdapterUnavailable) {
		t.Fatalf("unlinked helper error = %v, want %v", err, ErrDesktopAdapterUnavailable)
	}
	if RDPAdapterReady(unlinkedPath) {
		t.Fatal("RDPAdapterReady returned true for helper without IronRDP backend")
	}

	notReadyPath := writeRDPAdapterProbeScript(t, dir, "not-ready", true, false)
	if _, _, err := ProbeRDPAdapterCapabilities(context.Background(), notReadyPath); !errors.Is(err, ErrDesktopAdapterUnavailable) ||
		!strings.Contains(err.Error(), "live_auth_media_demo_not_validated") {
		t.Fatalf("not-ready helper error = %v, want %v", err, ErrDesktopAdapterUnavailable)
	}
	if RDPAdapterReady(notReadyPath) {
		t.Fatal("RDPAdapterReady returned true for not-ready helper")
	}
}

func TestProbeRDPAdapterCapabilitiesRejectsOversizedOutput(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "oversized")
	script := "#!/bin/sh\n" +
		"i=0\n" +
		"while [ \"$i\" -lt " + fmt.Sprint(rdpAdapterMaxCapabilitiesJSON+1) + " ]; do\n" +
		"  printf x\n" +
		"  i=$((i + 1))\n" +
		"done\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("WriteFile returned error: %v", err)
	}

	if _, _, err := ProbeRDPAdapterCapabilities(context.Background(), path); !errors.Is(err, ErrDesktopAdapterUnavailable) ||
		!strings.Contains(err.Error(), "capability output too large") {
		t.Fatalf("oversized capabilities error = %v, want %v", err, ErrDesktopAdapterUnavailable)
	}
}

func TestProbeRDPAdapterCapabilitiesNormalizesConnectorReadyReason(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	notReadyPath := writeRDPAdapterProbeScriptWithReason(
		t,
		dir,
		"not-ready-reason",
		true,
		false,
		" connector\nnot\tready "+strings.Repeat("x", rdpAdapterMaxReadyReasonBytes),
	)
	if _, _, err := ProbeRDPAdapterCapabilities(context.Background(), notReadyPath); !errors.Is(err, ErrDesktopAdapterUnavailable) {
		t.Fatalf("not-ready helper error = %v, want %v", err, ErrDesktopAdapterUnavailable)
	} else if strings.ContainsAny(err.Error(), "\n\t") {
		t.Fatalf("connector reason was not normalized: %q", err.Error())
	} else if strings.Contains(err.Error(), strings.Repeat("x", rdpAdapterMaxReadyReasonBytes)) {
		t.Fatalf("connector reason was not capped: %q", err.Error())
	}

	readyPath := writeRDPAdapterProbeScriptWithReason(
		t,
		dir,
		"ready-with-reason",
		true,
		true,
		"should-not-be-present",
	)
	if _, _, err := ProbeRDPAdapterCapabilities(context.Background(), readyPath); !errors.Is(err, ErrDesktopAdapterUnavailable) ||
		!strings.Contains(err.Error(), "unexpected connector-ready reason") {
		t.Fatalf("ready helper with reason error = %v, want unexpected reason", err)
	}
}

func writeRDPAdapterProbeScript(tb testing.TB, dir, name string, linked, ready bool) string {
	tb.Helper()

	reason := ""
	if !ready {
		reason = "live_auth_media_demo_not_validated"
	}

	return writeRDPAdapterProbeScriptWithReason(tb, dir, name, linked, ready, reason)
}

func writeRDPAdapterProbeScriptWithReason(
	tb testing.TB,
	dir string,
	name string,
	linked bool,
	ready bool,
	reason string,
) string {
	tb.Helper()

	path := filepath.Join(dir, name)
	linkedValue := enhancedMetadataFalse
	if linked {
		linkedValue = enhancedMetadataTrue
	}
	readyValue := enhancedMetadataFalse
	if ready {
		readyValue = enhancedMetadataTrue
	}
	connectorReadyReasonJSON := ""
	if reason != "" {
		reasonJSON, err := json.Marshal(reason)
		if err != nil {
			tb.Fatalf("Marshal reason returned error: %v", err)
		}
		connectorReadyReasonJSON = `,"connector_ready_reason":` + string(reasonJSON)
	}
	script := "#!/bin/sh\n" +
		"if [ \"$1\" = \"--capabilities\" ]; then\n" +
		"  echo '{\"schema\":\"serviceradar.rdp.helper.capabilities.v1\",\"protocol\":\"rdp\",\"helper_protocol_version\":1,\"ironrdp_backend_linked\":" + linkedValue + ",\"connector_ready\":" + readyValue + connectorReadyReasonJSON + "}'\n" +
		"  exit 0\n" +
		"fi\n" +
		"exit 0\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		tb.Fatalf("WriteFile returned error: %v", err)
	}

	return path
}
