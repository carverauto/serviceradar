package cli

import (
	"os"
	"runtime"
	"strings"
)

// enrollDefaults are srctl enroll's default locations: where the installed agent
// reads its config and certificates on each platform.
type enrollDefaults struct {
	ConfigPath string
	ConfigDir  string
	CertDir    string
	CredsDir   string
}

func platformEnrollDefaults() enrollDefaults {
	return enrollDefaultsFor(runtime.GOOS, os.Getenv)
}

// enrollDefaultsFor builds Windows paths with explicit backslashes so they are
// the same whichever platform computes them. The Windows agent service reads
// %ProgramData%\ServiceRadar\config\agent.json.
func enrollDefaultsFor(goos string, getenv func(string) string) enrollDefaults {
	if goos == "windows" {
		root := strings.TrimRight(strings.TrimSpace(getenv("ProgramData")), `\/`)
		if root == "" {
			root = `C:\ProgramData`
		}

		config := root + `\ServiceRadar\config`

		return enrollDefaults{
			ConfigPath: config + `\agent.json`,
			ConfigDir:  config,
			CertDir:    config + `\certs`,
			CredsDir:   config + `\creds`,
		}
	}

	return enrollDefaults{
		ConfigPath: "/etc/serviceradar/agent.json",
		ConfigDir:  "/etc/serviceradar",
		CertDir:    "/etc/serviceradar/certs",
		CredsDir:   "/etc/serviceradar/creds",
	}
}
