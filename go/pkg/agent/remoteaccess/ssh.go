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

package remoteaccess

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

const (
	defaultSSHTerminalType = "xterm-256color"
	defaultSSHCols         = 120
	defaultSSHRows         = 40
	defaultSSHTimeout      = 30 * time.Second
	maxSSHTimeout          = 5 * time.Minute
)

var (
	ErrMissingSSHTargetHost            = errors.New("missing SSH target host")
	ErrSSHUsernameRequired             = errors.New("ssh username is required")
	ErrSSHCredentialRequired           = errors.New("ssh private key or password is required")
	ErrSSHHostKeyStoreUnavailable      = errors.New("SSH host key verification store is not available to the agent connector yet; use explicit skip_verify for local testing")
	ErrUnsupportedSSHHostKeyPolicy     = errors.New("unsupported ssh_host_key_policy")
	ErrSSHSessionOutputChannelOverflow = errors.New("ssh session output channel overflow")
)

// SSHTarget identifies the target host opened by the selected agent.
type SSHTarget struct {
	Host string
	Port int
}

// SSHAuth contains session-scoped SSH credentials. Callers must not persist
// private keys, passwords, or passphrases when using user-present custody.
type SSHAuth struct {
	Username   string
	Password   string
	PrivateKey string
	Passphrase string
}

// SSHConfig configures an SSH-backed PTY adapter.
type SSHConfig struct {
	Target           SSHTarget
	Auth             SSHAuth
	TerminalType     string
	Cols             uint32
	Rows             uint32
	Timeout          time.Duration
	SSHHostKeyPolicy string
}

// SSHSession is the subset of x/crypto/ssh.Session used by the PTY adapter.
type SSHSession interface {
	StdinPipe() (io.WriteCloser, error)
	StdoutPipe() (io.Reader, error)
	StderrPipe() (io.Reader, error)
	RequestPty(term string, h, w int) error
	WindowChange(h, w int) error
	Shell() error
	Wait() error
	Close() error
}

// SSHDialer opens an SSH session for tests or alternate transports.
type SSHDialer func(context.Context, SSHConfig) (SSHSession, error)

type sshPTY struct {
	session SSHSession
	stdin   io.WriteCloser
	output  chan sshRead
	once    sync.Once
}

type sshRead struct {
	data []byte
	err  error
}

// OpenSSHPTY opens an SSH shell and exposes it as a remoteaccess PTY.
func OpenSSHPTY(ctx context.Context, cfg SSHConfig, dial SSHDialer) (PTY, error) {
	cfg = normalizeSSHConfig(cfg)
	if err := validateSSHConfig(cfg); err != nil {
		return nil, err
	}
	if dial == nil {
		dial = DialSSH
	}

	session, err := dial(ctx, cfg)
	if err != nil {
		return nil, err
	}

	pty, err := newSSHPTY(session, cfg)
	if err != nil {
		_ = session.Close()
		return nil, err
	}

	return pty, nil
}

func newSSHPTY(session SSHSession, cfg SSHConfig) (*sshPTY, error) {
	stdin, err := session.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := session.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := session.StderrPipe()
	if err != nil {
		return nil, err
	}

	rows := int(cfg.Rows)
	cols := int(cfg.Cols)
	if err := session.RequestPty(cfg.TerminalType, rows, cols); err != nil {
		return nil, err
	}
	if err := session.Shell(); err != nil {
		return nil, err
	}

	pty := &sshPTY{
		session: session,
		stdin:   stdin,
		output:  make(chan sshRead, 32),
	}

	go pty.copyOutput(stdout)
	go pty.copyOutput(stderr)
	go pty.wait()

	return pty, nil
}

