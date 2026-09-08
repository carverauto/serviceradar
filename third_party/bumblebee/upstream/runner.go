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

// Package upstream wraps the vendored Bumblebee v0.1.1 scanner code.
package upstream

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/third_party/bumblebee/upstream/internal/endpoint"
	"github.com/carverauto/serviceradar/third_party/bumblebee/upstream/internal/exposure"
	"github.com/carverauto/serviceradar/third_party/bumblebee/upstream/internal/model"
	"github.com/carverauto/serviceradar/third_party/bumblebee/upstream/internal/output"
	"github.com/carverauto/serviceradar/third_party/bumblebee/upstream/internal/scanner"
)

const Version = "v0.1.1"

type ScanOptions struct {
	Root        string
	CatalogPath string
	RunID       string
	Ecosystems  []string
	MaxDuration time.Duration
	MaxFileSize int64
	MaxOutput   int64
}

type ScanResult struct {
	Records        []byte
	ScannerVersion string
	Findings       int
}

func ScanRoot(ctx context.Context, opts ScanOptions) (ScanResult, error) {
	runID := opts.RunID
	if strings.TrimSpace(runID) == "" {
		runID = newRunID()
	}

	catalog, err := exposure.Load(opts.CatalogPath, opts.MaxOutput)
	if err != nil {
		return ScanResult{}, err
	}

	var records bytes.Buffer
	var diagnostics bytes.Buffer
	emitter := output.New(&records, &diagnostics, runID)
	scanStart := time.Now().UTC()
	base := model.Record{
		RecordType:     model.RecordTypePackage,
		SchemaVersion:  model.SchemaVersion,
		ScannerName:    model.ScannerName,
		ScannerVersion: Version,
		RunID:          runID,
		ScanTime:       scanStart.Format(time.RFC3339Nano),
		Endpoint:       endpoint.Current(""),
		Profile:        model.ProfileDeep,
	}

	res, runErr := scanner.Run(ctx, scanner.Config{
		Profile:      model.ProfileDeep,
		Roots:        []scanner.Root{{Path: opts.Root, Kind: model.RootKindDeepHome}},
		Ecosystems:   ecosystemFilter(opts.Ecosystems),
		MaxFileSize:  maxFileSize(opts.MaxFileSize),
		MaxDuration:  opts.MaxDuration,
		Concurrency:  4,
		Catalog:      catalog,
		FindingsOnly: true,
		BaseRecord:   base,
		Emitter:      emitter,
	})
	if runErr != nil {
		emitter.Diag("error", opts.Root, runErr.Error())
	}

	status := model.ScanStatusComplete
	errMsg := ""
	if runErr != nil {
		status = model.ScanStatusError
		errMsg = runErr.Error()
	}

	if err := emitter.EmitSummary(model.ScanSummary{
		SchemaVersion:            model.SchemaVersion,
		ScannerName:              model.ScannerName,
		ScannerVersion:           Version,
		RunID:                    runID,
		ScanTime:                 scanStart.Format(time.RFC3339Nano),
		EndTime:                  time.Now().UTC().Format(time.RFC3339Nano),
		Endpoint:                 base.Endpoint,
		Profile:                  model.ProfileDeep,
		Status:                   status,
		Roots:                    []model.SummaryRoot{{Path: opts.Root, Kind: model.RootKindDeepHome}},
		Counts:                   map[string]int{model.RecordTypeFinding: res.FindingsEmitted},
		PackageRecordsEmitted:    res.RecordsEmitted,
		PackageRecordsSuppressed: res.PackageRecordsSuppressed,
		FindingsEmitted:          res.FindingsEmitted,
		Duplicates:               res.Duplicates,
		DiagnosticsCount:         res.Diagnostics,
		FilesConsidered:          res.FilesConsidered,
		TimedOut:                 res.TimedOut,
		DurationMS:               res.Duration.Milliseconds(),
		Error:                    errMsg,
	}); err != nil {
		return ScanResult{}, err
	}

	if runErr != nil {
		return ScanResult{}, fmt.Errorf("%w; diagnostics=%s", runErr, strings.TrimSpace(diagnostics.String()))
	}

	return ScanResult{
		Records:        records.Bytes(),
		ScannerVersion: Version,
		Findings:       res.FindingsEmitted,
	}, nil
}

func ecosystemFilter(values []string) map[string]bool {
	filter := make(map[string]bool)
	for _, value := range values {
		for _, part := range strings.Split(value, ",") {
			part = strings.TrimSpace(part)
			if part != "" {
				filter[part] = true
			}
		}
	}

	return filter
}

func maxFileSize(value int64) int64 {
	if value > 0 {
		return value
	}

	return 5 * 1024 * 1024
}

func newRunID() string {
	var randomBytes [16]byte
	_, _ = rand.Read(randomBytes[:])

	return hex.EncodeToString(randomBytes[:])
}
