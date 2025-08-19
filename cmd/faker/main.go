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
	cryptoRand "crypto/rand"
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

type ArmisDevice struct {
	ID               int         `json:"id"`
	IPAddress        string      `json:"ipAddress"`
	MacAddress       string      `json:"macAddress"`
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

const totalDevices = 50000

var (
	// Pre-generate devices for consistent responses
	allDevices []ArmisDevice
	// Device types for variety - expanded for more realism
	deviceTypes = []string{
		"Computer", "Laptop", "Desktop", "Workstation", "Server", "Domain Controller",
		"Mobile Phone", "Tablet", "Smartphone", 
		"Printer", "Multifunction Printer", "Label Printer", "3D Printer",
		"IoT Device", "Smart Thermostat", "Security Camera", "Door Lock", "Smart Light",
		"Router", "Switch", "Access Point", "Firewall", "Load Balancer", "Gateway",
		"Network Storage", "NAS", "SAN Storage", "Backup Device",
		"Medical Device", "Industrial Controller", "PLC", "HMI",
		"Phone System", "IP Phone", "Conference Phone",
		"Gaming Console", "Smart TV", "Streaming Device", "Set Top Box",
	}
	// OS types - expanded with versions and more variety
	osTypes = []string{
		"Windows 10 Pro", "Windows 11 Enterprise", "Windows Server 2019", "Windows Server 2022",
		"macOS Monterey", "macOS Ventura", "macOS Big Sur",
		"Ubuntu 20.04", "Ubuntu 22.04", "Red Hat Enterprise Linux", "CentOS", "Debian",
		"iOS 15", "iOS 16", "iPadOS", "Android 12", "Android 13", "Android 11",
		"ESXi 7.0", "ESXi 8.0", "Proxmox", "Hyper-V",
		"Cisco IOS", "Cisco NX-OS", "Juniper JunOS", "pfSense", "OPNsense",
		"Embedded Linux", "FreeRTOS", "VxWorks", "Unknown", "N/A",
	}
	// Manufacturers - expanded with network and enterprise vendors
	manufacturers = []string{
		"Dell", "HP", "Lenovo", "Apple", "Microsoft", "Asus", "Acer", "Toshiba",
		"Cisco", "Juniper", "Aruba", "Ubiquiti", "Netgear", "D-Link", "TP-Link",
		"VMware", "Citrix", "Red Hat", "Canonical", "SUSE",
		"Samsung", "Google", "Amazon", "Roku", "Nvidia", "Intel", "AMD",
		"Hikvision", "Axis", "Bosch", "Honeywell", "Johnson Controls",
		"Siemens", "Schneider Electric", "ABB", "Rockwell Automation",
		"Canon", "Epson", "Brother", "Xerox", "Ricoh",
		"Synology", "QNAP", "NetApp", "EMC", "Pure Storage",
	}
)

func init() {
	// First, try to load existing device data from storage
	if loadFromStorage() {
		return
	}
	
	// No existing data found, generate new random device data
	log.Printf("Generating %d fake Armis devices with random data...", totalDevices)
	allDevices = generateAllDevices()
	log.Printf("Generated %d devices successfully", len(allDevices))
	
	// Save the generated data to persistent storage for future use
	saveToStorage()
}

func main() {
	mux := http.NewServeMux()
	// Armis API endpoints
	mux.HandleFunc("/api/v1/access_token/", tokenHandler)
	mux.HandleFunc("/api/v1/search/", searchHandler)
	// Legacy endpoint if needed
	mux.HandleFunc("/v1/devices", devicesHandler)

	server := &http.Server{
		Addr:         ":8080",
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	log.Println("Fake Armis API starting on :8080")
	log.Printf("Total devices available: %d", totalDevices)

	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
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
			AccessToken:   "fake-token-" + generateRandomString(32),
			ExpirationUTC: time.Now().Add(24 * time.Hour),
		},
		Success: true,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
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

	// Calculate pagination
	end := from + length
	if end > totalDevices {
		end = totalDevices
	}

	// Get the slice of devices
	var results []ArmisDevice
	if from < totalDevices {
		results = allDevices[from:end]
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
func generateAllDevices() []ArmisDevice {
	devices := make([]ArmisDevice, totalDevices)
	now := time.Now()
	
	for i := 0; i < totalDevices; i++ {
		// Generate unique IPs from different ranges
		ip := generateUniqueIP(i)
		
		// Generate variable number of MAC addresses (1-200, with weighted distribution)
		macCount := generateMACCount(i)
		macAddresses := generateMACAddresses(i, macCount)
		
		deviceType := deviceTypes[i%len(deviceTypes)]
		manufacturer := manufacturers[i%len(manufacturers)]
		
		devices[i] = ArmisDevice{
			ID:              i + 1,
			IPAddress:       ip,
			MacAddress:      strings.Join(macAddresses, ","),
			Name:            generateDeviceName(deviceType, manufacturer, i),
			Type:            deviceType,
			Category:        generateCategory(deviceType),
			Manufacturer:    manufacturer,
			Model:           generateModel(manufacturer, deviceType, i),
			OperatingSystem: generateOS(deviceType, manufacturer, i),
			FirstSeen:       now.Add(-time.Duration(randInt(30, 1095)) * 24 * time.Hour), // 30 days to 3 years ago
			LastSeen:        now.Add(-time.Duration(randInt(0, 30)) * 24 * time.Hour),    // Within last 30 days
			RiskLevel:       generateRiskLevel(deviceType, i),
			Boundaries:      generateBoundary(ip, deviceType),
			Tags:            generateTags(i),
		}
		
		// Log progress every 1000 devices
		if (i+1)%1000 == 0 {
			log.Printf("Generated %d/%d devices", i+1, totalDevices)
		}
	}
	
	return devices
}

// generateUniqueIP generates unique IPs from different ranges including real network ranges
func generateUniqueIP(index int) string {
	// Define network ranges with different sizes to simulate realistic environments
	networkRanges := []struct {
		base string
		size int // approximate number of devices to allocate to this range
	}{
		{"192.168.1", 254},     // Real network range - /24
		{"192.168.2", 254},     // Real network range - /24  
		{"10.0.0", 254},        // Real network range - /24
		{"10.0.1", 1024},       // Larger corporate range
		{"10.1", 5000},         // Large corporate range
		{"172.16", 8000},       // Medium corporate range
		{"172.17", 10000},      // Large corporate range
		{"192.168.100", 2000},  // VPN/remote range
		{"192.168.200", 3000},  // Guest network range
		{"10.10", 15000},       // Very large corporate range
	}
	
	// Distribute devices across ranges
	currentIndex := 0
	for _, netRange := range networkRanges {
		if index < currentIndex + netRange.size {
			localIndex := index - currentIndex
			
			if strings.Count(netRange.base, ".") == 2 {
				// /24 network (e.g., "192.168.1")
				octet4 := (localIndex % 254) + 1 // 1-254 (skip 0 and 255)
				return fmt.Sprintf("%s.%d", netRange.base, octet4)
			} else {
				// Larger network (e.g., "10.1")
				octet3 := (localIndex / 254) % 256
				octet4 := (localIndex % 254) + 1
				return fmt.Sprintf("%s.%d.%d", netRange.base, octet3, octet4)
			}
		}
		currentIndex += netRange.size
	}
	
	// Fallback for any remaining devices
	octet2 := ((index - currentIndex) / 65536) % 256
	octet3 := ((index - currentIndex) / 256) % 256 
	octet4 := ((index - currentIndex) % 254) + 1  // Use 254 instead of 256 to avoid 255+1=256
	return fmt.Sprintf("10.%d.%d.%d", octet2, octet3, octet4)
}

// generateMACCount determines how many MAC addresses a device should have
// Simulates real Armis behavior where devices can have many historical MACs
func generateMACCount(deviceIndex int) int {
	// Weight distribution to be more realistic:
	// 60% of devices have 1-5 MACs
	// 25% of devices have 6-20 MACs  
	// 10% of devices have 21-50 MACs
	// 4% of devices have 51-100 MACs
	// 1% of devices have 101-200 MACs (busy servers, switches, etc.)
	
	mod := deviceIndex % 100
	switch {
	case mod < 60:
		// 60% - typical end user devices
		return randInt(1, 5)
	case mod < 85:
		// 25% - devices with multiple network interfaces
		return randInt(6, 20)
	case mod < 95:
		// 10% - servers or devices that change networks frequently
		return randInt(21, 50)
	case mod < 99:
		// 4% - network infrastructure or very active devices
		return randInt(51, 100)
	default:
		// 1% - enterprise switches, routers, or servers with extensive history
		return randInt(101, 200)
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
					(seed>>8)&0xFF,
					seed&0xFF,
					(seed+i)&0xFF)
			} else {
				// Subsequent MACs are historical - more variation
				if attempts < 3 {
					// Try with real OUI prefixes first
					oui := ouiPrefixes[(seed+i)%len(ouiPrefixes)]
					mac = fmt.Sprintf("%s:%02x:%02x:%02x",
						oui,
						randInt(0, 255),
						randInt(0, 255),
						randInt(0, 255))
				} else {
					// Fallback to fully random MAC
					mac = fmt.Sprintf("%02x:%02x:%02x:%02x:%02x:%02x",
						randInt(0, 255),
						randInt(0, 255),
						randInt(0, 255),
						randInt(0, 255),
						randInt(0, 255),
						randInt(0, 255))
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
					(seed>>8)&0xFF,
					seed&0xFF,
					(i>>8)&0xFF,
					i&0xFF,
					randInt(0, 255),
					(seed+i+attempts)&0xFF)
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
		if len(name) >= 3 {
			return strings.ToUpper(name[:3])
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
		if len(deviceType) > 3 {
			devicePrefix = deviceType[:3]
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
	switch {
	case strings.Contains(deviceType, "Server") || strings.Contains(deviceType, "Domain Controller"):
		return "Server"
	case strings.Contains(deviceType, "Router") || strings.Contains(deviceType, "Switch") || 
		 strings.Contains(deviceType, "Access Point") || strings.Contains(deviceType, "Firewall"):
		return "Network Infrastructure"
	case strings.Contains(deviceType, "Computer") || strings.Contains(deviceType, "Laptop") || 
		 strings.Contains(deviceType, "Desktop") || strings.Contains(deviceType, "Workstation"):
		return "Endpoint"
	case strings.Contains(deviceType, "Mobile") || strings.Contains(deviceType, "Tablet") || 
		 strings.Contains(deviceType, "Smartphone"):
		return "Mobile Device"
	case strings.Contains(deviceType, "IoT") || strings.Contains(deviceType, "Smart") || 
		 strings.Contains(deviceType, "Camera") || strings.Contains(deviceType, "Door Lock"):
		return "IoT Device"
	case strings.Contains(deviceType, "Medical"):
		return "Medical Device"
	case strings.Contains(deviceType, "Industrial") || strings.Contains(deviceType, "PLC") || 
		 strings.Contains(deviceType, "HMI"):
		return "Industrial Control System"
	default:
		return "Other"
	}
}

// generateModel creates realistic model names
func generateModel(manufacturer, deviceType string, index int) string {
	switch manufacturer {
	case "Dell":
		if strings.Contains(deviceType, "Server") {
			models := []string{"PowerEdge R750", "PowerEdge R650", "PowerEdge R7525", "PowerEdge T350"}
			return models[index%len(models)]
		}
		return fmt.Sprintf("OptiPlex %d", 3000+(index%9000))
	case "HP":
		if strings.Contains(deviceType, "Server") {
			models := []string{"ProLiant DL380", "ProLiant DL360", "ProLiant ML350", "ProLiant DL560"}
			return models[index%len(models)]
		}
		return fmt.Sprintf("EliteDesk %d", 800+(index%1000))
	case "Cisco":
		if strings.Contains(deviceType, "Router") {
			models := []string{"ISR4331", "ISR4351", "ASR1001-X", "ISR4461"}
			return models[index%len(models)]
		} else if strings.Contains(deviceType, "Switch") {
			models := []string{"Catalyst 9300", "Catalyst 9200", "Nexus 3048", "Catalyst 2960"}
			return models[index%len(models)]
		}
		return fmt.Sprintf("Device-%d", index%1000)
	case "Apple":
		if strings.Contains(deviceType, "Mobile") || strings.Contains(deviceType, "Smartphone") {
			models := []string{"iPhone 13", "iPhone 14", "iPhone 12", "iPhone 15", "iPhone SE"}
			return models[index%len(models)]
		} else if strings.Contains(deviceType, "Tablet") {
			models := []string{"iPad Pro", "iPad Air", "iPad mini", "iPad"}
			return models[index%len(models)]
		}
		return fmt.Sprintf("MacBook Pro %d", 13+(index%3)*3) // 13, 16, 19
	default:
		return fmt.Sprintf("Model-%d", (index%1000)+1)
	}
}

// generateOS matches OS to device type and manufacturer
func generateOS(deviceType, manufacturer string, index int) string {
	switch {
	case strings.Contains(deviceType, "Server"):
		serverOS := []string{"Windows Server 2019", "Windows Server 2022", "Ubuntu 20.04", "Red Hat Enterprise Linux", "VMware ESXi 7.0"}
		return serverOS[index%len(serverOS)]
	case strings.Contains(deviceType, "Router") || strings.Contains(deviceType, "Switch") || strings.Contains(deviceType, "Firewall"):
		if manufacturer == "Cisco" {
			return "Cisco IOS"
		} else if manufacturer == "Juniper" {
			return "Juniper JunOS"
		}
		return "Embedded Linux"
	case strings.Contains(deviceType, "Mobile") || strings.Contains(deviceType, "Smartphone"):
		if manufacturer == "Apple" {
			iosVersions := []string{"iOS 15", "iOS 16", "iOS 17"}
			return iosVersions[index%len(iosVersions)]
		}
		androidVersions := []string{"Android 11", "Android 12", "Android 13"}
		return androidVersions[index%len(androidVersions)]
	case strings.Contains(deviceType, "Computer") || strings.Contains(deviceType, "Laptop") || strings.Contains(deviceType, "Desktop"):
		if manufacturer == "Apple" {
			macVersions := []string{"macOS Monterey", "macOS Ventura", "macOS Big Sur"}
			return macVersions[index%len(macVersions)]
		}
		winVersions := []string{"Windows 10 Pro", "Windows 11 Enterprise", "Windows 11 Pro"}
		return winVersions[index%len(winVersions)]
	case strings.Contains(deviceType, "IoT") || strings.Contains(deviceType, "Smart"):
		return "Embedded Linux"
	default:
		return osTypes[index%len(osTypes)]
	}
}

// generateRiskLevel assigns risk based on device type and characteristics
func generateRiskLevel(deviceType string, index int) int {
	switch {
	case strings.Contains(deviceType, "Server") || strings.Contains(deviceType, "Domain Controller"):
		return randInt(7, 10) // Servers are high risk
	case strings.Contains(deviceType, "Medical") || strings.Contains(deviceType, "Industrial"):
		return randInt(8, 10) // Critical infrastructure
	case strings.Contains(deviceType, "IoT") || strings.Contains(deviceType, "Smart"):
		return randInt(5, 8) // IoT devices often have vulnerabilities
	case strings.Contains(deviceType, "Mobile") || strings.Contains(deviceType, "Tablet"):
		return randInt(3, 6) // Mobile devices moderate risk
	case strings.Contains(deviceType, "Router") || strings.Contains(deviceType, "Firewall"):
		return randInt(6, 9) // Network infrastructure is important
	default:
		return randInt(1, 5) // General devices lower risk
	}
}

// generateBoundary determines network boundary based on IP range and device type
func generateBoundary(ip, deviceType string) string {
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
	tagOptions := []string{"production", "development", "testing", "critical", "monitored", "vulnerable", "patched", "compliant", "encrypted", "managed"}
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

// randInt generates a random integer between min and max (inclusive)
func randInt(min, max int) int {
	if min >= max {
		return min
	}
	n, _ := cryptoRand.Int(cryptoRand.Reader, big.NewInt(int64(max-min+1)))
	return int(n.Int64()) + min
}

// loadFromStorage attempts to load device data from persistent storage
func loadFromStorage() bool {
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
	
	allDevices = storedDevices
	log.Printf("Successfully loaded %d devices from persistent storage", len(allDevices))
	return true
}

// saveToStorage saves device data to persistent storage
func saveToStorage() {
	storageFile := getStorageFilePath()
	
	data, err := json.Marshal(allDevices)
	if err != nil {
		log.Printf("Failed to marshal device data for storage: %v", err)
		return
	}
	
	if err := os.WriteFile(storageFile, data, 0644); err != nil {
		log.Printf("Failed to write device data to storage: %v", err)
		return
	}
	
	log.Printf("Successfully saved %d devices to persistent storage at %s", len(allDevices), storageFile)
}

// getStorageFilePath returns the path where device data should be stored
func getStorageFilePath() string {
	// Check if we're running in Docker with a volume mount
	if _, err := os.Stat("/data"); err == nil {
		return "/data/fake_armis_devices.json"
	}
	// Fallback to current directory
	return "./fake_armis_devices.json"
}
