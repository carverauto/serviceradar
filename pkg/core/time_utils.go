package core

import "time"

func isValidTimestamp(t time.Time) bool {
	// Check if the timestamp is within valid range for Proton
	minTime := time.Date(1925, 1, 1, 0, 0, 0, 0, time.UTC)
	maxTime := time.Date(2283, 11, 11, 0, 0, 0, 0, time.UTC)

	return t.After(minTime) && t.Before(maxTime)
}
