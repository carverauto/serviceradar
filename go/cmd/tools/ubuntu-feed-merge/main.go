// ubuntu-feed-merge validates Canonical's compact OSV and OpenVEX tar.xz feeds,
// prepares bounded compressed spools, and streams sorted pairs to Elixir.
package main

import (
	"archive/tar"
	"container/heap"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/klauspost/compress/zstd"
	"github.com/ulikunitz/xz"
)

const (
	recordFrame                byte = 1
	controlFrame               byte = 2
	runVersion                      = 2
	runHeaderBytes                  = 8 + sha256.Size
	maxAuditControlBytes            = 64 << 10
	maxRunDecoderWindowBytes        = 8 << 20
	minRunDecoderResidentBytes      = 16 << 20
	mergeWriterResidentBytes        = 16 << 20
	osvKind                         = "osv"
	vexKind                         = "vex"
	legacyTarRegularType       byte = 0
)

const (
	defaultMemberCap     int64 = 250_000
	defaultPathBytesCap  int64 = 1024
	defaultTotalBytesCap int64 = 40 << 30
	// A decoded run can contain every accepted payload byte plus one frame and
	// maximum-length CVE key per member. This streaming cap does not reserve RAM.
	defaultDecodedBytesCap = defaultTotalBytesCap +
		defaultMemberCap*(runHeaderBytes+defaultPathBytesCap)
)

var (
	osvPath = regexp.MustCompile(`^osv/cve/([0-9]{4})/UBUNTU-(CVE-([0-9]{4})-[0-9]{4,})\.json$`)
	vexPath = regexp.MustCompile(`^vex/cve/([0-9]{4})/(CVE-([0-9]{4})-[0-9]{4,})\.json$`)
	cveName = regexp.MustCompile(`^CVE-[0-9]{4}-[0-9]{4,}$`)
	cveInID = regexp.MustCompile(`CVE-[0-9]{4}-[0-9]{4,}`)
)

type limits struct {
	members      int64
	pathBytes    int64
	fileBytes    int64
	totalBytes   int64
	archiveBytes int64
	workBytes    int64
	dictBytes    int
	chunkBytes   int64
	decodedBytes int64
	// encodedBytes optionally lowers the structural per-manifest wire bound.
	// Zero uses the bound derived from validated record counts and frame size.
	encodedBytes     int64
	decoderBytes     int64
	residentBytes    int64
	fanIn            int
	frameBytes       int
	projection       projectionLimits
	afterArchiveOpen func(kind string) error
}

func defaultLimits() limits {
	return limits{
		members:       defaultMemberCap,
		pathBytes:     defaultPathBytesCap,
		fileBytes:     64 << 20,
		totalBytes:    defaultTotalBytesCap,
		archiveBytes:  256 << 20,
		workBytes:     1 << 30,
		dictBytes:     64 << 20,
		chunkBytes:    64 << 20,
		decodedBytes:  defaultDecodedBytesCap,
		encodedBytes:  0,
		decoderBytes:  16 << 20,
		residentBytes: 256 << 20,
		fanIn:         16,
		frameBytes:    maxProjectionFrameBytes,
		projection:    defaultProjectionLimits(),
	}
}

type ref struct {
	CVE string `json:"cve"`
}

type inventory struct {
	Kind          string `json:"kind"`
	Spool         string `json:"spool"`
	Refs          []ref  `json:"refs"`
	Count         int64  `json:"count"`
	Members       int64  `json:"members"`
	Total         int64  `json:"total"`
	ArchiveBytes  int64  `json:"archive_bytes"`
	ArchiveSHA256 string `json:"archive_sha256"`
	SpoolBytes    int64  `json:"spool_bytes"`
	InitialRuns   int    `json:"initial_runs"`
	MergePasses   int    `json:"merge_passes"`
}

type manifest struct {
	Version           int       `json:"version"`
	ProjectionVersion int       `json:"projection_version"`
	OSV               inventory `json:"osv"`
	VEX               inventory `json:"vex"`
	InputBytes        int64     `json:"input_bytes"`
	WorkBytes         int64     `json:"work_bytes"`
	PeakWorkBytes     int64     `json:"peak_work_bytes"`
	WorkLimitBytes    int64     `json:"work_limit_bytes"`
}

type runRecord struct {
	CVE string
	Raw []byte
}

type runFile struct {
	path string
	size int64
}

var errWorkCap = errors.New("helper work cap exceeded")

var errEncodedOutputCap = errors.New("encoded output cap exceeded")

var errProjectedWireByteBound = errors.New("projected wire byte bound overflow")

var errResidentCap = errors.New("merge resident memory cap exceeded")

//nolint:err113 // This internal validator returns exact CLI diagnostics; callers do not match these errors.
func validateLimits(lim limits) error {
	maxInt := int64(^uint(0) >> 1)
	if lim.members <= 0 || lim.pathBytes <= 0 || lim.pathBytes > maxInt ||
		lim.fileBytes <= 0 || lim.fileBytes > maxInt || lim.totalBytes <= 0 ||
		lim.archiveBytes <= 0 || lim.workBytes <= 0 || lim.dictBytes <= 0 ||
		lim.chunkBytes <= 0 || lim.decodedBytes <= 0 || lim.encodedBytes < 0 ||
		lim.decoderBytes < minRunDecoderResidentBytes || lim.residentBytes <= 0 ||
		lim.fanIn < 2 || lim.frameBytes <= 0 || lim.projection.logicalProducts <= 0 ||
		lim.projection.assertions <= 0 || lim.projection.jsonTokens <= 0 || lim.projection.jsonNesting <= 0 {
		return errors.New("invalid helper limits")
	}
	if _, err := projectedWireByteBound(lim); err != nil {
		return errors.New("invalid helper limits")
	}
	if lim.members > (math.MaxInt64-(1<<20))/2048 {
		return errors.New("invalid helper limits")
	}
	memberOverhead := lim.members * 2048
	if lim.totalBytes > math.MaxInt64-memberOverhead-(1<<20) ||
		lim.fileBytes > math.MaxInt64-lim.chunkBytes-(16<<20) ||
		lim.fileBytes > math.MaxInt64-lim.pathBytes ||
		lim.fileBytes+lim.pathBytes > math.MaxInt64-lim.decoderBytes {
		return errors.New("invalid helper limits")
	}
	return nil
}

func projectedWireByteBound(lim limits) (int64, error) {
	if lim.members <= 0 || lim.members > (math.MaxInt64-1)/2 {
		return 0, errProjectedWireByteBound
	}
	return projectedRecordWireByteBound(2*lim.members, lim.frameBytes)
}

