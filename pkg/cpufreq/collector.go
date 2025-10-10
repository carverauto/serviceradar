package cpufreq

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v3/cpu"
)

const (
	sysfsCpufreqPath = "/sys/devices/system/cpu"

	// FrequencySourceSysfs indicates the value came from the cpufreq sysfs interface.
	FrequencySourceSysfs = "sysfs"
	// FrequencySourceProcCPU indicates the value came from /proc/cpuinfo via gopsutil.
	FrequencySourceProcCPU = "procfs"
	// FrequencySourcePerf indicates the value was derived from perf counters.
	FrequencySourcePerf = "perf"
	// FrequencySourceHostfreq indicates the value was provided by the macOS host helper.
	FrequencySourceHostfreq = "hostfreq"
)

// ErrFrequencyUnavailable is returned when no frequency data could be gathered.
var ErrFrequencyUnavailable = errors.New("cpu frequency data unavailable")

// CoreFrequency represents the current frequency reading for a logical CPU.
type CoreFrequency struct {
	CoreID      int     // zero-based logical core ID
	FrequencyHz float64 // instantaneous frequency in Hz
	Source      string  // data source used (sysfs, procfs, perf)
}

// Snapshot contains a collection of per-core frequency readings.
type Snapshot struct {
	Cores []CoreFrequency
}

type collectorDeps struct {
	countsWithContext     func(context.Context, bool) (int, error)
	infoWithContext       func(context.Context) ([]cpu.InfoStat, error)
	readSysfs             func(int) (float64, bool)
	sampleFrequency       func(context.Context, int, time.Duration) (float64, error)
	hostfreqPathResolver  func() (string, error)
	hostfreqCommandRunner func(context.Context, string, []string) ([]byte, error)
}

func defaultCollectorDeps() collectorDeps {
	return collectorDeps{
		countsWithContext:     cpu.CountsWithContext,
		infoWithContext:       cpu.InfoWithContext,
		readSysfs:             readSysfs,
		sampleFrequency:       sampleFrequencyWithPerf,
		hostfreqPathResolver:  resolveHostfreqPath,
		hostfreqCommandRunner: runHostfreqCommand,
	}
}

type option func(*collectorDeps)

const (
	defaultSampleWindow = 100 * time.Millisecond
	minSampleWindow     = 10 * time.Millisecond
)

// Collect gathers per-core CPU frequency readings using cpufreq sysfs where available,
// falling back to data exposed via /proc/cpuinfo through gopsutil and perf counters.
func Collect(ctx context.Context) (*Snapshot, error) {
	return collect(ctx, defaultSampleWindow)
}

// NewCollector returns a collection function that samples using the provided window.
func NewCollector(window time.Duration) func(context.Context) (*Snapshot, error) {
	if window < minSampleWindow {
		window = defaultSampleWindow
	}
	return func(ctx context.Context) (*Snapshot, error) {
		return collect(ctx, window)
	}
}

func collect(ctx context.Context, window time.Duration, opts ...option) (*Snapshot, error) {
	deps := defaultCollectorDeps()
	for _, opt := range opts {
		opt(&deps)
	}

	if runtime.GOOS == "darwin" {
		if snap, err := collectViaHostfreq(ctx, window, deps); err == nil {
			return snap, nil
		} else if !errors.Is(err, ErrFrequencyUnavailable) {
			return nil, err
		}
	}

	return collectStandard(ctx, window, deps)
}

func collectStandard(ctx context.Context, window time.Duration, deps collectorDeps) (*Snapshot, error) {
	logicalCount, err := deps.countsWithContext(ctx, true)
	if err != nil {
		return nil, fmt.Errorf("failed to determine logical cpu count: %w", err)
	}

	if logicalCount <= 0 {
		return nil, ErrFrequencyUnavailable
	}

	infoStats, err := deps.infoWithContext(ctx)
	if err != nil {
		infoStats = nil
	}

	fallbackByCore := make(map[int]float64, len(infoStats))
	for _, stat := range infoStats {
		coreID := int(stat.CPU)
		if coreID < 0 || stat.Mhz <= 0 {
			continue
		}
		fallbackByCore[coreID] = stat.Mhz * 1_000_000
	}

	snapshot := &Snapshot{
		Cores: make([]CoreFrequency, 0, logicalCount),
	}

	for core := 0; core < logicalCount; core++ {
		if hz, ok := deps.readSysfs(core); ok {
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

		hz, err := deps.sampleFrequency(ctx, core, window)
		if err != nil {
			snapshot.Cores = append(snapshot.Cores, CoreFrequency{
				CoreID:      core,
				FrequencyHz: 0,
				Source:      FrequencySourcePerf,
			})
			continue
		}

		snapshot.Cores = append(snapshot.Cores, CoreFrequency{
			CoreID:      core,
			FrequencyHz: hz,
			Source:      FrequencySourcePerf,
		})
	}

	return snapshot, nil
}

type hostfreqCore struct {
	Name   string  `json:"name"`
	AvgMHz float64 `json:"avg_mhz"`
}

type hostfreqPayload struct {
	Cores []hostfreqCore `json:"cores"`
}

func collectViaHostfreq(ctx context.Context, window time.Duration, deps collectorDeps) (*Snapshot, error) {
	path, err := deps.hostfreqPathResolver()
	if err != nil {
		return nil, err
	}

	interval := int(window / time.Millisecond)
	if interval <= 0 {
		interval = int(defaultSampleWindow / time.Millisecond)
	}

	args := []string{
		"--interval-ms", strconv.Itoa(interval),
		"--samples", "1",
	}

	output, err := deps.hostfreqCommandRunner(ctx, path, args)
	if err != nil {
		return nil, fmt.Errorf("hostfreq command failed: %w", err)
	}

	decoder := json.NewDecoder(bytes.NewReader(output))
	var payload hostfreqPayload
	if err := decoder.Decode(&payload); err != nil {
		return nil, fmt.Errorf("failed to parse hostfreq output: %w", err)
	}

	if len(payload.Cores) == 0 {
		return nil, ErrFrequencyUnavailable
	}

	snapshot := &Snapshot{
		Cores: make([]CoreFrequency, 0, len(payload.Cores)),
	}

	for idx, core := range payload.Cores {
		hz := core.AvgMHz * 1_000_000
		if hz < 0 {
			hz = 0
		}

		snapshot.Cores = append(snapshot.Cores, CoreFrequency{
			CoreID:      idx,
			FrequencyHz: hz,
			Source:      FrequencySourceHostfreq,
		})
	}

	return snapshot, nil
}

func resolveHostfreqPath() (string, error) {
	candidates := []string{
		os.Getenv("SERVICERADAR_HOSTFREQ_PATH"),
		"/usr/local/libexec/serviceradar/hostfreq",
		"/usr/local/bin/hostfreq",
		"/opt/serviceradar/bin/hostfreq",
	}

	for _, candidate := range candidates {
		if candidate == "" {
			continue
		}
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate, nil
		}
	}

	return "", ErrFrequencyUnavailable
}

func runHostfreqCommand(ctx context.Context, path string, args []string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, path, args...)
	return cmd.Output()
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
