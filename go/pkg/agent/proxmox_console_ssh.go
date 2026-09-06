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

package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	"golang.org/x/crypto/ssh"
)

var (
	errMissingProxmoxSSHTargetHost                   = errors.New("missing SSH target host")
	errInvalidProxmoxSSHTargetPort                   = errors.New("invalid SSH target port")
	errInvalidProxmoxSSHFieldSize                    = errors.New("invalid SSH field size")
	errProxmoxSSHUsernameRequired                    = errors.New("ssh username is required")
	errProxmoxSSHCredentialRequired                  = errors.New("ssh private key or password is required")
	errProxmoxSSHHostKeyVerificationStoreUnavailable = errors.New("SSH host key verification store is not available to the agent connector")
	errUnsupportedProxmoxSSHHostKeyPolicy            = errors.New("unsupported ssh_host_key_policy")
)

const (
	maxProxmoxSSHTargetHostBytes = 255
	maxProxmoxSSHUsernameBytes   = 128
	maxProxmoxSSHPrivateKeyBytes = 65_536
	maxProxmoxSSHPasswordBytes   = 4_096
	maxProxmoxSSHPassphraseBytes = 4_096

	proxmoxSSHConsoleUnavailableMessage = "SSH console unavailable\r\n"
)

type proxmoxConsoleSSHConfig struct {
	CredentialRuleID string                      `json:"credential_rule_id"`
	CredentialBroker map[string]any              `json:"credential_broker,omitempty"`
	Console          proxmoxConsoleSessionSpec   `json:"console"`
	Target           proxmoxConsoleSSHTarget     `json:"target,omitempty"`
	SSH              proxmoxConsoleSSHAuth       `json:"ssh,omitempty"`
	CredentialSecret json.RawMessage             `json:"credential_secret,omitempty"`
	TimeoutMS        int                         `json:"timeout_ms"`
	SSHHostKeyPolicy string                      `json:"ssh_host_key_policy"`
	KnownHostsPath   string                      `json:"known_hosts_path,omitempty"`
	revalidate       func(context.Context) error `json:"-"`
}

// proxmoxConsoleSSHHostRequest is the complete Wasm-to-host SSH ABI. The
// untrusted module may identify only the immutable session it is already
// executing; destination, credential, timeout, and host-key policy are rebuilt
// from trusted agent state.
type proxmoxConsoleSSHHostRequest struct {
	SessionID string `json:"session_id"`
}

type proxmoxConsoleSSHTarget struct {
	DeviceUID               string `json:"device_uid,omitempty"`
	BaseURL                 string `json:"base_url,omitempty"`
	Hostname                string `json:"hostname,omitempty"`
	IP                      string `json:"ip,omitempty"`
	SSHPort                 int    `json:"ssh_port,omitempty"`
	ProviderRef             string `json:"provider_ref,omitempty"`
	TargetRef               string `json:"target_ref,omitempty"`
	TargetKind              string `json:"target_kind,omitempty"`
	ConsoleMode             string `json:"console_mode,omitempty"`
	IntegrationID           string `json:"integration_id,omitempty"`
	Cluster                 string `json:"cluster,omitempty"`
	Node                    string `json:"node,omitempty"`
	OwnerNode               string `json:"owner_node,omitempty"`
	VMID                    int    `json:"vmid,omitempty"`
	ControllerDeviceUID     string `json:"controller_device_uid,omitempty"`
	ControllerRef           string `json:"controller_ref,omitempty"`
	ControllerIntegrationID string `json:"controller_integration_id,omitempty"`
	ControllerID            string `json:"controller_id,omitempty"`
	ProviderInstanceRef     string `json:"provider_instance_ref,omitempty"`
	NativeClusterID         string `json:"native_cluster_id,omitempty"`
	ObjectKind              string `json:"object_kind,omitempty"`
	NativeObjectID          string `json:"native_object_id,omitempty"`
}

type proxmoxConsoleSSHAuth struct {
	Username   string `json:"username,omitempty"`
	Password   string `json:"password,omitempty"`
	PrivateKey string `json:"private_key,omitempty"`
	Passphrase string `json:"passphrase,omitempty"`
}

type proxmoxConsoleSSHSession interface {
	StdinPipe() (io.WriteCloser, error)
	StdoutPipe() (io.Reader, error)
	StderrPipe() (io.Reader, error)
	RequestPty(term string, h, w int) error
	WindowChange(h, w int) error
	Shell() error
	Wait() error
	Close() error
}

type proxmoxConsoleSSHDialer func(context.Context, proxmoxConsoleSSHConfig) (proxmoxConsoleSSHSession, error)

