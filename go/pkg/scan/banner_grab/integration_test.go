/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package banner_grab

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/models"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

func TestIntegrationBannerGrabFixtureNetworkMatchesNetprobe(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping netprobe sidecar integration test in short mode")
	}

	netprobeBin := locateNetprobeBinary(t)
	if netprobeBin == "" {
		t.Skip("serviceradar-netprobe binary not found; set SERVICERADAR_NETPROBE_BIN or run the Bazel banner_grab_integration_test target")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	client := startNetprobeSidecarForIntegration(t, ctx, netprobeBin)
	defer func() { _ = client.Close() }()

	// Synthetic NTP mode-6 readvar response payload. The recog corpus matches
	// banners of the form `version="ntpd <ver> ...", processor="<arch>",
	// system="Linux/<kernel>"`; the bytes here are an opaque NTP control
	// header prefix followed by an ASCII variable list so the netprobe
	// corpus produces a real ntpd match without us having to forge the full
	// mode-6 framing the engine consumes.
	ntpReadvarResponse := append(
		[]byte{0x17, 0x82, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x00},
		[]byte(`version="ntpd 4.2.8p15@1.3728-o Wed Jun 23 09:31:32 UTC 2021 (1)", processor="x86_64", system="Linux/5.15.0", leap=00, stratum=3,`)...,
	)
	fixtures := []bannerFixture{
		startBannerFixture(t, ProtocolSSH, []byte("OpenSSH_8.9p1 Ubuntu-3ubuntu0.10"), false),
		startBannerFixture(t, ProtocolHTTP, []byte("HTTP/1.1 200 OK\r\nServer: Apache/2.4.58 (Ubuntu)\r\n\r\n"), true),
		startBannerFixture(t, ProtocolSMTP, []byte("foo.bar ESMTP Postfix 2.7.1\r\n"), false),
		startBannerFixture(t, ProtocolSMB, []byte("Samba 4.13.17"), true),
		startUDPBannerFixture(t, ProtocolNTP, ntpReadvarResponse),
	}

	config := Config{
		Enabled:               true,
		Protocols:             make([]string, 0, len(fixtures)),
		Ports:                 make(map[string][]int, len(fixtures)),
		ConnectTimeout:        time.Second,
		ReadTimeout:           time.Second,
		MaxBannerBytes:        512,
		MaxGlobalConcurrency:  4,
		MaxCandidateQueue:     8,
		MaxConcurrencyPerHost: 1,
		PerHostRateLimit:      time.Nanosecond,
	}
	for _, fixture := range fixtures {
		config.Protocols = append(config.Protocols, fixture.protocol)
		config.Ports[fixture.protocol] = []int{fixture.port}
	}

	engine := New(config)
	observations := engine.Start(ctx)

	for _, fixture := range fixtures {
		if err := engine.SubmitResult(ctx, models.Result{
			Target:    models.Target{Host: fixture.host, Port: fixture.port, Mode: models.ModeTCP},
			Available: true,
		}); err != nil {
			t.Fatalf("SubmitResult(%s) error = %v", fixture.protocol, err)
		}
	}

	engine.Stop()

	var captured []BannerObservation
	for observation := range observations {
		captured = append(captured, observation)
	}
	if len(captured) != len(fixtures) {
		t.Fatalf("captured observations = %d, want %d", len(captured), len(fixtures))
	}

	matches, err := client.MatchBanners(ctx, observationsToBannerBatch(captured))
	if err != nil {
		t.Fatalf("MatchBanners() error = %v", err)
	}
	assertIntegrationMatches(t, matches.GetMatches())
}

type bannerFixture struct {
	protocol string
	host     string
	port     int
}

