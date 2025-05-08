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

package cli

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// Default paths and settings
const (
	defaultWorkDir   = "/tmp/serviceradar-tls"
	defaultDaysValid = 3650
	defaultCertPerms = 0644
	defaultKeyPerms  = 0600
)

func newLogStyles() logStyles {
	return logStyles{
		info: lipgloss.NewStyle().
			Foreground(lipgloss.Color(draculaCyan)),
		success: lipgloss.NewStyle().
			Foreground(lipgloss.Color(draculaGreen)),
		warning: lipgloss.NewStyle().
			Foreground(lipgloss.Color(draculaYellow)),
		error: lipgloss.NewStyle().
			Foreground(lipgloss.Color(draculaRed)).
			Bold(true),
	}
}

// GenerateTLSCerts generates mTLS certificates for ServiceRadar and Proton.
func GenerateTLSCerts(cfg *CmdConfig) error {
	styles := newLogStyles()

	// Initialize service IPs
	serviceIPs, err := initializeServiceIPs(cfg, &styles)
	if err != nil {
		return err
	}

	// Create certificate directories
	err = createCertDirs(cfg.CertDir, cfg.ProtonDir, &styles)
	if err != nil {
		return err
	}

	fmt.Println(styles.info.Render("[INFO] Starting TLS certificate setup for ServiceRadar components"))

	// Default components if none specified
	components := cfg.Components
	if len(components) == 0 {
		components = []string{
			"core", "proton", "agent", "poller", "kv", "sync", "nats", "web",
			"sysmon", "snmp", "rperf", "rperf-checker", "dusk-checker",
		}
	}

	if cfg.AddIPs {
		return addIPsToCerts(cfg, serviceIPs, &styles, components)
	}

	rootCA, rootKey, err := generateRootCA(cfg, &styles)
	if err != nil {
		return err
	}

	// Generate certificates for each component
	for _, component := range components {
		certName := component
		switch component {
		case "proton":
			certName = "core" // Proton uses core certificates
		case "nats":
			certName = "nats-server"
		case "dusk-checker":
			certName = "checkers"
		case "rperf":
			continue // rperf doesn't use mTLS in config
		}

		if err := generateServiceCert(certName, serviceIPs, rootCA, rootKey, &styles); err != nil {
			return fmt.Errorf("failed to generate certificate for %s: %w", component, err)
		}
	}

	if err := installCertificates(cfg, &styles, components); err != nil {
		return err
	}

	showPostInstallInfo(cfg, serviceIPs, &styles, components)

	fmt.Println(styles.success.Render("[SUCCESS] TLS certificate setup complete!"))

	return nil
}

// initializeServiceIPs determines the IP addresses to use for certificates.
func initializeServiceIPs(cfg *CmdConfig, styles *logStyles) (string, error) {
	if cfg.IPS != "" {
		// Validate provided IPs
		if err := validateIPs(cfg.IPS); err != nil {
			return "", fmt.Errorf("%w: invalid IP address format", err)
		}

		// Ensure 127.0.0.1 is included
		if !strings.Contains(cfg.IPS, "127.0.0.1") {
			return cfg.IPS + ",127.0.0.1", nil
		}

		return cfg.IPS, nil
	}

	if cfg.NonInteractive {
		fmt.Println(styles.info.Render("[INFO] Non-interactive mode: Using localhost (127.0.0.1) for certificates"))
		return "127.0.0.1", nil
	}

	// Auto-detect local IP
	localIP, err := getLocalIP()
	if err != nil {
		localIP = defaultIPAddress
	}

	serviceIPs := localIP + ",127.0.0.1"

	fmt.Println(styles.info.Render("[INFO] Auto-detected IP addresses: " + serviceIPs))

	return serviceIPs, nil
}

// validateIPs checks if the provided IPs are valid.
func validateIPs(ips string) error {
	var ipRegex = regexp.MustCompile(`^\d{1,3}(\.\d{1,3}){3}$`)

	ipArray := strings.Split(ips, ",")

	for _, ip := range ipArray {
		if !ipRegex.MatchString(ip) {
			return fmt.Errorf("%w: %s", ErrInvalidIPFormat, ip)
		}
	}

	return nil
}

