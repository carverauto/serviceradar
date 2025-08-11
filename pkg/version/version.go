package version

// These variables are set via ldflags during build
var (
	Version = "dev"
	BuildID = "dev"
)

// GetVersion returns the current version
func GetVersion() string {
	return Version
}

// GetBuildID returns the current build ID
func GetBuildID() string {
	return BuildID
}

// GetFullVersion returns version with build ID
func GetFullVersion() string {
	return Version + " (build: " + BuildID + ")"
}