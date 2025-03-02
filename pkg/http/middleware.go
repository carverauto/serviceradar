// Package httpx provides HTTP utilities for the application
package httpx

import (
	"log"
	"net/http"
	"os"
)

// CommonMiddleware returns an http.Handler that sets up typical
// headers (CORS, etc.) before calling the next handler.
func CommonMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type,Authorization,X-API-Key")

		if r.Method == http.MethodOptions {
			// Preflight request response
			w.WriteHeader(http.StatusOK)

			return
		}

		next.ServeHTTP(w, r)
	})
}

// APIKeyMiddleware creates middleware that validates API keys.
// It can accept an API key directly or read from the environment.
func APIKeyMiddleware(apiKeyParam string) func(next http.Handler) http.Handler {
	apiKey := apiKeyParam

	// Fall back to environment variable if not provided directly
	if apiKey == "" {
		apiKey = os.Getenv("API_KEY")
	}

	if apiKey == "" {
		log.Printf("WARNING: API_KEY not set, API endpoints are unprotected!")
	}

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Skip API key check if it's not configured (development mode)
			if apiKey == "" {
				next.ServeHTTP(w, r)

				return
			}

			// Check API key in header or query parameter
			requestKey := r.Header.Get("X-API-Key")
			if requestKey == "" {
				requestKey = r.URL.Query().Get("api_key")
			}

			// Validate API key
			if requestKey == "" || requestKey != apiKey {
				log.Printf("Unauthorized API access attempt: %s %s", r.Method, r.URL.Path)
				http.Error(w, "Unauthorized", http.StatusUnauthorized)

				return
			}

			next.ServeHTTP(w, r)
		})
	}
}
