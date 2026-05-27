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

package netprobe

import (
	"context"
	"sync/atomic"

	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
)

const (
	DefaultSidecarName        = "netprobe"
	DefaultBinaryPath         = "/usr/local/lib/serviceradar/bin/serviceradar-netprobe"
	DefaultLogFormat          = "json"
	defaultHealthPort  uint16 = 0
)

// SidecarConfig configures the netprobe sidecar process.
type SidecarConfig struct {
	Name       string
	BinaryPath string
	LogFormat  string
	HealthPort uint16
	ExtraArgs  []string
}

// Sidecar implements the generic agent sidecar contract for serviceradar-netprobe.
type Sidecar struct {
	cfg SidecarConfig

	healthy       atomic.Bool
	unhealthy     atomic.Bool
	engineVersion atomic.Value
	lastError     atomic.Value
}

var _ sidecar.Sidecar = (*Sidecar)(nil)

// NewSidecar creates a netprobe sidecar adapter.
func NewSidecar(cfg SidecarConfig) *Sidecar {
	if cfg.Name == "" {
		cfg.Name = DefaultSidecarName
	}
	if cfg.BinaryPath == "" {
		cfg.BinaryPath = DefaultBinaryPath
	}
	if cfg.LogFormat == "" {
		cfg.LogFormat = DefaultLogFormat
	}

	return &Sidecar{cfg: cfg}
}

// ClientFactory returns the health/client factory expected by the sidecar manager.
func ClientFactory() sidecar.ClientFactory {
	return func(ctx context.Context, socketPath string) (sidecar.Client, error) {
		return Dial(ctx, socketPath)
	}
}

func (s *Sidecar) Name() string {
	return s.cfg.Name
}

func (s *Sidecar) BinaryPath() string {
	return s.cfg.BinaryPath
}

func (s *Sidecar) Args(socketPath, configPath string) []string {
	args := []string{
		"--socket", socketPath,
		"--config", configPath,
		"--log-format", s.cfg.LogFormat,
	}
	if s.cfg.HealthPort != defaultHealthPort {
		args = append(args, "--health-port", uint16String(s.cfg.HealthPort))
	}
	args = append(args, s.cfg.ExtraArgs...)

	return args
}

func (s *Sidecar) OnHealthy(client sidecar.Client) {
	s.healthy.Store(true)
	s.unhealthy.Store(false)
	s.lastError.Store("")

	if netprobeClient, ok := client.(*Client); ok {
		s.engineVersion.Store(netprobeClient.FingerprintEngineVersion())
	}
}

func (s *Sidecar) OnUnhealthy(err error) {
	s.healthy.Store(false)
	s.unhealthy.Store(true)
	if err != nil {
		s.lastError.Store(err.Error())
	}
}

func (s *Sidecar) Healthy() bool {
	return s.healthy.Load()
}

func (s *Sidecar) FingerprintEngineVersion() string {
	value := s.engineVersion.Load()
	if value == nil {
		return ""
	}
	version, _ := value.(string)

	return version
}

func uint16String(value uint16) string {
	if value == 0 {
		return "0"
	}

	var buf [5]byte
	i := len(buf)
	for value > 0 {
		i--
		buf[i] = byte('0' + value%10)
		value /= 10
	}

	return string(buf[i:])
}
