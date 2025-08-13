package kv

import (
	"log"
	"path/filepath"
)

// Validate ensures the configuration is valid.
func (c *Config) Validate() error {
	// Set defaults first, before validation
	c.setDefaultBucket()
	c.setDefaultGRPCSettings()

	if err := c.validateRequiredFields(); err != nil {
		return err
	}

	if err := c.validateSecurity(); err != nil {
		return err
	}

	c.normalizeCertPaths()

	return nil
}

// validateRequiredFields checks for mandatory top-level fields.
func (c *Config) validateRequiredFields() error {
	if c.ListenAddr == "" {
		return errListenAddrRequired
	}

	if c.NatsURL == "" {
		return errNatsURLRequired
	}

	return nil
}

// validateSecurity ensures security settings are valid.
func (c *Config) validateSecurity() error {
	if c.Security == nil || c.Security.Mode != "mtls" {
		return errSecurityRequired
	}

	tls := c.Security.TLS

	if tls.CertFile == "" {
		return errCertFileRequired
	}

	if tls.KeyFile == "" {
		return errKeyFileRequired
	}

	if tls.CAFile == "" {
		return errCAFileRequired
	}

	return nil
}

// normalizeCertPaths prepends CertDir to relative TLS file paths.
func (c *Config) normalizeCertPaths() {
	certDir := c.Security.CertDir
	if certDir == "" {
		return
	}

	tls := &c.Security.TLS

	if !filepath.IsAbs(tls.CertFile) {
		tls.CertFile = filepath.Join(certDir, tls.CertFile)
	}

	if !filepath.IsAbs(tls.KeyFile) {
		tls.KeyFile = filepath.Join(certDir, tls.KeyFile)
	}

	if !filepath.IsAbs(tls.CAFile) {
		tls.CAFile = filepath.Join(certDir, tls.CAFile)
	}

	// Always normalize ClientCAFile if it's set and relative
	if tls.ClientCAFile != "" && !filepath.IsAbs(tls.ClientCAFile) {
		tls.ClientCAFile = filepath.Join(certDir, tls.ClientCAFile)
	} else if tls.ClientCAFile == "" {
		tls.ClientCAFile = tls.CAFile // Fallback to CAFile if unset

		log.Printf("ClientCAFile unset, using CAFile: %s", tls.ClientCAFile)
	}
}

// setDefaultBucket assigns a default bucket name if none is specified.
func (c *Config) setDefaultBucket() {
	if c.Bucket == "" {
		c.Bucket = "serviceradar-kv"
	}
}

// setDefaultGRPCSettings assigns default gRPC message sizes if none are specified.
func (c *Config) setDefaultGRPCSettings() {
	if c.GRPC.MaxRecvMsgSize == "" {
		c.GRPC.MaxRecvMsgSize = "16MB"
		log.Printf("No GRPC MaxRecvMsgSize configured, using default: 16MB")
	}

	if c.GRPC.MaxSendMsgSize == "" {
		c.GRPC.MaxSendMsgSize = "16MB"
		log.Printf("No GRPC MaxSendMsgSize configured, using default: 16MB")
	}
}
