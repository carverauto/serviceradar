package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
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
	http.HandleFunc("/v1/devices", devicesHandler)

	log.Println("Fake ARMIS API starting on :8080")

	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

func devicesHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)

		return
	}

	log.Println("Request received")

	// Parse pagination params
	pageStr := r.URL.Query().Get("page")
	perPageStr := r.URL.Query().Get("per_page")

	page, _ := strconv.Atoi(pageStr)
	if page < 1 {
		page = 1
	}

	perPage, _ := strconv.Atoi(perPageStr)
	if perPage < 1 || perPage > 100 {
		perPage = 10
	}

	// Simulate a dataset of 50 devices
	totalDevices := 50

	start := (page - 1) * perPage
	end := start + perPage

	if start > totalDevices {
		start = totalDevices
	}

	if end > totalDevices {
		end = totalDevices
	}

	// Generate fake devices
	devices := make([]Device, 0, perPage)

	for i := start; i < end; i++ {
		devices = append(devices, Device{
			DeviceID:  fmt.Sprintf("device-%d", i+1),
			IPAddress: fmt.Sprintf("192.168.1.%d", (i%255)+1),
		})
	}

	// Pagination metadata
	var nextPage, prevPage *int

	if end < totalDevices {
		n := page + 1
		nextPage = &n
	}
	if page > 1 {
		p := page - 1
		prevPage = &p
	}

	resp := DeviceResponse{
		Devices:  devices,
		Total:    totalDevices,
		Page:     page,
		PerPage:  perPage,
		NextPage: nextPage,
		PrevPage: prevPage,
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(resp); err != nil {
		http.Error(w, "Failed to encode response", http.StatusInternalServerError)
	}
}
