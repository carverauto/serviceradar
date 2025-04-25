// Package swagger pkg/swagger/embed.go
package swagger

import (
	"embed"
	"io/fs"
	"net/http"
)

//go:embed swagger.json swagger.yaml docs.go
var SwaggerFiles embed.FS

// GetSwaggerHandler returns an http.Handler that serves the embedded Swagger files
func GetSwaggerHandler() http.Handler {
	// Get a sub-filesystem containing just the swagger files
	fsys, err := fs.Sub(SwaggerFiles, ".")
	if err != nil {
		panic(err)
	}

	// Return a handler that serves the embedded files
	return http.FileServer(http.FS(fsys))
}

// GetSwaggerJSON returns the swagger.json content as a byte slice
func GetSwaggerJSON() ([]byte, error) {
	return SwaggerFiles.ReadFile("swagger.json")
}

// GetSwaggerYAML returns the swagger.yaml content as a byte slice
func GetSwaggerYAML() ([]byte, error) {
	return SwaggerFiles.ReadFile("swagger.yaml")
}
