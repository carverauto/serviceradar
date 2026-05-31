/*
 * Copyright 2026 Carver Automation Corporation.
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

package agent

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestNormalizeAddonCapabilities(t *testing.T) {
	// Allowed caps are lower-cased, de-duplicated, and returned sorted.
	got, err := normalizeAddonCapabilities([]string{"CAP_NET_RAW", "cap_bpf", " cap_perfmon ", "cap_bpf"})
	if err != nil {
		t.Fatalf("normalize: %v", err)
	}
	want := []string{"cap_bpf", "cap_net_raw", "cap_perfmon"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("normalize = %v, want %v", got, want)
	}

	// A capability outside the allowlist fails closed.
	if _, err := normalizeAddonCapabilities([]string{"cap_net_raw", "cap_sys_admin"}); !errors.Is(err, ErrAddonCapabilityUnsafe) {
		t.Fatalf("want ErrAddonCapabilityUnsafe for cap_sys_admin, got %v", err)
	}

	// No (effective) capabilities is a distinct signal so callers skip setcap.
	if _, err := normalizeAddonCapabilities([]string{"", "  "}); !errors.Is(err, ErrAddonCapabilityNone) {
		t.Fatalf("want ErrAddonCapabilityNone, got %v", err)
	}
}

func TestSetcapCapabilityString(t *testing.T) {
	got := setcapCapabilityString([]string{"cap_bpf", "cap_net_raw", "cap_perfmon"})
	want := "cap_bpf,cap_net_raw,cap_perfmon=+ep"
	if got != want {
		t.Fatalf("setcapCapabilityString = %q, want %q", got, want)
	}
}

func TestResolveStagedAddonBinaryForCapabilities(t *testing.T) {
	tmp := t.TempDir()
	addonsRoot := filepath.Join(tmp, addonsDirName)
	stageTestAddon(t, addonsRoot, "1.0.0", []byte("np-binary"))

	req := AddonCapabilityRequest{RuntimeRoot: tmp, AddonID: "np", BinaryName: "serviceradar-np-addon"}
	got, err := resolveStagedAddonBinaryForCapabilities(req)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if filepath.Base(got) != "serviceradar-np-addon" {
		t.Fatalf("resolved base = %q, want serviceradar-np-addon", filepath.Base(got))
	}
	if data, err := os.ReadFile(got); err != nil || string(data) != "np-binary" {
		t.Fatalf("resolved path is not the staged binary: data=%q err=%v", data, err)
	}
}

func TestResolveStagedAddonBinaryRejectsUnsafeSegments(t *testing.T) {
	cases := []AddonCapabilityRequest{
		{RuntimeRoot: t.TempDir(), AddonID: "../etc", BinaryName: "serviceradar-np-addon"},
		{RuntimeRoot: t.TempDir(), AddonID: "np", BinaryName: "../evil"},
		{RuntimeRoot: t.TempDir(), AddonID: "", BinaryName: "bin"},
	}
	for _, req := range cases {
		if _, err := resolveStagedAddonBinaryForCapabilities(req); !errors.Is(err, ErrAddonUnsafePath) {
			t.Fatalf("want ErrAddonUnsafePath for %+v, got %v", req, err)
		}
	}
}

func TestResolveStagedAddonBinaryEscapeGuard(t *testing.T) {
	tmp := t.TempDir()
	addonDir := filepath.Join(tmp, addonsDirName, "np")
	if err := os.MkdirAll(addonDir, 0o755); err != nil {
		t.Fatalf("mkdir addon dir: %v", err)
	}

	// A binary living OUTSIDE the add-on directory, reached via a tampered `current`
	// symlink, must be rejected rather than setcap'd.
	outside := filepath.Join(tmp, "outside")
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatalf("mkdir outside: %v", err)
	}
	if err := os.WriteFile(filepath.Join(outside, "serviceradar-np-addon"), []byte("x"), 0o755); err != nil {
		t.Fatalf("write outside binary: %v", err)
	}
	if err := os.Symlink(outside, filepath.Join(addonDir, addonCurrentLink)); err != nil {
		t.Fatalf("symlink current->outside: %v", err)
	}

	req := AddonCapabilityRequest{RuntimeRoot: tmp, AddonID: "np", BinaryName: "serviceradar-np-addon"}
	if _, err := resolveStagedAddonBinaryForCapabilities(req); !errors.Is(err, ErrAddonCapabilityBinaryEscape) {
		t.Fatalf("want ErrAddonCapabilityBinaryEscape, got %v", err)
	}
}
