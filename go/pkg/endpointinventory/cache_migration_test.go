/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package endpointinventory

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCacheWithoutImmutableFullScanAnchorCannotSlideCadence(t *testing.T) {
	cfg := DefaultConfig()
	cfg.AgentID = endpointInventoryTestAgentID
	cfg.Cadence = endpointInventoryTestDaily
	cfg.Sources = []string{PackageSourceDpkg}
	identity := testCacheIdentity(cfg)
	now := time.Unix(20_000, 0).UTC()
	current := map[string]SourceMTime{
		PackageSourceDpkg: {Source: PackageSourceDpkg, Exists: true, MTimeUnixNano: 10},
	}
	manifest := &InventoryCacheManifest{
		AgentID:         identity.AgentID,
		ConfigHash:      identity.ConfigHash,
		ProducerID:      identity.ProducerID,
		ProducerVersion: identity.ProducerVersion,
		PackageSetHash:  "package-hash",
		ArtifactHash:    "artifact-hash",
		SourceMTimes:    copySourceMTimes(current),
		LastScanAt:      now.Add(-time.Minute),
	}

	for _, wake := range []time.Time{now, now.Add(time.Hour), now.Add(23 * time.Hour)} {
		manifest.LastScanAt = wake.Add(-time.Minute)
		if CacheCanSkipFullScan(cfg, identity, manifest, current, wake) {
			t.Fatalf("cache without last_full_scan_at skipped at %s", wake)
		}
	}
}

func TestLegacyPendingPayloadMigratesAnImmutableCadenceAnchor(t *testing.T) {
	root := t.TempDir()
	cfg := DefaultConfig()
	cfg.AgentID = endpointInventoryTestAgentID
	cfg.Cadence = endpointInventoryTestDaily
	cfg.Sources = []string{PackageSourceDpkg}
	cfg.SpoolDir = filepath.Join(root, "spool")
	cfg.CacheDir = filepath.Join(root, "cache")
	cfg.TmpDir = filepath.Join(root, "tmp")
	identity := testCacheIdentity(cfg)
	anchor := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)
	current := map[string]SourceMTime{
		PackageSourceDpkg: {Source: PackageSourceDpkg, Exists: true, MTimeUnixNano: 10},
	}
	payload := fullUploadPayloadForCacheTest(identity, "scan-legacy", "package-hash", "artifact-hash", anchor)
	if err := WriteSpool(cfg, payload); err != nil {
		t.Fatal(err)
	}

	legacyManifest := `{
  "schema_version": "serviceradar.endpoint_inventory.cache.v1",
  "agent_id": "agent-1",
  "package_set_hash": "package-hash",
  "artifact_hash": "artifact-hash",
  "packages": [],
  "source_summaries": [],
  "source_mtimes": {"dpkg": {"source": "dpkg", "exists": true, "mtime_unix_nano": 10}},
  "last_scan_at": "2026-07-11T11:00:00Z",
  "pending_upload": {
    "scan_id": "scan-legacy",
    "package_set_hash": "package-hash",
    "artifact_hash": "artifact-hash",
    "upload_reason": "changed",
    "available_after": "2026-07-10T12:00:00Z",
    "attempts": 0,
    "created_at": "2026-07-10T12:00:00Z",
    "updated_at": "2026-07-10T12:00:00Z"
  },
  "updated_at": "2026-07-11T11:00:00Z"
}`
	if err := os.WriteFile(CacheManifestPath(cfg.CacheDir), []byte(legacyManifest), 0640); err != nil {
		t.Fatal(err)
	}

	firstWake := anchor.Add(time.Hour)
	manifest, err := ReadCacheManifest(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !CacheCanSkipFullScan(cfg, identity, manifest, current, firstWake) {
		t.Fatal("legacy pending payload should prove identity and cadence anchor")
	}
	if err := RecordCachedScan(cfg, identity, current, firstWake); err != nil {
		t.Fatal(err)
	}
	secondWake := anchor.Add(23 * time.Hour)
	if err := RecordCachedScan(cfg, identity, current, secondWake); err != nil {
		t.Fatal(err)
	}

	migrated, err := ReadCacheManifest(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if migrated.LastFullScanAt == nil || !migrated.LastFullScanAt.Equal(anchor) {
		t.Fatalf("last_full_scan_at = %v, want immutable pending anchor %v", migrated.LastFullScanAt, anchor)
	}
	if !migrated.LastScanAt.Equal(secondWake) {
		t.Fatalf("last_scan_at = %v, want latest wake %v", migrated.LastScanAt, secondWake)
	}
	if migrated.ConfigHash != identity.ConfigHash || migrated.ProducerVersion != identity.ProducerVersion ||
		migrated.PendingUpload == nil || migrated.PendingUpload.ConfigHash != identity.ConfigHash {
		t.Fatalf("legacy identity was not fully migrated: %#v", migrated)
	}
	if CacheCanSkipFullScan(cfg, identity, migrated, current, anchor.Add(25*time.Hour)) {
		t.Fatal("sliding last_scan_at must not extend the immutable cadence anchor")
	}
}

func TestCacheIdentityMismatchForcesFullScan(t *testing.T) {
	cfg := DefaultConfig()
	cfg.AgentID = endpointInventoryTestAgentID
	cfg.Cadence = endpointInventoryTestDaily
	cfg.Sources = []string{PackageSourceDpkg}
	identity := testCacheIdentity(cfg)
	now := time.Unix(30_000, 0).UTC()
	current := map[string]SourceMTime{PackageSourceDpkg: {Source: PackageSourceDpkg}}
	manifest := &InventoryCacheManifest{
		AgentID:         identity.AgentID,
		ConfigHash:      identity.ConfigHash,
		ProducerID:      identity.ProducerID,
		ProducerVersion: identity.ProducerVersion,
		PackageSetHash:  "package-hash",
		ArtifactHash:    "artifact-hash",
		SourceMTimes:    copySourceMTimes(current),
		LastFullScanAt:  &now,
	}
	if !CacheCanSkipFullScan(cfg, identity, manifest, current, now.Add(time.Hour)) {
		t.Fatal("exact cache identity should permit cadence reuse")
	}

	tests := map[string]func(*CacheIdentity){
		"agent":            func(got *CacheIdentity) { got.AgentID = "other-agent" },
		"config":           func(got *CacheIdentity) { got.ConfigHash = "other-config" },
		"producer":         func(got *CacheIdentity) { got.ProducerID = "other-producer" },
		"producer version": func(got *CacheIdentity) { got.ProducerVersion = "other-version" },
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			mismatch := identity
			mutate(&mismatch)
			if CacheCanSkipFullScan(cfg, mismatch, manifest, current, now.Add(time.Hour)) {
				t.Fatal("mismatched identity reused cache")
			}
		})
	}
}

