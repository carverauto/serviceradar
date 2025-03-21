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
)

func CommonMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*") // For testing; restrict in prod if needed
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-API-Key")
		w.Header().Set("Access-Control-Max-Age", "3600")           // Cache preflight for 1 hour
		w.Header().Set("Access-Control-Allow-Credentials", "true") // For cookies

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
