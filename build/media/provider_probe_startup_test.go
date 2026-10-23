package media_test

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

// The release, rather than a source interpreter, must enter the diagnostic
// without database, vault, NATS or deployment credentials. A missing input is
// the negative control: exactly one redacted diagnostic result and exit 1.
func TestProviderProbeReleaseEntrypoint(t *testing.T) {
	archive, err := runfiles.Rlocation(os.Getenv("PROBE_RELEASE_RUNFILE"))
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	unpackRelease(t, archive, root)
	if err := os.WriteFile(filepath.Join(root, "probe.config"), []byte("[].\n"), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(root, "bin/serviceradar_core_elx"), "eval", "ServiceRadarCoreElx.CameraRecording.ProviderProbe.main()")
	cmd.Env = []string{
		"PATH=/usr/bin:/bin", "HOME=" + root, "TMPDIR=" + root,
		"RELEASE_SYS_CONFIG=" + filepath.Join(root, "probe"),
		"RELEASE_COOKIE=synthetic_provider_probe_cookie", "ERL_FLAGS=+S 2:2 +fnu",
	}
	var output cappedOutput
	cmd.Stdout, cmd.Stderr = &output, &output
	err = cmd.Run()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 1 {
		t.Fatalf("diagnostic exit = %v, output: %s", err, output.String())
	}
	var result struct {
		Status string            `json:"status"`
		Checks map[string]string `json:"checks"`
	}
	if json.Unmarshal(output.Bytes(), &result) != nil || result.Status != "failed" || len(result.Checks) != 1 || result.Checks["input"] != "invalid" {
		t.Fatalf("unexpected release startup output: %s", output.String())
	}
}

type cappedOutput struct{ bytes.Buffer }

func (b *cappedOutput) Write(p []byte) (int, error) {
	if b.Len()+len(p) > 64*1024 {
		return 0, errors.New("startup output exceeds 64 KiB")
	}
	return b.Buffer.Write(p)
}

func unpackRelease(t *testing.T, archive, root string) {
	t.Helper()
	f, err := os.Open(archive)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	z, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	defer z.Close()
	r := tar.NewReader(z)
	var total int64
	for entries := 0; ; entries++ {
		h, err := r.Next()
		if err == io.EOF {
			return
		}
		if err != nil {
			t.Fatal(err)
		}
		total += h.Size
		if entries > 100000 || total > 4*1024*1024*1024 {
			t.Fatal("release extraction bound exceeded")
		}
		name := filepath.Clean(h.Name)
		if filepath.IsAbs(name) || name == ".." || strings.HasPrefix(name, "../") {
			t.Fatal("unsafe release path")
		}
		path := filepath.Join(root, name)
		switch h.Typeflag {
		case tar.TypeDir:
			err = os.MkdirAll(path, 0755)
		case tar.TypeReg:
			if err = os.MkdirAll(filepath.Dir(path), 0755); err == nil {
				var out *os.File
				out, err = os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_EXCL, os.FileMode(h.Mode)&0777)
				if err == nil {
					_, err = io.CopyN(out, r, h.Size)
					closeErr := out.Close()
					if err == nil {
						err = closeErr
					}
				}
			}
		case tar.TypeSymlink:
			target := filepath.Clean(filepath.Join(filepath.Dir(name), h.Linkname))
			if filepath.IsAbs(h.Linkname) || target == ".." || strings.HasPrefix(target, "../") {
				t.Fatal("unsafe release symlink")
			}
			err = os.Symlink(h.Linkname, path)
		default:
			t.Fatalf("unexpected release entry type: %d", h.Typeflag)
		}
		if err != nil {
			t.Fatal(err)
		}
	}
}
