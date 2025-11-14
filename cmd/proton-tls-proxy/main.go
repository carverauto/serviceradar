package main

import (
	"crypto/tls"
	"crypto/x509"
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
		defer f.Close()
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
	defer ln.Close()

	logger.Printf("listening on %s, proxying to %s", cfg.listenAddr, cfg.targetAddr)

	signalCh := make(chan os.Signal, 1)
	signal.Notify(signalCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-signalCh
		logger.Println("shutting down listener")
		ln.Close()
	}()

	for {
		clientConn, err := ln.Accept()
		if err != nil {
			// Listener closed during shutdown.
			if ne, ok := err.(net.Error); ok && ne.Temporary() {
				logger.Printf("temporary accept error: %v", err)
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
			return nil, fmt.Errorf("failed to parse CA file")
		}
		tlsConf.ClientCAs = pool
		tlsConf.ClientAuth = tls.RequireAndVerifyClientCert
	}

	return tlsConf, nil
}

func handleConnection(logger *log.Logger, clientConn net.Conn, target string) {
	defer clientConn.Close()
	logPrefix := fmt.Sprintf("client %s -> %s", clientConn.RemoteAddr(), target)

	serverConn, err := net.DialTimeout("tcp", target, 5*time.Second)
	if err != nil {
		logger.Printf("%s: backend dial failed: %v", logPrefix, err)
		return
	}
	defer serverConn.Close()

	errCh := make(chan error, 2)

	go proxyCopy(errCh, serverConn, clientConn)
	go proxyCopy(errCh, clientConn, serverConn)

	if err := <-errCh; err != nil && err != io.EOF {
		logger.Printf("%s: %v", logPrefix, err)
	}
}

func proxyCopy(errCh chan<- error, dst net.Conn, src net.Conn) {
	_, err := io.Copy(dst, src)
	// Ensure the other side sees EOF.
	dst.Close()
	errCh <- err
}
