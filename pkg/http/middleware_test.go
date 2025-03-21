// pkg/http/middleware_test.go
package http

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestCommonMiddleware_CORS(t *testing.T) {
	corsConfig := models.CORSConfig{
		AllowedOrigins:   []string{"http://localhost:3000"},
		AllowCredentials: true,
	}

	handler := CommonMiddleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, err := w.Write([]byte("OK"))
		if err != nil {
			t.Errorf("Error writing response: %v", err)

			return
		}
	}), corsConfig)

	req := httptest.NewRequest(http.MethodGet, "/", http.NoBody)
	req.Header.Set("Origin", "http://localhost:3000")

	rr := httptest.NewRecorder()

	handler.ServeHTTP(rr, req)

	if status := rr.Code; status != http.StatusOK {
		t.Errorf("handler returned wrong status code: got %v want %v", status, http.StatusOK)
	}

	if rr.Header().Get("Access-Control-Allow-Origin") != "http://localhost:3000" {
		t.Errorf("CORS origin not set correctly: got %v", rr.Header().Get("Access-Control-Allow-Origin"))
	}

	// Test unallowed origin
	req = httptest.NewRequest(http.MethodGet, "/", http.NoBody)

	req.Header.Set("Origin", "http://evil.com")

	rr = httptest.NewRecorder()

	handler.ServeHTTP(rr, req)

	if rr.Header().Get("Access-Control-Allow-Origin") == "http://evil.com" {
		t.Errorf("CORS allowed an unpermitted origin")
	}
}
