package main

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/klauspost/compress/zstd"
	"github.com/ulikunitz/xz"
)

func linuxAgentExecutablePaths() []string {
	return []string{
		"usr/local/lib/serviceradar/agent/serviceradar-agent-seed",
		"usr/local/bin/serviceradar-agent-updater",
		"usr/local/bin/srctl",
	}
}

func TestDeclaredLinuxAgentPackages(t *testing.T) {
	resolver, err := newRunfileResolver()
	if err != nil {
		t.Fatal(err)
	}
	for _, arch := range []string{"amd64", "arm64"} {
		for _, format := range []string{"deb", "rpm"} {
			t.Run(arch+"/"+format, func(t *testing.T) {
				path := os.Getenv(strings.ToUpper(arch + "_" + format))
				if path == "" {
					t.Fatal("package must be supplied as a declared Bazel input")
				}
				path, err := resolver.resolve(path)
				if err != nil {
					t.Fatal(err)
				}
				file, err := os.Open(path)
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = file.Close() })
				if format == "deb" {
					verifyDebianAgent(t, file, arch)
				} else {
					verifyRPMAgent(t, file, arch)
				}
			})
		}
	}
}

func TestDeclaredLinuxManagedRuntimes(t *testing.T) {
	resolver, err := newRunfileResolver()
	if err != nil {
		t.Fatal(err)
	}
	for arch, runfile := range map[string]string{"amd64": defaultAgentRuntimeRunfile, "arm64": arm64AgentRuntimeRunfile} {
		path, err := resolver.resolve(runfile)
		if err != nil {
			t.Fatal(err)
		}
		if err := validateLinuxRuntimeArchive(path, arch); err != nil {
			t.Fatalf("%s runtime: %v", arch, err)
		}
		wrong := "amd64"
		if arch == wrong {
			wrong = "arm64"
		}
		if err := validateLinuxRuntimeArchive(path, wrong); err == nil {
			t.Fatalf("%s runtime accepted as %s", arch, wrong)
		}
	}
}

func verifyDebianAgent(t *testing.T, file *os.File, arch string) {
	t.Helper()
	magic := make([]byte, 8)
	readPackageBytes(t, file, magic)
	if string(magic) != "!<arch>\n" {
		t.Fatal("invalid Debian ar signature")
	}
	control, payload := false, false
	for {
		header := make([]byte, 60)
		_, err := io.ReadFull(file, header)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil || string(header[58:60]) != "`\n" {
			t.Fatalf("invalid Debian ar member: %v", err)
		}
		size := packageNumber(t, string(header[48:58]), 10)
		name := strings.TrimRight(strings.TrimSpace(string(header[:16])), "/")
		position, err := file.Seek(0, io.SeekCurrent)
		if err != nil {
			t.Fatal(err)
		}
		reader := io.NewSectionReader(file, position, size)
		switch {
		case strings.HasPrefix(name, "control.tar"):
			verifyDebianControl(t, decompressedPackage(t, reader), arch)
			control = true
		case strings.HasPrefix(name, "data.tar"):
			verifyTarPayload(t, decompressedPackage(t, reader), arch)
			payload = true
		}
		if _, err := file.Seek(position+size+size%2, io.SeekStart); err != nil {
			t.Fatal(err)
		}
	}
	if !control || !payload {
		t.Fatal("Debian package lacks control or data archive")
	}
}

func verifyDebianControl(t *testing.T, reader io.Reader, arch string) {
	t.Helper()
	archive := tar.NewReader(reader)
	for {
		header, err := archive.Next()
		if err != nil {
			t.Fatalf("Debian control metadata not found: %v", err)
		}
		if strings.TrimPrefix(header.Name, "./") != "control" {
			continue
		}
		data, err := io.ReadAll(archive)
		if err != nil {
			t.Fatal(err)
		}
		for _, line := range []string{"Package: serviceradar-agent", "Architecture: " + arch, "Version: " + os.Getenv("EXPECTED_VERSION"), "Depends: systemd, libcap2-bin"} {
			if !strings.Contains("\n"+string(data), "\n"+line+"\n") {
				t.Fatalf("Debian metadata missing %q", line)
			}
		}
		return
	}
}

func verifyTarPayload(t *testing.T, reader io.Reader, arch string) {
	t.Helper()
	found := map[string]bool{}
	archive := tar.NewReader(reader)
	for {
		header, err := archive.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		verifyPackagedExecutable(t, found, header.Name, header.Mode, archive, arch)
	}
	requirePackageExecutables(t, found)
}

