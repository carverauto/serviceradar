package datasvc

import (
	"fmt"
	"log"
	"math"
	"path/filepath"
	"strings"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	securityModeMTLS   = "mtls"
	securityModeSPIFFE = "spiffe"
)

// Validate ensures the configuration is valid.
func (c *Config) Validate() error {
	if err := c.validateRequiredFields(); err != nil {
		return err
	}

	if c.BucketMaxBytes < 0 {
		return errBucketMaxBytesNegative
	}

	if err := c.validateSecurity(); err != nil {
		return err
	}

	if err := c.validateNATSSecurity(); err != nil {
		return err
	}

	c.normalizeSecurityCertPaths(c.Security)
	c.normalizeSecurityCertPaths(c.NATSSecurity)
	c.setDefaultBucket()
	c.setDefaultObjectBucket()
	c.setDefaultBucketOptions()

	if c.BucketHistory > math.MaxUint8 {
		return fmt.Errorf("%w: got %d", errBucketHistoryTooLarge, c.BucketHistory)
	}

	return nil
}

// validateRequiredFields checks for mandatory top-level fields.
func (c *Config) validateRequiredFields() error {
	if c.ListenAddr == "" {
		return errListenAddrRequired
	}

	if c.NATSURL == "" {
		return errNatsURLRequired
	}

	return nil
}

// validateSecurity ensures security settings are valid.
func (c *Config) validateSecurity() error {
	if c.Security == nil {
		return errSecurityRequired
	}

	mode := strings.ToLower(string(c.Security.Mode))

	switch mode {
	case securityModeMTLS:
	case securityModeSPIFFE:
	default:
		return fmt.Errorf("%w: %s", errInvalidSecurityMode, c.Security.Mode)
	}

	if err := validateTLSConfig(c.Security); err != nil {
		return err
	}

	return nil
}

func (c *Config) validateNATSSecurity() error {
	if c.NATSSecurity == nil {
		return errNATSSecurityRequired
	}

	mode := strings.ToLower(string(c.NATSSecurity.Mode))

	if mode != securityModeMTLS {
		return errMTLSRequired
	}

	if err := validateTLSConfig(c.NATSSecurity); err != nil {
		return err
	}

	return nil
}

func validateTLSConfig(sec *models.SecurityConfig) error {
	tls := sec.TLS

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

// normalizeSecurityCertPaths prepends CertDir to relative TLS file paths for mTLS configs.
func (c *Config) normalizeSecurityCertPaths(sec *models.SecurityConfig) {
	if sec == nil {
		return
	}

	if strings.ToLower(string(sec.Mode)) != securityModeMTLS {
		return
	}

	certDir := sec.CertDir
	if certDir == "" {
		return
	}

	tls := &sec.TLS

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
		c.Bucket = "serviceradar-datasvc"
	}
}

func (c *Config) setDefaultObjectBucket() {
	if c.ObjectBucket == "" {
		c.ObjectBucket = "serviceradar-objects"
	}
}

func (c *Config) setDefaultBucketOptions() {
	if c.BucketHistory == 0 {
		c.BucketHistory = 1
	}
	if c.BucketTTL < 0 {
		c.BucketTTL = 0
	}
	if c.BucketMaxBytes < 0 {
		c.BucketMaxBytes = 0
	}
}
