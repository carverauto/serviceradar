package cpufreq

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/shirou/gopsutil/v3/cpu"
)

const (
	sysfsCpufreqPath = "/sys/devices/system/cpu"

	// FrequencySourceSysfs indicates the value came from the cpufreq sysfs interface.
	FrequencySourceSysfs = "sysfs"
	// FrequencySourceProcCPU indicates the value came from /proc/cpuinfo via gopsutil.
	FrequencySourceProcCPU = "procfs"
)

// ErrFrequencyUnavailable is returned when no frequency data could be gathered.
var ErrFrequencyUnavailable = errors.New("cpu frequency data unavailable")

// CoreFrequency represents the current frequency reading for a logical CPU.
type CoreFrequency struct {
	CoreID      int     // zero-based logical core ID
	FrequencyHz float64 // instantaneous frequency in Hz
	Source      string  // data source used (sysfs or procfs)
}

// Snapshot contains a collection of per-core frequency readings.
type Snapshot struct {
	Cores []CoreFrequency
}

// Collect gathers per-core CPU frequency readings using cpufreq sysfs where available,
// falling back to data exposed via /proc/cpuinfo through gopsutil.
func Collect(ctx context.Context) (*Snapshot, error) {
	logicalCount, err := cpu.CountsWithContext(ctx, true)
	if err != nil {
		return nil, fmt.Errorf("failed to determine logical cpu count: %w", err)
	}

	if logicalCount <= 0 {
		return nil, ErrFrequencyUnavailable
	}

	infoStats, err := cpu.InfoWithContext(ctx)
	if err != nil {
		// Treat as warning; fallback path may still succeed.
		infoStats = nil
	}

	fallbackByCore := make(map[int]float64, len(infoStats))
	for _, stat := range infoStats {
		coreID := int(stat.CPU)
		if coreID < 0 || stat.Mhz <= 0 {
			continue
		}
		// cpu.Info reports MHz.
		fallbackByCore[coreID] = stat.Mhz * 1_000_000
	}

	snapshot := &Snapshot{
		Cores: make([]CoreFrequency, 0, logicalCount),
	}

	for core := 0; core < logicalCount; core++ {
		if hz, ok := readSysfs(core); ok {
			snapshot.Cores = append(snapshot.Cores, CoreFrequency{
				CoreID:      core,
				FrequencyHz: hz,
				Source:      FrequencySourceSysfs,
			})
			continue
		}

		if hz, ok := fallbackByCore[core]; ok && hz > 0 {
			snapshot.Cores = append(snapshot.Cores, CoreFrequency{
				CoreID:      core,
				FrequencyHz: hz,
				Source:      FrequencySourceProcCPU,
			})
			continue
		}
	}

	if len(snapshot.Cores) == 0 {
		return nil, ErrFrequencyUnavailable
	}

	return snapshot, nil
}

func readSysfs(core int) (float64, bool) {
	path := filepath.Join(sysfsCpufreqPath, fmt.Sprintf("cpu%d/cpufreq/scaling_cur_freq", core))

	data, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}

	raw := strings.TrimSpace(string(data))
	if raw == "" {
		return 0, false
	}

	// scaling_cur_freq is reported in kHz.
	val, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return 0, false
	}

	return val * 1_000, true
}
