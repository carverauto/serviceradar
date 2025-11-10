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

// cmd/faker/main.go
package main

import (
	"context"
	cryptoRand "crypto/rand"
	_ "embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	cfgconfig "github.com/carverauto/serviceradar/pkg/config"
	cfgbootstrap "github.com/carverauto/serviceradar/pkg/config/bootstrap"
	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
	"github.com/carverauto/serviceradar/pkg/models"
)

//go:embed config.json
var defaultConfigTemplate []byte

var (
	errConfigNil                  = errors.New("config must not be nil")
	errListenAddressRequired      = errors.New("server.listen_address is required")
	errReadTimeoutRequired        = errors.New("server.read_timeout is required")
	errWriteTimeoutRequired       = errors.New("server.write_timeout is required")
	errIdleTimeoutRequired        = errors.New("server.idle_timeout is required")
	errIPShuffleIntervalRequired  = errors.New("simulation.ip_shuffle.interval is required")
	errIPShufflePercentageInvalid = errors.New("simulation.ip_shuffle.percentage must be > 0")
	errDataDirRequired            = errors.New("storage.data_dir is required")
	errDevicesFileRequired        = errors.New("storage.devices_file is required")
)

const (
	dataDirPerms = 0o755

	// Token generation constants
	tokenStringLength    = 32
	tokenExpirationHours = 24

	// Device distribution percentages
	singleIPPercent   = 60
	doubleIPPercent   = 85
	multipleIPPercent = 95

	// MAC address generation constants
	maxRetryAttempts = 3
	maxByteValue     = 255

	// Random generation ranges
	minRandomRange = 0
	maxRandomRange = 4
	ipRangeOffset  = 1000

	// Percentage distribution thresholds
	percentageBase           = 100
	lowPercentThreshold      = 60
	midPercentThreshold      = 85
	highPercentThreshold     = 95
	veryHighPercentThreshold = 99

	// MAC address count ranges
	minMACsEndUser        = 1
	maxMACsEndUser        = 5
	minMACsMultiInterface = 6
	maxMACsMultiInterface = 20
	minMACsServer         = 21
	maxMACsServer         = 50
	minMACsInfra          = 51
	maxMACsInfra          = 100
	minMACsEnterprise     = 101
	maxMACsEnterprise     = 200

	// IP count ranges
	minAdditionalIPs = 2
	maxAdditionalIPs = 3
	minMultipleIPs   = 4
	maxMultipleIPs   = 5
	minManyIPs       = 6
	maxManyIPs       = 10

	// Random string lengths (removed unused constants)

	// MacBook models
	baseMacBookSize      = 13
	macBookSizeIncrement = 3
	macBookVariants      = 3

	// Risk level ranges
	serverRiskMin  = 7
	serverRiskMax  = 10
	medicalRiskMin = 8
	medicalRiskMax = 10
	iotRiskMin     = 5
	iotRiskMax     = 8
	mobileRiskMin  = 3
	mobileRiskMax  = 6
	networkRiskMin = 6
	networkRiskMax = 9
	generalRiskMin = 1
	generalRiskMax = 5
)

type ArmisDevice struct {
	ID               int         `json:"id"`
	IPAddress        string      `json:"ipAddress"`
	MacAddress       string      `json:"macAddress"`
	MacAddresses     []string    `json:"-"` // Internal representation, ignored by JSON marshaller
	Name             string      `json:"name"`
	Type             string      `json:"type"`
	Category         string      `json:"category"`
	Manufacturer     string      `json:"manufacturer"`
	Model            string      `json:"model"`
	OperatingSystem  string      `json:"operatingSystem"`
	FirstSeen        time.Time   `json:"firstSeen"`
	LastSeen         time.Time   `json:"lastSeen"`
	RiskLevel        int         `json:"riskLevel"`
	Boundaries       string      `json:"boundaries"`
	Tags             []string    `json:"tags"`
	CustomProperties interface{} `json:"customProperties"`
	BusinessImpact   string      `json:"businessImpact"`
	Visibility       string      `json:"visibility"`
	Site             interface{} `json:"site"`
}

type SearchResponse struct {
	Data struct {
		Count   int           `json:"count"`
		Next    int           `json:"next"`
		Prev    interface{}   `json:"prev"`
		Results []ArmisDevice `json:"results"`
		Total   int           `json:"total"`
	} `json:"data"`
	Success bool `json:"success"`
}

type AccessTokenResponse struct {
	Data struct {
		AccessToken   string    `json:"access_token"`
		ExpirationUTC time.Time `json:"expiration_utc"`
	} `json:"data"`
	Success bool `json:"success"`
}

// Config holds the configuration for the faker service
type Config struct {
	Service struct {
		Name        string `json:"name"`
		Description string `json:"description"`
		Version     string `json:"version"`
	} `json:"service"`
	Server struct {
		ListenAddress string `json:"listen_address"`
		ReadTimeout   string `json:"read_timeout"`
		WriteTimeout  string `json:"write_timeout"`
		IdleTimeout   string `json:"idle_timeout"`
	} `json:"server"`
	Simulation struct {
		TotalDevices int `json:"total_devices"`
		IPShuffle    struct {
			Enabled    bool   `json:"enabled"`
			Interval   string `json:"interval"`
			Percentage int    `json:"percentage"`
			LogChanges bool   `json:"log_changes"`
		} `json:"ip_shuffle"`
	} `json:"simulation"`
	Storage struct {
		DataDir        string `json:"data_dir"`
		DevicesFile    string `json:"devices_file"`
		PersistChanges bool   `json:"persist_changes"`
	} `json:"storage"`
	Logging struct {
		Level      string `json:"level"`
		File       string `json:"file"`
		MaxSize    string `json:"max_size"`
		MaxBackups int    `json:"max_backups"`
		MaxAge     int    `json:"max_age"`
	} `json:"logging"`
}

