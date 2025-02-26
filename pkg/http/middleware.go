// Package httpx provides HTTP utilities for the application
package httpx

import (
	"log"
	"net/http"
	"os"
	"strings"
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

		// You might also add a request logging line:
		// TODO: should log for debug only
		// log.Printf("[HTTP] %s %s", r.Method, r.URL.Path)

		next.ServeHTTP(w, r)
	})
}

// APIKeyMiddleware creates middleware that validates API keys.
func APIKeyMiddleware(next http.Handler) http.Handler {
	apiKey := os.Getenv("API_KEY")
	if apiKey == "" {
		log.Printf("WARNING: API_KEY environment variable not set, API endpoints are unprotected!")
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Skip API key check for static file requests
		if isStaticFileRequest(r.URL.Path) {
			next.ServeHTTP(w, r)

			return
		}

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

// isStaticFileRequest returns true if the request is for static content.
func isStaticFileRequest(path string) bool {
	// Skip API key check for static files (adjust as needed)
	staticExtensions := []string{".js", ".css", ".html", ".png", ".jpg", ".svg", ".ico", ".woff", ".woff2"}

	for _, ext := range staticExtensions {
		if strings.HasSuffix(path, ext) {
			return true
		}
	}

	// Also skip for the root path (which serves index.html)
	return path == "/"
}