func verifyRPMAgent(t *testing.T, file *os.File, arch string) {
	t.Helper()
	lead := make([]byte, 96)
	readPackageBytes(t, file, lead)
	if !bytes.Equal(lead[:4], []byte{0xed, 0xab, 0xee, 0xdb}) {
		t.Fatal("invalid RPM signature")
	}
	_, signatureSize := readRPMHeader(t, file)
	readPackageBytes(t, file, make([]byte, (8-signatureSize%8)%8))
	tags, _ := readRPMHeader(t, file)
	expectedArch := map[string]string{"amd64": "x86_64", "arm64": "aarch64"}[arch]
	if !slices.Equal(tags[1000], []string{"serviceradar-agent"}) || !slices.Equal(tags[1022], []string{expectedArch}) {
		t.Fatalf("RPM name=%q architecture=%q, expected %s", tags[1000], tags[1022], expectedArch)
	}
	version, release := splitRPMVersion(os.Getenv("EXPECTED_VERSION"))
	if !slices.Equal(tags[1001], []string{version}) || !slices.Equal(tags[1002], []string{release}) {
		t.Fatalf("RPM version=%q release=%q, expected %s-%s", tags[1001], tags[1002], version, release)
	}
	provides, requires := tags[1047], tags[1049]
	if !rpmDependenciesMatch(provides, requires, arch) {
		t.Fatalf("RPM %s has incorrect dependencies: Provides=%q Requires=%q", arch, provides, requires)
	}
	t.Logf("RPM %s Provides=%q Requires=%q", arch, provides, requires)
	verifyCPIOPayload(t, decompressedPackage(t, file), arch)
}

func rpmDependenciesMatch(provides, requires []string, arch string) bool {
	isa, wrongISA := "(x86-64)", "(aarch-64)"
	if arch == "arm64" {
		isa, wrongISA = wrongISA, isa
	}
	if !slices.Contains(provides, "serviceradar-agent") || !slices.Contains(provides, "serviceradar-agent"+isa) {
		return false
	}
	if !slices.Contains(requires, "systemd") || !slices.Contains(requires, "libcap") {
		return false
	}
	for _, names := range [][]string{provides, requires} {
		for _, name := range names {
			if strings.Contains(name, wrongISA) {
				return false
			}
		}
	}
	return true
}

func TestRPMDependencyISAValidation(t *testing.T) {
	for _, arch := range []string{"amd64", "arm64"} {
		isa := map[string]string{"amd64": "(x86-64)", "arm64": "(aarch-64)"}[arch]
		wrongISA := map[string]string{"amd64": "(aarch-64)", "arm64": "(x86-64)"}[arch]
		provides := []string{"serviceradar-agent", "serviceradar-agent" + isa}
		requires := []string{"systemd", "libcap"}
		if !rpmDependenciesMatch(provides, requires, arch) {
			t.Fatalf("valid %s dependency metadata rejected", arch)
		}
		for _, invalid := range []struct{ provides, requires []string }{
			{[]string{"serviceradar-agent", "serviceradar-agent" + wrongISA}, requires},
			{append(slices.Clone(provides), "other-package"+wrongISA), requires},
			{provides, append(slices.Clone(requires), "other-package"+wrongISA)},
			{provides[:1], requires},
			{provides[1:], requires},
			{provides, requires[:1]},
			{provides, requires[1:]},
		} {
			if rpmDependenciesMatch(invalid.provides, invalid.requires, arch) {
				t.Fatalf("invalid %s dependency metadata accepted: %+v", arch, invalid)
			}
		}
	}
}

func readRPMHeader(t *testing.T, reader io.Reader) (map[uint32][]string, int) {
	t.Helper()
	header := make([]byte, 16)
	readPackageBytes(t, reader, header)
	if !bytes.Equal(header[:4], []byte{0x8e, 0xad, 0xe8, 1}) {
		t.Fatal("invalid RPM header")
	}
	count, size := int(binary.BigEndian.Uint32(header[8:12])), int(binary.BigEndian.Uint32(header[12:16]))
	if count > 100000 || size > 16*1024*1024 {
		t.Fatal("oversized RPM header")
	}
	entries, store := make([]byte, count*16), make([]byte, size)
	readPackageBytes(t, reader, entries)
	readPackageBytes(t, reader, store)
	tags := map[uint32][]string{}
	for i := 0; i < count; i++ {
		entry := entries[i*16 : (i+1)*16]
		kind := binary.BigEndian.Uint32(entry[4:8])
		if kind == 6 || kind == 8 {
			tags[binary.BigEndian.Uint32(entry[:4])] = rpmHeaderStrings(t, store, entry)
		}
	}
	return tags, 16 + count*16 + size
}