func projectedManifestWireByteBound(m *manifest, lim limits) (int64, error) {
	if m == nil || m.OSV.Count < 0 || m.VEX.Count < 0 || m.OSV.Count > math.MaxInt64-m.VEX.Count {
		return 0, errProjectedWireByteBound
	}
	return projectedRecordWireByteBound(m.OSV.Count+m.VEX.Count, lim.frameBytes)
}

func projectedRecordWireByteBound(recordCount int64, configuredFrameLimit int) (int64, error) {
	frameLimit := configuredFrameLimit
	if frameLimit > maxProjectionFrameBytes {
		frameLimit = maxProjectionFrameBytes
	}
	if recordCount < 0 || recordCount == math.MaxInt64 || frameLimit <= 0 {
		return 0, errProjectedWireByteBound
	}
	frameCount := recordCount + 1
	framedBytes := int64(frameLimit) + 4
	if frameCount > math.MaxInt64/framedBytes {
		return 0, errProjectedWireByteBound
	}
	return frameCount * framedBytes, nil
}

type workBudget struct {
	limit int64
	used  int64
	peak  int64
}

func (b *workBudget) reserve(n int64) error {
	if n < 0 || n > b.limit-b.used {
		return errWorkCap
	}
	b.used += n
	if b.used > b.peak {
		b.peak = b.used
	}
	return nil
}

func (b *workBudget) release(n int64) {
	b.used -= n
	if b.used < 0 {
		panic("ubuntu feed helper work budget underflow")
	}
}

type budgetWriter struct {
	w       io.Writer
	budget  *workBudget
	written int64
}

//nolint:err113 // The writer rejects malformed implementations with an exact internal diagnostic.
func (w *budgetWriter) Write(p []byte) (int, error) {
	if err := w.budget.reserve(int64(len(p))); err != nil {
		return 0, err
	}
	n, err := w.w.Write(p)
	if n < 0 || n > len(p) {
		w.budget.release(int64(len(p)))
		return 0, errors.New("invalid file write count")
	}
	if n < len(p) {
		w.budget.release(int64(len(p) - n))
	}
	w.written += int64(n)
	if err == nil && n != len(p) {
		err = io.ErrShortWrite
	}
	return n, err
}

//nolint:err113 // Header validation diagnostics are consumed as text at the CLI boundary.
func safeHeader(h *tar.Header, lim limits) error {
	name := strings.TrimSuffix(h.Name, "/")
	if name == "" || int64(len(h.Name)) > lim.pathBytes || strings.ContainsAny(h.Name, "\\\x00") || path.IsAbs(h.Name) || path.Clean(name) != name || name == ".." || strings.HasPrefix(name, "../") {
		return fmt.Errorf("unsafe path %q", h.Name)
	}
	if h.Size < 0 || h.Size > lim.fileBytes {
		return fmt.Errorf("file cap exceeded for %q", h.Name)
	}
	if !isRegularTarType(h.Typeflag) && h.Typeflag != tar.TypeDir {
		return fmt.Errorf("unsupported type %d for %q", h.Typeflag, h.Name)
	}
	return nil
}

func validateIdentity(kind, cve string, raw []byte) error {
	return validateIdentityWithLimits(kind, cve, raw, defaultProjectionLimits())
}

func validateIdentityWithLimits(kind, cve string, raw []byte, projectionLimits projectionLimits) error {
	_, err := preflightDocumentStructure(kind, cve, raw, projectionLimits)
	return err
}

func validTimestamp(value string) bool {
	if value == "" {
		return false
	}
	_, err := time.Parse(time.RFC3339Nano, value)
	return err == nil
}

//nolint:err113 // Path validation diagnostics are consumed as text at the CLI boundary.
func archiveCVE(kind, name string) (string, bool, error) {
	re := osvPath
	prefix := "osv/cve/"
	if kind == vexKind {
		re = vexPath
		prefix = "vex/cve/"
	}
	match := re.FindStringSubmatch(name)
	if len(match) == 0 {
		if strings.HasPrefix(name, prefix) {
			return "", false, fmt.Errorf("unexpected %s CVE path %q", kind, name)
		}
		return "", false, nil
	}
	if match[1] != match[3] {
		return "", false, fmt.Errorf("%s CVE path year mismatch %q", kind, name)
	}
	return match[2], true, nil
}

type hardLimitReader struct {
	r         io.Reader
	remaining int64
}

//nolint:err113 // The reader reports a precise local cap violation; callers do not match it.
func (r *hardLimitReader) Read(p []byte) (int, error) {
	if r.remaining == 0 {
		var one [1]byte
		n, err := r.r.Read(one[:])
		if n > 0 {
			return 0, errors.New("expanded archive cap exceeded")
		}
		return 0, err
	}
	if int64(len(p)) > r.remaining {
		p = p[:int(r.remaining)]
	}
	n, err := r.r.Read(p)
	r.remaining -= int64(n)
	return n, err
}

type archiveInput struct {
	file *os.File
	info os.FileInfo
	size int64
}

func (input *archiveInput) close() {
	if input != nil && input.file != nil {
		_ = input.file.Close()
	}
}

//nolint:err113 // Archive validation diagnostics are consumed as text at the CLI boundary.
func openArchive(filename, kind string, lim limits) (*archiveInput, error) {
	st, err := os.Lstat(filename)
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() || st.Size() < 0 || st.Size() > lim.archiveBytes {
		return nil, errors.New("unsafe or oversized input archive")
	}
	f, err := os.Open(filename)
	if err != nil {
		return nil, err
	}
	openedInfo, err := f.Stat()
	if err != nil || !openedInfo.Mode().IsRegular() || openedInfo.Size() != st.Size() || !os.SameFile(st, openedInfo) {
		_ = f.Close()
		return nil, errors.New("archive changed while opening")
	}
	input := &archiveInput{file: f, info: openedInfo, size: openedInfo.Size()}
	if lim.afterArchiveOpen != nil {
		if err := lim.afterArchiveOpen(kind); err != nil {
			input.close()
			return nil, err
		}
	}
	return input, nil
}

type archiveRunState struct {
	chunk      []runRecord
	chunkBytes int64
	runs       []runFile
}

