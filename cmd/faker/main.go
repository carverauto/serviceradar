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
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"time"
)

type Device struct {
	DeviceID  string `json:"device_id"`
	IPAddress string `json:"ip_address"`
}

type DeviceResponse struct {
	Devices  []Device `json:"devices"`
	Total    int      `json:"total"`
	Page     int      `json:"page"`
	PerPage  int      `json:"per_page"`
	NextPage *int     `json:"next_page,omitempty"`
	PrevPage *int     `json:"prev_page,omitempty"`
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/devices", devicesHandler)

	server := &http.Server{
		Addr:         ":8080",
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	log.Println("Fake Armis API starting on :8080")

	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

// devicesHandler handles GET requests for /v1/devices with pagination.
func devicesHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)

		return
	}

	log.Println("Request received")

	page, perPage := parsePagination(r)
	start, end := calculateRange(page, perPage)

	devices := generateDevices(start, end)
	resp := buildResponse(devices, page, perPage)

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(resp); err != nil {
		http.Error(w, "Failed to encode response", http.StatusInternalServerError)
	}
}

// parsePagination extracts and validates page and per_page query parameters.
func parsePagination(r *http.Request) (page, perPage int) {
	pageStr := r.URL.Query().Get("page")

	page, _ = strconv.Atoi(pageStr)
	if page < 1 {
		page = 1
	}

	perPageStr := r.URL.Query().Get("per_page")

	perPage, _ = strconv.Atoi(perPageStr)
	if perPage < 1 || perPage > 100 {
		perPage = 10
	}

	return page, perPage
}

// calculateRange computes the start and end indices for pagination.
func calculateRange(page, perPage int) (start, end int) {
	const totalDevices = 50

	start = (page - 1) * perPage
	end = start + perPage

	if start > totalDevices {
		start = totalDevices
	}

	if end > totalDevices {
		end = totalDevices
	}

	return start, end
}

// generateDevices creates a slice of fake devices for the given range.
func generateDevices(start, end int) []Device {
	devices := make([]Device, 0, end-start)
	for i := start; i < end; i++ {
		devices = append(devices, Device{
			DeviceID:  fmt.Sprintf("device-%d", i+1),
			IPAddress: fmt.Sprintf("192.168.1.%d", (i%255)+1),
		})
	}

	return devices
}

// buildResponse constructs the paginated response with metadata.
func buildResponse(devices []Device, page, perPage int) DeviceResponse {
	const totalDevices = 50

	var nextPage, prevPage *int

	if page*perPage < totalDevices {
		n := page + 1
		nextPage = &n
	}

	if page > 1 {
		p := page - 1
		prevPage = &p
	}

	return DeviceResponse{
		Devices:  devices,
		Total:    totalDevices,
		Page:     page,
		PerPage:  perPage,
		NextPage: nextPage,
		PrevPage: prevPage,
	}
}
