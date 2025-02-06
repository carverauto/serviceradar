package httpx

import (
	"net/http"
)

// CommonMiddleware returns an http.Handler that sets up typical
// headers (CORS, etc.) before calling the next handler.
func CommonMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type,Authorization")

		if r.Method == http.MethodOptions {
			// Possibly respond 200 here
			w.WriteHeader(http.StatusOK)
			return
		}

		// You might also add a request logging line:
		// TODO: should log for debug only
		// log.Printf("[HTTP] %s %s", r.Method, r.URL.Path)

		next.ServeHTTP(w, r)
	})
}