// Validate ensures the configuration is well-formed while applying defaults for optional fields.
func (c *Config) Validate() error {
	if c == nil {
		return errConfigNil
	}

	if c.Server.ListenAddress == "" {
		return errListenAddressRequired
	}
	if c.Server.ReadTimeout == "" {
		return errReadTimeoutRequired
	}
	if c.Server.WriteTimeout == "" {
		return errWriteTimeoutRequired
	}
	if c.Server.IdleTimeout == "" {
		return errIdleTimeoutRequired
	}

	if c.Simulation.TotalDevices <= 0 {
		c.Simulation.TotalDevices = totalDevices
	}
	if c.Simulation.IPShuffle.Interval == "" {
		return errIPShuffleIntervalRequired
	}
	if c.Simulation.IPShuffle.Percentage <= 0 {
		return errIPShufflePercentageInvalid
	}
	if c.Storage.DataDir == "" {
		return errDataDirRequired
	}
	if c.Storage.DevicesFile == "" {
		return errDevicesFileRequired
	}

	return nil
}

func (c *Config) applyDefaults() {
	c.Server.ListenAddress = ":8080"
	c.Server.ReadTimeout = "10s"
	c.Server.WriteTimeout = "30s"
	c.Server.IdleTimeout = "30s"
	c.Simulation.TotalDevices = totalDevices
	c.Simulation.IPShuffle.Enabled = true
	c.Simulation.IPShuffle.Interval = "60s"
	c.Simulation.IPShuffle.Percentage = 5
	c.Simulation.IPShuffle.LogChanges = true
	c.Storage.DataDir = "/var/lib/serviceradar/faker"
	c.Storage.DevicesFile = "fake_armis_devices.json"
	c.Storage.PersistChanges = true
}

const (
	totalDevices = 50000
	// File permission constants
	deviceFilePermissions = 0o600
	// Magic number constants
	daysInThreeYears     = 1095
	daysInMonth          = 30
	maxDellOptiPlexBase  = 3000
	maxDellOptiPlexRange = 9000
	maxHPEliteDeskBase   = 800
	maxHPEliteDeskRange  = 1000
	byteMaxValue         = 0xFF
	hexByteShift         = 8
	// String constants
	appleManufacturer = "Apple"
)

// DeviceGenerator holds all the data and methods for generating fake devices
type DeviceGenerator struct {
	allDevices    []ArmisDevice
	deviceTypes   []string
	osTypes       []string
	manufacturers []string
	mu            sync.RWMutex // Add this mutex for safe concurrent access
}

// NewDeviceGenerator creates a new device generator with predefined data
func NewDeviceGenerator() *DeviceGenerator {
	return &DeviceGenerator{
		deviceTypes: []string{
			"Computer", "Laptop", "Desktop", "Workstation", "Server", "Domain Controller",
			"Mobile Phone", "Tablet", "Smartphone",
			"Printer", "Multifunction Printer", "Label Printer", "3D Printer",
			"IoT Device", "Smart Thermostat", "Security Camera", "Door Lock", "Smart Light",
			"Router", "Switch", "Access Point", "Firewall", "Load Balancer", "Gateway",
			"Network Storage", "NAS", "SAN Storage", "Backup Device",
			"Medical Device", "Industrial Controller", "PLC", "HMI",
			"Phone System", "IP Phone", "Conference Phone",
			"Gaming Console", "Smart TV", "Streaming Device", "Set Top Box",
		},
		osTypes: []string{
			"Windows 10 Pro", "Windows 11 Enterprise", "Windows Server 2019", "Windows Server 2022",
			"macOS Monterey", "macOS Ventura", "macOS Big Sur",
			"Ubuntu 20.04", "Ubuntu 22.04", "Red Hat Enterprise Linux", "CentOS", "Debian",
			"iOS 15", "iOS 16", "iPadOS", "Android 12", "Android 13", "Android 11",
			"ESXi 7.0", "ESXi 8.0", "Proxmox", "Hyper-V",
			"Cisco IOS", "Cisco NX-OS", "Juniper JunOS", "pfSense", "OPNsense",
			"Embedded Linux", "FreeRTOS", "VxWorks", "Unknown", "N/A",
		},
		manufacturers: []string{
			"Dell", "HP", "Lenovo", appleManufacturer, "Microsoft", "Asus", "Acer", "Toshiba",
			"Cisco", "Juniper", "Aruba", "Ubiquiti", "Netgear", "D-Link", "TP-Link",
			"VMware", "Citrix", "Red Hat", "Canonical", "SUSE",
			"Samsung", "Google", "Amazon", "Roku", "Nvidia", "Intel", "AMD",
			"Hikvision", "Axis", "Bosch", "Honeywell", "Johnson Controls",
			"Siemens", "Schneider Electric", "ABB", "Rockwell Automation",
			"Canon", "Epson", "Brother", "Xerox", "Ricoh",
			"Synology", "QNAP", "NetApp", "EMC", "Pure Storage",
		},
	}
}

//nolint:gochecknoglobals // Required for HTTP handlers
var (
	deviceGen *DeviceGenerator
	config    *Config
)