const (
	defaultDirPerms = 0755
)

// createCertDirs creates the necessary certificate directories.
func createCertDirs(certDir, protonDir string, styles *logStyles) error {
	fmt.Println(styles.info.Render("[INFO] Creating certificate directories..."))

	for _, dir := range []string{certDir, protonDir, defaultWorkDir} {
		if err := os.MkdirAll(dir, defaultDirPerms); err != nil {
			return fmt.Errorf("failed to create directory %s: %w", dir, err)
		}
	}

	return nil
}

// generateRootCA generates the root CA certificate and key.
func generateRootCA(cfg *CmdConfig, styles *logStyles) (*x509.Certificate, *ecdsa.PrivateKey, error) {
	fmt.Println(styles.info.Render("[INFO] Generating root CA certificate..."))

	rootPEM := filepath.Join(cfg.CertDir, "root.pem")
	if _, err := os.Stat(rootPEM); err == nil {
		fmt.Println(styles.warning.Render("[WARNING] Root CA already exists at " + rootPEM))
		fmt.Println(styles.warning.Render("[WARNING] If you want to create new certificates, remove existing ones first"))
		fmt.Println(styles.warning.Render("[WARNING] or use --add-ips to add IPs to existing certificates"))

		return nil, nil, ErrRootCAExists
	}

	// Generate ECDSA private key
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to generate root CA key: %w", err)
	}

	// Create root CA certificate
	serial, err := randSerial()
	if err != nil {
		return nil, nil, err
	}

	notBefore := time.Now()
	notAfter := notBefore.Add(defaultDaysValid * 24 * time.Hour)

	template := x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			Country:            []string{"US"},
			Province:           []string{"CA"},
			Locality:           []string{"San Francisco"},
			Organization:       []string{"ServiceRadar"},
			OrganizationalUnit: []string{"Operations"},
			CommonName:         "ServiceRadar CA",
		},
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &priv.PublicKey, priv)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create root CA certificate: %w", err)
	}

	rootCert, err := x509.ParseCertificate(derBytes)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to parse root CA certificate: %w", err)
	}

	// Save root CA certificate
	if err := saveCertificate(rootCert, filepath.Join(defaultWorkDir, "root.pem")); err != nil {
		return nil, nil, err
	}

	if err := saveCertificate(rootCert, filepath.Join(cfg.CertDir, "root.pem")); err != nil {
		return nil, nil, err
	}

	if err := saveCertificate(rootCert, filepath.Join(cfg.ProtonDir, "ca-cert.pem")); err != nil {
		return nil, nil, err
	}

	// Save root CA private key
	if err := savePrivateKey(priv, filepath.Join(defaultWorkDir, "root-key.pem")); err != nil {
		return nil, nil, err
	}

	fmt.Println(styles.success.Render("[SUCCESS] Root CA generated and installed"))

	return rootCert, priv, nil
}

// generateServiceCert generates a service certificate with SAN.
func generateServiceCert(service, ips string, rootCA *x509.Certificate, rootKey *ecdsa.PrivateKey, styles *logStyles) error {
	fmt.Println(styles.info.Render("[INFO] Generating certificate for " + service + "..."))

	// Generate private key
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return fmt.Errorf("failed to generate %s key: %w", service, err)
	}

	// Create and sign certificate
	cert, err := createServiceCertificate(service, ips, priv, rootCA, rootKey)
	if err != nil {
		return fmt.Errorf("failed to create %s certificate: %w", service, err)
	}

	// Save certificate and key
	if err := saveServiceCertAndKey(service, cert, priv); err != nil {
		return fmt.Errorf("failed to save %s certificate: %w", service, err)
	}

	// Log certificate details
	logCertificateDetails(cert, styles)

	fmt.Println(styles.success.Render("[SUCCESS] " + service + " certificate generated successfully"))

	return nil
}

