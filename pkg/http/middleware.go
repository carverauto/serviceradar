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

// Package http pkg/http/middleware.go
package http

import (
	"log"
	"net/http"
	"strings"

	"github.com/carverauto/serviceradar/pkg/models"
)

// CommonMiddleware handles CORS and other common HTTP concerns.
func CommonMiddleware(next http.Handler, corsConfig models.CORSConfig) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")

		// If there's no Origin header, this isn't a CORS request - let it through
		if origin == "" {
			next.ServeHTTP(w, r)

			return
		}

		allowed := false

		// Check if the request origin is in the allowed list
		for _, allowedOrigin := range corsConfig.AllowedOrigins {
			if allowedOrigin == origin || allowedOrigin == "*" {
				allowed = true

				w.Header().Set("Access-Control-Allow-Origin", origin)

				break
			}
		}

		if !allowed {
			// Log the rejected origin
			log.Printf("CORS: Origin %s not allowed. Allowed origins: %v", origin, corsConfig.AllowedOrigins)
			http.Error(w, "Origin not allowed", http.StatusForbidden)

			return
		}

		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")

		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-API-Key")

		w.Header().Set("Access-Control-Max-Age", "3600") // Cache preflight for 1 hour

		if corsConfig.AllowCredentials {
			w.Header().Set("Access-Control-Allow-Credentials", "true")
		} else {
			w.Header().Set("Access-Control-Allow-Credentials", "false")
		}

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusOK)

			return
		}

		next.ServeHTTP(w, r)
	})
}

type APIKeyOptions struct {
	// API key to validate against
	APIKey string
	// Paths to exclude from API key authentication (prefix-based)
	ExcludePaths []string
	// Whether to log unauthorized attempts
	LogUnauthorized bool
}

// NewAPIKeyOptions creates a new options struct with defaults.
func NewAPIKeyOptions(apiKey string) APIKeyOptions {
	return APIKeyOptions{
		APIKey:          apiKey,
		ExcludePaths:    []string{"/swagger/", "/api-docs"},
		LogUnauthorized: true,
	}
}

// APIKeyMiddleware checks for a valid API key on requests
// excludes specified paths from authentication.
func APIKeyMiddleware(apiKey string) func(next http.Handler) http.Handler {
	opts := NewAPIKeyOptions(apiKey)

	return APIKeyMiddlewareWithOptions(opts)
}

// APIKeyMiddlewareWithOptions is an enhanced version of APIKeyMiddleware
// that allows configuring exclude paths and other options.
func APIKeyMiddlewareWithOptions(opts APIKeyOptions) func(next http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Check if path should be excluded
			path := r.URL.Path

			for _, excludePath := range opts.ExcludePaths {
				if strings.HasPrefix(path, excludePath) {
					// Path is excluded from authentication, let it through
					next.ServeHTTP(w, r)

					return
				}
			}

			// print out all of hte headers
			for k, v := range r.Header {
				log.Printf("Header: %s: %s", k, v)
			}

			// Check for API key
			requestKey := r.Header.Get("X-API-Key")
			if requestKey == "" {
				requestKey = r.URL.Query().Get("api_key")
			}

			if requestKey == "" || (opts.APIKey != "" && requestKey != opts.APIKey) {
				if opts.LogUnauthorized {
					log.Printf("Unauthorized API access attempt: %s %s", r.Method, r.URL.Path)
				}

				http.Error(w, "Unauthorized", http.StatusUnauthorized)

				return
			}

			next.ServeHTTP(w, r)
		})
	}
}