// Initialize sets up the device generator and loads or generates device data
func Initialize() {
	deviceGen = NewDeviceGenerator()

	// First, try to load existing device data from storage
	if deviceGen.loadFromStorage() {
		return
	}

	// No existing data found, generate new random device data
	log.Printf("Generating %d fake Armis devices with random data...", totalDevices)

	deviceGen.allDevices = deviceGen.generateAllDevices()
	log.Printf("Generated %d devices successfully", len(deviceGen.allDevices))

	// Save the generated data to persistent storage for future use
	deviceGen.saveToStorage()
}

// shuffleIPs runs as a background goroutine to simulate devices changing their IP addresses.
func shuffleIPs() {
	log.Println("Starting IP address shuffle simulation...")

	// Parse interval from config
	interval, err := time.ParseDuration(config.Simulation.IPShuffle.Interval)
	if err != nil {
		interval = 60 * time.Second
		log.Printf("Invalid shuffle interval in config, using default: %v", interval)
	}

	// Shuffle IPs on a regular interval
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for range ticker.C {
		// Acquire a full write lock to modify the device list
		deviceGen.mu.Lock()

		// Select a random percentage of devices to update based on config
		percentage := float64(config.Simulation.IPShuffle.Percentage) / 100.0
		numToShuffle := int(float64(len(deviceGen.allDevices)) * percentage)

		if config.Simulation.IPShuffle.LogChanges {
			log.Printf("--> SIMULATING IP CHANGE: Shuffling IPs for %d devices (%.1f%%)...",
				numToShuffle, percentage*100)
		}

		for i := 0; i < numToShuffle; i++ {
			// Pick a random device to modify
			deviceIndex := randInt(0, len(deviceGen.allDevices)-1)
			device := &deviceGen.allDevices[deviceIndex]

			// Generate a new primary IP address.
			// We use the current nanosecond as an offset to ensure the IP is different.
			newPrimaryIP := generateSingleIP(deviceIndex, time.Now().Nanosecond())

			// Update the device's IP address list
			ipList := strings.Split(device.IPAddress, ",")
			oldPrimaryIP := ipList[0]
			ipList[0] = newPrimaryIP
			device.IPAddress = strings.Join(ipList, ",")
			device.LastSeen = time.Now() // Update LastSeen to reflect the change

			if config.Simulation.IPShuffle.LogChanges {
				log.Printf("    Device ID %d (Name: %s) IP changed from %s to %s",
					device.ID, device.Name, oldPrimaryIP, newPrimaryIP)
			}
		}

		// Release the lock
		deviceGen.mu.Unlock()

		// Persist the changes if configured
		if config.Storage.PersistChanges {
			deviceGen.saveToStorage()
		}
	}
}

func main() {
	var configPath string

	flag.StringVar(&configPath, "config", "/etc/serviceradar/faker.json", "Path to configuration file")
	_ = flag.String("onboarding-token", "", "Edge onboarding token (if provided, triggers edge onboarding)")
	_ = flag.String("kv-endpoint", "", "KV service endpoint (required for edge onboarding)")
	flag.Parse()

	ctx := context.Background()

	// Try edge onboarding first (checks env vars if flags not set)
	onboardingResult, err := edgeonboarding.TryOnboard(ctx, models.EdgeOnboardingComponentTypeAgent, nil)
	if err != nil {
		log.Fatalf("Edge onboarding failed: %v", err)
	}

	// If onboarding was performed, use the generated config
	if onboardingResult != nil {
		configPath = onboardingResult.ConfigPath
		log.Printf("Using edge-onboarded configuration from: %s", configPath)
		log.Printf("SPIFFE ID: %s", onboardingResult.SPIFFEID)
	}

	config = &Config{}
	bootstrapResult := loadFakerConfig(ctx, configPath, config)
	if bootstrapResult != nil {
		defer func() { _ = bootstrapResult.Close() }()
	}

	log.Printf("ServiceRadar Faker %s starting...", config.Service.Version)

	// Initialize the device generator
	Initialize()

	// Start the background process to simulate IP changes if enabled
	if config.Simulation.IPShuffle.Enabled {
		go shuffleIPs()
	}

	mux := http.NewServeMux()
	// Armis API endpoints
	mux.HandleFunc("/api/v1/access_token/", tokenHandler)
	mux.HandleFunc("/api/v1/search/", searchHandler)
	// Legacy endpoint if needed
	mux.HandleFunc("/v1/devices", devicesHandler)

	// Parse durations
	readTimeout, _ := time.ParseDuration(config.Server.ReadTimeout)
	writeTimeout, _ := time.ParseDuration(config.Server.WriteTimeout)
	idleTimeout, _ := time.ParseDuration(config.Server.IdleTimeout)

	server := &http.Server{
		Addr:         config.Server.ListenAddress,
		Handler:      mux,
		ReadTimeout:  readTimeout,
		WriteTimeout: writeTimeout,
		IdleTimeout:  idleTimeout,
	}

	log.Printf("Fake Armis API starting on %s", config.Server.ListenAddress)
	log.Printf("Total devices available: %d", config.Simulation.TotalDevices)

	if config.Simulation.IPShuffle.Enabled {
		log.Printf("IP shuffle enabled: %d%% of devices every %s",
			config.Simulation.IPShuffle.Percentage,
			config.Simulation.IPShuffle.Interval)
	}

	if err := server.ListenAndServe(); err != nil {
		_ = bootstrapResult.Close()
		log.Fatalf("Server failed: %v", err) //nolint:gocritic // Close is explicitly called before Fatalf
	}
}

