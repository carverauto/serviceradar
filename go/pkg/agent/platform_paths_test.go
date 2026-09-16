package agent

import "testing"

func TestPlatformDefaultDirs(t *testing.T) {
	t.Parallel()

	env := func(values map[string]string) func(string) string {
		return func(key string) string { return values[key] }
	}

	tests := []struct {
		name       string
		goos       string
		env        map[string]string
		wantConfig string
		wantState  string
		wantLog    string
	}{
		{"linux keeps the unix layout", "linux", nil, "/etc/serviceradar", "/var/lib/serviceradar", "/var/log/serviceradar"},
		{"darwin keeps the unix layout", "darwin", nil, "/etc/serviceradar", "/var/lib/serviceradar", "/var/log/serviceradar"},
		{
			"windows uses ProgramData", "windows", map[string]string{"ProgramData": `D:\ProgramData`},
			`D:\ProgramData\ServiceRadar\config`, `D:\ProgramData\ServiceRadar\data`, `D:\ProgramData\ServiceRadar\logs`,
		},
		{
			"windows trims a trailing separator", "windows", map[string]string{"ProgramData": `D:\ProgramData\`},
			`D:\ProgramData\ServiceRadar\config`, `D:\ProgramData\ServiceRadar\data`, `D:\ProgramData\ServiceRadar\logs`,
		},
		{
			"windows falls back when ProgramData is unset", "windows", nil,
			`C:\ProgramData\ServiceRadar\config`, `C:\ProgramData\ServiceRadar\data`, `C:\ProgramData\ServiceRadar\logs`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			if got := configDirFor(tt.goos, env(tt.env)); got != tt.wantConfig {
				t.Errorf("configDirFor(%q) = %q, want %q", tt.goos, got, tt.wantConfig)
			}
			if got := stateDirFor(tt.goos, env(tt.env)); got != tt.wantState {
				t.Errorf("stateDirFor(%q) = %q, want %q", tt.goos, got, tt.wantState)
			}
			if got := logDirFor(tt.goos, env(tt.env)); got != tt.wantLog {
				t.Errorf("logDirFor(%q) = %q, want %q", tt.goos, got, tt.wantLog)
			}
		})
	}
}
