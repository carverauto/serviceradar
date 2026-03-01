// Package version provides version information for ServiceRadar.
package version

// These variables are set via ldflags during build
//
//nolint:gochecknoglobals // These are intentionally global for ldflags injection
var (
	version = "dev"
	buildID = "dev"
)

// GetVersion returns the current version
func GetVersion() string {
	return version
}

// GetBuildID returns the current build ID
func GetBuildID() string {
	return buildID
}

// GetFullVersion returns version with build ID
func GetFullVersion() string {
	return version + " (build: " + buildID + ")"
}
