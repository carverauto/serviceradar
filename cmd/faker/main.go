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
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"net/http"
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

const totalDevices = 25000

var (
	// Pre-generate devices for consistent responses
	allDevices []ArmisDevice
	// Device types for variety
	deviceTypes = []string{"Computer", "Mobile Phone", "Server", "Printer", "IoT Device", "Router", "Switch", "Access Point"}
	// OS types
	osTypes = []string{"Windows 10", "Windows 11", "macOS", "Linux", "iOS", "Android", "Unknown"}
	// Manufacturers
	manufacturers = []string{"Dell", "HP", "Apple", "Cisco", "Samsung", "Lenovo", "Microsoft", "Google"}
)

func init() {
	log.Printf("Generating %d fake Armis devices...", totalDevices)
	allDevices = generateAllDevices()
	log.Printf("Generated %d devices successfully", len(allDevices))
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
		
		// Generate variable number of MAC addresses (1-50)
		macCount := (i % 50) + 1
		if macCount > 10 {
			macCount = randInt(1, 10) // Most devices have 1-10 MACs
		}
		macAddresses := generateMACAddresses(i, macCount)
		
		devices[i] = ArmisDevice{
			ID:              i + 1,
			IPAddress:       ip,
			MacAddress:      strings.Join(macAddresses, ","),
			Name:            fmt.Sprintf("device-%d", i+1),
			Type:            deviceTypes[i%len(deviceTypes)],
			Category:        "Managed",
			Manufacturer:    manufacturers[i%len(manufacturers)],
			Model:           fmt.Sprintf("Model-%d", (i%100)+1),
			OperatingSystem: osTypes[i%len(osTypes)],
			FirstSeen:       now.Add(-time.Duration(randInt(1, 365)) * 24 * time.Hour),
			LastSeen:        now.Add(-time.Duration(randInt(0, 7)) * 24 * time.Hour),
			RiskLevel:       randInt(1, 10),
			Boundaries:      "Corporate",
			Tags:            generateTags(i),
		}
		
		// Log progress every 1000 devices
		if (i+1)%1000 == 0 {
			log.Printf("Generated %d/%d devices", i+1, totalDevices)
		}
	}
	
	return devices
}

// generateUniqueIP generates unique IPs from different ranges
func generateUniqueIP(index int) string {
	// Use different IP ranges for variety
	ranges := []string{
		"10.0",    // 10.0.x.x
		"10.1",    // 10.1.x.x
		"172.16",  // 172.16.x.x
		"172.17",  // 172.17.x.x
		"192.168", // 192.168.x.x
	}
	
	rangeIndex := index / 5000 // Change range every 5000 devices
	if rangeIndex >= len(ranges) {
		rangeIndex = index % len(ranges)
	}
	
	baseRange := ranges[rangeIndex]
	octet3 := (index / 250) % 256
	octet4 := (index % 250) + 1
	
	return fmt.Sprintf("%s.%d.%d", baseRange, octet3, octet4)
}

// generateMACAddresses generates a list of MAC addresses
func generateMACAddresses(seed, count int) []string {
	macs := make([]string, count)
	for i := 0; i < count; i++ {
		// Generate MAC based on seed and index for consistency
		mac := fmt.Sprintf("%02x:%02x:%02x:%02x:%02x:%02x",
			(seed>>8)&0xFF,
			seed&0xFF,
			(i>>8)&0xFF,
			i&0xFF,
			randInt(0, 255),
			randInt(0, 255))
		macs[i] = mac
	}
	return macs
}

// generateTags generates random tags for a device
func generateTags(index int) []string {
	tagOptions := []string{"production", "development", "testing", "critical", "monitored", "vulnerable", "patched"}
	numTags := index % 4 // 0-3 tags per device
	
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
	n, _ := rand.Int(rand.Reader, big.NewInt(int64(max-min+1)))
	return int(n.Int64()) + min
}