func runProxmoxConsoleSSH(
	ctx context.Context,
	cfg proxmoxConsoleSSHConfig,
	bridge *pluginProxmoxConsoleBridge,
	dial proxmoxConsoleSSHDialer,
) error {
	if bridge == nil {
		return errProxmoxConsoleBridgeUnavailable
	}
	if dial == nil {
		dial = dialProxmoxConsoleSSH
	}
	if err := validateProxmoxConsoleSSHConfig(cfg); err != nil {
		return err
	}

	handle, err := bridge.activeHandle()
	if err != nil {
		return err
	}
	if cfg.revalidate != nil {
		if err := cfg.revalidate(ctx); err != nil {
			return err
		}
	}

	session, err := dial(ctx, cfg)
	if err != nil {
		_, _ = bridge.WriteOutput(ctx, handle, []byte(proxmoxSSHConsoleUnavailableMessage))
		return err
	}
	defer func() { _ = session.Close() }()

	stdin, err := session.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := session.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := session.StderrPipe()
	if err != nil {
		return err
	}

	cols := int(firstNonZero(cfg.Console.Cols, 120))
	rows := int(firstNonZero(cfg.Console.Rows, 40))
	if err := session.RequestPty("xterm-256color", rows, cols); err != nil {
		return err
	}
	if err := session.Shell(); err != nil {
		return err
	}

	done := make(chan error, 3)
	var once sync.Once
	go copyProxmoxConsoleSSHOutput(ctx, bridge, handle, stdout, done, &once)
	go copyProxmoxConsoleSSHOutput(ctx, bridge, handle, stderr, done, &once)
	go func() {
		once.Do(func() { done <- session.Wait() })
	}()

	return proxyProxmoxConsoleSSHInput(ctx, bridge, handle, stdin, session, done)
}

func copyProxmoxConsoleSSHOutput(
	ctx context.Context,
	bridge *pluginProxmoxConsoleBridge,
	handle uint32,
	reader io.Reader,
	done chan<- error,
	once *sync.Once,
) {
	buf := make([]byte, 16*1024)
	for {
		n, readErr := reader.Read(buf)
		if n > 0 {
			if _, err := bridge.WriteOutput(ctx, handle, buf[:n]); err != nil {
				once.Do(func() { done <- err })
				return
			}
		}
		if readErr != nil {
			if !errors.Is(readErr, io.EOF) {
				once.Do(func() { done <- readErr })
			}
			return
		}
	}
}

func proxyProxmoxConsoleSSHInput(
	ctx context.Context,
	bridge *pluginProxmoxConsoleBridge,
	handle uint32,
	stdin io.Writer,
	session proxmoxConsoleSSHSession,
	done <-chan error,
) error {
	for {
		if finished, err := proxmoxConsoleSSHDone(done); finished {
			return err
		}
		frame, err := bridge.ReadInput(ctx, handle, 250*time.Millisecond)
		switch {
		case errors.Is(err, context.DeadlineExceeded):
			continue
		case errors.Is(err, io.EOF):
			return nil
		case err != nil:
			return err
		}

		switch frame.FrameType {
		case consoleFrameTypeData:
			if len(frame.Data) > 0 {
				if _, err := stdin.Write(frame.Data); err != nil {
					return err
				}
			}
		case consoleFrameTypeResize:
			if frame.Cols > 0 && frame.Rows > 0 {
				if err := session.WindowChange(int(frame.Rows), int(frame.Cols)); err != nil {
					return err
				}
			}
		case consoleFrameTypeClose:
			return nil
		}
	}
}

func proxmoxConsoleSSHDone(done <-chan error) (bool, error) {
	select {
	case err := <-done:
		if err != nil && !errors.Is(err, io.EOF) {
			return true, err
		}
		return true, nil
	default:
		return false, nil
	}
}