func rpmHeaderStrings(t *testing.T, store, entry []byte) []string {
	t.Helper()
	offset, count := int(binary.BigEndian.Uint32(entry[8:12])), int(binary.BigEndian.Uint32(entry[12:16]))
	if offset >= len(store) || count > len(store)-offset {
		t.Fatal("invalid RPM string offset or count")
	}
	if binary.BigEndian.Uint32(entry[4:8]) == 6 && count != 1 {
		t.Fatal("RPM scalar string must have one value")
	}
	values := make([]string, 0, count)
	for range count {
		end := bytes.IndexByte(store[offset:], 0)
		if end < 0 {
			t.Fatal("unterminated RPM string")
		}
		values = append(values, string(store[offset:offset+end]))
		offset += end + 1
	}
	return values
}

func verifyCPIOPayload(t *testing.T, reader io.Reader, arch string) {
	t.Helper()
	found := map[string]bool{}
	for {
		header := make([]byte, 110)
		readPackageBytes(t, reader, header)
		if string(header[:6]) != "070701" && string(header[:6]) != "070702" {
			t.Fatal("RPM payload is not newc CPIO")
		}
		size := packageNumber(t, string(header[54:62]), 16)
		namesize := packageNumber(t, string(header[94:102]), 16)
		if namesize <= 0 || namesize > 4096 {
			t.Fatal("invalid CPIO filename size")
		}
		name := make([]byte, namesize)
		readPackageBytes(t, reader, name)
		readPackageBytes(t, reader, make([]byte, (4-(110+namesize)%4)%4))
		if string(name) == "TRAILER!!!\x00" {
			break
		}
		limited := &io.LimitedReader{R: reader, N: size}
		verifyPackagedExecutable(t, found, strings.TrimSuffix(string(name), "\x00"), packageNumber(t, string(header[14:22]), 16), limited, arch)
		if _, err := io.Copy(io.Discard, limited); err != nil {
			t.Fatal(err)
		}
		readPackageBytes(t, reader, make([]byte, (4-size%4)%4))
	}
	requirePackageExecutables(t, found)
}

func verifyPackagedExecutable(t *testing.T, found map[string]bool, name string, mode int64, reader io.Reader, arch string) {
	t.Helper()
	name = strings.TrimPrefix(name, "./")
	for _, expected := range linuxAgentExecutablePaths() {
		if name != expected {
			continue
		}
		header := make([]byte, 64)
		readPackageBytes(t, reader, header)
		machine := map[string]uint16{"amd64": 62, "arm64": 183}[arch]
		if !bytes.Equal(header[:6], []byte{0x7f, 'E', 'L', 'F', 2, 1}) || binary.LittleEndian.Uint16(header[18:20]) != machine {
			t.Fatalf("%s is not a Linux %s ELF64 executable", name, arch)
		}
		if mode&0o111 == 0 || (strings.HasSuffix(name, "agent-updater") && mode&0o7777 != 0o4750) {
			t.Fatalf("%s has incorrect permissions %o", name, mode)
		}
		if found[name] {
			t.Fatalf("duplicate executable %s", name)
		}
		found[name] = true
	}
}

func requirePackageExecutables(t *testing.T, found map[string]bool) {
	t.Helper()
	for _, path := range linuxAgentExecutablePaths() {
		if !found[path] {
			t.Fatalf("package is missing %s", path)
		}
	}
}

func decompressedPackage(t *testing.T, input io.Reader) io.Reader {
	t.Helper()
	reader := bufio.NewReader(input)
	header, err := reader.Peek(6)
	if err != nil {
		t.Fatal(err)
	}
	switch {
	case bytes.HasPrefix(header, []byte{0x1f, 0x8b}):
		compressed, err := gzip.NewReader(reader)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = compressed.Close() })
		return compressed
	case bytes.HasPrefix(header, []byte{0xfd, '7', 'z', 'X', 'Z', 0}):
		compressed, err := xz.NewReader(reader)
		if err != nil {
			t.Fatal(err)
		}
		return compressed
	case bytes.HasPrefix(header, []byte{0x28, 0xb5, 0x2f, 0xfd}):
		compressed, err := zstd.NewReader(reader)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(compressed.Close)
		return compressed
	default:
		return reader
	}
}

func readPackageBytes(t *testing.T, reader io.Reader, buffer []byte) {
	t.Helper()
	if _, err := io.ReadFull(reader, buffer); err != nil {
		t.Fatal(err)
	}
}

func packageNumber(t *testing.T, value string, base int) int64 {
	t.Helper()
	number, err := strconv.ParseInt(strings.TrimSpace(value), base, 64)
	if err != nil || number < 0 {
		t.Fatalf("invalid package number %q: %v", value, err)
	}
	return number
}
