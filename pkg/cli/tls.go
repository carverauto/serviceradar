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
	defaultCertDir   = "/etc/serviceradar/certs"
	defaultProtonDir = "/etc/proton-server"
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

// GenerateTLSCerts generates mTLS certificates for ServiceRadar and Proton
func GenerateTLSCerts(cfg *CmdConfig) error {
	styles := newLogStyles()

	// Initialize service IPs
	serviceIPs, err := initializeServiceIPs(cfg, styles)
	if err != nil {
		return err
	}

	// Create certificate directories
	if err := createCertDirs(cfg.CertDir, cfg.ProtonDir, styles); err != nil {
		return err
	}

	// Main execution
	fmt.Println(styles.info.Render("[INFO] Starting TLS certificate setup for ServiceRadar and Proton"))

	if cfg.AddIPs {
		return addIPsToCerts(cfg, serviceIPs, styles)
	}

	rootCA, rootKey, err := generateRootCA(cfg, styles)
	if err != nil {
		return err
	}

	if err := generateServiceCert(cfg, "core", serviceIPs, rootCA, rootKey, styles); err != nil {
		return err
	}

	if err := installCertificates(cfg, styles); err != nil {
		return err
	}

	showPostInstallInfo(cfg, serviceIPs, styles)
	fmt.Println(styles.success.Render("[SUCCESS] TLS certificate setup complete!"))

	return nil
}

