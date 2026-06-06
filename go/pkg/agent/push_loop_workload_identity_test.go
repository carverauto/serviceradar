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
	"os"
	"path/filepath"
	"testing"
)

func TestReadWorkloadIdentitySnapshot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "latest.json")
	payload := []byte(`{"enabled":true,"identities":[]}`)
	if err := os.WriteFile(path, payload, 0o600); err != nil {
		t.Fatalf("write snapshot: %v", err)
	}

	got, sig, err := readWorkloadIdentitySnapshot(path, 1024)
	if err != nil {
		t.Fatalf("read snapshot: %v", err)
	}
	if string(got) != string(payload) {
		t.Fatalf("payload = %q, want %q", got, payload)
	}
	if sig.path != path || sig.size != int64(len(payload)) || sig.modTime == 0 {
		t.Fatalf("unexpected signature: %#v", sig)
	}
}

func TestReadWorkloadIdentitySnapshotRejectsOversizedPayload(t *testing.T) {
	path := filepath.Join(t.TempDir(), "latest.json")
	if err := os.WriteFile(path, []byte(`{"too":"large"}`), 0o600); err != nil {
		t.Fatalf("write snapshot: %v", err)
	}

	if _, _, err := readWorkloadIdentitySnapshot(path, 4); err == nil {
		t.Fatal("expected oversized snapshot error")
	}
}

func TestWorkloadIdentityForwardingSignatureAdvancesOnlyOnCommit(t *testing.T) {
	pl := &PushLoop{}
	sig := workloadIdentityFileSignature{path: "/tmp/latest.json", size: 10, modTime: 123}

	if !pl.shouldForwardWorkloadIdentity(sig) {
		t.Fatal("first signature should forward")
	}
	if !pl.shouldForwardWorkloadIdentity(sig) {
		t.Fatal("signature should still forward before ack commit")
	}

	pl.commitWorkloadIdentitySignature(sig)
	if pl.shouldForwardWorkloadIdentity(sig) {
		t.Fatal("committed signature should not forward again")
	}

	next := workloadIdentityFileSignature{path: "/tmp/latest.json", size: 11, modTime: 124}
	if !pl.shouldForwardWorkloadIdentity(next) {
		t.Fatal("changed signature should forward")
	}
}
