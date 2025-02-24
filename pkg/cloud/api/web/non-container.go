//go:build !containers
// +build !containers

// Package web pkg/cloud/api/web/noncontainer.go
package web

// GetStaticFilesPath returns the path to static files in non-container mode.
func GetStaticFilesPath() string {
	// Default path for deb package installation
	return "/usr/local/share/serviceradar-cloud/web/dist"
}
