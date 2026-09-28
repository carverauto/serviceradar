package main

import (
	"context"

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
	deviceID, deviceUID := loadRuntimeDeviceIdentity()
	retrieved, err := NewCollector(SDKHTTPDoer{}).RetrieveRunningConfig(
		context.Background(),
		cfg,
		deviceID,
		deviceUID,
	)
	if err != nil {
		return submitPluginError(err)
	}
	// The artifact is the only carrier of the body: status details are
	// viewer-readable and running-configs routinely hold device secrets.
	artifact, err := stageRunningConfigArtifact(retrieved)
	if err != nil || artifact == nil || artifact.ObjectKey == "" {
		return submitPluginError(runError("opentext_nom_config_artifact_failed"))
	}
	result := buildConfigRetrieveResult(retrieved, artifact)
	return sdk.Execute(func() (*sdk.Result, error) { return result, nil })
}

func stageRunningConfigArtifact(cfg RunningConfig) (*sdk.ArtifactCommitResponse, error) {
	stream, err := sdk.OpenArtifactStream(sdk.ArtifactOpenRequest{
		ObjectKey:   "opentext-nom/running-config/" + cfg.DeviceID,
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
