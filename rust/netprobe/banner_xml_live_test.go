package netprobe_test

import (
	"encoding/binary"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	pb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	"google.golang.org/protobuf/proto"
)

// Exercise the shipped process through its public IPC protocol. The XML 1.0
// attribute contract supplies the oracle: entities decode, literal whitespace
// normalizes to spaces, and character references preserve their characters.
func TestBannerXMLLive(t *testing.T) {
	bin := os.Getenv("NETPROBE_BINARY")
	if _, err := os.Stat(bin); err != nil {
		bin = filepath.Join(os.Getenv("TEST_SRCDIR"), os.Getenv("TEST_WORKSPACE"), bin)
	}
	bin, err := filepath.Abs(bin)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	corpus := filepath.Join(dir, "corpus")
	if err := os.Mkdir(corpus, 0700); err != nil {
		t.Fatal(err)
	}
	xml := `<fingerprints><fingerprint name="  Café &amp; Router&#x9;X  " os_class="TestOS" device_type="Test&#32;Appliance">
<test weight="9" matchtype="exact" webserver="Example&amp;Probe&#32;Ω` + "\n" + `v1"/>
</fingerprint><Fingerprint name="wrong-case"><test webserver="CaseTrap"/></Fingerprint></fingerprints>`
	if err := os.WriteFile(filepath.Join(corpus, "web.xml"), []byte(xml), 0600); err != nil {
		t.Fatal(err)
	}
	config := filepath.Join(dir, "config.json")
	if err := os.WriteFile(config, []byte(`{"enabled":false,"capture_interfaces":[]}`), 0600); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "ipc.sock")
	logFile, err := os.Create(filepath.Join(dir, "netprobe.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer logFile.Close()
	cmd := exec.Command(bin, "--socket", socket, "--config", config, "--health-port", "0", "--skip-cap-check", "--allow-root")
	cmd.Env = append(os.Environ(), "SERVICERADAR_SATORI_CORPUS_DIR="+corpus)
	cmd.Stdout, cmd.Stderr = logFile, logFile
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	t.Cleanup(func() {
		_ = cmd.Process.Signal(syscall.SIGTERM)
		select {
		case err := <-done:
			if err != nil {
				t.Errorf("netprobe exit: %v", err)
			}
		case <-time.After(10 * time.Second):
			_ = cmd.Process.Kill()
			<-done
			t.Error("netprobe did not shut down")
		}
		if t.Failed() {
			data, _ := os.ReadFile(logFile.Name())
			t.Log(string(data))
		}
	})
	var conn net.Conn
	for deadline := time.Now().Add(15 * time.Second); time.Now().Before(deadline); {
		conn, err = net.Dial("unix", socket)
		if err == nil {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(10 * time.Second)); err != nil {
		t.Fatal(err)
	}
	observations := []*pb.BannerObservation{
		{ObservationId: 1, Protocol: "http", BannerBytes: []byte("Apache/2.4.58 (Ubuntu)")},
		{ObservationId: 2, Protocol: "http", BannerBytes: []byte("Example&Probe Ω v1")},
		{ObservationId: 3, Protocol: "http", BannerBytes: []byte("Example&amp;Probe Ω v1")},
		{ObservationId: 4, Protocol: "http", BannerBytes: []byte("CaseTrap")},
	}
	request := &pb.NetprobeFrame{Sequence: 7, Payload: &pb.NetprobeFrame_BannerBatch{BannerBatch: &pb.BannerBatch{Observations: observations}}}
	body, err := proto.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := binary.Write(conn, binary.BigEndian, uint32(len(body))); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Write(body); err != nil {
		t.Fatal(err)
	}
	var size uint32
	if err := binary.Read(conn, binary.BigEndian, &size); err != nil {
		t.Fatal(err)
	}
	if size > 4*1024*1024 {
		t.Fatalf("oversized response: %d", size)
	}
	body = make([]byte, size)
	if _, err := io.ReadFull(conn, body); err != nil {
		t.Fatal(err)
	}
	response := new(pb.NetprobeFrame)
	if err := proto.Unmarshal(body, response); err != nil {
		t.Fatal(err)
	}
	t.Logf("IPC response: %s", response)
	batch := response.GetBannerMatchBatch()
	if response.Sequence != 7 || batch == nil || len(batch.Matches) != 2 {
		t.Fatalf("unexpected response: %s", response)
	}
	seen := make(map[uint64]bool)
	for _, match := range batch.Matches {
		if seen[match.ObservationId] {
			t.Fatalf("duplicate observation: %d", match.ObservationId)
		}
		seen[match.ObservationId] = true
		switch match.ObservationId {
		case 1:
			if !strings.HasPrefix(match.CorpusLabel, "recog:") || match.Product != "HTTPD" || match.Version != "2.4.58" {
				t.Errorf("Recog mismatch: %s", match)
			}
		case 2:
			if !strings.HasPrefix(match.CorpusLabel, "satori:") || match.RawPatternId != "Café & Router\tX" || match.Product != "Test Appliance" || match.OsFamily != "TestOS" {
				t.Errorf("Satori mismatch: %s", match)
			}
		default:
			t.Errorf("negative observation matched: %s", match)
		}
	}
}
