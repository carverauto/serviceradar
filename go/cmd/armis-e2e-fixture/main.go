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

// Command armis-e2e-fixture drives the real Armis sync source against a local
// faker and writes the emitted, runtime-normalized pages as JSONL. It is a
// test-only binary and is intentionally not registered as a production
// ServiceRadar service.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources"
	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources/armis"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

const (
	defaultPageSize = 997
	defaultSourceID = "00000000-0000-4000-8000-000000004707"
	defaultRunID    = "armis-e2e-run"
)

// Static validation and HTTP errors for err113 compliance.
var (
	errEndpointRequired           = errors.New("-endpoint is required")
	errOutputRequired             = errors.New("-output is required")
	errPageSizeOutOfRange         = errors.New("-page-size must be between 1 and 1000")
	errChurnSwapsNegative         = errors.New("-churn-swaps must not be negative")
	errRepeatAfterChurnRequires   = errors.New("-repeat-after-churn requires -churn-swaps")
	errTriggerFakerChurnHTTP      = errors.New("trigger faker churn failed")
	errFakerChurnNoDevicesChanged = errors.New("faker churn did not change any devices")
)

type fixturePage struct {
	Run     int                      `json:"run"`
	Page    int                      `json:"page"`
	Count   int                      `json:"count"`
	Updates []map[string]interface{} `json:"updates"`
}

type runSummary struct {
	Run     int `json:"run"`
	Pages   int `json:"pages"`
	Updates int `json:"updates"`
}

type fixtureSummary struct {
	Runs    []runSummary `json:"runs"`
	Pages   int          `json:"pages"`
	Updates int          `json:"updates"`
}

type fixtureOptions struct {
	Endpoint         string
	Output           string
	SourceID         string
	RunID            string
	PageSize         int
	ChurnSwaps       int
	RepeatAfterChurn bool
	HTTPClient       *http.Client
}

func main() {
	options := fixtureOptions{}
	flag.StringVar(&options.Endpoint, "endpoint", "", "faker base URL")
	flag.StringVar(&options.Output, "output", "", "JSONL output path")
	flag.StringVar(&options.SourceID, "source-id", defaultSourceID, "integration source UUID")
	flag.StringVar(&options.RunID, "run-id", defaultRunID, "sync run ID prefix")
	flag.IntVar(&options.PageSize, "page-size", defaultPageSize, "Armis search page size")
	flag.IntVar(&options.ChurnSwaps, "churn-swaps", 0, "number of deterministic faker IP swaps between runs")
	flag.BoolVar(&options.RepeatAfterChurn, "repeat-after-churn", false, "run the driver again after deterministic faker churn")
	flag.Parse()

	if err := validateOptions(options); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	ctx := context.Background()
	summary, err := produceFixture(ctx, options)
	if err != nil {
		fmt.Fprintf(os.Stderr, "armis fixture production failed: %v\n", err)
		os.Exit(1)
	}

	if err := json.NewEncoder(os.Stdout).Encode(summary); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write fixture summary: %v\n", err)
		os.Exit(1)
	}
}

func validateOptions(options fixtureOptions) error {
	if strings.TrimSpace(options.Endpoint) == "" {
		return errEndpointRequired
	}
	if strings.TrimSpace(options.Output) == "" {
		return errOutputRequired
	}
	if options.PageSize <= 0 || options.PageSize > 1000 {
		return errPageSizeOutOfRange
	}
	if options.ChurnSwaps < 0 {
		return errChurnSwapsNegative
	}
	if options.RepeatAfterChurn && options.ChurnSwaps == 0 {
		return errRepeatAfterChurnRequires
	}
	return nil
}

