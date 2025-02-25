//go:build containers
// +build containers

package api

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/carverauto/serviceradar/pkg/cloud/api/web"
)

// configureStaticServing sets up static file serving for container mode
func (s *APIServer) configureStaticServing() {
	staticFilesPath := web.GetStaticFilesPath()
	fileServer := http.FileServer(http.Dir(staticFilesPath))

	s.router.PathPrefix("/").HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Check if file exists
		path := filepath.Join(staticFilesPath, r.URL.Path)
		_, err := os.Stat(path)

		// If file doesn't exist or is a directory (and not root), serve index.html
		if os.IsNotExist(err) || (r.URL.Path != "/" && strings.HasSuffix(r.URL.Path, "/")) {
			http.ServeFile(w, r, filepath.Join(staticFilesPath, "index.html"))
			return
		}

		// Otherwise serve the requested file
		fileServer.ServeHTTP(w, r)
	})
}