func loadFakerConfig(ctx context.Context, path string, cfg *Config) *cfgbootstrap.Result {
	cfg.applyDefaults()

	desc, ok := cfgconfig.ServiceDescriptorFor("faker")
	if !ok {
		log.Fatalf("faker descriptor missing")
	}

	configPath := strings.TrimSpace(path)
	if configPath == "" {
		if err := cfg.Validate(); err != nil {
			log.Fatalf("default faker configuration invalid: %v", err)
		}
		return nil
	}

	useKV := strings.EqualFold(os.Getenv("CONFIG_SOURCE"), "kv")
	resolvedPath := configPath

	info, err := os.Stat(configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			if !useKV {
				if err := cfg.Validate(); err != nil {
					log.Fatalf("default faker configuration invalid: %v", err)
				}
				log.Printf("Config file %s not found; using defaults", configPath)
				return nil
			}

			materializedPath, matErr := materializeEmbeddedConfig(configPath)
			if matErr != nil {
				log.Fatalf("Failed to materialize default faker config for KV bootstrap: %v", matErr)
			}
			log.Printf("Config file %s not found; using embedded defaults from %s for KV bootstrap", configPath, materializedPath)
			resolvedPath = materializedPath
		} else {
			if !useKV {
				log.Fatalf("Failed to inspect config file %s: %v", configPath, err)
			}

			materializedPath, matErr := materializeEmbeddedConfig(configPath)
			if matErr != nil {
				log.Fatalf("Failed to materialize fallback faker config for KV bootstrap: %v", matErr)
			}
			log.Printf("Unable to read config file %s (%v); using embedded defaults from %s for KV bootstrap", configPath, err, materializedPath)
			resolvedPath = materializedPath
		}
	} else if info.IsDir() {
		log.Fatalf("config path %s is a directory", configPath)
	}

	result, err := cfgbootstrap.ServiceWithTemplateRegistration(ctx, desc, cfg, defaultConfigTemplate, cfgbootstrap.ServiceOptions{
		Role:         models.RoleAgent,
		ConfigPath:   resolvedPath,
		DisableWatch: true,
	})
	if err != nil {
		log.Fatalf("Failed to load faker config: %v", err)
	}
	return result
}

func materializeEmbeddedConfig(targetPath string) (string, error) {
	dir, err := os.MkdirTemp("", "serviceradar-faker-config-*")
	if err != nil {
		return "", err
	}

	fullPath := filepath.Join(dir, filepath.Base(targetPath))
	if err := os.WriteFile(fullPath, defaultConfigTemplate, 0o600); err != nil {
		return "", err
	}

	return fullPath, nil
}

// tokenHandler handles POST requests for /api/v1/access_token/
func tokenHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Return a fake token
	response := AccessTokenResponse{
		Data: struct {
			AccessToken   string    `json:"access_token"`
			ExpirationUTC time.Time `json:"expiration_utc"`
		}{
			AccessToken:   "fake-token-" + generateRandomString(tokenStringLength),
			ExpirationUTC: time.Now().Add(tokenExpirationHours * time.Hour),
		},
		Success: true,
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("Error encoding token response: %v", err)
		http.Error(w, "Failed to encode response", http.StatusInternalServerError)
	}
}

// searchHandler handles GET requests for /api/v1/search/
func searchHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Parse query parameters
	lengthStr := r.URL.Query().Get("length")
	fromStr := r.URL.Query().Get("from")
	aql := r.URL.Query().Get("aql")

	length, _ := strconv.Atoi(lengthStr)
	if length <= 0 || length > 1000 {
		length = 100
	}

	from, _ := strconv.Atoi(fromStr)
	if from < 0 {
		from = 0
	}

	log.Printf("Search request - AQL: %s, from: %d, length: %d", aql, from, length)

	// Acquire a read lock before accessing the shared device list
	deviceGen.mu.RLock()
	defer deviceGen.mu.RUnlock() // Defer the unlock to ensure it's always released

	// Calculate pagination
	end := from + length
	if end > totalDevices {
		end = totalDevices
	}

	// Get the slice of devices
	var results []ArmisDevice

	if from < totalDevices {
		// Create a copy of the data slice to release the lock faster
		paginatedDevices := deviceGen.allDevices[from:end]
		results = make([]ArmisDevice, len(paginatedDevices))
		copy(results, paginatedDevices)
	}

	// Determine next page
	var next int
	if end < totalDevices {
		next = end
	}

	// Build response
	response := SearchResponse{
		Data: struct {
			Count   int           `json:"count"`
			Next    int           `json:"next"`
			Prev    interface{}   `json:"prev"`
			Results []ArmisDevice `json:"results"`
			Total   int           `json:"total"`
		}{
			Count:   len(results),
			Next:    next,
			Prev:    nil,
			Results: results,
			Total:   totalDevices,
		},
		Success: true,
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("Error encoding response: %v", err)
		http.Error(w, "Failed to encode response", http.StatusInternalServerError)
	}
}

// Legacy handler for backward compatibility
func devicesHandler(w http.ResponseWriter, r *http.Request) {
	searchHandler(w, r)
}