func produceFixture(ctx context.Context, options fixtureOptions) (fixtureSummary, error) {
	output, err := os.Create(options.Output)
	if err != nil {
		return fixtureSummary{}, fmt.Errorf("create output: %w", err)
	}
	defer func() { _ = output.Close() }()

	client := options.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 2 * time.Minute}
	}

	summary := fixtureSummary{Runs: make([]runSummary, 0, 2)}
	for runIndex := 0; ; runIndex++ {
		run, err := produceRun(ctx, output, options, runIndex)
		if err != nil {
			return summary, err
		}
		summary.Runs = append(summary.Runs, run)
		summary.Pages += run.Pages
		summary.Updates += run.Updates

		if !options.RepeatAfterChurn || runIndex > 0 {
			break
		}
		if err := triggerChurn(ctx, client, options.Endpoint, options.ChurnSwaps); err != nil {
			return summary, err
		}
	}

	return summary, nil
}

func produceRun(
	ctx context.Context,
	output io.Writer,
	options fixtureOptions,
	runIndex int,
) (runSummary, error) {
	page := 0
	updates := 0
	runID := fmt.Sprintf("%s-%d", options.RunID, runIndex)
	pages := make([]fixturePage, 0)

	run := syncsources.RunContext{
		RunID:     runID,
		SourceKey: "armis-e2e",
		AgentID:   "armis-e2e-agent",
		GatewayID: "armis-e2e-gateway",
		Partition: "default",
		Source: models.SourceConfig{
			Type:          armis.SourceType,
			Endpoint:      strings.TrimRight(options.Endpoint, "/"),
			Credentials:   map[string]string{"secret_key": "armis-e2e-secret", "page_size": fmt.Sprint(options.PageSize)},
			Queries:       []models.QueryConfig{{Label: "all-devices", Query: "in:devices", SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP}}},
			Partition:     "default",
			SyncServiceID: options.SourceID,
		},
		Logger: logger.NewTestLogger(),
		Emit: func(batch []map[string]any) error {
			for _, update := range batch {
				syncsources.NormalizeUpdate(update)
			}

			pages = append(pages, fixturePage{Run: runIndex, Page: page, Count: len(batch), Updates: batch})
			page++
			updates += len(batch)
			return nil
		},
	}

	if _, err := armis.NewDriver().Sync(ctx, run); err != nil {
		return runSummary{Run: runIndex, Pages: page, Updates: updates}, err
	}

	for pageIndex := range pages {
		for _, update := range pages[pageIndex].Updates {
			update["sync_meta"] = map[string]interface{}{
				"sync_service_id": options.SourceID,
				"sync_run_id":     runID,
				"chunk_index":     pageIndex,
				"total_chunks":    len(pages),
				"total_devices":   updates,
				"is_final":        pageIndex == len(pages)-1,
			}
		}
		if err := json.NewEncoder(output).Encode(pages[pageIndex]); err != nil {
			return runSummary{Run: runIndex, Pages: page, Updates: updates}, err
		}
	}

	return runSummary{Run: runIndex, Pages: page, Updates: updates}, nil
}

func triggerChurn(ctx context.Context, client *http.Client, endpoint string, swaps int) error {
	payload, err := json.Marshal(map[string]int{"swaps": swaps})
	if err != nil {
		return fmt.Errorf("encode churn request: %w", err)
	}

	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		strings.TrimRight(endpoint, "/")+"/debug/armis/simulation/churn",
		strings.NewReader(string(payload)),
	)
	if err != nil {
		return fmt.Errorf("build churn request: %w", err)
	}
	request.Header.Set("Content-Type", "application/json")

	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("trigger faker churn: %w", err)
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return fmt.Errorf("%w: status %s: %s", errTriggerFakerChurnHTTP, response.Status, strings.TrimSpace(string(body)))
	}

	var result struct {
		Success bool `json:"success"`
		Data    struct {
			ChangedDevices int `json:"changed_devices"`
		} `json:"data"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		return fmt.Errorf("decode faker churn response: %w", err)
	}
	if !result.Success || result.Data.ChangedDevices == 0 {
		return fmt.Errorf("%w: %+v", errFakerChurnNoDevicesChanged, result)
	}
	return nil
}