// initializeServiceIPs determines the IP addresses to use for certificates
func initializeServiceIPs(cfg *CmdConfig, styles logStyles) (string, error) {
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

// validateIPs checks if the provided IPs are valid
func validateIPs(ips string) error {
	ipArray := strings.Split(ips, ",")
	for _, ip := range ipArray {
		if !regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$`).MatchString(ip) {
			return fmt.Errorf("invalid IP address format: %s", ip)
		}
	}
	return nil
}

// createCertDirs creates the necessary certificate directories
func createCertDirs(certDir, protonDir string, styles logStyles) error {
	fmt.Println(styles.info.Render("[INFO] Creating certificate directories..."))
	for _, dir := range []string{certDir, protonDir, defaultWorkDir} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return fmt.Errorf("failed to create directory %s: %w", dir, err)
		}
	}
	return nil
}

// generateRootCA generates the root CA certificate and key
func generateRootCA(cfg *CmdConfig, styles logStyles) (*x509.Certificate, *ecdsa.PrivateKey, error) {
	fmt.Println(styles.info.Render("[INFO] Generating root CA certificate..."))

	rootPEM := filepath.Join(cfg.CertDir, "root.pem")
	if _, err := os.Stat(rootPEM); err == nil {
		fmt.Println(styles.warning.Render("[WARNING] Root CA already exists at " + rootPEM))
		fmt.Println(styles.warning.Render("[WARNING] If you want to create new certificates, remove existing ones first"))
		fmt.Println(styles.warning.Render("[WARNING] or use --add-ips to add IPs to existing certificates"))
		return nil, nil, fmt.Errorf("root CA already exists")
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

// generateServiceCert generates a service certificate with SAN
func generateServiceCert(cfg *CmdConfig, service, ips string, rootCA *x509.Certificate, rootKey *ecdsa.PrivateKey, styles logStyles) error {
	fmt.Println(styles.info.Render("[INFO] Generating certificate for " + service + "..."))

	// Generate ECDSA private key
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return fmt.Errorf("failed to generate %s key: %w", service, err)
	}

	// Create service certificate
	serial, err := randSerial()
	if err != nil {
		return err
	}

	notBefore := time.Now()
	notAfter := notBefore.Add(defaultDaysValid * 24 * time.Hour)

	ipAddresses := []net.IP{}
	for _, ipStr := range strings.Split(ips, ",") {
		ipAddresses = append(ipAddresses, net.ParseIP(ipStr))
	}

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
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		BasicConstraintsValid: true,
		IPAddresses:           ipAddresses,
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, &template, rootCA, &priv.PublicKey, rootKey)
	if err != nil {
		return fmt.Errorf("failed to create %s certificate: %w", service, err)
	}

	serviceCert, err := x509.ParseCertificate(derBytes)
	if err != nil {
		return fmt.Errorf("failed to parse %s certificate: %w", service, err)
	}

	// Verify certificate
	roots := x509.NewCertPool()
	roots.AddCert(rootCA)
	_, err = serviceCert.Verify(x509.VerifyOptions{
		Roots: roots,
	})
	if err != nil {
		return fmt.Errorf("certificate verification failed: %w", err)
	}

	// Save service certificate and key
	if err := saveCertificate(serviceCert, filepath.Join(defaultWorkDir, service+".pem")); err != nil {
		return err
	}
	if err := savePrivateKey(priv, filepath.Join(defaultWorkDir, service+"-key.pem")); err != nil {
		return err
	}

	// Show certificate info
	fmt.Println(styles.info.Render("[INFO] Certificate details:"))
	fmt.Println(styles.info.Render("  Subject: CN=" + serviceCert.Subject.CommonName))
	fmt.Println(styles.info.Render("  Issuer: CN=" + serviceCert.Issuer.CommonName))
	san := "  X509v3 Subject Alternative Name: "
	for i, ip := range serviceCert.IPAddresses {
		if i > 0 {
			san += ", "
		}
		san += "IP Address:" + ip.String()
	}
	fmt.Println(styles.info.Render(san))

	fmt.Println(styles.success.Render("[SUCCESS] " + service + " certificate generated successfully"))
	return nil
}

// installCertificates installs the generated certificates
func installCertificates(cfg *CmdConfig, styles logStyles) error {
	fmt.Println(styles.info.Render("[INFO] Installing certificates..."))

	// Install ServiceRadar certificates
	if err := copyFile(filepath.Join(defaultWorkDir, "core.pem"), filepath.Join(cfg.CertDir, "core.pem")); err != nil {
		return err
	}
	if err := copyFile(filepath.Join(defaultWorkDir, "core-key.pem"), filepath.Join(cfg.CertDir, "core-key.pem")); err != nil {
		return err
	}

	// Install Proton certificates
	if err := copyFile(filepath.Join(defaultWorkDir, "core.pem"), filepath.Join(cfg.ProtonDir, "root.pem")); err != nil {
		return err
	}
	if err := copyFile(filepath.Join(defaultWorkDir, "core-key.pem"), filepath.Join(cfg.ProtonDir, "core-key.pem")); err != nil {
		return err
	}

	// Set permissions
	for _, file := range []string{
		filepath.Join(cfg.CertDir, "root.pem"),
		filepath.Join(cfg.CertDir, "core.pem"),
		filepath.Join(cfg.ProtonDir, "ca-cert.pem"),
		filepath.Join(cfg.ProtonDir, "root.pem"),
	} {
		if err := os.Chmod(file, defaultCertPerms); err != nil {
			return fmt.Errorf("failed to set permissions for %s: %w", file, err)
		}
	}
	for _, file := range []string{
		filepath.Join(cfg.CertDir, "core-key.pem"),
		filepath.Join(cfg.ProtonDir, "core-key.pem"),
	} {
		if err := os.Chmod(file, defaultKeyPerms); err != nil {
			return fmt.Errorf("failed to set permissions for %s: %w", file, err)
		}
	}

	// Set ownership if users exist
	if userExists("proton") {
		for _, file := range []string{
			filepath.Join(cfg.ProtonDir, "ca-cert.pem"),
			filepath.Join(cfg.ProtonDir, "root.pem"),
			filepath.Join(cfg.ProtonDir, "core-key.pem"),
		} {
			if err := syscall.Chown(file, getUID("proton"), getGID("proton")); err != nil {
				fmt.Println(styles.warning.Render("[WARNING] Failed to set ownership for " + file))
			}
		}
	}
	if userExists("serviceradar") {
		for _, file := range []string{
			filepath.Join(cfg.CertDir, "root.pem"),
			filepath.Join(cfg.CertDir, "core.pem"),
			filepath.Join(cfg.CertDir, "core-key.pem"),
		} {
			if err := syscall.Chown(file, getUID("serviceradar"), getGID("serviceradar")); err != nil {
				fmt.Println(styles.warning.Render("[WARNING] Failed to set ownership for " + file))
			}
		}
	}

	fmt.Println(styles.success.Render("[SUCCESS] Certificates installed"))
	return nil
}

// addIPsToCerts adds IPs to existing certificates
func addIPsToCerts(cfg *CmdConfig, serviceIPs string, styles logStyles) error {
	fmt.Println(styles.info.Render("[INFO] Adding IPs to existing certificates..."))

	corePEM := filepath.Join(cfg.CertDir, "core.pem")
	if _, err := os.Stat(corePEM); os.IsNotExist(err) {
		return fmt.Errorf("no existing certificates found at %s; run without --add-ips first", corePEM)
	}

	// Load existing certificate
	coreCertData, err := os.ReadFile(corePEM)
	if err != nil {
		return fmt.Errorf("failed to read existing certificate: %w", err)
	}
	coreBlock, _ := pem.Decode(coreCertData)
	if coreBlock == nil {
		return fmt.Errorf("failed to decode existing certificate PEM")
	}
	coreCert, err := x509.ParseCertificate(coreBlock.Bytes)
	if err != nil {
		return fmt.Errorf("failed to parse existing certificate: %w", err)
	}

	// Extract existing IPs
	existingIPs := strings.Join(ipSliceToStringSlice(coreCert.IPAddresses), ",")
	fmt.Println(styles.info.Render("[INFO] Existing IPs in certificate: " + existingIPs))

	// Merge IPs
	allIPs := mergeIPs(existingIPs, serviceIPs)
	fmt.Println(styles.info.Render("[INFO] Combined IPs for new certificate: " + allIPs))

	// Load root CA and key
	rootPEM := filepath.Join(cfg.CertDir, "root.pem")
	rootCertData, err := os.ReadFile(rootPEM)
	if err != nil {
		return fmt.Errorf("failed to read root CA: %w", err)
	}
	rootBlock, _ := pem.Decode(rootCertData)
	if rootBlock == nil {
		return fmt.Errorf("failed to decode root CA PEM")
	}
	rootCert, err := x509.ParseCertificate(rootBlock.Bytes)
	if err != nil {
		return fmt.Errorf("failed to parse root CA: %w", err)
	}

	rootKeyPEM := filepath.Join(cfg.CertDir, "root-key.pem")
	if _, err := os.Stat(rootKeyPEM); os.IsNotExist(err) {
		rootKeyPEM = filepath.Join(cfg.CertDir, "core-key.pem")
		fmt.Println(styles.warning.Render("[WARNING] Root CA key not found, using core-key.pem as a fallback"))
	}
	rootKeyData, err := os.ReadFile(rootKeyPEM)
	if err != nil {
		return fmt.Errorf("failed to read root CA key: %w", err)
	}
	rootKeyBlock, _ := pem.Decode(rootKeyData)
	if rootKeyBlock == nil {
		return fmt.Errorf("failed to decode root CA key PEM")
	}
	rootKey, err := x509.ParseECPrivateKey(rootKeyBlock.Bytes)
	if err != nil {
		return fmt.Errorf("failed to parse root CA key: %w", err)
	}

	// Generate new certificate with combined IPs
	if err := generateServiceCert(cfg, "core", allIPs, rootCert, rootKey, styles); err != nil {
		return err
	}

	// Install new certificates
	if err := installCertificates(cfg, styles); err != nil {
		return err
	}

	fmt.Println(styles.success.Render("[SUCCESS] IPs added to certificates"))
	return nil
}

// mergeIPs combines and deduplicates IP addresses
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

	result := []string{}
	for ip := range uniqueIPs {
		result = append(result, ip)
	}

	return strings.Join(result, ",")
}

// showPostInstallInfo displays post-installation instructions
func showPostInstallInfo(cfg *CmdConfig, serviceIPs string, styles logStyles) {
	ips := strings.Split(serviceIPs, ",")
	firstIP := ips[0]

	fmt.Println()
	fmt.Println(lipgloss.NewStyle().Bold(true).Render("TLS Certificate Setup Complete"))
	fmt.Println()
	fmt.Println("Certificates have been installed with the following IPs:")
	for _, ip := range ips {
		fmt.Println("  - " + styles.info.Render(ip))
	}
	fmt.Println()
	fmt.Println(lipgloss.NewStyle().Bold(true).Render("Certificate locations:"))
	fmt.Println("  - ServiceRadar: " + styles.info.Render(fmt.Sprintf("%s/root.pem, %s/core.pem, %s/core-key.pem", cfg.CertDir, cfg.CertDir, cfg.CertDir)))
	fmt.Println("  - Proton: " + styles.info.Render(fmt.Sprintf("%s/ca-cert.pem, %s/root.pem, %s/core-key.pem", cfg.ProtonDir, cfg.ProtonDir, cfg.ProtonDir)))
	fmt.Println()
	fmt.Println(lipgloss.NewStyle().Bold(true).Render("Next steps:"))
	fmt.Println("1. Verify the Proton connection:")
	fmt.Printf("   proton-client --host %s --port 9440 --secure \\\n", firstIP)
	fmt.Printf("     --certificate-file %s/core.pem \\\n", cfg.CertDir)
	fmt.Printf("     --private-key-file %s/core-key.pem -q \"SELECT 1\"\n", cfg.CertDir)
	fmt.Println()
	fmt.Println("2. If you need to add more IPs later, run:")
	fmt.Println("   serviceradar generate-tls --add-ips --ip new.ip.address")
	fmt.Println()
	fmt.Println("3. To restart services with new certificates:")
	fmt.Println("   systemctl restart serviceradar-proton serviceradar-core")
	fmt.Println()
}

// saveCertificate saves a certificate to a PEM file
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

// savePrivateKey saves an ECDSA private key to a PEM file
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

// copyFile copies a file from src to dst
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

// randSerial generates a random serial number
func randSerial() (*big.Int, error) {
	serialNumberLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, serialNumberLimit)
	if err != nil {
		return nil, fmt.Errorf("failed to generate serial number: %w", err)
	}
	return serial, nil
}

// userExists checks if a user exists
func userExists(username string) bool {
	_, err := exec.Command("getent", "passwd", username).Output()
	return err == nil
}

// getUID retrieves the UID for a user
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

// getGID retrieves the GID for a user
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

// ipSliceToStringSlice converts a slice of net.IP to strings
func ipSliceToStringSlice(ips []net.IP) []string {
	result := []string{}
	for _, ip := range ips {
		result = append(result, ip.String())
	}
	return result
}
