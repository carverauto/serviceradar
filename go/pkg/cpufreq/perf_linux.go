//go:build linux

package cpufreq

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

var (
	errPerfTimeEnabledZero   = errors.New("perf timeEnabled zero")
	errNegativeFrequency     = errors.New("negative frequency")
	errUnexpectedPerfReadLen = errors.New("unexpected perf read length")
)

func sampleFrequencyWithPerf(ctx context.Context, core int, window time.Duration) (float64, error) {
	if window < minSampleWindow {
		window = defaultSampleWindow
	}

	attr := unix.PerfEventAttr{
		Type:        unix.PERF_TYPE_HARDWARE,
		Size:        uint32(unsafe.Sizeof(unix.PerfEventAttr{})),
		Config:      unix.PERF_COUNT_HW_CPU_CYCLES,
		Read_format: unix.PERF_FORMAT_TOTAL_TIME_ENABLED | unix.PERF_FORMAT_TOTAL_TIME_RUNNING,
		Bits:        unix.PerfBitDisabled | unix.PerfBitInherit,
	}

	fd, err := unix.PerfEventOpen(&attr, -1, core, -1, unix.PERF_FLAG_FD_CLOEXEC)
	if err != nil {
		return 0, err
	}
	defer func() {
		_ = unix.Close(fd)
	}()

	if err := unix.IoctlSetInt(fd, unix.PERF_EVENT_IOC_RESET, 0); err != nil {
		return 0, err
	}
	if err := unix.IoctlSetInt(fd, unix.PERF_EVENT_IOC_ENABLE, 0); err != nil {
		return 0, err
	}

	timer := time.NewTimer(window)
	select {
	case <-ctx.Done():
		timer.Stop()
		_ = unix.IoctlSetInt(fd, unix.PERF_EVENT_IOC_DISABLE, 0)
		return 0, ctx.Err()
	case <-timer.C:
	}

	if err := unix.IoctlSetInt(fd, unix.PERF_EVENT_IOC_DISABLE, 0); err != nil {
		return 0, err
	}

	var buf [3]uint64
	if err := readPerf(fd, buf[:]); err != nil {
		return 0, err
	}

	rawCycles := float64(buf[0])
	timeEnabled := float64(buf[1])
	timeRunning := float64(buf[2])

	if timeEnabled <= 0 {
		return 0, errPerfTimeEnabledZero
	}

	effectiveCycles := rawCycles
	if timeRunning > 0 && timeRunning != timeEnabled {
		effectiveCycles *= timeEnabled / timeRunning
	}

	freqHz := effectiveCycles / (timeEnabled / float64(time.Second))
	if freqHz < 0 {
		return 0, errNegativeFrequency
	}

	return freqHz, nil
}

func readPerf(fd int, buf []uint64) error {
	bytes := make([]byte, len(buf)*8)
	n, err := unix.Read(fd, bytes)
	if err != nil {
		return err
	}
	if n != len(bytes) {
		return fmt.Errorf("%w: got %d bytes", errUnexpectedPerfReadLen, n)
	}
	for i := range buf {
		buf[i] = binary.LittleEndian.Uint64(bytes[i*8 : (i+1)*8])
	}
	return nil
}