// generateAllDevices generates all fake devices at startup
func (dg *DeviceGenerator) generateAllDevices() []ArmisDevice {
	devices := make([]ArmisDevice, totalDevices)
	now := time.Now()

	for i := 0; i < totalDevices; i++ {
		// Generate multiple unique IPs for multi-homed devices
		ips := generateUniqueIPs(i)

		// Generate variable number of MAC addresses (1-200, with weighted distribution)
		macCount := generateMACCount(i)
		macAddresses := generateMACAddresses(i, macCount)

		deviceType := dg.deviceTypes[i%len(dg.deviceTypes)]
		manufacturer := dg.manufacturers[i%len(dg.manufacturers)]

		devices[i] = ArmisDevice{
			ID:              i + 1,
			IPAddress:       ips,
			MacAddress:      strings.Join(macAddresses, ","), // Create the comma-separated string for JSON
			MacAddresses:    macAddresses,                    // Store the internal slice
			Name:            generateDeviceName(deviceType, manufacturer, i),
			Type:            deviceType,
			Category:        generateCategory(deviceType),
			Manufacturer:    manufacturer,
			Model:           generateModel(manufacturer, deviceType, i),
			OperatingSystem: generateOS(deviceType, manufacturer, i),
			FirstSeen:       now.Add(-time.Duration(randInt(daysInMonth, daysInThreeYears)) * 24 * time.Hour),
			LastSeen:        now.Add(-time.Duration(randInt(0, daysInMonth)) * 24 * time.Hour),
			RiskLevel:       generateRiskLevel(deviceType),
			Boundaries:      generateBoundary(ips, deviceType),
			Tags:            generateTags(i),
		}

		// Log progress every 1000 devices
		if (i+1)%1000 == 0 {
			log.Printf("Generated %d/%d devices", i+1, totalDevices)
		}
	}

	return devices
}

// generateUniqueIPs generates multiple unique IPs for a device
// Returns a comma-separated string of IP addresses
func generateUniqueIPs(index int) string {
	// Determine how many IPs this device should have
	// 60% have 1 IP, 25% have 2-3 IPs, 10% have 4-5 IPs, 5% have 6+ IPs
	mod := index % percentageBase

	var numIPs int

	switch {
	case mod < singleIPPercent:
		numIPs = 1
	case mod < doubleIPPercent:
		numIPs = minAdditionalIPs + randInt(minRandomRange, 1) // 2-3 IPs
	case mod < multipleIPPercent:
		numIPs = minMultipleIPs + randInt(minRandomRange, 1) // 4-5 IPs
	default:
		numIPs = minManyIPs + randInt(minRandomRange, maxRandomRange) // 6-10 IPs
	}

	ips := make([]string, numIPs)
	// Generate primary IP
	ips[0] = generateSingleIP(index, 0)

	// Generate additional IPs for multi-homed devices
	for i := 1; i < numIPs; i++ {
		// Use a different offset to get IPs from different ranges
		ips[i] = generateSingleIP(index, i*ipRangeOffset)
	}

	return strings.Join(ips, ",")
}

// generateSingleIP generates a single unique IP from different ranges
func generateSingleIP(index, offset int) string {
	// Apply offset to simulate different network interfaces
	effectiveIndex := index + offset

	// Define network ranges with different sizes to simulate realistic environments
	networkRanges := []struct {
		base string
		size int // approximate number of devices to allocate to this range
	}{
		{"192.168.1", 254},    // Real network range - /24
		{"192.168.2", 254},    // Real network range - /24
		{"10.0.0", 254},       // Real network range - /24
		{"10.0.1", 1024},      // Larger corporate range
		{"10.1", 5000},        // Large corporate range
		{"172.16", 8000},      // Medium corporate range
		{"172.17", 10000},     // Large corporate range
		{"192.168.100", 2000}, // VPN/remote range
		{"192.168.200", 3000}, // Guest network range
		{"10.10", 15000},      // Very large corporate range
	}

	// Distribute devices across ranges
	currentIndex := 0
	for _, netRange := range networkRanges {
		if effectiveIndex < currentIndex+netRange.size {
			localIndex := effectiveIndex - currentIndex

			if strings.Count(netRange.base, ".") == 2 {
				// /24 network (e.g., "192.168.1")
				octet4 := (localIndex % 254) + 1 // 1-254 (skip 0 and 255)
				return fmt.Sprintf("%s.%d", netRange.base, octet4)
			}
			// Larger network (e.g., "10.1")
			octet3 := (localIndex / 254) % 256
			octet4 := (localIndex % 254) + 1

			return fmt.Sprintf("%s.%d.%d", netRange.base, octet3, octet4)
		}

		currentIndex += netRange.size
	}

	// Fallback for any remaining devices
	octet2 := ((effectiveIndex - currentIndex) / 65536) % 256
	octet3 := ((effectiveIndex - currentIndex) / 256) % 256
	octet4 := ((effectiveIndex - currentIndex) % 254) + 1 // Use 254 instead of 256 to avoid 255+1=256

	return fmt.Sprintf("10.%d.%d.%d", octet2, octet3, octet4)
}

// generateMACCount determines how many MAC addresses a device should have
// Simulates real Armis behavior where devices can have many historical MACs
//
//nolint:wsl // false positive for whitespace before opening brace
func generateMACCount(deviceIndex int) int {
	// Weight distribution to be more realistic:
	// 60% of devices have 1-5 MACs
	// 25% of devices have 6-20 MACs
	// 10% of devices have 21-50 MACs
	// 4% of devices have 51-100 MACs
	// 1% of devices have 101-200 MACs (busy servers, switches, etc.)
	mod := deviceIndex % percentageBase

	switch {
	case mod < lowPercentThreshold:
		// 60% - typical end user devices
		return randInt(minMACsEndUser, maxMACsEndUser)
	case mod < midPercentThreshold:
		// 25% - devices with multiple network interfaces
		return randInt(minMACsMultiInterface, maxMACsMultiInterface)
	case mod < highPercentThreshold:
		// 10% - servers or devices that change networks frequently
		return randInt(minMACsServer, maxMACsServer)
	case mod < veryHighPercentThreshold:
		// 4% - network infrastructure or very active devices
		return randInt(minMACsInfra, maxMACsInfra)
	default:
		// 1% - enterprise switches, routers, or servers with extensive history
		return randInt(minMACsEnterprise, maxMACsEnterprise)
	}
}

