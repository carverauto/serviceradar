package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func runPlugin() error {
	cfg, err := loadRuntimeConfig()
	if err != nil {
		return submitPluginError(err)
	}

	if loadRuntimeActionID() == interfaceCheckActionID {
		run, err := parseConfigCheckRun(loadRawConfigMap())
		if err != nil {
			return submitPluginError(err)
		}
		return runConfigCheck(cfg, run)
	}

	if loadRuntimeActionID() == configRetrieveActionID {
		return runConfigRetrieve(cfg)
	}

	snapshot, err := NewCollector(SDKHTTPDoer{}).Collect(context.Background(), cfg)
	if err != nil {
		return submitPluginError(err)
	}

	result, err := buildPluginResult(snapshot, cfg.MaxResultBytes)
	if err != nil {
		return submitPluginError(err)
	}
	return sdk.Execute(func() (*sdk.Result, error) { return result, nil })
}

func runConfigRetrieve(cfg Config) error {
	devices, err := runtimeRetrieveDevices(loadRawConfigMap())
	if err != nil {
		return submitPluginError(err)
	}
	collector := NewCollector(SDKHTTPDoer{})
	configs := make([]RunningConfig, 0, len(devices))
	for _, device := range devices {
		config, err := collector.RetrieveRunningConfig(context.Background(), cfg, device.DeviceID, device.DeviceUID)
		if err != nil {
			// Retrieve the whole bounded batch before opening any artifact stream.
			return submitPluginError(err)
		}
		configs = append(configs, config)
	}

	results := make([]*sdk.Result, 0, len(configs))
	var stageError error
	for i := range configs {
		artifact, err := stageRunningConfigArtifact(configs[i])
		configs[i].Body = ""
		if err != nil || artifact == nil || artifact.ObjectKey == "" {
			stageError = runError("opentext_nom_config_artifact_failed")
			break
		}
		results = append(results, buildConfigRetrieveResult(configs[i], artifact))
	}
	result := buildConfigRetrieveBatchResult(results, stageError)
	return sdk.Execute(func() (*sdk.Result, error) { return result, nil })
}

func stageRunningConfigArtifact(cfg RunningConfig) (*sdk.ArtifactCommitResponse, error) {
	var attempt [16]byte
	if _, err := rand.Read(attempt[:]); err != nil {
		return nil, runError("opentext_nom_config_artifact_failed")
	}
	stream, err := sdk.OpenArtifactStream(sdk.ArtifactOpenRequest{
		ObjectKey:   "opentext-nom/running-config/" + cfg.DeviceID + "/" + hex.EncodeToString(attempt[:]),
		ContentType: "text/plain",
		SHA256:      cfg.Hash,
		SizeBytes:   int64(len(cfg.Body)),
		Attributes: map[string]string{
			"kind":       "running_config",
			"device_uid": cfg.DeviceUID,
		},
	})
	if err != nil {
		return nil, err
	}
	if _, err := stream.Write([]byte(cfg.Body)); err != nil {
		_ = stream.Abort()
		return nil, err
	}
	committed, err := stream.Commit(sdk.ArtifactCommitRequest{
		SHA256:    cfg.Hash,
		SizeBytes: int64(len(cfg.Body)),
	})
	if err != nil {
		_ = stream.Abort()
		return nil, err
	}
	return committed, nil
}

func submitPluginError(err error) error {
	code := safeErrorCode(err)
	return sdk.Execute(func() (*sdk.Result, error) {
		return sdk.Critical(code), nil
	})
}
