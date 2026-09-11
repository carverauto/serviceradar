package cli

import "testing"

func TestEnrollDefaultsFollowTheInstalledAgent(t *testing.T) {
	env := func(values map[string]string) func(string) string {
		return func(key string) string { return values[key] }
	}

	unix := enrollDefaultsFor("linux", env(nil))
	if unix.ConfigPath != "/etc/serviceradar/agent.json" || unix.CertDir != "/etc/serviceradar/certs" {
		t.Fatalf("linux defaults = %+v", unix)
	}

	if mac := enrollDefaultsFor("darwin", env(nil)); mac != unix {
		t.Fatalf("darwin defaults = %+v, want the Linux layout", mac)
	}

	win := enrollDefaultsFor("windows", env(map[string]string{"ProgramData": `D:\ProgramData\`}))
	want := enrollDefaults{
		ConfigPath: `D:\ProgramData\ServiceRadar\config\agent.json`,
		ConfigDir:  `D:\ProgramData\ServiceRadar\config`,
		CertDir:    `D:\ProgramData\ServiceRadar\config\certs`,
		CredsDir:   `D:\ProgramData\ServiceRadar\config\creds`,
	}
	if win != want {
		t.Fatalf("windows defaults = %+v, want %+v", win, want)
	}

	if got := enrollDefaultsFor("windows", env(nil)).ConfigPath; got != `C:\ProgramData\ServiceRadar\config\agent.json` {
		t.Fatalf("windows fallback config path = %q", got)
	}
}
