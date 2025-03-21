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

	"github.com/carverauto/serviceradar/pkg/models"
)

func CommonMiddleware(next http.Handler, corsConfig models.CORSConfig) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
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
			// If origin isn't allowed, don't set ACAO header and proceed (or reject based on our policy)
			log.Printf("CORS: Origin %s not allowed", origin)
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

func APIKeyMiddleware(apiKey string) func(next http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			requestKey := r.Header.Get("X-API-Key")
			if requestKey == "" {
				requestKey = r.URL.Query().Get("api_key")
			}

			if requestKey == "" || (apiKey != "" && requestKey != apiKey) {
				log.Printf("Unauthorized API access attempt: %s %s", r.Method, r.URL.Path)
				http.Error(w, "Unauthorized", http.StatusUnauthorized)

				return
			}

			next.ServeHTTP(w, r)
		})
	}
}