func startBannerFixture(t *testing.T, protocol string, banner []byte, readBeforeWrite bool) bannerFixture {
	t.Helper()

	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen(%s) error = %v", protocol, err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			return
		}
		defer func() { _ = conn.Close() }()

		if readBeforeWrite {
			buf := make([]byte, 1024)
			_ = conn.SetReadDeadline(time.Now().Add(time.Second))
			_, _ = conn.Read(buf)
		}
		_, _ = conn.Write(banner)
	}()

	tcpAddr, ok := listener.Addr().(*net.TCPAddr)
	if !ok {
		t.Fatalf("listener addr = %T, want *net.TCPAddr", listener.Addr())
	}

	return bannerFixture{
		protocol: protocol,
		host:     tcpAddr.IP.String(),
		port:     tcpAddr.Port,
	}
}

func startUDPBannerFixture(t *testing.T, protocol string, response []byte) bannerFixture {
	t.Helper()

	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatalf("ListenUDP(%s) error = %v", protocol, err)
	}
	t.Cleanup(func() { _ = conn.Close() })

	go func() {
		buf := make([]byte, 1500)
		_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		n, addr, readErr := conn.ReadFromUDP(buf)
		if readErr != nil || n == 0 || addr == nil {
			return
		}
		_, _ = conn.WriteToUDP(response, addr)
	}()

	udpAddr, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok {
		t.Fatalf("listener addr = %T, want *net.UDPAddr", conn.LocalAddr())
	}

	return bannerFixture{
		protocol: protocol,
		host:     udpAddr.IP.String(),
		port:     udpAddr.Port,
	}
}

