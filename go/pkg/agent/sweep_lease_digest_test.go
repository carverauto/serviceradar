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
	"strings"
	"testing"
)

// Synthetic installed-payload digest fixture: 64 lowercase hex chars, never
// captured from a live system.

//nolint:gochecknoglobals // immutable synthetic fixture, not state
var testInstalledDigest = strings.Repeat("ab12", 16)

// The hello digest must round-trip through a restart: core skips re-issuing
// only a window whose digest matches, so a digest lost on restart would leave
// the agent without leases core believes it holds.
func TestSweepLeaseInstalledDigestRoundTrip(t *testing.T) {
	dir := t.TempDir()

	store, err := newSweepLeaseStore(dir)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}

	group := testLeaseGroup.String()

	if _, err := store.Install(testLeasePush(100, 400, testLeaseSlot(100)), group); err != nil {
		t.Fatalf("install: %v", err)
	}

	if err := store.RecordInstalledDigest(group, testInstalledDigest); err != nil {
		t.Fatalf("record digest: %v", err)
	}

	if got := store.InstalledLeaseDigests(); got[group] != testInstalledDigest {
		t.Fatalf("before restart: %v, want %s recorded", got, testInstalledDigest)
	}

	reopened, err := newSweepLeaseStore(dir)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}

	if got := reopened.InstalledLeaseDigests(); got[group] != testInstalledDigest {
		t.Fatalf("after restart: %v, want %s recorded", got, testInstalledDigest)
	}
}

// A group with an installed lease but no recorded digest must be omitted:
// the missing digest is what tells core to re-issue the window.
func TestSweepLeaseInstalledDigestOmittedWithoutRecord(t *testing.T) {
	store, err := newSweepLeaseStore(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}

	group := testLeaseGroup.String()

	if _, err := store.Install(testLeasePush(100, 400, testLeaseSlot(100)), group); err != nil {
		t.Fatalf("install: %v", err)
	}

	if got := store.InstalledLeaseDigests(); len(got) != 0 {
		t.Fatalf("digests = %v, want empty without a record", got)
	}
}

// A digest file without a loaded lease, and a malformed digest file, must
// both be dropped at open: reporting either would make core skip a window the
// agent does not verifiably hold. Neither may fail the store open.
func TestSweepLeaseInstalledDigestOrphansDropped(t *testing.T) {
	dir := t.TempDir()

	stray := strings.Repeat("cd34", 16)

	if err := os.WriteFile(filepath.Join(dir, "stray-group"+sweepLeaseDigestSuffix), []byte(stray+"\n"), 0o600); err != nil {
		t.Fatalf("write stray digest: %v", err)
	}

	if err := os.WriteFile(filepath.Join(dir, "broken-group"+sweepLeaseDigestSuffix), []byte("not-a-digest\n"), 0o600); err != nil {
		t.Fatalf("write malformed digest: %v", err)
	}

	store, err := newSweepLeaseStore(dir)
	if err != nil {
		t.Fatalf("open store with orphan digests: %v", err)
	}

	if got := store.InstalledLeaseDigests(); len(got) != 0 {
		t.Fatalf("digests = %v, want orphans dropped", got)
	}
}

// Revoking a group must clear its digest: the group holds no window, so the
// hello must stop reporting one.
func TestSweepLeaseInstalledDigestClearedOnRevoke(t *testing.T) {
	dir := t.TempDir()

	store, err := newSweepLeaseStore(dir)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}

	group := testLeaseGroup.String()

	held, err := store.Install(testLeasePush(100, 400, testLeaseSlot(100)), group)
	if err != nil {
		t.Fatalf("install: %v", err)
	}

	if err := store.RecordInstalledDigest(group, testInstalledDigest); err != nil {
		t.Fatalf("record digest: %v", err)
	}

	revoked := testLeasePush(600, 601)
	revoked.LeaseId = held.GetLeaseId()
	revoked.Revoked = true

	if _, err := store.Install(revoked, group); err != nil {
		t.Fatalf("revoke: %v", err)
	}

	if got := store.InstalledLeaseDigests(); len(got) != 0 {
		t.Fatalf("digests after revoke = %v, want empty", got)
	}

	if _, err := os.Stat(filepath.Join(dir, group+sweepLeaseDigestSuffix)); !os.IsNotExist(err) {
		t.Fatalf("digest file survives revoke: %v", err)
	}
}

func TestSweepLeaseRecordInstalledDigestRejectsMalformed(t *testing.T) {
	store, err := newSweepLeaseStore(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}

	if err := store.RecordInstalledDigest(testLeaseGroup.String(), "too-short"); err == nil {
		t.Fatal("recorded a malformed digest without an error")
	}
}
