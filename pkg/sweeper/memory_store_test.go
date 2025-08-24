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

package sweeper

import (
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// TestMatchesFilterNilFilter tests that matchesFilter doesn't panic with nil filter
func TestMatchesFilterNilFilter(t *testing.T) {
	store := &InMemoryStore{}
	result := &models.Result{
		Target: models.Target{
			Host: "192.168.1.1",
			Port: 80,
			Mode: models.ModeTCP,
		},
		Available: true,
		FirstSeen: time.Now(),
		LastSeen:  time.Now(),
	}

	// This should not panic and should return true (match all)
	matches := store.matchesFilter(result, nil)
	if !matches {
		t.Error("Expected nil filter to match all results (return true)")
	}
}

// TestCheckFunctionsNilFilter tests that all check functions handle nil filter correctly
func TestCheckFunctionsNilFilter(t *testing.T) {
	result := &models.Result{
		Target: models.Target{
			Host: "192.168.1.1",
			Port: 80,
			Mode: models.ModeTCP,
		},
		Available: true,
		FirstSeen: time.Now(),
		LastSeen:  time.Now(),
	}

	// Test each check function with nil filter
	tests := []struct {
		name string
		fn   func(*models.Result, *models.ResultFilter) bool
	}{
		{"checkTimeRange", checkTimeRange},
		{"checkHost", checkHost},
		{"checkPort", checkPort},
		{"checkAvailability", checkAvailability},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			// Should not panic and should return true for nil filter
			matches := test.fn(result, nil)
			if !matches {
				t.Errorf("%s with nil filter should return true (match all)", test.name)
			}
		})
	}
}

// TestMatchesFilterNonNilFilter tests that normal filtering still works
func TestMatchesFilterNonNilFilter(t *testing.T) {
	store := &InMemoryStore{}

	result := &models.Result{
		Target: models.Target{
			Host: "192.168.1.1",
			Port: 80,
			Mode: models.ModeTCP,
		},
		Available: true,
		FirstSeen: time.Now(),
		LastSeen:  time.Now(),
	}

	// Test with matching filter
	filter := &models.ResultFilter{
		Host: "192.168.1.1",
		Port: 80,
	}

	matches := store.matchesFilter(result, filter)
	if !matches {
		t.Error("Expected matching filter to return true")
	}

	// Test with non-matching filter
	nonMatchingFilter := &models.ResultFilter{
		Host: "192.168.1.2", // Different host
		Port: 80,
	}

	matches = store.matchesFilter(result, nonMatchingFilter)
	if matches {
		t.Error("Expected non-matching filter to return false")
	}
}
