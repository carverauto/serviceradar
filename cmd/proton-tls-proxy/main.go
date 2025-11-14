package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

type proxyConfig struct {
	listenAddr        string
	targetAddr        string
	certPath          string
	keyPath           string
	caPath            string
	requireClientCert bool
	logPath           string
}

var errInvalidCAFile = errors.New("failed to parse CA file")

func main() {
	cfg := parseFlags()

	logger := log.New(os.Stdout, "[proton-tls-proxy] ", log.LstdFlags|log.Lmicroseconds)
	if cfg.logPath != "" {
		if err := os.MkdirAll(filepath.Dir(cfg.logPath), 0o755); err != nil {
			log.Fatalf("failed to create log directory: %v", err)
		}
		f, err := os.OpenFile(cfg.logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			log.Fatalf("failed to open log file: %v", err)
		}
		defer func() {
			if err := f.Close(); err != nil {
				logger.Printf("error closing log file: %v", err)
			}
		}()
		logger.SetOutput(f)
	}

	tlsConfig, err := buildTLSConfig(cfg)
	if err != nil {
		logger.Fatalf("failed to build TLS config: %v", err)
	}

	ln, err := tls.Listen("tcp", cfg.listenAddr, tlsConfig)
	if err != nil {
		logger.Fatalf("failed to listen on %s: %v", cfg.listenAddr, err)
	}
	defer func() {
		if err := ln.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			logger.Printf("error closing listener: %v", err)
		}
	}()

	logger.Printf("listening on %s, proxying to %s", cfg.listenAddr, cfg.targetAddr)

	signalCh := make(chan os.Signal, 1)
	signal.Notify(signalCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-signalCh
		logger.Println("shutting down listener")
		if err := ln.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			logger.Printf("listener close error: %v", err)
		}
	}()

	for {
		clientConn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				logger.Printf("listener exiting: %v", err)
				return
			}
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				logger.Printf("accept timeout: %v", err)
				time.Sleep(100 * time.Millisecond)
				continue
			}
			logger.Printf("listener exiting: %v", err)
			return
		}

		go handleConnection(logger, clientConn, cfg.targetAddr)
	}
}

func parseFlags() proxyConfig {
	var cfg proxyConfig
	flag.StringVar(&cfg.listenAddr, "listen", "", "listen address (host:port)")
	flag.StringVar(&cfg.targetAddr, "target", "", "target address (host:port)")
	flag.StringVar(&cfg.certPath, "cert", "", "path to TLS certificate (PEM)")
	flag.StringVar(&cfg.keyPath, "key", "", "path to TLS private key (PEM)")
	flag.StringVar(&cfg.caPath, "ca", "", "path to CA bundle for client verification")
	flag.BoolVar(&cfg.requireClientCert, "require-client-cert", false, "enforce mutual TLS by verifying client certificates")
	flag.StringVar(&cfg.logPath, "log-file", "", "optional log file path")
	flag.Parse()

	if cfg.listenAddr == "" || cfg.targetAddr == "" {
		log.Fatal("both --listen and --target must be provided")
	}
	if cfg.certPath == "" || cfg.keyPath == "" {
		log.Fatal("--cert and --key must be provided")
	}
	if cfg.requireClientCert && cfg.caPath == "" {
		log.Fatal("--ca is required when --require-client-cert is set")
	}

	return cfg
}

func buildTLSConfig(cfg proxyConfig) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(cfg.certPath, cfg.keyPath)
	if err != nil {
		return nil, fmt.Errorf("load keypair: %w", err)
	}

	tlsConf := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}

	if cfg.requireClientCert {
		caPEM, err := os.ReadFile(cfg.caPath)
		if err != nil {
			return nil, fmt.Errorf("read CA file: %w", err)
		}

		pool := x509.NewCertPool()
		if ok := pool.AppendCertsFromPEM(caPEM); !ok {
			return nil, errInvalidCAFile
		}
		tlsConf.ClientCAs = pool
		tlsConf.ClientAuth = tls.RequireAndVerifyClientCert
	}

	return tlsConf, nil
}

func handleConnection(logger *log.Logger, clientConn net.Conn, target string) {
	defer func() {
		if err := clientConn.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			logger.Printf("close client connection: %v", err)
		}
	}()
	logPrefix := fmt.Sprintf("client %s -> %s", clientConn.RemoteAddr(), target)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	serverConn, err := (&net.Dialer{}).DialContext(ctx, "tcp", target)
	if err != nil {
		logger.Printf("%s: backend dial failed: %v", logPrefix, err)
		return
	}
	defer func() {
		if err := serverConn.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			logger.Printf("%s: close server connection: %v", logPrefix, err)
		}
	}()

	errCh := make(chan error, 2)

	go proxyCopy(errCh, serverConn, clientConn)
	go proxyCopy(errCh, clientConn, serverConn)

	if err := <-errCh; err != nil && !errors.Is(err, io.EOF) {
		logger.Printf("%s: %v", logPrefix, err)
	}
}

func proxyCopy(errCh chan<- error, dst net.Conn, src net.Conn) {
	_, copyErr := io.Copy(dst, src)
	closeErr := dst.Close()
	var resultErr error
	if copyErr != nil {
		resultErr = copyErr
	} else if closeErr != nil && !errors.Is(closeErr, net.ErrClosed) {
		resultErr = fmt.Errorf("close destination: %w", closeErr)
	}
	errCh <- resultErr
}