func TestCachedScanCommitDetectsConcurrentReconcileRequest(t *testing.T) {
	root := t.TempDir()
	cfg := DefaultConfig()
	cfg.AgentID = endpointInventoryTestAgentID
	cfg.Cadence = endpointInventoryTestDaily
	cfg.Sources = []string{PackageSourceDpkg}
	cfg.SpoolDir = filepath.Join(root, "spool")
	cfg.CacheDir = filepath.Join(root, "cache")
	cfg.TmpDir = filepath.Join(root, "tmp")
	identity := testCacheIdentity(cfg)
	anchor := time.Unix(35_000, 0).UTC()
	current := map[string]SourceMTime{PackageSourceDpkg: {Source: PackageSourceDpkg}}
	manifest := &InventoryCacheManifest{
		SchemaVersion: CacheVersion, AgentID: identity.AgentID, ConfigHash: identity.ConfigHash,
		ProducerID: identity.ProducerID, ProducerVersion: identity.ProducerVersion,
		PackageSetHash: "package-hash", ArtifactHash: "artifact-hash",
		SourceMTimes: copySourceMTimes(current), LastFullScanAt: &anchor,
		Packages: []Package{}, SourceSummaries: []SourceSummary{},
	}
	if err := WriteCacheManifest(cfg, manifest); err != nil {
		t.Fatal(err)
	}
	wake := anchor.Add(time.Hour)
	if !CacheCanSkipFullScan(cfg, identity, manifest, current, wake) {
		t.Fatal("precheck should initially permit a cached scan")
	}
	if err := MarkServerReconcileRequested(cfg, wake, "concurrent reconcile"); err != nil {
		t.Fatal(err)
	}
	if err := RecordCachedScan(cfg, identity, current, wake); !errors.Is(err, ErrCacheRefreshRequired) {
		t.Fatalf("cached commit error = %v, want ErrCacheRefreshRequired", err)
	}

	latest, err := ReadCacheManifest(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if latest.ServerReconcileRequestedAt == nil || latest.ServerReconcileReason != "concurrent reconcile" {
		t.Fatalf("cached commit erased reconcile request: %#v", latest)
	}
}