// generateMACAddresses generates a list of unique MAC addresses for a device
// This simulates Armis tracking every MAC address ever seen for an IP
func generateMACAddresses(seed, count int) []string {
	macs := make([]string, count)
	macSet := make(map[string]bool) // Ensure uniqueness

	// Common OUI prefixes for realistic MAC addresses
	ouiPrefixes := []string{
		"00:1B:44", // Dell
		"3C:97:0E", // HP
		"A4:BB:6D", // Apple
		"00:50:56", // VMware
		"00:0C:29", // VMware
		"08:00:27", // VirtualBox
		"52:54:00", // QEMU/KVM
		"00:16:3E", // Xen
		"F0:DE:F1", // Intel
		"00:1A:A0", // Cisco
		"00:14:22", // Dell
		"70:B3:D5", // Apple
		"AC:DE:48", // Cisco
		"00:24:D7", // Intel
		"00:15:5D", // Microsoft
	}

	for i := 0; i < count; i++ {
		var mac string

		attempts := 0

		// Generate unique MAC addresses
		for {
			if i == 0 {
				// First MAC is the primary/current MAC - use more deterministic generation
				oui := ouiPrefixes[seed%len(ouiPrefixes)]
				mac = fmt.Sprintf("%s:%02x:%02x:%02x",
					oui,
					(seed>>hexByteShift)&byteMaxValue,
					seed&byteMaxValue,
					(seed+i)&byteMaxValue)
			} else {
				// Subsequent MACs are historical - more variation
				if attempts < maxRetryAttempts {
					// Try with real OUI prefixes first
					oui := ouiPrefixes[(seed+i)%len(ouiPrefixes)]
					mac = fmt.Sprintf("%s:%02x:%02x:%02x",
						oui,
						randInt(minRandomRange, maxByteValue),
						randInt(minRandomRange, maxByteValue),
						randInt(minRandomRange, maxByteValue))
				} else {
					// Fallback to fully random MAC
					mac = fmt.Sprintf("%02x:%02x:%02x:%02x:%02x:%02x",
						randInt(minRandomRange, maxByteValue),
						randInt(minRandomRange, maxByteValue),
						randInt(minRandomRange, maxByteValue),
						randInt(minRandomRange, maxByteValue),
						randInt(minRandomRange, maxByteValue),
						randInt(minRandomRange, maxByteValue))
				}
			}

			// Ensure MAC is unique within this device
			if !macSet[mac] {
				macSet[mac] = true
				macs[i] = mac

				break
			}

			attempts++
			if attempts > 10 {
				// Fallback to indexed MAC to prevent infinite loops
				mac = fmt.Sprintf("%02x:%02x:%02x:%02x:%02x:%02x",
					(seed>>hexByteShift)&byteMaxValue,
					seed&byteMaxValue,
					(i>>hexByteShift)&byteMaxValue,
					i&byteMaxValue,
					randInt(minRandomRange, maxByteValue),
					(seed+i+attempts)&byteMaxValue)
				macs[i] = mac

				break
			}
		}
	}

	return macs
}

// generateDeviceName creates realistic device names based on type and manufacturer
func generateDeviceName(deviceType, manufacturer string, index int) string {
	// Helper function to safely get prefix from manufacturer name
	getManufacturerPrefix := func(name string) string {
		const prefixLength = 3
		if len(name) >= prefixLength {
			return strings.ToUpper(name[:prefixLength])
		}

		return strings.ToUpper(name)
	}

	switch {
	case strings.Contains(deviceType, "Server"):
		return fmt.Sprintf("%s-SRV-%03d", getManufacturerPrefix(manufacturer), index%1000)
	case strings.Contains(deviceType, "Router") || strings.Contains(deviceType, "Switch"):
		return fmt.Sprintf("%s-NET-%03d", getManufacturerPrefix(manufacturer), index%1000)
	case strings.Contains(deviceType, "Printer"):
		return fmt.Sprintf("%s-PRT-%03d", getManufacturerPrefix(manufacturer), index%1000)
	case strings.Contains(deviceType, "Phone"):
		return fmt.Sprintf("%s-PHN-%03d", getManufacturerPrefix(manufacturer), index%1000)
	case strings.Contains(deviceType, "Camera"):
		return fmt.Sprintf("CAM-%03d", index%1000)
	case strings.Contains(deviceType, "Mobile") || strings.Contains(deviceType, "Tablet"):
		usernames := []string{"jdoe", "msmith", "bwilson", "lgarcia", "alee", "kbrown", "sjohnson", "dwhite"}
		devicePrefix := deviceType

		const prefixLength = 3

		if len(deviceType) > prefixLength {
			devicePrefix = deviceType[:prefixLength]
		}

		return fmt.Sprintf("%s-%s", usernames[index%len(usernames)], devicePrefix)
	case strings.Contains(deviceType, "Computer") || strings.Contains(deviceType, "Laptop") || strings.Contains(deviceType, "Desktop"):
		return fmt.Sprintf("WS-%03d", index%1000)
	default:
		return fmt.Sprintf("DEV-%05d", index)
	}
}

// generateCategory determines device category based on type
func generateCategory(deviceType string) string {
	if isServerDevice(deviceType) {
		return "Server"
	}

	if isNetworkDevice(deviceType) {
		return "Network Infrastructure"
	}

	if isEndpointDevice(deviceType) {
		return "Endpoint"
	}

	if isMobileDevice(deviceType) {
		return "Mobile Device"
	}

	if isIoTDevice(deviceType) {
		return "IoT Device"
	}

	if isMedicalDevice(deviceType) {
		return "Medical Device"
	}

	if isIndustrialDevice(deviceType) {
		return "Industrial Control System"
	}

	return "Other"
}

