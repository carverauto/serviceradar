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

	"golang.org/x/crypto/ssh"
)

var (
	errMissingProxmoxSSHTargetHost                   = errors.New("missing SSH target host")
	errProxmoxSSHUsernameRequired                    = errors.New("ssh username is required")
	errProxmoxSSHCredentialRequired                  = errors.New("ssh private key or password is required")
	errProxmoxSSHHostKeyVerificationStoreUnavailable = errors.New("SSH host key verification store is not available to the agent connector yet; use explicit skip_verify for local testing")
	errUnsupportedProxmoxSSHHostKeyPolicy            = errors.New("unsupported ssh_host_key_policy")
)

type proxmoxConsoleSSHConfig struct {
	CredentialRuleID string                    `json:"credential_rule_id"`
	CredentialBroker map[string]any            `json:"credential_broker,omitempty"`
	Console          proxmoxConsoleSessionSpec `json:"console"`
	Target           proxmoxConsoleSSHTarget   `json:"target,omitempty"`
	SSH              proxmoxConsoleSSHAuth     `json:"ssh,omitempty"`
	CredentialSecret json.RawMessage           `json:"credential_secret,omitempty"`
	TimeoutMS        int                       `json:"timeout_ms"`
	SSHHostKeyPolicy string                    `json:"ssh_host_key_policy"`
}

type proxmoxConsoleSSHTarget struct {
	BaseURL  string `json:"base_url,omitempty"`
	Hostname string `json:"hostname,omitempty"`
	IP       string `json:"ip,omitempty"`
	SSHPort  int    `json:"ssh_port,omitempty"`
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

	handle, err := bridge.activeHandle()
	if err != nil {
		return err
	}

	session, err := dial(ctx, cfg)
	if err != nil {
		_, _ = bridge.WriteOutput(ctx, handle, []byte("Unable to open SSH console: "+err.Error()+"\r\n"))
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
	copyOutput := func(reader io.Reader) {
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

	go copyOutput(stdout)
	go copyOutput(stderr)
	go func() {
		once.Do(func() { done <- session.Wait() })
	}()

	for {
		select {
		case err := <-done:
			if err != nil && !errors.Is(err, io.EOF) {
				return err
			}
			return nil
		default:
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

	hostKeyCallback, err := proxmoxConsoleSSHHostKeyCallback(cfg.SSHHostKeyPolicy)
	if err != nil {
		return nil, err
	}

	timeout := time.Duration(normalizeProxmoxConsoleTimeoutMS(cfg.TimeoutMS)) * time.Millisecond
	dialer := net.Dialer{Timeout: timeout}
	rawConn, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
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
		return nil, err
	}

	client := ssh.NewClient(conn, chans, reqs)
	session, err := client.NewSession()
	if err != nil {
		_ = client.Close()
		return nil, err
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

func proxmoxConsoleSSHTargetAddress(target proxmoxConsoleSSHTarget) (string, int, error) {
	host := strings.TrimSpace(firstNonEmpty(target.Hostname, target.IP))
	if host == "" && strings.TrimSpace(target.BaseURL) != "" {
		parsed, err := url.Parse(strings.TrimSpace(target.BaseURL))
		if err != nil {
			return "", 0, err
		}
		host = parsed.Hostname()
	}
	if host == "" {
		return "", 0, errMissingProxmoxSSHTargetHost
	}
	port := target.SSHPort
	if port <= 0 {
		port = 22
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

func proxmoxConsoleSSHHostKeyCallback(policy string) (ssh.HostKeyCallback, error) {
	switch strings.TrimSpace(policy) {
	case "skip_verify":
		return ssh.InsecureIgnoreHostKey(), nil //nolint:gosec // explicit operator policy for agent-local SSH console config
	case "trust_on_first_use", "known_hosts", "":
		return nil, errProxmoxSSHHostKeyVerificationStoreUnavailable
	default:
		return nil, fmt.Errorf("%w %q", errUnsupportedProxmoxSSHHostKeyPolicy, policy)
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
