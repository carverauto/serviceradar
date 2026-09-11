package agent

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// Default configuration and state roots. Windows keeps both under ProgramData,
// which survives upgrades and is writable by the service account; every other
// platform keeps the historical unix layout.
const (
	unixConfigDir             = "/etc/serviceradar"
	unixStateDir              = "/var/lib/serviceradar"
	unixLogDir                = "/var/log/serviceradar"
	windowsDefaultProgramData = `C:\ProgramData`
)

// DefaultConfigPath is the agent config file used when --config is not given.
func DefaultConfigPath() string {
	return filepath.Join(defaultConfigDir(), "agent.json")
}

// DefaultLogDir is where the agent writes its log file when it runs without a
// console (as a Windows service).
func DefaultLogDir() string {
	return logDirFor(runtime.GOOS, os.Getenv)
}

func defaultConfigDir() string {
	return configDirFor(runtime.GOOS, os.Getenv)
}

func defaultStateDir() string {
	return stateDirFor(runtime.GOOS, os.Getenv)
}

func configDirFor(goos string, getenv func(string) string) string {
	if goos == "windows" {
		return windowsServiceRadarDir(getenv, "config")
	}

	return unixConfigDir
}

func stateDirFor(goos string, getenv func(string) string) string {
	if goos == "windows" {
		return windowsServiceRadarDir(getenv, "data")
	}

	return unixStateDir
}

func logDirFor(goos string, getenv func(string) string) string {
	if goos == "windows" {
		return windowsServiceRadarDir(getenv, "logs")
	}

	return unixLogDir
}

// windowsServiceRadarDir builds the path with explicit backslashes so it is the
// same whichever platform computes it.
func windowsServiceRadarDir(getenv func(string) string, leaf string) string {
	root := strings.TrimRight(strings.TrimSpace(getenv("ProgramData")), `\/`)
	if root == "" {
		root = windowsDefaultProgramData
	}

	return root + `\ServiceRadar\` + leaf
}