func (p *sshPTY) Read(ctx context.Context) ([]byte, error) {
	select {
	case read := <-p.output:
		return read.data, read.err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (p *sshPTY) Write(data []byte) error {
	if len(data) == 0 {
		return nil
	}
	_, err := p.stdin.Write(data)
	return err
}

func (p *sshPTY) Resize(cols, rows uint32) error {
	if cols == 0 || rows == 0 {
		return nil
	}
	return p.session.WindowChange(int(rows), int(cols))
}

func (p *sshPTY) Close() error {
	var err error
	p.once.Do(func() {
		_ = p.stdin.Close()
		err = p.session.Close()
	})
	return err
}

func (p *sshPTY) copyOutput(reader io.Reader) {
	buf := make([]byte, 16*1024)
	for {
		n, err := reader.Read(buf)
		if n > 0 {
			data := append([]byte(nil), buf[:n]...)
			p.send(sshRead{data: data})
		}
		if err != nil {
			if !errors.Is(err, io.EOF) {
				p.send(sshRead{err: err})
			}
			return
		}
	}
}

func (p *sshPTY) wait() {
	err := p.session.Wait()
	if err == nil {
		err = io.EOF
	}
	p.send(sshRead{err: err})
}

func (p *sshPTY) send(read sshRead) {
	select {
	case p.output <- read:
	default:
		select {
		case p.output <- sshRead{err: ErrSSHSessionOutputChannelOverflow}:
		default:
		}
	}
}

// DialSSH opens a real SSH session using x/crypto/ssh.
func DialSSH(ctx context.Context, cfg SSHConfig) (SSHSession, error) {
	host, port, err := sshTargetAddress(cfg.Target)
	if err != nil {
		return nil, err
	}

	auth, err := sshAuthMethods(cfg.Auth)
	if err != nil {
		return nil, err
	}

	hostKeyCallback, err := sshHostKeyCallback(cfg.SSHHostKeyPolicy)
	if err != nil {
		return nil, err
	}

	timeout := normalizeSSHTimeout(cfg.Timeout)
	dialer := net.Dialer{Timeout: timeout}
	rawConn, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return nil, err
	}

	sshCfg := &ssh.ClientConfig{
		User:            strings.TrimSpace(cfg.Auth.Username),
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

	return &sshClientSession{client: client, session: session}, nil
}

type sshClientSession struct {
	client  *ssh.Client
	session *ssh.Session
}

func (s *sshClientSession) StdinPipe() (io.WriteCloser, error) { return s.session.StdinPipe() }
func (s *sshClientSession) StdoutPipe() (io.Reader, error)     { return s.session.StdoutPipe() }
func (s *sshClientSession) StderrPipe() (io.Reader, error)     { return s.session.StderrPipe() }
func (s *sshClientSession) RequestPty(term string, h, w int) error {
	return s.session.RequestPty(term, h, w, ssh.TerminalModes{ssh.ECHO: 1})
}
func (s *sshClientSession) WindowChange(h, w int) error { return s.session.WindowChange(h, w) }
func (s *sshClientSession) Shell() error                { return s.session.Shell() }
func (s *sshClientSession) Wait() error                 { return s.session.Wait() }
func (s *sshClientSession) Close() error {
	_ = s.session.Close()
	return s.client.Close()
}

func normalizeSSHConfig(cfg SSHConfig) SSHConfig {
	cfg.Auth.Username = strings.TrimSpace(cfg.Auth.Username)
	cfg.Target.Host = strings.TrimSpace(cfg.Target.Host)
	cfg.TerminalType = strings.TrimSpace(cfg.TerminalType)
	if cfg.TerminalType == "" {
		cfg.TerminalType = defaultSSHTerminalType
	}
	if cfg.Cols == 0 {
		cfg.Cols = defaultSSHCols
	}
	if cfg.Rows == 0 {
		cfg.Rows = defaultSSHRows
	}
	cfg.Timeout = normalizeSSHTimeout(cfg.Timeout)
	return cfg
}

func validateSSHConfig(cfg SSHConfig) error {
	if strings.TrimSpace(cfg.Target.Host) == "" {
		return ErrMissingSSHTargetHost
	}
	if strings.TrimSpace(cfg.Auth.Username) == "" {
		return ErrSSHUsernameRequired
	}
	if strings.TrimSpace(cfg.Auth.PrivateKey) == "" && strings.TrimSpace(cfg.Auth.Password) == "" {
		return ErrSSHCredentialRequired
	}
	return nil
}

func sshTargetAddress(target SSHTarget) (string, int, error) {
	host := strings.TrimSpace(target.Host)
	if host == "" {
		return "", 0, ErrMissingSSHTargetHost
	}
	port := target.Port
	if port <= 0 {
		port = 22
	}
	return host, port, nil
}

func sshAuthMethods(auth SSHAuth) ([]ssh.AuthMethod, error) {
	methods := make([]ssh.AuthMethod, 0, 2)
	if strings.TrimSpace(auth.PrivateKey) != "" {
		signer, err := sshSigner(auth.PrivateKey, auth.Passphrase)
		if err != nil {
			return nil, err
		}
		methods = append(methods, ssh.PublicKeys(signer))
	}
	if strings.TrimSpace(auth.Password) != "" {
		methods = append(methods, ssh.Password(auth.Password))
	}
	return methods, nil
}

func sshSigner(privateKey, passphrase string) (ssh.Signer, error) {
	key := []byte(strings.TrimSpace(privateKey))
	if strings.TrimSpace(passphrase) != "" {
		return ssh.ParsePrivateKeyWithPassphrase(key, []byte(passphrase))
	}
	return ssh.ParsePrivateKey(key)
}

func sshHostKeyCallback(policy string) (ssh.HostKeyCallback, error) {
	switch strings.TrimSpace(policy) {
	case "skip_verify":
		return ssh.InsecureIgnoreHostKey(), nil //nolint:gosec // explicit operator policy for scoped agent-side SSH testing
	case "trust_on_first_use", "known_hosts", "":
		return nil, ErrSSHHostKeyStoreUnavailable
	default:
		return nil, fmt.Errorf("%w %q", ErrUnsupportedSSHHostKeyPolicy, policy)
	}
}

func normalizeSSHTimeout(timeout time.Duration) time.Duration {
	if timeout <= 0 {
		return defaultSSHTimeout
	}
	if timeout > maxSSHTimeout {
		return maxSSHTimeout
	}
	return timeout
}