// Helper functions to categorize devices
func isServerDevice(deviceType string) bool {
	return strings.Contains(deviceType, "Server") || strings.Contains(deviceType, "Domain Controller")
}

func isNetworkDevice(deviceType string) bool {
	return strings.Contains(deviceType, "Router") || strings.Contains(deviceType, "Switch") ||
		strings.Contains(deviceType, "Access Point") || strings.Contains(deviceType, "Firewall")
}

func isEndpointDevice(deviceType string) bool {
	return strings.Contains(deviceType, "Computer") || strings.Contains(deviceType, "Laptop") ||
		strings.Contains(deviceType, "Desktop") || strings.Contains(deviceType, "Workstation")
}

func isMobileDevice(deviceType string) bool {
	return strings.Contains(deviceType, "Mobile") || strings.Contains(deviceType, "Tablet") ||
		strings.Contains(deviceType, "Smartphone")
}

func isIoTDevice(deviceType string) bool {
	return strings.Contains(deviceType, "IoT") || strings.Contains(deviceType, "Smart") ||
		strings.Contains(deviceType, "Camera") || strings.Contains(deviceType, "Door Lock")
}

func isMedicalDevice(deviceType string) bool {
	return strings.Contains(deviceType, "Medical")
}

func isIndustrialDevice(deviceType string) bool {
	return strings.Contains(deviceType, "Industrial") || strings.Contains(deviceType, "PLC") ||
		strings.Contains(deviceType, "HMI")
}

// generateModel creates realistic model names
func generateModel(manufacturer, deviceType string, index int) string {
	switch manufacturer {
	case "Dell":
		if strings.Contains(deviceType, "Server") {
			models := []string{"PowerEdge R750", "PowerEdge R650", "PowerEdge R7525", "PowerEdge T350"}
			return models[index%len(models)]
		}

		return fmt.Sprintf("OptiPlex %d", maxDellOptiPlexBase+(index%maxDellOptiPlexRange))
	case "HP":
		if strings.Contains(deviceType, "Server") {
			models := []string{"ProLiant DL380", "ProLiant DL360", "ProLiant ML350", "ProLiant DL560"}
			return models[index%len(models)]
		}

		return fmt.Sprintf("EliteDesk %d", maxHPEliteDeskBase+(index%maxHPEliteDeskRange))
	case "Cisco":
		if strings.Contains(deviceType, "Router") {
			models := []string{"ISR4331", "ISR4351", "ASR1001-X", "ISR4461"}
			return models[index%len(models)]
		} else if strings.Contains(deviceType, "Switch") {
			models := []string{"Catalyst 9300", "Catalyst 9200", "Nexus 3048", "Catalyst 2960"}
			return models[index%len(models)]
		}

		return fmt.Sprintf("Device-%d", index%1000)
	case appleManufacturer:
		if strings.Contains(deviceType, "Mobile") || strings.Contains(deviceType, "Smartphone") {
			models := []string{"iPhone 13", "iPhone 14", "iPhone 12", "iPhone 15", "iPhone SE"}
			return models[index%len(models)]
		} else if strings.Contains(deviceType, "Tablet") {
			models := []string{"iPad Pro", "iPad Air", "iPad mini", "iPad"}
			return models[index%len(models)]
		}

		return fmt.Sprintf("MacBook Pro %d", baseMacBookSize+(index%macBookVariants)*macBookSizeIncrement) // 13, 16, 19

	default:
		return fmt.Sprintf("Model-%d", (index%1000)+1)
	}
}

// generateOS matches OS to device type and manufacturer
func generateOS(deviceType, manufacturer string, index int) string {
	if isServerDevice(deviceType) {
		return getServerOS(index)
	}

	if isNetworkDevice(deviceType) {
		return getNetworkOS(manufacturer)
	}

	if isMobileDevice(deviceType) {
		return getMobileOS(manufacturer, index)
	}

	if isEndpointDevice(deviceType) {
		return getEndpointOS(manufacturer, index)
	}

	if isIoTDevice(deviceType) {
		return "Embedded Linux"
	}

	return deviceGen.osTypes[index%len(deviceGen.osTypes)]
}

// Helper functions for OS generation
func getServerOS(index int) string {
	serverOS := []string{"Windows Server 2019", "Windows Server 2022", "Ubuntu 20.04", "Red Hat Enterprise Linux", "VMware ESXi 7.0"}
	return serverOS[index%len(serverOS)]
}

func getNetworkOS(manufacturer string) string {
	switch manufacturer {
	case "Cisco":
		return "Cisco IOS"
	case "Juniper":
		return "Juniper JunOS"
	default:
		return "Embedded Linux"
	}
}

func getMobileOS(manufacturer string, index int) string {
	if manufacturer == appleManufacturer {
		iosVersions := []string{"iOS 15", "iOS 16", "iOS 17"}
		return iosVersions[index%len(iosVersions)]
	}

	androidVersions := []string{"Android 11", "Android 12", "Android 13"}

	return androidVersions[index%len(androidVersions)]
}

func getEndpointOS(manufacturer string, index int) string {
	if manufacturer == appleManufacturer {
		macVersions := []string{"macOS Monterey", "macOS Ventura", "macOS Big Sur"}
		return macVersions[index%len(macVersions)]
	}

	winVersions := []string{"Windows 10 Pro", "Windows 11 Enterprise", "Windows 11 Pro"}

	return winVersions[index%len(winVersions)]
}