//nolint:err113 // Duplicate identities are exact validation diagnostics local to this CLI.
func (state *archiveRunState) flush(kind, outDir string, budget *workBudget) error {
	if len(state.chunk) == 0 {
		return nil
	}
	sort.Slice(state.chunk, func(i, j int) bool { return state.chunk[i].CVE < state.chunk[j].CVE })
	for i := 1; i < len(state.chunk); i++ {
		if state.chunk[i-1].CVE == state.chunk[i].CVE {
			return fmt.Errorf("duplicate CVE %s", state.chunk[i].CVE)
		}
	}
	destination := filepath.Join(outDir, fmt.Sprintf(".%s-run-%06d.zst", kind, len(state.runs)))
	size, err := writeRunAtomic(destination, budget, func(yield func(runRecord) error) error {
		for i := range state.chunk {
			if err := yield(state.chunk[i]); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	state.runs = append(state.runs, runFile{path: destination, size: size})
	state.chunk = make([]runRecord, 0, 1024)
	state.chunkBytes = 0
	return nil
}

func isRegularTarType(typeFlag byte) bool {
	return typeFlag == tar.TypeReg || typeFlag == legacyTarRegularType
}

//nolint:err113 // Member validation diagnostics are consumed as text at the CLI boundary.
func consumeArchiveMember(tr *tar.Reader, header *tar.Header, kind, outDir string, lim limits, budget *workBudget, inv *inventory, state *archiveRunState) error {
	cve, matched, err := archiveCVE(kind, header.Name)
	if err != nil {
		if header.Typeflag == tar.TypeDir && strings.HasPrefix(header.Name, kind+"/cve/") {
			return nil
		}
		return err
	}
	if !matched {
		if isRegularTarType(header.Typeflag) {
			if _, err := io.Copy(io.Discard, tr); err != nil {
				return fmt.Errorf("read ignored %s member: %w", kind, err)
			}
		}
		return nil
	}
	if !isRegularTarType(header.Typeflag) {
		return errors.New("CVE member not regular")
	}
	raw, err := io.ReadAll(tr)
	if err != nil || int64(len(raw)) != header.Size {
		return errors.New("truncated member")
	}
	if err := validateIdentityWithLimits(kind, cve, raw, lim.projection); err != nil {
		return fmt.Errorf("%s: %w", header.Name, err)
	}
	cost := int64(runHeaderBytes + len(cve) + len(raw))
	if len(state.chunk) > 0 && state.chunkBytes > lim.chunkBytes-cost {
		if err := state.flush(kind, outDir, budget); err != nil {
			return err
		}
	}
	state.chunk = append(state.chunk, runRecord{CVE: cve, Raw: raw})
	state.chunkBytes += cost
	inv.Count++
	return nil
}

//nolint:err113 // Archive cap violations are exact validation diagnostics local to this CLI.
func readArchiveMembers(tr *tar.Reader, kind, outDir string, lim limits, budget *workBudget, inv *inventory, state *archiveRunState) error {
	for {
		header, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("read %s tar: %w", kind, err)
		}
		inv.Members++
		if inv.Members > lim.members {
			return errors.New("member cap exceeded")
		}
		if err := safeHeader(header, lim); err != nil {
			return err
		}
		if header.Size > lim.totalBytes-inv.Total {
			return errors.New("total cap exceeded")
		}
		inv.Total += header.Size
		if err := consumeArchiveMember(tr, header, kind, outDir, lim, budget, inv, state); err != nil {
			return err
		}
	}
}

//nolint:err113 // Preparation validates immutable archive identity and reports exact CLI diagnostics.
func prepareOne(input *archiveInput, kind, outDir string, lim limits, budget *workBudget) (inventory, error) {
	inv := inventory{Kind: kind, Spool: kind + ".spool", ArchiveBytes: input.size}
	if _, err := input.file.Seek(0, io.SeekStart); err != nil {
		return inv, err
	}
	hasher := sha256.New()
	limited := &io.LimitedReader{R: input.file, N: input.size}
	hashed := io.TeeReader(limited, hasher)
	xr, err := (xz.ReaderConfig{DictCap: lim.dictBytes}).NewReader(hashed)
	if err != nil {
		return inv, fmt.Errorf("open %s xz: %w", kind, err)
	}
	expandedCap := lim.totalBytes + lim.members*2048 + 1<<20
	capped := &hardLimitReader{r: xr, remaining: expandedCap}
	state := archiveRunState{chunk: make([]runRecord, 0, 1024)}
	if err := readArchiveMembers(tar.NewReader(capped), kind, outDir, lim, budget, &inv, &state); err != nil {
		return inv, err
	}
	if _, err := io.Copy(io.Discard, capped); err != nil {
		return inv, fmt.Errorf("finish %s xz stream: %w", kind, err)
	}
	if _, err := io.Copy(io.Discard, hashed); err != nil || limited.N != 0 {
		return inv, fmt.Errorf("%s archive changed during preparation", kind)
	}
	consumedInfo, err := input.file.Stat()
	if err != nil || !consumedInfo.Mode().IsRegular() || consumedInfo.Size() != input.size || !os.SameFile(input.info, consumedInfo) {
		return inv, fmt.Errorf("%s archive changed during preparation", kind)
	}
	inv.ArchiveSHA256 = hex.EncodeToString(hasher.Sum(nil))
	if err := state.flush(kind, outDir, budget); err != nil {
		return inv, err
	}
	if inv.Count == 0 {
		return inv, errors.New("empty required CVE tree")
	}
	inv.InitialRuns = len(state.runs)
	final, passes, err := collapseRuns(kind, outDir, state.runs, lim, budget)
	if err != nil {
		return inv, err
	}
	inv.MergePasses = passes
	spoolPath := filepath.Join(outDir, inv.Spool)
	if err := os.Rename(final.path, spoolPath); err != nil {
		return inv, err
	}
	if err := syncDirectory(outDir); err != nil {
		return inv, err
	}
	inv.SpoolBytes = final.size
	refs, err := scanRun(spoolPath, inv.Count, lim)
	if err != nil {
		return inv, err
	}
	inv.Refs = refs
	return inv, nil
}

func writeRunAtomic(destination string, budget *workBudget, produce func(func(runRecord) error) error) (int64, error) {
	return writeAtomic(destination, budget, func(w io.Writer) error {
		zw, err := zstd.NewWriter(w,
			zstd.WithEncoderLevel(zstd.SpeedDefault),
			zstd.WithEncoderConcurrency(1),
			zstd.WithWindowSize(8<<20),
			zstd.WithLowerEncoderMem(true),
			zstd.WithEncoderCRC(true),
		)
		if err != nil {
			return err
		}
		produceErr := produce(func(record runRecord) error { return writeRunRecord(zw, record) })
		closeErr := zw.Close()
		if produceErr != nil {
			return produceErr
		}
		return closeErr
	})
}

func writeAtomic(destination string, budget *workBudget, write func(io.Writer) error) (size int64, err error) {
	temporary := destination + ".tmp"
	f, err := os.OpenFile(temporary, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return 0, err
	}
	bw := &budgetWriter{w: f, budget: budget}
	committed := false
	defer func() {
		if !committed {
			_ = f.Close()
			_ = os.Remove(temporary)
			budget.release(bw.written)
		}
	}()
	if err = write(bw); err != nil {
		return 0, err
	}
	if err = f.Sync(); err != nil {
		return 0, err
	}
	if err = f.Close(); err != nil {
		return 0, err
	}
	if err = os.Rename(temporary, destination); err != nil {
		return 0, err
	}
	if err = syncDirectory(filepath.Dir(destination)); err != nil {
		_ = os.Remove(destination)
		return 0, err
	}
	committed = true
	return bw.written, nil
}

func syncDirectory(directory string) error {
	f, err := os.Open(directory)
	if err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

//nolint:err113 // Run-record validation errors are local spool diagnostics and are not matched.
func writeRunRecord(w io.Writer, record runRecord) error {
	if uint64(len(record.CVE)) > uint64(^uint32(0)) || uint64(len(record.Raw)) > uint64(^uint32(0)) {
		return errors.New("run record too large")
	}
	var header [runHeaderBytes]byte
	binary.BigEndian.PutUint32(header[0:4], uint32(len(record.CVE)))
	binary.BigEndian.PutUint32(header[4:8], uint32(len(record.Raw)))
	digest := sha256.Sum256(record.Raw)
	copy(header[8:], digest[:])
	if err := writeAll(w, header[:]); err != nil {
		return err
	}
	if err := writeAll(w, []byte(record.CVE)); err != nil {
		return err
	}
	return writeAll(w, record.Raw)
}

//nolint:err113 // Empty-run validation is an exact internal diagnostic and is not matched.
func collapseRuns(kind, outDir string, runs []runFile, lim limits, budget *workBudget) (runFile, int, error) {
	if len(runs) == 0 {
		return runFile{}, 0, errors.New("no sort runs")
	}
	if len(runs) == 1 {
		return runs[0], 0, nil
	}
	mergeFanIn, err := boundedMergeFanIn(lim)
	if err != nil {
		return runFile{}, 0, err
	}
	passes := 0
	for len(runs) > 1 {
		passes++
		next := make([]runFile, 0, (len(runs)+mergeFanIn-1)/mergeFanIn)
		for start := 0; start < len(runs); start += mergeFanIn {
			end := start + mergeFanIn
			if end > len(runs) {
				end = len(runs)
			}
			group := runs[start:end]
			if len(group) == 1 {
				next = append(next, group[0])
				continue
			}
			destination := filepath.Join(outDir, fmt.Sprintf(".%s-merge-%03d-%06d.zst", kind, passes, len(next)))
			merged, err := mergeRunGroup(destination, group, lim, budget)
			if err != nil {
				return runFile{}, passes, err
			}
			next = append(next, merged)
		}
		runs = next
	}
	return runs[0], passes, nil
}

// mergeResidentCapacity returns the number of run readers that fit while
// reserving each decoder, every heap cursor at its maximum legal size, one
// transient replacement cursor, and the merge writer. The deliberately
// conservative replacement reservation prevents a read of the next record
// from temporarily exceeding the cap before the prior cursor becomes dead.
func mergeResidentCapacity(lim limits) (int64, error) {
	if err := validateLimits(lim); err != nil {
		return 0, err
	}
	cursorBytes := lim.fileBytes + lim.pathBytes
	if lim.residentBytes <= mergeWriterResidentBytes || cursorBytes > lim.residentBytes-mergeWriterResidentBytes {
		return 0, errResidentCap
	}
	available := lim.residentBytes - mergeWriterResidentBytes - cursorBytes
	perReader := lim.decoderBytes + cursorBytes
	return available / perReader, nil
}

func boundedMergeFanIn(lim limits) (int, error) {
	capacity, err := mergeResidentCapacity(lim)
	if err != nil {
		return 0, err
	}
	if capacity < 2 {
		return 0, errResidentCap
	}
	if capacity > int64(lim.fanIn) {
		return lim.fanIn, nil
	}
	return int(capacity), nil
}

//nolint:err113 // Invalid run counts are exact internal diagnostics; cap errors remain sentinels.
func requireMergeResidentCapacity(sourceCount int, lim limits) error {
	if sourceCount <= 0 {
		return errors.New("no sort runs")
	}
	capacity, err := mergeResidentCapacity(lim)
	if err != nil {
		return err
	}
	if int64(sourceCount) > capacity {
		return errResidentCap
	}
	return nil
}

//nolint:err113 // Duplicate spool identities are exact internal validation diagnostics.
func mergeRunGroup(destination string, sources []runFile, lim limits, budget *workBudget) (runFile, error) {
	if err := requireMergeResidentCapacity(len(sources), lim); err != nil {
		return runFile{}, err
	}
	readers := make([]*runReader, 0, len(sources))
	for _, source := range sources {
		r, err := openRun(source.path, lim)
		if err != nil {
			closeRunReaders(readers)
			return runFile{}, err
		}
		readers = append(readers, r)
	}
	defer closeRunReaders(readers)
	size, err := writeRunAtomic(destination, budget, func(yield func(runRecord) error) error {
		queue := make(runHeap, 0, len(readers))
		for i, reader := range readers {
			record, err := reader.next(lim)
			if errors.Is(err, io.EOF) {
				continue
			}
			if err != nil {
				return err
			}
			heap.Push(&queue, runCursor{record: record, source: i})
		}
		lastCVE := ""
		for queue.Len() > 0 {
			cursor := heap.Pop(&queue).(runCursor)
			if cursor.record.CVE == lastCVE {
				return fmt.Errorf("duplicate CVE %s", cursor.record.CVE)
			}
			lastCVE = cursor.record.CVE
			if err := yield(cursor.record); err != nil {
				return err
			}
			record, err := readers[cursor.source].next(lim)
			if err == nil {
				heap.Push(&queue, runCursor{record: record, source: cursor.source})
			} else if !errors.Is(err, io.EOF) {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return runFile{}, err
	}
	for _, source := range sources {
		if err := os.Remove(source.path); err != nil {
			return runFile{}, err
		}
		budget.release(source.size)
	}
	if err := syncDirectory(filepath.Dir(destination)); err != nil {
		return runFile{}, err
	}
	return runFile{path: destination, size: size}, nil
}

type runCursor struct {
	record runRecord
	source int
}

type runHeap []runCursor

func (h runHeap) Len() int { return len(h) }
func (h runHeap) Less(i, j int) bool {
	if h[i].record.CVE == h[j].record.CVE {
		return h[i].source < h[j].source
	}
	return h[i].record.CVE < h[j].record.CVE
}
func (h runHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }
func (h *runHeap) Push(x any)   { *h = append(*h, x.(runCursor)) }
func (h *runHeap) Pop() any {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[:n-1]
	return x
}

type runReader struct {
	file         *os.File
	decoder      *zstd.Decoder
	recordLimit  int64
	records      int64
	decodedBytes int64
}

func openRun(filename string, lim limits) (*runReader, error) {
	return openRunWithRecordLimit(filename, lim, lim.members)
}

//nolint:err113 // Sort-run validation diagnostics are local to the prepared-spool reader.
func openRunWithRecordLimit(filename string, lim limits, recordLimit int64) (*runReader, error) {
	if err := validateLimits(lim); err != nil {
		return nil, err
	}
	if recordLimit <= 0 || recordLimit > lim.members {
		return nil, errors.New("invalid sort run record limit")
	}
	st, err := os.Lstat(filename)
	if err != nil || !st.Mode().IsRegular() {
		return nil, errors.New("invalid sort run")
	}
	f, err := os.Open(filename)
	if err != nil {
		return nil, err
	}
	openedInfo, err := f.Stat()
	if err != nil || !openedInfo.Mode().IsRegular() || !os.SameFile(st, openedInfo) {
		_ = f.Close()
		return nil, errors.New("sort run changed while opening")
	}
	decoder, err := newRunDecoder(f, lim)
	if err != nil {
		_ = f.Close()
		return nil, err
	}
	return &runReader{file: f, decoder: decoder, recordLimit: recordLimit}, nil
}

func newRunDecoder(r io.Reader, lim limits) (*zstd.Decoder, error) {
	return zstd.NewReader(r,
		zstd.WithDecoderConcurrency(1),
		zstd.WithDecoderLowmem(true),
		zstd.WithDecoderMaxWindow(maxRunDecoderWindowBytes),
		zstd.WithDecoderMaxMemory(uint64(lim.decoderBytes)),
	)
}

func (r *runReader) close() {
	r.decoder.Close()
	_ = r.file.Close()
}

func closeRunReaders(readers []*runReader) {
	for _, reader := range readers {
		reader.close()
	}
}

//nolint:err113 // Sort-run validation diagnostics are local to the prepared-spool reader.
func (r *runReader) next(lim limits) (runRecord, error) {
	var header [runHeaderBytes]byte
	n, err := io.ReadFull(r.decoder, header[:])
	if err != nil {
		if errors.Is(err, io.EOF) && n == 0 {
			return runRecord{}, io.EOF
		}
		return runRecord{}, fmt.Errorf("truncated sort run header: %w", err)
	}
	cveLength := int64(binary.BigEndian.Uint32(header[0:4]))
	rawLength := int64(binary.BigEndian.Uint32(header[4:8]))
	if cveLength <= 0 || cveLength > lim.pathBytes || rawLength < 0 || rawLength > lim.fileBytes {
		return runRecord{}, errors.New("invalid sort run record length")
	}
	if r.records >= r.recordLimit {
		return runRecord{}, errors.New("sort run record cap exceeded")
	}
	remaining := lim.decodedBytes - r.decodedBytes
	if remaining < int64(runHeaderBytes) {
		return runRecord{}, errors.New("sort run decoded byte cap exceeded")
	}
	remaining -= int64(runHeaderBytes)
	if cveLength > remaining {
		return runRecord{}, errors.New("sort run decoded byte cap exceeded")
	}
	remaining -= cveLength
	if rawLength > remaining {
		return runRecord{}, errors.New("sort run decoded byte cap exceeded")
	}
	r.decodedBytes += int64(runHeaderBytes) + cveLength + rawLength
	r.records++
	cve := make([]byte, int(cveLength))
	raw := make([]byte, int(rawLength))
	if _, err := io.ReadFull(r.decoder, cve); err != nil {
		return runRecord{}, fmt.Errorf("truncated sort run CVE: %w", err)
	}
	if _, err := io.ReadFull(r.decoder, raw); err != nil {
		return runRecord{}, fmt.Errorf("truncated sort run payload: %w", err)
	}
	if !cveName.Match(cve) {
		return runRecord{}, errors.New("invalid sort run CVE")
	}
	digest := sha256.Sum256(raw)
	if !equalBytes(header[8:], digest[:]) {
		return runRecord{}, errors.New("sort run digest mismatch")
	}
	return runRecord{CVE: string(cve), Raw: raw}, nil
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var different byte
	for i := range a {
		different |= a[i] ^ b[i]
	}
	return different == 0
}

//nolint:err113 // Sort-run validation diagnostics are local to the prepared-spool reader.
func scanRun(filename string, expected int64, lim limits) ([]ref, error) {
	if expected <= 0 || expected > lim.members || expected > int64(^uint(0)>>1) {
		return nil, errors.New("invalid expected sort run count")
	}
	r, err := openRunWithRecordLimit(filename, lim, expected)
	if err != nil {
		return nil, err
	}
	defer r.close()
	refs := make([]ref, 0, int(expected))
	lastCVE := ""
	for {
		record, err := r.next(lim)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if record.CVE <= lastCVE {
			if record.CVE == lastCVE {
				return nil, fmt.Errorf("duplicate CVE %s", record.CVE)
			}
			return nil, errors.New("sort run is not ordered")
		}
		lastCVE = record.CVE
		refs = append(refs, ref{CVE: record.CVE})
	}
	if int64(len(refs)) != expected {
		return nil, fmt.Errorf("sort run count %d does not match expected %d", len(refs), expected)
	}
	return refs, nil
}

//nolint:err113 // Input byte accounting is an exact internal validation diagnostic.
func prepare(osv, vex, outDir string, lim limits) error {
	if err := validateLimits(lim); err != nil {
		return err
	}
	osvInput, err := openArchive(osv, osvKind, lim)
	if err != nil {
		return fmt.Errorf("inspect OSV archive: %w", err)
	}
	defer osvInput.close()
	vexInput, err := openArchive(vex, vexKind, lim)
	if err != nil {
		return fmt.Errorf("inspect VEX archive: %w", err)
	}
	defer vexInput.close()
	if osvInput.size > math.MaxInt64-vexInput.size {
		return errors.New("input archive byte accounting overflow")
	}
	inputBytes := osvInput.size + vexInput.size
	budget := &workBudget{limit: lim.workBytes}
	if err := budget.reserve(inputBytes); err != nil {
		return fmt.Errorf("%w by input archives", errWorkCap)
	}
	if err := os.Mkdir(outDir, 0o700); err != nil {
		return err
	}
	ok := false
	defer func() {
		if !ok {
			_ = os.RemoveAll(outDir)
		}
	}()
	o, err := prepareOne(osvInput, osvKind, outDir, lim, budget)
	if err != nil {
		return err
	}
	v, err := prepareOne(vexInput, vexKind, outDir, lim, budget)
	if err != nil {
		return err
	}
	m := manifest{
		Version:           runVersion,
		ProjectionVersion: projectionVersion,
		OSV:               o,
		VEX:               v,
		InputBytes:        inputBytes,
		WorkLimitBytes:    lim.workBytes,
	}
	encoded, err := encodeManifest(&m, budget)
	if err != nil {
		return err
	}
	if _, err := writeAtomic(filepath.Join(outDir, "manifest.json"), budget, func(w io.Writer) error {
		return writeAll(w, encoded)
	}); err != nil {
		return err
	}
	ok = true
	return nil
}

//nolint:err113 // Convergence failure is an exact internal encoding diagnostic and is not matched.
func encodeManifest(m *manifest, budget *workBudget) ([]byte, error) {
	for i := 0; i < 12; i++ {
		encoded, err := json.Marshal(m)
		if err != nil {
			return nil, err
		}
		workBytes := budget.used + int64(len(encoded))
		peakBytes := budget.peak
		if workBytes > peakBytes {
			peakBytes = workBytes
		}
		if m.WorkBytes == workBytes && m.PeakWorkBytes == peakBytes {
			if workBytes > budget.limit {
				return nil, errWorkCap
			}
			return encoded, nil
		}
		m.WorkBytes = workBytes
		m.PeakWorkBytes = peakBytes
	}
	return nil, errors.New("manifest size did not converge")
}

//nolint:err113 // Manifest validation diagnostics are consumed as text at the CLI boundary.
func validateManifestHeader(m *manifest, lim limits) error {
	if m.Version != runVersion || m.ProjectionVersion != projectionVersion || m.OSV.Count <= 0 || m.VEX.Count <= 0 ||
		m.OSV.Kind != osvKind || m.VEX.Kind != vexKind ||
		m.OSV.Spool != "osv.spool" || m.VEX.Spool != "vex.spool" ||
		int64(len(m.OSV.Refs)) != m.OSV.Count || int64(len(m.VEX.Refs)) != m.VEX.Count ||
		m.WorkLimitBytes <= 0 || m.WorkLimitBytes > lim.workBytes ||
		m.InputBytes <= 0 || m.WorkBytes <= 0 || m.PeakWorkBytes < m.WorkBytes ||
		m.PeakWorkBytes > m.WorkLimitBytes || m.WorkBytes > m.WorkLimitBytes {
		return errors.New("invalid manifest")
	}
	return nil
}

//nolint:err113 // Manifest accounting diagnostics are consumed as text at the CLI boundary.
func validateManifestAccounting(manifestBytes int64, m *manifest, lim limits) error {
	if m.OSV.ArchiveBytes <= 0 || m.OSV.ArchiveBytes > lim.archiveBytes ||
		m.VEX.ArchiveBytes <= 0 || m.VEX.ArchiveBytes > lim.archiveBytes ||
		m.InputBytes != m.OSV.ArchiveBytes+m.VEX.ArchiveBytes ||
		m.WorkBytes != m.InputBytes+m.OSV.SpoolBytes+m.VEX.SpoolBytes+manifestBytes {
		return errors.New("invalid manifest work accounting")
	}
	return nil
}

//nolint:err113 // Inventory validation diagnostics are consumed as text at the CLI boundary.
func validateManifestInventory(dir string, inv *inventory, m *manifest, lim limits) error {
	if inv.Count > lim.members || inv.Members < inv.Count || inv.Members > lim.members ||
		inv.Total < 0 || inv.Total > lim.totalBytes || inv.SpoolBytes <= 0 ||
		inv.SpoolBytes > m.WorkLimitBytes || inv.InitialRuns <= 0 ||
		int64(inv.InitialRuns) > inv.Count || inv.MergePasses < 0 ||
		(inv.InitialRuns == 1 && inv.MergePasses != 0) ||
		(inv.InitialRuns > 1 && inv.MergePasses == 0) {
		return errors.New("invalid manifest inventory")
	}
	if len(inv.ArchiveSHA256) != sha256.Size*2 {
		return errors.New("invalid manifest archive digest")
	}
	if _, err := hex.DecodeString(inv.ArchiveSHA256); err != nil {
		return errors.New("invalid manifest archive digest")
	}
	last := ""
	for _, entry := range inv.Refs {
		if !cveName.MatchString(entry.CVE) || entry.CVE <= last {
			return errors.New("invalid manifest references")
		}
		last = entry.CVE
	}
	st, err := os.Lstat(filepath.Join(dir, inv.Spool))
	if err != nil || !st.Mode().IsRegular() || st.Size() != inv.SpoolBytes {
		return errors.New("invalid manifest spool")
	}
	return nil
}

func validateManifest(dir string, manifestBytes int64, m *manifest, lim limits) error {
	if err := validateManifestHeader(m, lim); err != nil {
		return err
	}
	if err := validateManifestAccounting(manifestBytes, m, lim); err != nil {
		return err
	}
	for _, inv := range []*inventory{&m.OSV, &m.VEX} {
		if err := validateManifestInventory(dir, inv, m, lim); err != nil {
			return err
		}
	}
	return nil
}

func streamPrepared(dir string, out io.Writer, lim limits) error {
	// The terminal frame plus a zero process exit is the stream's commit marker.
	// Callers may receive complete record frames before a late error, but the
	// loader keeps them inside one transaction and rolls back without a terminal.
	return projectPrepared(dir, out, lim)
}

//nolint:err113 // Prepared-manifest validation diagnostics are consumed as CLI text.
func projectPrepared(dir string, out io.Writer, lim limits) error {
	if err := validateLimits(lim); err != nil {
		return err
	}
	manifestPath := filepath.Join(dir, "manifest.json")
	st, err := os.Lstat(manifestPath)
	if err != nil || !st.Mode().IsRegular() || st.Size() > 32<<20 {
		return errors.New("invalid manifest file")
	}
	b, err := os.ReadFile(manifestPath)
	if err != nil {
		return err
	}
	var m manifest
	if err := json.Unmarshal(b, &m); err != nil {
		return errors.New("invalid manifest")
	}
	if err := validateManifest(dir, st.Size(), &m, lim); err != nil {
		return err
	}
	or, err := openRunWithRecordLimit(filepath.Join(dir, m.OSV.Spool), lim, m.OSV.Count)
	if err != nil {
		return err
	}
	defer or.close()
	vr, err := openRunWithRecordLimit(filepath.Join(dir, m.VEX.Spool), lim, m.VEX.Count)
	if err != nil {
		return err
	}
	defer vr.close()
	return projectPreparedPass(or, vr, &m, out, lim)
}

//nolint:err113 // Cross-spool validation diagnostics are consumed as CLI text.
func projectPreparedPass(or, vr *runReader, m *manifest, out io.Writer, lim limits) error {
	oRecord, oErr := or.next(lim)
	vRecord, vErr := vr.next(lim)
	oi, vi, records := 0, 0, int64(0)
	projection := newProjectionState()
	wireLimit, err := projectedManifestWireByteBound(m, lim)
	if err != nil {
		return err
	}
	if lim.encodedBytes > 0 && lim.encodedBytes < wireLimit {
		wireLimit = lim.encodedBytes
	}
	wire := wireCounters{limit: wireLimit}
	for !errors.Is(oErr, io.EOF) || !errors.Is(vErr, io.EOF) {
		if oErr != nil && !errors.Is(oErr, io.EOF) {
			return oErr
		}
		if vErr != nil && !errors.Is(vErr, io.EOF) {
			return vErr
		}
		var cve string
		var oraw, vraw []byte
		switch {
		case errors.Is(vErr, io.EOF) || (oErr == nil && oRecord.CVE < vRecord.CVE):
			cve, oraw = oRecord.CVE, oRecord.Raw
			if oi >= len(m.OSV.Refs) || m.OSV.Refs[oi].CVE != cve {
				return errors.New("OSV spool does not match manifest")
			}
			oi++
			oRecord, oErr = or.next(lim)
		case errors.Is(oErr, io.EOF) || vRecord.CVE < oRecord.CVE:
			cve, vraw = vRecord.CVE, vRecord.Raw
			if vi >= len(m.VEX.Refs) || m.VEX.Refs[vi].CVE != cve {
				return errors.New("VEX spool does not match manifest")
			}
			vi++
			vRecord, vErr = vr.next(lim)
		default:
			cve, oraw, vraw = oRecord.CVE, oRecord.Raw, vRecord.Raw
			if oi >= len(m.OSV.Refs) || vi >= len(m.VEX.Refs) || m.OSV.Refs[oi].CVE != cve || m.VEX.Refs[vi].CVE != cve {
				return errors.New("paired spools do not match manifest")
			}
			oi++
			vi++
			oRecord, oErr = or.next(lim)
			vRecord, vErr = vr.next(lim)
		}
		projected, err := projectRecordWithLimits(cve, oraw, vraw, m.OSV.ArchiveSHA256, m.VEX.ArchiveSHA256, projection, lim.projection)
		if err != nil {
			return err
		}
		encoded, err := json.Marshal(projected)
		if err != nil {
			return err
		}
		if err := writeCountedTypedFrame(out, recordFrame, encoded, lim.frameBytes, &wire); err != nil {
			if errors.Is(err, errEncodedOutputCap) {
				return err
			}
			return fmt.Errorf("%s projection frame: %w", cve, err)
		}
		records++
	}
	if oi != len(m.OSV.Refs) || vi != len(m.VEX.Refs) {
		return errors.New("spool ended before manifest references")
	}
	control := terminalDTO{
		ProtocolVersion:               projectionVersion,
		CVECount:                      records,
		RecordCount:                   records,
		OSVDocumentCount:              projection.counters.OSVDocuments,
		VEXDocumentCount:              projection.counters.VEXDocuments,
		OSVCount:                      m.OSV.Count,
		VEXCount:                      m.VEX.Count,
		WithdrawnDocumentCount:        projection.counters.WithdrawnDocuments,
		VEXTombstoneCount:             projection.counters.VEXTombstones,
		OSVAffectedEntryCount:         projection.counters.OSVAffectedEntries,
		VEXStatementCount:             projection.counters.VEXStatements,
		LogicalProductOccurrenceCount: projection.counters.LogicalProductOccurrences,
		UniqueProductCount:            int64(len(projection.seenProducts)),
		UniqueProductSetCount:         int64(len(projection.seenSets)),
		AssertionCount:                projection.counters.Assertions,
		UnscopedProductCount:          projection.counters.UnscopedProducts,
		RepairedSourcePURLCount:       projection.counters.RepairedSourcePURLs,
		OSVMembers:                    m.OSV.Members,
		VEXMembers:                    m.VEX.Members,
		OSVSpoolBytes:                 m.OSV.SpoolBytes,
		VEXSpoolBytes:                 m.VEX.SpoolBytes,
		PeakWorkBytes:                 m.PeakWorkBytes,
	}
	encoded, err := marshalTerminal(control, wire)
	if err != nil {
		return err
	}
	return writeCountedTypedFrame(out, controlFrame, encoded, lim.frameBytes, &wire)
}

type wireCounters struct {
	bytes    int64
	frames   int64
	maxFrame int64
	limit    int64
}

//nolint:err113 // Frame validation diagnostics are local to the bounded wire encoder.
func writeCountedTypedFrame(w io.Writer, frameType byte, encoded []byte, configuredLimit int, counters *wireCounters) error {
	frameBytes, err := checkedCollectionSize(1, len(encoded))
	if err != nil {
		return errors.New("frame size overflow")
	}
	frameLimit := configuredLimit
	if frameLimit > maxProjectionFrameBytes {
		frameLimit = maxProjectionFrameBytes
	}
	if frameLimit <= 0 || frameBytes > frameLimit || uint64(frameBytes) > uint64(^uint32(0)) {
		return fmt.Errorf("frame cap exceeded: %d > %d bytes", frameBytes, frameLimit)
	}
	totalFrameBytes := int64(4 + frameBytes)
	if counters.limit <= 0 || counters.bytes < 0 || counters.bytes > counters.limit || totalFrameBytes > counters.limit-counters.bytes {
		return errEncodedOutputCap
	}
	var length [4]byte
	binary.BigEndian.PutUint32(length[:], uint32(frameBytes))
	if err := writeAll(w, length[:]); err != nil {
		return err
	}
	if err := writeAll(w, []byte{frameType}); err != nil {
		return err
	}
	if err := writeAll(w, encoded); err != nil {
		return err
	}
	counters.bytes += int64(4 + frameBytes)
	counters.frames++
	if int64(frameBytes) > counters.maxFrame {
		counters.maxFrame = int64(frameBytes)
	}
	return nil
}

//nolint:err113 // Frame validation diagnostics are local to the bounded wire encoder.
func writeFrame(w io.Writer, payload []byte) error {
	if len(payload) > maxProjectionFrameBytes || uint64(len(payload)) > uint64(^uint32(0)) {
		return fmt.Errorf("frame cap exceeded: %d > %d bytes", len(payload), maxProjectionFrameBytes)
	}
	var length [4]byte
	binary.BigEndian.PutUint32(length[:], uint32(len(payload)))
	if err := writeAll(w, length[:]); err != nil {
		return err
	}
	return writeAll(w, payload)
}

//nolint:err113 // Convergence failure is an exact internal encoding diagnostic and is not matched.
func marshalTerminal(terminal terminalDTO, prior wireCounters) ([]byte, error) {
	terminal.EmittedFrameCount = prior.frames + 1
	for i := 0; i < 12; i++ {
		encoded, err := json.Marshal(terminal)
		if err != nil {
			return nil, err
		}
		payloadBytes := int64(1 + len(encoded))
		emittedBytes := prior.bytes + 4 + payloadBytes
		maxFrame := prior.maxFrame
		if payloadBytes > maxFrame {
			maxFrame = payloadBytes
		}
		if terminal.EmittedBytes == emittedBytes && terminal.MaxFrameBytes == maxFrame {
			return encoded, nil
		}
		terminal.EmittedBytes = emittedBytes
		terminal.MaxFrameBytes = maxFrame
	}
	return nil, errors.New("terminal size did not converge")
}

func writeAll(w io.Writer, p []byte) error {
	for len(p) > 0 {
		n, err := w.Write(p)
		if n > 0 {
			p = p[n:]
		}
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
	}
	return nil
}

// auditFrameWriter consumes the exact packet4 stream produced by streamPrepared,
// discarding record payloads while retaining and independently checking the
// terminal control frame. It intentionally never buffers a projected record.
type auditFrameWriter struct {
	header       [4]byte
	headerBytes  int
	remaining    int64
	frameBytes   int64
	frameType    byte
	typeSeen     bool
	control      []byte
	terminal     terminalDTO
	sawTerminal  bool
	recordFrames int64
	wire         wireCounters
}

//nolint:err113 // Audit validation diagnostics are local to the bounded stream checker.
func (w *auditFrameWriter) Write(p []byte) (int, error) {
	written := 0
	for len(p) > 0 {
		if w.remaining == 0 && !w.typeSeen {
			need := len(w.header) - w.headerBytes
			if need > len(p) {
				need = len(p)
			}
			copy(w.header[w.headerBytes:], p[:need])
			w.headerBytes += need
			written += need
			p = p[need:]
			if w.headerBytes < len(w.header) {
				continue
			}
			if w.sawTerminal {
				return written, errors.New("frame follows terminal control frame")
			}
			w.frameBytes = int64(binary.BigEndian.Uint32(w.header[:]))
			w.headerBytes = 0
			if w.frameBytes < 1 || w.frameBytes > maxProjectionFrameBytes {
				return written, errors.New("invalid audit frame length")
			}
			w.remaining = w.frameBytes
		}
		if len(p) == 0 {
			continue
		}

		take := int64(len(p))
		if take > w.remaining {
			take = w.remaining
		}
		chunk := p[:int(take)]
		if !w.typeSeen {
			w.frameType = chunk[0]
			w.typeSeen = true
			chunk = chunk[1:]
			switch w.frameType {
			case recordFrame:
				w.recordFrames++
			case controlFrame:
				w.control = w.control[:0]
			default:
				return written, errors.New("invalid audit frame type")
			}
		}
		if w.frameType == controlFrame && len(chunk) > 0 {
			if len(w.control) > maxAuditControlBytes-len(chunk) {
				return written, errors.New("audit control frame cap exceeded")
			}
			w.control = append(w.control, chunk...)
		}
		w.remaining -= take
		written += int(take)
		p = p[int(take):]
		if w.remaining == 0 {
			w.wire.frames++
			w.wire.bytes += 4 + w.frameBytes
			if w.frameBytes > w.wire.maxFrame {
				w.wire.maxFrame = w.frameBytes
			}
			if w.frameType == controlFrame {
				if w.sawTerminal || json.Unmarshal(w.control, &w.terminal) != nil {
					return written, errors.New("invalid audit terminal control frame")
				}
				w.sawTerminal = true
			}
			w.typeSeen = false
			w.frameType = 0
			w.frameBytes = 0
		}
	}
	return written, nil
}

//nolint:err113 // Audit validation diagnostics are local to the bounded stream checker.
func (w *auditFrameWriter) finish() (terminalDTO, error) {
	if w.headerBytes != 0 || w.remaining != 0 || w.typeSeen || !w.sawTerminal {
		return terminalDTO{}, errors.New("incomplete audit stream")
	}
	if w.terminal.RecordCount != w.recordFrames ||
		w.terminal.CVECount != w.recordFrames ||
		w.terminal.EmittedFrameCount != w.wire.frames ||
		w.terminal.EmittedBytes != w.wire.bytes ||
		w.terminal.MaxFrameBytes != w.wire.maxFrame {
		return terminalDTO{}, errors.New("audit terminal counters do not match stream")
	}
	return w.terminal, nil
}

func auditPrepared(dir string, out io.Writer, lim limits) error {
	sink := &auditFrameWriter{}
	if err := projectPrepared(dir, sink, lim); err != nil {
		return err
	}
	terminal, err := sink.finish()
	if err != nil {
		return err
	}
	encoded, err := json.Marshal(terminal)
	if err != nil {
		return err
	}
	return writeAll(out, append(encoded, '\n'))
}

func merge(osv, vex string, out io.Writer, lim limits) error {
	dir, err := os.MkdirTemp("", "ubuntu-feed-merge-")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(dir) }()
	prepared := filepath.Join(dir, "prepared")
	if err := prepare(osv, vex, prepared, lim); err != nil {
		return err
	}
	return streamPrepared(prepared, out, lim)
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		return 2
	}
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	fs.SetOutput(stderr)
	var osv, vex, dir string
	switch args[0] {
	case "prepare":
		fs.StringVar(&osv, "osv", "", "OSV tar.xz")
		fs.StringVar(&vex, "vex", "", "VEX tar.xz")
		fs.StringVar(&dir, "output-dir", "", "prepared output directory")
		if fs.Parse(args[1:]) != nil || osv == "" || vex == "" || dir == "" {
			return 2
		}
		if err := prepare(osv, vex, dir, defaultLimits()); err != nil {
			_, _ = fmt.Fprintln(stderr, err)
			return 1
		}
	case "stream":
		fs.StringVar(&dir, "prepared-dir", "", "prepared input directory")
		if fs.Parse(args[1:]) != nil || dir == "" {
			return 2
		}
		if err := streamPrepared(dir, stdout, defaultLimits()); err != nil {
			_, _ = fmt.Fprintln(stderr, err)
			return 1
		}
	case "audit":
		fs.StringVar(&dir, "prepared-dir", "", "prepared input directory")
		if fs.Parse(args[1:]) != nil || dir == "" {
			return 2
		}
		if err := auditPrepared(dir, stdout, defaultLimits()); err != nil {
			_, _ = fmt.Fprintln(stderr, err)
			return 1
		}
	default:
		return 2
	}
	return 0
}

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }
