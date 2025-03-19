// Package http pkg/http/middleware.go
package http

import (
	"log"
	"net/http"
)

func CommonMiddleware(next http.Handler) http.Handler {
	log.Println("CommonMiddleware")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// log request
		log.Printf("%s %s %s", r.RemoteAddr, r.Method, r.URL.Path)

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
			log.Printf("API-KEY received: %s", requestKey)
			if requestKey == "" || (apiKey != "" && requestKey != apiKey) {
				log.Printf("Unauthorized API access attempt: %s %s", r.Method, r.URL.Path)
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