// generateRiskLevel assigns risk based on device type and characteristics
func generateRiskLevel(deviceType string) int {
	switch {
	case strings.Contains(deviceType, "Server") || strings.Contains(deviceType, "Domain Controller"):
		return randInt(serverRiskMin, serverRiskMax) // Servers are high risk
	case strings.Contains(deviceType, "Medical") || strings.Contains(deviceType, "Industrial"):
		return randInt(medicalRiskMin, medicalRiskMax) // Critical infrastructure
	case strings.Contains(deviceType, "IoT") || strings.Contains(deviceType, "Smart"):
		return randInt(iotRiskMin, iotRiskMax) // IoT devices often have vulnerabilities
	case strings.Contains(deviceType, "Mobile") || strings.Contains(deviceType, "Tablet"):
		return randInt(mobileRiskMin, mobileRiskMax) // Mobile devices moderate risk
	case strings.Contains(deviceType, "Router") || strings.Contains(deviceType, "Firewall"):
		return randInt(networkRiskMin, networkRiskMax) // Network infrastructure is important
	default:
		return randInt(generalRiskMin, generalRiskMax) // General devices lower risk
	}
}

// generateBoundary determines network boundary based on IP range and device type
func generateBoundary(ips, deviceType string) string {
	// Use the first IP to determine the primary boundary
	ipList := strings.Split(ips, ",")
	if len(ipList) == 0 {
		return "Corporate"
	}

	ip := strings.TrimSpace(ipList[0])

	switch {
	case strings.HasPrefix(ip, "192.168.1.") || strings.HasPrefix(ip, "192.168.2.") || strings.HasPrefix(ip, "10.0.0."):
		return "Corporate LAN"
	case strings.HasPrefix(ip, "192.168.100."):
		return "VPN Users"
	case strings.HasPrefix(ip, "192.168.200."):
		return "Guest Network"
	case strings.HasPrefix(ip, "172."):
		return "DMZ"
	case strings.Contains(deviceType, "Medical"):
		return "Medical Network"
	case strings.Contains(deviceType, "Industrial"):
		return "OT Network"
	default:
		return "Corporate"
	}
}

// generateTags generates random tags for a device
func generateTags(index int) []string {
	tagOptions := []string{
		"production", "development", "testing", "critical", "monitored",
		"vulnerable", "patched", "compliant", "encrypted", "managed",
	}
	numTags := index % 5 // 0-4 tags per device

	tags := make([]string, 0, numTags)
	for i := 0; i < numTags; i++ {
		tags = append(tags, tagOptions[(index+i)%len(tagOptions)])
	}

	return tags
}

// generateRandomString generates a random string of given length
func generateRandomString(length int) string {
	const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

	result := make([]byte, length)

	for i := range result {
		result[i] = chars[randInt(0, len(chars)-1)]
	}

	return string(result)
}

// randInt generates a random integer between minVal and max (inclusive)
func randInt(minVal, maxVal int) int {
	if minVal >= maxVal {
		return minVal
	}

	n, _ := cryptoRand.Int(cryptoRand.Reader, big.NewInt(int64(maxVal-minVal+1)))

	return int(n.Int64()) + minVal
}

// loadFromStorage attempts to load device data from persistent storage
func (dg *DeviceGenerator) loadFromStorage() bool {
	storageFile := getStorageFilePath()

	data, err := os.ReadFile(storageFile)
	if err != nil {
		log.Printf("No existing device data found at %s, will generate new data", storageFile)
		return false
	}

	var storedDevices []ArmisDevice
	if err := json.Unmarshal(data, &storedDevices); err != nil {
		log.Printf("Failed to parse stored device data: %v, will generate new data", err)
		return false
	}

	if len(storedDevices) != totalDevices {
		log.Printf("Stored device count (%d) doesn't match expected (%d), will generate new data", len(storedDevices), totalDevices)
		return false
	}

	dg.allDevices = storedDevices
	log.Printf("Successfully loaded %d devices from persistent storage", len(dg.allDevices))

	return true
}

// saveToStorage saves device data to persistent storage
func (dg *DeviceGenerator) saveToStorage() {
	storageFile := getStorageFilePath()

	// Create a copy of the devices while holding the read lock
	dg.mu.RLock()
	devicesCopy := make([]ArmisDevice, len(dg.allDevices))
	copy(devicesCopy, dg.allDevices)
	dg.mu.RUnlock()

	data, err := json.Marshal(devicesCopy)
	if err != nil {
		log.Printf("Failed to marshal device data for storage: %v", err)
		return
	}

	if err := os.WriteFile(storageFile, data, deviceFilePermissions); err != nil {
		log.Printf("Failed to write device data to storage: %v", err)
		return
	}

	log.Printf("Successfully saved %d devices to persistent storage at %s", len(devicesCopy), storageFile)
}

// getStorageFilePath returns the path where device data should be stored
func getStorageFilePath() string {
	if config != nil && config.Storage.DataDir != "" {
		// Ensure directory exists
		if err := os.MkdirAll(config.Storage.DataDir, dataDirPerms); err != nil {
			log.Printf("Warning: Failed to create data directory %s: %v", config.Storage.DataDir, err)
		}

		return fmt.Sprintf("%s/%s", config.Storage.DataDir, config.Storage.DevicesFile)
	}

	// Check if we're running in Docker with a volume mount
	if _, err := os.Stat("/data"); err == nil {
		return "/data/fake_armis_devices.json"
	}
	// Fallback to current directory
	return "./fake_armis_devices.json"
}
