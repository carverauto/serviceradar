//go:build containers
// +build containers

// Package web pkg/cloud/api/web/container.go
package web

// GetStaticFilesPath returns the path to static files in container mode.
func GetStaticFilesPath() string {
	// Path where ko copies the .kodata directory contents in the container
	return "/ko-app/web/dist"
}