func startNetprobeSidecarForIntegration(t *testing.T, ctx context.Context, binaryPath string) *agentnetprobe.Client {
	t.Helper()

	dir, err := os.MkdirTemp("", "np-*")
	if err != nil {
		t.Fatalf("create netprobe temp dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })

	socketPath := filepath.Join(dir, "netprobe.sock")
	configPath := filepath.Join(dir, "netprobe.json")
	if err := os.WriteFile(configPath, []byte(`{"enabled":false}`), 0o600); err != nil {
		t.Fatalf("write netprobe config: %v", err)
	}

	var output bytes.Buffer
	cmd := exec.CommandContext(
		ctx,
		binaryPath,
		"--socket", socketPath,
		"--config", configPath,
		"--health-port", "0",
		"--log-format", "json",
		// Test runners run as root -- BuildBuddy executors always do. Without this the
		// sidecar exits before binding the socket ("refuses to serve IPC as root") and
		// the Dial loop below times out with a misleading ENOENT on netprobe.sock.
		//
		// Safe here specifically because the config written above is {"enabled":false}:
		// this sidecar probes nothing and only answers Ping. The privilege drop exists to
		// stop a REAL probe from running as root; there is no probe in this test.
		"--allow-root",
	)
	cmd.Stdout = &output
	cmd.Stderr = &output

	if err := cmd.Start(); err != nil {
		t.Fatalf("start netprobe sidecar %q: %v", binaryPath, err)
	}
	t.Cleanup(func() {
		if cmd.Process != nil {
			_ = cmd.Process.Signal(os.Interrupt)
		}
		done := make(chan struct{})
		go func() {
			_ = cmd.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			_ = cmd.Process.Kill()
			<-done
		}
	})

	deadline := time.Now().Add(5 * time.Second)
	var lastErr error
	for time.Now().Before(deadline) {
		client, err := agentnetprobe.Dial(ctx, socketPath)
		if err == nil {
			if pingErr := client.Ping(ctx); pingErr == nil {
				if !client.RecogCorpusLoaded() {
					_ = client.Close()
					t.Fatalf("netprobe PingAck reported recog_corpus_loaded=false")
				}

				return client
			} else {
				lastErr = pingErr
				_ = client.Close()
			}
		} else {
			lastErr = err
		}

		time.Sleep(50 * time.Millisecond)
	}

	t.Fatalf("netprobe sidecar did not become ready: %v\noutput:\n%s", lastErr, output.String())
	return nil
}

func observationsToBannerBatch(observations []BannerObservation) *netprobepb.BannerBatch {
	batch := &netprobepb.BannerBatch{
		Observations: make([]*netprobepb.BannerObservation, 0, len(observations)),
	}
	for _, observation := range observations {
		batch.Observations = append(batch.Observations, &netprobepb.BannerObservation{
			ObservationId: observation.ObservationID,
			Host:          strings.TrimSpace(observation.Host),
			Port:          uint32(observation.Port),
			Protocol:      strings.ToLower(strings.TrimSpace(observation.Protocol)),
			BannerBytes:   append([]byte(nil), observation.BannerBytes...),
			ObservedAt:    observation.ObservedAt.UnixNano(),
			Source:        strings.TrimSpace(observation.Source),
		})
	}

	return batch
}

func assertIntegrationMatches(t *testing.T, matches []*netprobepb.BannerMatch) {
	t.Helper()

	byProduct := make(map[string]*netprobepb.BannerMatch, len(matches))
	for _, match := range matches {
		if match.GetCorpusLabel() == "unknown" {
			t.Logf("unknown match for observation_id=%d", match.GetObservationId())
			continue
		}
		byProduct[strings.ToLower(match.GetProduct())] = match
	}

	for _, product := range []string{"openssh", "httpd", "postfix", "samba", "ntp"} {
		if byProduct[product] == nil {
			t.Fatalf("missing %s match in %s", product, bannerMatchSummary(matches))
		}
	}
}

func bannerMatchSummary(matches []*netprobepb.BannerMatch) string {
	parts := make([]string, 0, len(matches))
	for _, match := range matches {
		parts = append(parts, fmt.Sprintf(
			"id=%d corpus=%s product=%s version=%s raw=%s",
			match.GetObservationId(),
			match.GetCorpusLabel(),
			match.GetProduct(),
			match.GetVersion(),
			match.GetRawPatternId(),
		))
	}

	return strings.Join(parts, "; ")
}

func locateNetprobeBinary(t *testing.T) string {
	t.Helper()

	if override := strings.TrimSpace(os.Getenv("SERVICERADAR_NETPROBE_BIN")); override != "" {
		if executableFile(override) {
			return override
		}
		t.Fatalf("SERVICERADAR_NETPROBE_BIN points to missing or non-executable file %q", override)
	}

	if manifest := strings.TrimSpace(os.Getenv("RUNFILES_MANIFEST_FILE")); manifest != "" {
		if found := findRunfileExecutable(t, manifest, "rust/netprobe/netprobe"); found != "" {
			return found
		}
	}

	if testSrcDir := strings.TrimSpace(os.Getenv("TEST_SRCDIR")); testSrcDir != "" {
		for _, workspace := range []string{strings.TrimSpace(os.Getenv("TEST_WORKSPACE")), "_main"} {
			if workspace == "" {
				continue
			}
			candidate := filepath.Join(testSrcDir, workspace, "rust", "netprobe", "netprobe")
			if executableFile(candidate) {
				return candidate
			}
		}
	}

	for _, candidate := range []string{
		filepath.Join("bazel-bin", "rust", "netprobe", "netprobe"),
		filepath.Join("target", "debug", "serviceradar-netprobe"),
		filepath.Join("target", "release", "serviceradar-netprobe"),
	} {
		if executableFile(candidate) {
			abs, err := filepath.Abs(candidate)
			if err == nil {
				return abs
			}
			return candidate
		}
	}

	return ""
}

func findRunfileExecutable(t *testing.T, manifestPath, suffix string) string {
	t.Helper()

	data, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatalf("read Bazel runfiles manifest: %v", err)
	}

	for _, line := range strings.Split(string(data), "\n") {
		runfile, target, ok := strings.Cut(line, " ")
		if !ok {
			continue
		}
		if strings.HasSuffix(runfile, suffix) && executableFile(target) {
			return target
		}
	}

	return ""
}

func executableFile(path string) bool {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return false
	}

	return info.Mode()&0o111 != 0
}