// createServiceCertificate creates and signs a service certificate.
func createServiceCertificate(
	service, ips string,
	priv *ecdsa.PrivateKey,
	rootCA *x509.Certificate,
	rootKey *ecdsa.PrivateKey) (*x509.Certificate, error) {
	// Generate serial number
	serial, err := randSerial()
	if err != nil {
		return nil, err
	}

	// Parse IP addresses
	ipAddresses, err := parseIPAddresses(ips)
	if err != nil {
		return nil, err
	}

	// Create certificate template
	template := x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			Country:            []string{"US"},
			Province:           []string{"CA"},
			Locality:           []string{"San Francisco"},
			Organization:       []string{"ServiceRadar"},
			OrganizationalUnit: []string{"Operations"},
			CommonName:         service + ".serviceradar",
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().Add(defaultDaysValid * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		BasicConstraintsValid: true,
		IPAddresses:           ipAddresses,
	}

	// Create certificate
	derBytes, err := x509.CreateCertificate(rand.Reader, &template, rootCA, &priv.PublicKey, rootKey)
	if err != nil {
		return nil, fmt.Errorf("failed to create certificate: %w", err)
	}

	// Parse certificate
	cert, err := x509.ParseCertificate(derBytes)
	if err != nil {
		return nil, fmt.Errorf("failed to parse certificate: %w", err)
	}

	// Verify certificate
	roots := x509.NewCertPool()
	roots.AddCert(rootCA)

	if _, err := cert.Verify(x509.VerifyOptions{Roots: roots}); err != nil {
		return nil, fmt.Errorf("certificate verification failed: %w", err)
	}

	return cert, nil
}

// parseIPAddresses converts a comma-separated IP string into a slice of net.IP.
func parseIPAddresses(ips string) ([]net.IP, error) {
	ipAddresses := make([]net.IP, 0, len(strings.Split(ips, ",")))

	for _, ipStr := range strings.Split(ips, ",") {
		ip := net.ParseIP(ipStr)
		if ip == nil {
			return nil, fmt.Errorf("%w: %s", ErrInvalidIPAddress, ipStr)
		}

		ipAddresses = append(ipAddresses, ip)
	}

	return ipAddresses, nil
}

// saveServiceCertAndKey saves the certificate and private key to files.
func saveServiceCertAndKey(service string, cert *x509.Certificate, priv *ecdsa.PrivateKey) error {
	certPath := filepath.Join(defaultWorkDir, service+".pem")
	if err := saveCertificate(cert, certPath); err != nil {
		return err
	}

	keyPath := filepath.Join(defaultWorkDir, service+"-key.pem")
	if err := savePrivateKey(priv, keyPath); err != nil {
		return err
	}

	return nil
}

// logCertificateDetails logs the certificate's subject, issuer, and SANs.
func logCertificateDetails(cert *x509.Certificate, styles *logStyles) {
	fmt.Println(styles.info.Render("[INFO] Certificate details:"))
	fmt.Println(styles.info.Render("  Subject: CN=" + cert.Subject.CommonName))
	fmt.Println(styles.info.Render("  Issuer: CN=" + cert.Issuer.CommonName))

	san := "  X509v3 Subject Alternative Name: "

	for i, ip := range cert.IPAddresses {
		if i > 0 {
			san += ", "
		}

		san += "IP Address:" + ip.String()
	}

	fmt.Println(styles.info.Render(san))
}

