//go:build !tinygo

package main

import (
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

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
	"golang.org/x/crypto/ssh"
)

func streamSSHConsole(
	cfg consoleConfig,
	bridge proxmoxConsoleBridge,
	dial func(consoleConfig) (sshConsoleSession, error),
) error {
	session, err := dial(cfg)
	if err != nil {
		_ = bridge.Write([]byte("Unable to open SSH console: " + err.Error() + "\r\n"))
		return err
	}
	defer session.Close()

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

	cols := int(firstNonZero32(cfg.Console.Cols, 120))
	rows := int(firstNonZero32(cfg.Console.Rows, 40))
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
				if err := bridge.Write(buf[:n]); err != nil {
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

	inputBuf := make([]byte, 32*1024)
	for {
		select {
		case err := <-done:
			if err != nil && !errors.Is(err, io.EOF) {
				return err
			}
			return nil
		default:
		}

		n, err := bridge.Read(inputBuf, 250*time.Millisecond)
		if errors.Is(err, errConsoleBridgeUnavailable) {
			return err
		}
		if err != nil || n == 0 {
			continue
		}

		var frame consoleInputFrame
		if err := json.Unmarshal(inputBuf[:n], &frame); err != nil {
			continue
		}

		switch frame.FrameType {
		case "data":
			if len(frame.Data) > 0 {
				if _, err := stdin.Write(frame.Data); err != nil {
					return err
				}
			}
		case "resize":
			if frame.Cols > 0 && frame.Rows > 0 {
				if err := session.WindowChange(int(frame.Rows), int(frame.Cols)); err != nil {
					return err
				}
			}
		case "close":
			return nil
		}
	}
}

func dialSSHConsole(cfg consoleConfig) (sshConsoleSession, error) {
	host, port, err := sshTarget(cfg.Target)
	if err != nil {
		return nil, err
	}

	cred, err := sshCredential(cfg)
	if err != nil {
		return nil, err
	}

	auth, err := sshAuthMethods(cred)
	if err != nil {
		return nil, err
	}

	hostKeyCallback, err := sshHostKeyCallback(cfg.SSHHostKeyPolicy)
	if err != nil {
		return nil, err
	}

	timeout := time.Duration(normalizeConsoleTimeoutMS(cfg.TimeoutMS)) * time.Millisecond
	tcp, err := sdk.TCPDial(host, uint16(port), timeout)
	if err != nil {
		return nil, err
	}

	sshCfg := &ssh.ClientConfig{
		User:            cred.Username,
		Auth:            auth,
		HostKeyCallback: hostKeyCallback,
		Timeout:         timeout,
	}

	addr := net.JoinHostPort(host, strconv.Itoa(port))
	conn, chans, reqs, err := ssh.NewClientConn(tcp.NetConn(), addr, sshCfg)
	if err != nil {
		_ = tcp.Close()
		return nil, err
	}

	client := ssh.NewClient(conn, chans, reqs)
	session, err := client.NewSession()
	if err != nil {
		_ = client.Close()
		return nil, err
	}

	return &sshConsoleClient{client: client, session: session}, nil
}

type sshConsoleClient struct {
	client  *ssh.Client
	session *ssh.Session
}

func (c *sshConsoleClient) StdinPipe() (io.WriteCloser, error) { return c.session.StdinPipe() }
func (c *sshConsoleClient) StdoutPipe() (io.Reader, error)     { return c.session.StdoutPipe() }
func (c *sshConsoleClient) StderrPipe() (io.Reader, error)     { return c.session.StderrPipe() }
func (c *sshConsoleClient) RequestPty(term string, h, w int) error {
	return c.session.RequestPty(term, h, w, ssh.TerminalModes{ssh.ECHO: 1})
}
func (c *sshConsoleClient) WindowChange(h, w int) error { return c.session.WindowChange(h, w) }
func (c *sshConsoleClient) Shell() error                { return c.session.Shell() }
func (c *sshConsoleClient) Wait() error                 { return c.session.Wait() }
func (c *sshConsoleClient) Close() error {
	_ = c.session.Close()
	return c.client.Close()
}

func sshTarget(target consoleTarget) (string, int, error) {
	host := strings.TrimSpace(firstNonEmpty(target.Hostname, target.IP))
	if host == "" && strings.TrimSpace(target.BaseURL) != "" {
		parsed, err := url.Parse(strings.TrimSpace(target.BaseURL))
		if err != nil {
			return "", 0, err
		}
		host = parsed.Hostname()
	}
	if host == "" {
		return "", 0, errors.New("missing SSH target host")
	}
	port := target.SSHPort
	if port <= 0 {
		port = 22
	}
	return host, port, nil
}

func sshCredential(cfg consoleConfig) (consoleSSH, error) {
	cred := cfg.SSH
	if len(cfg.CredentialSecret) > 0 {
		var secret consoleSSH
		if err := json.Unmarshal(cfg.CredentialSecret, &secret); err == nil {
			cred = mergeSSHCredential(cred, secret)
		}
	}
	if strings.TrimSpace(cred.Username) == "" {
		return consoleSSH{}, errors.New("ssh username is required")
	}
	if strings.TrimSpace(cred.PrivateKey) == "" && strings.TrimSpace(cred.Password) == "" {
		return consoleSSH{}, errors.New("ssh private key or password is required")
	}
	return cred, nil
}

func mergeSSHCredential(primary, fallback consoleSSH) consoleSSH {
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

func sshAuthMethods(cred consoleSSH) ([]ssh.AuthMethod, error) {
	methods := make([]ssh.AuthMethod, 0, 2)
	if strings.TrimSpace(cred.PrivateKey) != "" {
		signer, err := sshSigner(cred.PrivateKey, cred.Passphrase)
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
		return ssh.InsecureIgnoreHostKey(), nil //nolint:gosec // explicit operator policy for local agent-side console config
	case "trust_on_first_use", "known_hosts", "":
		return nil, errors.New("SSH host key verification store is not available to the Wasm plugin yet; use agent-hosted broker or explicit skip_verify for local testing")
	default:
		return nil, fmt.Errorf("unsupported ssh_host_key_policy %q", policy)
	}
}
