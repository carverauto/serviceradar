package main

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

type signingEvidence struct {
	Identity        string `json:"identity"`
	TeamID          string `json:"team_id"`
	HardenedRuntime bool   `json:"hardened_runtime"`
	Timestamp       bool   `json:"timestamp"`
	Verified        bool   `json:"verified"`
}

type notarizationEvidence struct {
	Status       string `json:"status"`
	SubmissionID string `json:"submission_id"`
	Stapled      bool   `json:"stapled"`
	Validated    bool   `json:"validated"`
}

type provenance struct {
	SchemaVersion      int                  `json:"schema_version"`
	Product            string               `json:"product"`
	Version            string               `json:"version"`
	SourceCommit       string               `json:"source_commit"`
	OS                 string               `json:"os"`
	Arch               string               `json:"arch"`
	Mode               string               `json:"mode"`
	PackageFilename    string               `json:"package_filename"`
	PackageSHA256      string               `json:"package_sha256"`
	BinarySHA256       string               `json:"binary_sha256"`
	CLIBinarySHA256    string               `json:"cli_binary_sha256"`
	ApplicationSigning signingEvidence      `json:"application_signing"`
	CLISigning         signingEvidence      `json:"cli_signing"`
	InstallerSigning   signingEvidence      `json:"installer_signing"`
	Notarization       notarizationEvidence `json:"notarization"`
	GatekeeperVerified bool                 `json:"gatekeeper_verified"`
}

func (b builder) signAgent(ctx context.Context, opts options, agent string) (signingEvidence, error) {
	if _, err := b.runner.run(ctx, "/usr/bin/codesign", "--force", "--timestamp", "--options", "runtime", "--keychain", opts.Keychain, "--sign", opts.AppIdentity, agent); err != nil {
		return signingEvidence{}, err
	}
	return b.verifyAgentSignature(ctx, agent, opts.AppIdentity)
}

func (b builder) verifyAgentSignature(ctx context.Context, agent, identity string) (signingEvidence, error) {
	if _, err := b.runner.run(ctx, "/usr/bin/codesign", "--verify", "--strict", "--verbose=2", agent); err != nil {
		return signingEvidence{}, err
	}
	data, err := b.runner.run(ctx, "/usr/bin/codesign", "--display", "--verbose=4", agent)
	if err != nil {
		return signingEvidence{}, err
	}
	team, err := identityTeam(identity, "Application")
	if err != nil {
		return signingEvidence{}, err
	}
	text := string(data)
	flags := regexp.MustCompile(`(?m)^CodeDirectory .*flags=0x([0-9a-fA-F]+)\(`).FindStringSubmatch(text)
	var bits uint64
	if len(flags) == 2 {
		bits, err = strconv.ParseUint(flags[1], 16, 64)
	}
	if err != nil || bits&0x10000 == 0 || bits&0x2 != 0 {
		return signingEvidence{}, fmt.Errorf("%w: agent signature lacks a non-ad-hoc hardened runtime", errInvalidPackage)
	}
	if !hasLine(text, "Authority="+identity) || !hasLine(text, "TeamIdentifier="+team) {
		return signingEvidence{}, fmt.Errorf("%w: agent signature does not match the required Developer ID Application identity", errInvalidPackage)
	}
	if !regexp.MustCompile(`(?m)^Timestamp=[^\r\n]+$`).MatchString(text) || hasLine(text, "Timestamp=none") {
		return signingEvidence{}, fmt.Errorf("%w: agent signature lacks a trusted timestamp", errInvalidPackage)
	}
	return signingEvidence{Identity: identity, TeamID: team, HardenedRuntime: true, Timestamp: true, Verified: true}, nil
}

func hasLine(text, value string) bool {
	for _, line := range strings.Split(text, "\n") {
		if strings.TrimSpace(line) == value {
			return true
		}
	}
	return false
}

func (b builder) signPackage(ctx context.Context, opts options, pkg, work string, proof *provenance) (string, error) {
	signed := filepath.Join(work, "signed.pkg")
	if _, err := b.runner.run(ctx, "/usr/bin/productsign", "--sign", opts.InstallerIdentity, "--keychain", opts.Keychain, "--timestamp", pkg, signed); err != nil {
		return "", err
	}
	var err error
	proof.InstallerSigning, err = b.verifyInstallerSignature(ctx, signed, opts.InstallerIdentity)
	if err != nil {
		return "", err
	}
	data, err := b.runner.run(ctx, "/usr/bin/xcrun", "notarytool", "submit", signed, "--keychain-profile", opts.NotaryProfile, "--keychain", opts.Keychain, "--wait", "--timeout", "30m", "--output-format", "json")
	if err != nil {
		return "", err
	}
	var submitted struct {
		ID     string `json:"id"`
		Status string `json:"status"`
	}
	if err := json.Unmarshal(data, &submitted); err != nil {
		return "", fmt.Errorf("%w: notarytool returned invalid JSON", errInvalidPackage)
	}
	if submitted.Status != "Accepted" || !regexp.MustCompile(`^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$`).MatchString(submitted.ID) {
		return "", fmt.Errorf("%w: notarization was not Accepted with a valid submission ID", errInvalidPackage)
	}
	proof.Notarization = notarizationEvidence{Status: submitted.Status, SubmissionID: submitted.ID}
	if _, err := b.runner.run(ctx, "/usr/bin/xcrun", "stapler", "staple", signed); err != nil {
		return "", err
	}
	proof.Notarization.Stapled = true
	if _, err := b.runner.run(ctx, "/usr/bin/xcrun", "stapler", "validate", signed); err != nil {
		return "", err
	}
	proof.Notarization.Validated = true
	proof.InstallerSigning, err = b.verifyInstallerSignature(ctx, signed, opts.InstallerIdentity)
	if err != nil {
		return "", err
	}
	data, err = b.runner.run(ctx, "/usr/sbin/spctl", "--assess", "--type", "install", "--verbose=4", signed)
	if err != nil {
		return "", err
	}
	if !regexp.MustCompile(`(?m)^.+: accepted\s*$`).Match(data) {
		return "", fmt.Errorf("%w: Gatekeeper did not accept the notarized installer", errInvalidPackage)
	}
	proof.GatekeeperVerified = true
	return signed, nil
}

func (b builder) verifyInstallerSignature(ctx context.Context, pkg, identity string) (signingEvidence, error) {
	data, err := b.runner.run(ctx, "/usr/sbin/pkgutil", "--check-signature", pkg)
	if err != nil {
		return signingEvidence{}, err
	}
	team, err := identityTeam(identity, "Installer")
	if err != nil {
		return signingEvidence{}, err
	}
	text := string(data)
	if !regexp.MustCompile(`(?m)^\s*Status: signed by (a certificate trusted by (macOS|Mac OS X)|a developer certificate issued by Apple for distribution)\s*$`).MatchString(text) || !hasLine(text, "1. "+identity) {
		return signingEvidence{}, fmt.Errorf("%w: installer signature is not the required trusted Developer ID Installer identity", errInvalidPackage)
	}
	if !regexp.MustCompile(`(?m)^\s*Signed with a trusted timestamp on:\s+\S.+$`).MatchString(text) {
		return signingEvidence{}, fmt.Errorf("%w: installer signature lacks a trusted timestamp", errInvalidPackage)
	}
	return signingEvidence{Identity: identity, TeamID: team, Timestamp: true, Verified: true}, nil
}