// installCertificates installs the generated certificates for ServiceRadar and Proton.
func installCertificates(cfg *CmdConfig, styles *logStyles, components []string) error {
	fmt.Println(styles.info.Render("[INFO] Installing certificates..."))

	// Copy certificates
	copies := []struct {
		src, dst string
	}{
		// Common root CA
		{filepath.Join(defaultWorkDir, "root.pem"), filepath.Join(cfg.CertDir, "root.pem")},
		{filepath.Join(defaultWorkDir, "core.pem"), filepath.Join(cfg.ProtonDir, "root.pem")},
		{filepath.Join(defaultWorkDir, "core-key.pem"), filepath.Join(cfg.ProtonDir, "core-key.pem")},
		{filepath.Join(defaultWorkDir, "core.pem"), filepath.Join(cfg.CertDir, "core.pem")},
		{filepath.Join(defaultWorkDir, "core-key.pem"), filepath.Join(cfg.CertDir, "core-key.pem")},
		// Proton-specific
		{filepath.Join(defaultWorkDir, "root.pem"), filepath.Join(cfg.ProtonDir, "ca-cert.pem")},
	}

	// Add component-specific certificates
	for _, component := range components {
		certName := component
		switch component {
		case "proton":
			continue // Handled above
		case "nats":
			certName = "nats-server"
		case "dusk-checker":
			certName = "checkers"
		case "rperf":
			continue // No mTLS
		}
		copies = append(copies,
			struct{ src, dst string }{filepath.Join(defaultWorkDir, certName+".pem"), filepath.Join(cfg.CertDir, certName+".pem")},
			struct{ src, dst string }{filepath.Join(defaultWorkDir, certName+"-key.pem"), filepath.Join(cfg.CertDir, certName+"-key.pem")},
		)
	}

	for _, c := range copies {
		if err := copyFile(c.src, c.dst); err != nil {
			return fmt.Errorf("failed to copy %s to %s: %w", c.src, c.dst, err)
		}
	}

	// Set permissions
	permSettings := map[string]os.FileMode{
		filepath.Join(cfg.CertDir, "root.pem"):       defaultCertPerms,
		filepath.Join(cfg.CertDir, "core.pem"):       defaultCertPerms,
		filepath.Join(cfg.ProtonDir, "ca-cert.pem"):  defaultCertPerms,
		filepath.Join(cfg.ProtonDir, "root.pem"):     defaultCertPerms,
		filepath.Join(cfg.CertDir, "core-key.pem"):   defaultKeyPerms,
		filepath.Join(cfg.ProtonDir, "core-key.pem"): defaultKeyPerms,
	}

	for _, component := range components {
		certName := component
		switch component {
		case "proton":
			continue
		case "nats":
			certName = "nats-server"
		case "dusk-checker":
			certName = "checkers"
		case "rperf":
			continue
		}
		permSettings[filepath.Join(cfg.CertDir, certName+".pem")] = defaultCertPerms
		permSettings[filepath.Join(cfg.CertDir, certName+"-key.pem")] = defaultKeyPerms
	}

	for path, perm := range permSettings {
		if err := os.Chmod(path, perm); err != nil {
			return fmt.Errorf("failed to set permissions for %s: %w", path, err)
		}
	}

	// Set ownership
	if err := setCertificateOwnership(cfg, components); err != nil {
		fmt.Println(styles.warning.Render("[WARNING] Failed to set ownership: " + err.Error()))
	}

	fmt.Println(styles.success.Render("[SUCCESS] Certificates installed"))

	return nil
}

// copyCertificates copies certificate and key files to ServiceRadar and Proton directories.
func copyCertificates(cfg *CmdConfig) error {
	copies := []struct {
		src, dst string
	}{
		{filepath.Join(defaultWorkDir, "core.pem"), filepath.Join(cfg.CertDir, "core.pem")},
		{filepath.Join(defaultWorkDir, "core-key.pem"), filepath.Join(cfg.CertDir, "core-key.pem")},
		{filepath.Join(defaultWorkDir, "core.pem"), filepath.Join(cfg.ProtonDir, "root.pem")},
		{filepath.Join(defaultWorkDir, "core-key.pem"), filepath.Join(cfg.ProtonDir, "core-key.pem")},
	}

	for _, c := range copies {
		if err := copyFile(c.src, c.dst); err != nil {
			return fmt.Errorf("failed to copy %s to %s: %w", c.src, c.dst, err)
		}
	}

	return nil
}