func dialProxmoxConsoleSSH(ctx context.Context, cfg proxmoxConsoleSSHConfig) (proxmoxConsoleSSHSession, error) {
	host, port, err := proxmoxConsoleSSHTargetAddress(cfg.Target)
	if err != nil {
		return nil, err
	}

	cred, err := proxmoxConsoleSSHCredential(cfg)
	if err != nil {
		return nil, err
	}

	auth, err := proxmoxConsoleSSHAuthMethods(cred)
	if err != nil {
		return nil, err
	}

	hostKeyCallback, err := proxmoxConsoleSSHHostKeyCallback(cfg.SSHHostKeyPolicy, cfg.KnownHostsPath)
	if err != nil {
		return nil, err
	}

	timeout := time.Duration(normalizeProxmoxConsoleTimeoutMS(cfg.TimeoutMS)) * time.Millisecond
	dialer := net.Dialer{Timeout: timeout}
	rawConn, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return nil, err
	}
	// ssh.NewClientConn and the subsequent session-open exchange do not accept a
	// context. Keep the transport owned by this call and close it as soon as the
	// assignment/session context is revoked so a peer that stalls before its SSH
	// banner cannot keep a revoked console execution alive.
	cancelWatchDone := make(chan struct{})
	defer close(cancelWatchDone)
	go func() {
		select {
		case <-ctx.Done():
			_ = rawConn.Close()
		case <-cancelWatchDone:
		}
	}()
	if err := rawConn.SetDeadline(time.Now().Add(timeout)); err != nil {
		_ = rawConn.Close()
		if ctxErr := ctx.Err(); ctxErr != nil {
			return nil, ctxErr
		}
		return nil, err
	}

	sshCfg := &ssh.ClientConfig{
		User:            cred.Username,
		Auth:            auth,
		HostKeyCallback: hostKeyCallback,
		Timeout:         timeout,
	}

	conn, chans, reqs, err := ssh.NewClientConn(rawConn, rawConn.RemoteAddr().String(), sshCfg)
	if err != nil {
		_ = rawConn.Close()
		if ctxErr := ctx.Err(); ctxErr != nil {
			return nil, ctxErr
		}
		return nil, err
	}
	client := ssh.NewClient(conn, chans, reqs)
	session, err := client.NewSession()
	if err != nil {
		_ = client.Close()
		if ctxErr := ctx.Err(); ctxErr != nil {
			return nil, ctxErr
		}
		return nil, err
	}
	if err := rawConn.SetDeadline(time.Time{}); err != nil {
		_ = session.Close()
		_ = client.Close()
		if ctxErr := ctx.Err(); ctxErr != nil {
			return nil, ctxErr
		}
		return nil, err
	}
	if ctxErr := ctx.Err(); ctxErr != nil {
		_ = session.Close()
		_ = client.Close()
		return nil, ctxErr
	}

	return &proxmoxConsoleSSHClient{client: client, session: session}, nil
}

type proxmoxConsoleSSHClient struct {
	client  *ssh.Client
	session *ssh.Session
}

func (c *proxmoxConsoleSSHClient) StdinPipe() (io.WriteCloser, error) { return c.session.StdinPipe() }
func (c *proxmoxConsoleSSHClient) StdoutPipe() (io.Reader, error)     { return c.session.StdoutPipe() }
func (c *proxmoxConsoleSSHClient) StderrPipe() (io.Reader, error)     { return c.session.StderrPipe() }
func (c *proxmoxConsoleSSHClient) RequestPty(term string, h, w int) error {
	return c.session.RequestPty(term, h, w, ssh.TerminalModes{ssh.ECHO: 1})
}
func (c *proxmoxConsoleSSHClient) WindowChange(h, w int) error { return c.session.WindowChange(h, w) }
func (c *proxmoxConsoleSSHClient) Shell() error                { return c.session.Shell() }
func (c *proxmoxConsoleSSHClient) Wait() error                 { return c.session.Wait() }
func (c *proxmoxConsoleSSHClient) Close() error {
	_ = c.session.Close()
	return c.client.Close()
}

func validateProxmoxConsoleSSHConfig(cfg proxmoxConsoleSSHConfig) error {
	if _, _, err := proxmoxConsoleSSHTargetAddress(cfg.Target); err != nil {
		return err
	}
	if _, err := validateProxmoxConsoleSSHCredential(cfg.SSH); err != nil {
		return err
	}
	if !proxmoxConsoleSSHHostKeyPolicyAllowed(cfg.SSHHostKeyPolicy) {
		return fmt.Errorf("%w %q", errUnsupportedProxmoxSSHHostKeyPolicy, cfg.SSHHostKeyPolicy)
	}
	return nil
}

func proxmoxConsoleSSHTargetAddress(target proxmoxConsoleSSHTarget) (string, int, error) {
	// Device-reported node names need not resolve from this agent. Keep the IP
	// preference aligned with consoleSpecCanonicalOrigin's authorization target.
	host := strings.TrimSpace(firstNonEmpty(target.IP, target.Hostname))
	if host == "" && strings.TrimSpace(target.BaseURL) != "" {
		if len(strings.TrimSpace(target.BaseURL)) > maxProxmoxSSHTargetHostBytes*2 {
			return "", 0, errInvalidProxmoxSSHFieldSize
		}
		parsed, err := url.Parse(strings.TrimSpace(target.BaseURL))
		if err != nil {
			return "", 0, err
		}
		host = parsed.Hostname()
	}
	if host == "" {
		return "", 0, errMissingProxmoxSSHTargetHost
	}
	if len(host) > maxProxmoxSSHTargetHostBytes {
		return "", 0, errInvalidProxmoxSSHFieldSize
	}
	port := target.SSHPort
	if port <= 0 {
		port = 22
	}
	if port > 65_535 {
		return "", 0, errInvalidProxmoxSSHTargetPort
	}
	return host, port, nil
}

