//go:build !containers
// +build !containers

package api

// configureStaticServing sets up static file serving for non-container mode.
func (s *APIServer) configureStaticServing() {
	// Use embedded FS for regular builds
	s.setupStaticFileServing()
}