// setCertificatePermissions sets permissions for certificate and key files.
func setCertificatePermissions(cfg *CmdConfig) error {
	permSettings := map[string]os.FileMode{
		filepath.Join(cfg.CertDir, "root.pem"):       defaultCertPerms,
		filepath.Join(cfg.CertDir, "core.pem"):       defaultCertPerms,
		filepath.Join(cfg.ProtonDir, "ca-cert.pem"):  defaultCertPerms,
		filepath.Join(cfg.ProtonDir, "root.pem"):     defaultCertPerms,
		filepath.Join(cfg.CertDir, "core-key.pem"):   defaultKeyPerms,
		filepath.Join(cfg.ProtonDir, "core-key.pem"): defaultKeyPerms,
	}

	for path, perm := range permSettings {
		if err := os.Chmod(path, perm); err != nil {
			return fmt.Errorf("failed to set permissions for %s: %w", path, err)
		}
	}

	return nil
}

// setCertificateOwnership sets ownership for certificate files if users exist.
func setCertificateOwnership(cfg *CmdConfig, components []string) error {
	var errors []string

	// Proton files
	if userExists("proton") {
		protonFiles := []string{
			filepath.Join(cfg.ProtonDir, "ca-cert.pem"),
			filepath.Join(cfg.ProtonDir, "root.pem"),
			filepath.Join(cfg.ProtonDir, "core-key.pem"),
		}
		if err := setOwnershipForFiles(protonFiles, "proton"); err != nil {
			errors = append(errors, fmt.Sprintf("proton files: %v", err))
		}
	}

	// ServiceRadar files
	if userExists("serviceradar") {
		radarFiles := []string{
			filepath.Join(cfg.CertDir, "root.pem"),
			filepath.Join(cfg.CertDir, "core.pem"),
			filepath.Join(cfg.CertDir, "core-key.pem"),
		}
		for _, component := range components {
			certName := component
			switch component {
			case "proton":
				continue
			case "nats":
				certName = "nats-server"
			case "dusk-checker":
				certName = "checkers"
			case "rperf":
				continue
			}
			radarFiles = append(radarFiles,
				filepath.Join(cfg.CertDir, certName+".pem"),
				filepath.Join(cfg.CertDir, certName+"-key.pem"),
			)
		}
		if err := setOwnershipForFiles(radarFiles, "serviceradar"); err != nil {
			errors = append(errors, fmt.Sprintf("serviceradar files: %v", err))
		}
	}

	// NATS files
	if userExists("nats") {
		natsFiles := []string{
			filepath.Join(cfg.CertDir, "nats-server.pem"),
			filepath.Join(cfg.CertDir, "nats-server-key.pem"),
		}
		if err := setOwnershipForFiles(natsFiles, "nats"); err != nil {
			errors = append(errors, fmt.Sprintf("nats files: %v", err))
		}
	}

	if len(errors) > 0 {
		return fmt.Errorf("%w: %s", ErrSettingOwnership, strings.Join(errors, "; "))
	}

	return nil
}

// setOwnershipForFiles sets ownership for a list of files to the specified user.
func setOwnershipForFiles(files []string, username string) error {
	uid := getUID(username)
	gid := getGID(username)

	if uid == -1 || gid == -1 {
		return fmt.Errorf("%w: %s", ErrInvalidUIDGID, username)
	}

	var errors []string

	for _, file := range files {
		if err := syscall.Chown(file, uid, gid); err != nil {
			errors = append(errors, fmt.Sprintf("failed to set ownership for %s: %v", file, err))
		}
	}

	if len(errors) > 0 {
		return fmt.Errorf("%w: %s", ErrChownFailed, strings.Join(errors, "; "))
	}

	return nil
}

