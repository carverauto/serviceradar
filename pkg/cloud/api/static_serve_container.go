//go:build containers
// +build containers

package api

// configureStaticServing sets up static file serving for container mode
func (s *APIServer) configureStaticServing() {
	// Use Ko's approach for containers
	s.setupContainerStaticFileServing()
}
