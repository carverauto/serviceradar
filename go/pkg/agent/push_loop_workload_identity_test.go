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
	if sig.path != path || sig.semanticHash == [32]byte{} {
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
	sig := workloadIdentityFileSignature{
		path:         "/tmp/latest.json",
		semanticHash: workloadIdentitySemanticHash([]byte(`{"identities":[]}`)),
	}

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

	next := workloadIdentityFileSignature{
		path:         "/tmp/latest.json",
		semanticHash: workloadIdentitySemanticHash([]byte(`{"identities":[{"container_id":"abc"}]}`)),
	}
	if !pl.shouldForwardWorkloadIdentity(next) {
		t.Fatal("changed signature should forward")
	}
}

func TestWorkloadIdentitySemanticHashIgnoresCollectionTimestamp(t *testing.T) {
	first := workloadIdentitySemanticHash([]byte(`{
		"observed_at_unix_nano": 100,
		"enabled": true,
		"identities": [
			{"container_id": "b", "identity": {"pod_name": "pod-b"}},
			{"container_id": "a", "identity": {"pod_name": "pod-a"}}
		]
	}`))
	second := workloadIdentitySemanticHash([]byte(`{
		"observed_at_unix_nano": 200,
		"enabled": true,
		"identities": [
			{"container_id": "a", "identity": {"pod_name": "pod-a"}},
			{"container_id": "b", "identity": {"pod_name": "pod-b"}}
		]
	}`))

	if first != second {
		t.Fatal("semantic hash should ignore observed_at and identity order")
	}
}

func TestWorkloadIdentitySemanticHashChangesWhenIdentityChanges(t *testing.T) {
	first := workloadIdentitySemanticHash([]byte(`{
		"enabled": true,
		"identities": [{"container_id": "a", "identity": {"pod_name": "pod-a"}}]
	}`))
	second := workloadIdentitySemanticHash([]byte(`{
		"enabled": true,
		"identities": [{"container_id": "a", "identity": {"pod_name": "pod-renamed"}}]
	}`))

	if first == second {
		t.Fatal("semantic hash should change when identity content changes")
	}
}