func proxmoxConsoleSSHCredential(cfg proxmoxConsoleSSHConfig) (proxmoxConsoleSSHAuth, error) {
	cred := cfg.SSH
	if len(cfg.CredentialSecret) > 0 {
		var secret proxmoxConsoleSSHAuth
		if err := json.Unmarshal(cfg.CredentialSecret, &secret); err == nil {
			cred = mergeProxmoxConsoleSSHCredential(cred, secret)
		}
	}
	return validateProxmoxConsoleSSHCredential(cred)
}

func validateProxmoxConsoleSSHCredential(cred proxmoxConsoleSSHAuth) (proxmoxConsoleSSHAuth, error) {
	if strings.TrimSpace(cred.Username) == "" {
		return proxmoxConsoleSSHAuth{}, errProxmoxSSHUsernameRequired
	}
	if len(strings.TrimSpace(cred.Username)) > maxProxmoxSSHUsernameBytes ||
		len(strings.TrimSpace(cred.PrivateKey)) > maxProxmoxSSHPrivateKeyBytes ||
		len(cred.Password) > maxProxmoxSSHPasswordBytes ||
		len(cred.Passphrase) > maxProxmoxSSHPassphraseBytes {
		return proxmoxConsoleSSHAuth{}, errInvalidProxmoxSSHFieldSize
	}
	if strings.TrimSpace(cred.PrivateKey) == "" && strings.TrimSpace(cred.Password) == "" {
		return proxmoxConsoleSSHAuth{}, errProxmoxSSHCredentialRequired
	}
	return cred, nil
}

func mergeProxmoxConsoleSSHCredential(primary, fallback proxmoxConsoleSSHAuth) proxmoxConsoleSSHAuth {
	if strings.TrimSpace(primary.Username) == "" {
		primary.Username = fallback.Username
	}
	if strings.TrimSpace(primary.Password) == "" {
		primary.Password = fallback.Password
	}
	if strings.TrimSpace(primary.PrivateKey) == "" {
		primary.PrivateKey = fallback.PrivateKey
	}
	if strings.TrimSpace(primary.Passphrase) == "" {
		primary.Passphrase = fallback.Passphrase
	}
	return primary
}

func proxmoxConsoleSSHAuthMethods(cred proxmoxConsoleSSHAuth) ([]ssh.AuthMethod, error) {
	methods := make([]ssh.AuthMethod, 0, 2)
	if strings.TrimSpace(cred.PrivateKey) != "" {
		signer, err := proxmoxConsoleSSHSigner(cred.PrivateKey, cred.Passphrase)
		if err != nil {
			return nil, err
		}
		methods = append(methods, ssh.PublicKeys(signer))
	}
	if strings.TrimSpace(cred.Password) != "" {
		methods = append(methods, ssh.Password(cred.Password))
	}
	return methods, nil
}

func proxmoxConsoleSSHSigner(privateKey, passphrase string) (ssh.Signer, error) {
	key := []byte(strings.TrimSpace(privateKey))
	if strings.TrimSpace(passphrase) != "" {
		return ssh.ParsePrivateKeyWithPassphrase(key, []byte(passphrase))
	}
	return ssh.ParsePrivateKey(key)
}

func proxmoxConsoleSSHHostKeyCallback(policy, knownHostsPath string) (ssh.HostKeyCallback, error) {
	if !proxmoxConsoleSSHHostKeyPolicyAllowed(policy) {
		return nil, fmt.Errorf("%w %q", errUnsupportedProxmoxSSHHostKeyPolicy, policy)
	}
	callback, err := remoteaccess.SSHHostKeyCallback(policy, knownHostsPath)
	if err == nil {
		return callback, nil
	}
	if errors.Is(err, remoteaccess.ErrUnsupportedSSHHostKeyPolicy) {
		return nil, fmt.Errorf("%w %q", errUnsupportedProxmoxSSHHostKeyPolicy, policy)
	}
	if errors.Is(err, remoteaccess.ErrSSHHostKeyStoreUnavailable) {
		return nil, fmt.Errorf("%w: %w", errProxmoxSSHHostKeyVerificationStoreUnavailable, err)
	}

	return nil, err
}

func proxmoxConsoleSSHHostKeyPolicyAllowed(policy string) bool {
	switch strings.TrimSpace(policy) {
	case proxmoxSSHHostKeyPolicyKnownHosts, proxmoxSSHHostKeyPolicyTrustFirstUse:
		return true
	default:
		return false
	}
}

func normalizeProxmoxConsoleTimeoutMS(timeoutMS int) int {
	if timeoutMS <= 0 {
		return 30000
	}
	if timeoutMS > 300000 {
		return 300000
	}
	return timeoutMS
}
