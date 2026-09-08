/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package endpointinventory

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestNewerFullScanSurvivesDelayedFinalizeSpoolAndAck(t *testing.T) {
	root := t.TempDir()
	cfg := DefaultConfig()
	cfg.AgentID = endpointInventoryTestAgentID
	cfg.SpoolDir = filepath.Join(root, "spool")
	cfg.CacheDir = filepath.Join(root, "cache")
	cfg.TmpDir = filepath.Join(root, "tmp")
	cfg.UploadJitter = "0s"
	identity := testCacheIdentity(cfg)
	firstAt := time.Unix(40_000, 0).UTC()
	secondAt := firstAt.Add(time.Minute)
	first := fullUploadPayloadForCacheTest(identity, "scan-first", "package-first", "artifact-first", firstAt)
	second := fullUploadPayloadForCacheTest(identity, "scan-second", "package-second", "artifact-second", secondAt)

	if err := FinalizeFullScan(cfg, identity, first, []Package{{Name: "first"}}, nil, firstAt); err != nil {
		t.Fatal(err)
	}
	if err := WriteSpool(cfg, first); err != nil {
		t.Fatal(err)
	}
	if err := FinalizeFullScan(cfg, identity, second, []Package{{Name: "second"}}, nil, secondAt); err != nil {
		t.Fatal(err)
	}
	if err := WriteSpool(cfg, second); err != nil {
		t.Fatal(err)
	}
	if err := WriteSpool(cfg, first); err != nil {
		t.Fatal(err)
	}
	if err := MarkUploadSucceeded(cfg, first, secondAt.Add(time.Minute)); !errors.Is(err, ErrNoPendingUpload) {
		t.Fatalf("stale acknowledgement error = %v, want ErrNoPendingUpload", err)
	}

	manifest, err := ReadCacheManifest(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.PendingUpload == nil || manifest.PendingUpload.ScanID != second.ScanID ||
		manifest.PackageSetHash != second.PackageSetHash {
		t.Fatalf("new manifest/pending state was lost: %#v", manifest)
	}
	for _, path := range []string{LatestPath(cfg.SpoolDir), PendingUploadPath(cfg.SpoolDir)} {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var got ScanPayload
		if err := json.Unmarshal(data, &got); err != nil {
			t.Fatal(err)
		}
		if got.ScanID != second.ScanID {
			t.Fatalf("%s contains stale scan %q, want %q", path, got.ScanID, second.ScanID)
		}
	}

	stalePartial := &ScanPayload{
		AgentID: identity.AgentID, ScanID: "scan-partial-stale", State: scanStatePartial,
		CoverageState: coveragePartial, LastScanAt: firstAt,
	}
	if err := WriteSpool(cfg, stalePartial); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(LatestPath(cfg.SpoolDir))
	if err != nil {
		t.Fatal(err)
	}
	var latest ScanPayload
	if err := json.Unmarshal(data, &latest); err != nil {
		t.Fatal(err)
	}
	if latest.ScanID != second.ScanID {
		t.Fatalf("stale partial scan overwrote latest with %q", latest.ScanID)
	}

	newPartial := &ScanPayload{
		AgentID: identity.AgentID, ScanID: "scan-partial-new", State: scanStatePartial,
		CoverageState: coveragePartial, LastScanAt: secondAt.Add(time.Minute),
	}
	if err := WriteSpool(cfg, newPartial); err != nil {
		t.Fatal(err)
	}
	data, err = os.ReadFile(LatestPath(cfg.SpoolDir))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &latest); err != nil {
		t.Fatal(err)
	}
	if latest.ScanID != newPartial.ScanID {
		t.Fatalf("newer partial diagnostic was discarded: %q", latest.ScanID)
	}

	stale := fullUploadPayloadForCacheTest(identity, "scan-stale", "package-stale", "artifact-stale", firstAt)
	if err := FinalizeFullScan(cfg, identity, stale, []Package{{Name: "stale"}}, nil, firstAt); !errors.Is(err, ErrStaleFullScan) {
		t.Fatalf("stale finalize error = %v, want ErrStaleFullScan", err)
	}
}

func fullUploadPayloadForCacheTest(
	identity CacheIdentity,
	scanID string,
	packageHash string,
	artifactHash string,
	scannedAt time.Time,
) *ScanPayload {
	return &ScanPayload{
		SchemaVersion:        SchemaVersion,
		AgentID:              identity.AgentID,
		ConfigHash:           identity.ConfigHash,
		CollectorVersion:     identity.ProducerVersion,
		ScanID:               scanID,
		State:                scanStateScanned,
		CoverageState:        coverageComplete,
		LastScanAt:           scannedAt,
		LastSuccessfulScanAt: &scannedAt,
		PackageCount:         1,
		PackageSetHash:       packageHash,
		ArtifactHash:         artifactHash,
		HashAlgorithm:        HashAlgorithm,
		UploadReason:         UploadReasonChanged,
		SBOM:                 &CycloneDXBOM{},
		Metadata: map[string]any{
			"scanner_producer_id": identity.ProducerID,
		},
	}
}