// addIPsToCerts adds IPs to existing certificates.
func addIPsToCerts(cfg *CmdConfig, serviceIPs string, styles *logStyles, components []string) error {
	fmt.Println(styles.info.Render("[INFO] Adding IPs to existing certificates..."))

	// Load root CA and key
	rootCert, rootKey, err := loadRootCACertAndKey(cfg.CertDir, styles)
	if err != nil {
		return fmt.Errorf("failed to load root CA: %w", err)
	}

	// Generate new certificates with combined IPs
	for _, component := range components {
		certName := component
		switch component {
		case "proton":
			certName = "core"
		case "nats":
			certName = "nats-server"
		case "dusk-checker":
			certName = "checkers"
		case "rperf":
			continue
		}

		// Load existing certificate
		certPath := filepath.Join(cfg.CertDir, certName+".pem")
		if component == "proton" {
			certPath = filepath.Join(cfg.ProtonDir, "root.pem")
		}
		existingCert, err := loadCertificate(certPath)
		if err != nil {
			return fmt.Errorf("failed to load certificate for %s: %w", component, err)
		}

		// Merge IPs
		existingIPs := strings.Join(ipSliceToStringSlice(existingCert.IPAddresses), ",")
		allIPs := mergeIPs(existingIPs, serviceIPs)
		fmt.Println(styles.info.Render("[INFO] Combined IPs for " + component + ": " + allIPs))

		// Generate new certificate
		if err := generateServiceCert(certName, allIPs, rootCert, rootKey, styles); err != nil {
			return fmt.Errorf("failed to generate new certificate for %s: %w", component, err)
		}
	}

	// Install new certificates
	if err := installCertificates(cfg, styles, components); err != nil {
		return fmt.Errorf("failed to install certificates: %w", err)
	}

	fmt.Println(styles.success.Render("[SUCCESS] IPs added to certificates"))

	return nil
}

// loadCertificate reads and parses a certificate from a PEM file.
func loadCertificate(path string) (*x509.Certificate, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("%w: %s; run without --add-ips first", ErrCertNotFound, path)
		}

		return nil, fmt.Errorf("failed to read certificate: %w", err)
	}

	block, _ := pem.Decode(data)
	if block == nil {
		return nil, ErrDecodeCertPEM
	}

	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("failed to parse certificate: %w", err)
	}

	return cert, nil
}

// loadRootCACertAndKey loads the root CA certificate and private key.
func loadRootCACertAndKey(certDir string, styles *logStyles) (*x509.Certificate, *ecdsa.PrivateKey, error) {
	// Load root CA certificate
	rootCert, err := loadCertificate(filepath.Join(certDir, "root.pem"))
	if err != nil {
		return nil, nil, err
	}

	// Determine key path with fallback
	keyPath := filepath.Join(certDir, "root-key.pem")
	if _, err = os.Stat(keyPath); os.IsNotExist(err) {
		keyPath = filepath.Join(certDir, "core-key.pem")

		fmt.Println(styles.warning.Render("[WARNING] Root CA key not found, using core-key.pem as a fallback"))
	}

	// Load root CA key
	data, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to read root CA key: %w", err)
	}

	block, _ := pem.Decode(data)
	if block == nil {
		return nil, nil, ErrDecodeRootCAKeyPEM
	}

	key, err := x509.ParseECPrivateKey(block.Bytes)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to parse root CA key: %w", err)
	}

	return rootCert, key, nil
}

// mergeIPs combines and deduplicates IP addresses.
func mergeIPs(existingIPs, newIPs string) string {
	combined := existingIPs

	if combined != "" && newIPs != "" {
		combined += ","
	}

	combined += newIPs

	ips := strings.Split(combined, ",")
	uniqueIPs := make(map[string]bool)

	for _, ip := range ips {
		uniqueIPs[ip] = true
	}

	result := make([]string, 0, len(uniqueIPs))
	for ip := range uniqueIPs {
		result = append(result, ip)
	}

	return strings.Join(result, ",")
}

// showPostInstallInfo displays post-installation instructions.
func showPostInstallInfo(cfg *CmdConfig, serviceIPs string, styles *logStyles, components []string) {
	ips := strings.Split(serviceIPs, ",")
	fmt.Println()
	fmt.Println(lipgloss.NewStyle().Bold(true).Render("TLS Certificate Setup Complete"))
	fmt.Println()
	fmt.Println("Certificates have been installed with the following IPs:")
	for _, ip := range ips {
		fmt.Println("  - " + styles.info.Render(ip))
	}
	fmt.Println()
	fmt.Println(lipgloss.NewStyle().Bold(true).Render("Certificate locations:"))
	for _, component := range components {
		certName := component
		certPath := cfg.CertDir
		switch component {
		case "proton":
			certName = "core"
			certPath = cfg.ProtonDir
		case "nats":
			certName = "nats-server"
		case "dusk-checker":
			certName = "checkers"
		case "rperf":
			continue
		}
		fmt.Println("  - " + component + ": " +
			styles.info.Render(fmt.Sprintf("%s/%s.pem, %s/%s-key.pem", certPath, certName, certPath, certName)))
	}
	fmt.Println()
	fmt.Println(lipgloss.NewStyle().Bold(true).Render("Next steps:"))
	fmt.Println("1. If you need to add more IPs later, run:")
	fmt.Println("   serviceradar generate-tls --add-ips --ip new.ip.address")
	fmt.Println()
	fmt.Println("2. To restart services with new certificates:")
	fmt.Println("   systemctl restart serviceradar-*")
	fmt.Println()
}

// saveCertificate saves a certificate to a PEM file.
func saveCertificate(cert *x509.Certificate, path string) error {
	pemData := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: cert.Raw,
	})
	if err := os.WriteFile(path, pemData, defaultCertPerms); err != nil {
		return fmt.Errorf("failed to write certificate to %s: %w", path, err)
	}

	return nil
}

// savePrivateKey saves an ECDSA private key to a PEM file.
func savePrivateKey(key *ecdsa.PrivateKey, path string) error {
	keyBytes, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return fmt.Errorf("failed to marshal private key: %w", err)
	}

	pemData := pem.EncodeToMemory(&pem.Block{
		Type:  "EC PRIVATE KEY",
		Bytes: keyBytes,
	})
	if err := os.WriteFile(path, pemData, defaultKeyPerms); err != nil {
		return fmt.Errorf("failed to write private key to %s: %w", path, err)
	}

	return nil
}

// copyFile copies a file from src to dst.
func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return fmt.Errorf("failed to read %s: %w", src, err)
	}

	if err := os.WriteFile(dst, data, defaultCertPerms); err != nil {
		return fmt.Errorf("failed to write %s: %w", dst, err)
	}

	return nil
}

const (
	defaultLshShift = 128
)

// randSerial generates a random serial number.
func randSerial() (*big.Int, error) {
	serialNumberLimit := new(big.Int).Lsh(big.NewInt(1), defaultLshShift)

	serial, err := rand.Int(rand.Reader, serialNumberLimit)
	if err != nil {
		return nil, fmt.Errorf("failed to generate serial number: %w", err)
	}

	return serial, nil
}

// userExists checks if a user exists.
func userExists(username string) bool {
	_, err := exec.Command("getent", "passwd", username).Output()

	return err == nil
}

// getUID retrieves the UID for a user.
func getUID(username string) int {
	cmd := exec.Command("id", "-u", username)

	output, err := cmd.Output()
	if err != nil {
		return -1
	}

	uid, err := strconv.Atoi(strings.TrimSpace(string(output)))
	if err != nil {
		return -1
	}

	return uid
}

// getGID retrieves the GID for a user.
func getGID(username string) int {
	cmd := exec.Command("id", "-g", username)

	output, err := cmd.Output()
	if err != nil {
		return -1
	}

	gid, err := strconv.Atoi(strings.TrimSpace(string(output)))
	if err != nil {
		return -1
	}

	return gid
}

// ipSliceToStringSlice converts a slice of net.IP to strings.
func ipSliceToStringSlice(ips []net.IP) []string {
	result := make([]string, 0, len(ips))

	for _, ip := range ips {
		result = append(result, ip.String())
	}

	return result
}
