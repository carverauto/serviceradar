package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"

	core "k8s.io/api/core/v1"
	storage "k8s.io/api/storage/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// These objects are invented API responses. The real client and command decide
// whether they satisfy the retained association; the server implements no check.
type apiFixture struct {
	namespace   core.Namespace
	claim       core.PersistentVolumeClaim
	volume      core.PersistentVolume
	driver      storage.CSIDriver
	pods        []core.PodList
	attachments []storage.VolumeAttachmentList
	errorPath   string
	errorStatus int
	loopPages   bool
}

func fixture() *apiFixture {
	class := "retained-example"
	return &apiFixture{
		namespace: core.Namespace{
			ObjectMeta: meta.ObjectMeta{Name: "spool-test", UID: "namespace-original"},
			Status:     core.NamespaceStatus{Phase: core.NamespaceActive},
		},
		claim: core.PersistentVolumeClaim{
			ObjectMeta: meta.ObjectMeta{Name: "recordings-camera-0", Namespace: "spool-test", UID: "claim-original"},
			Spec: core.PersistentVolumeClaimSpec{
				VolumeName: "volume-example", StorageClassName: &class,
				AccessModes: []core.PersistentVolumeAccessMode{core.ReadWriteOncePod},
				Resources:   core.VolumeResourceRequirements{Requests: core.ResourceList{core.ResourceStorage: resource.MustParse("1Gi")}},
			},
			Status: core.PersistentVolumeClaimStatus{Phase: core.ClaimBound, Capacity: core.ResourceList{core.ResourceStorage: resource.MustParse("2Gi")}},
		},
		volume: core.PersistentVolume{
			ObjectMeta: meta.ObjectMeta{Name: "volume-example", UID: "volume-original"},
			Spec: core.PersistentVolumeSpec{
				StorageClassName:              class,
				PersistentVolumeReclaimPolicy: core.PersistentVolumeReclaimRetain,
				AccessModes:                   []core.PersistentVolumeAccessMode{core.ReadWriteOncePod},
				Capacity:                      core.ResourceList{core.ResourceStorage: resource.MustParse("2Gi")},
				ClaimRef:                      &core.ObjectReference{Name: "recordings-camera-0", Namespace: "spool-test", UID: "claim-original"},
				PersistentVolumeSource: core.PersistentVolumeSource{CSI: &core.CSIPersistentVolumeSource{
					Driver: "storage.example.com", VolumeHandle: "invented-volume-lifetime-1",
				}},
			},
			Status: core.PersistentVolumeStatus{Phase: core.VolumeBound},
		},
		driver: storage.CSIDriver{ObjectMeta: meta.ObjectMeta{Name: "storage.example.com", UID: "driver-original"}},
		pods:   []core.PodList{{}}, attachments: []storage.VolumeAttachmentList{{}},
	}
}

func TestCommandChecksAPIResponses(t *testing.T) {
	const replacementIdentity = "replacement"
	retiring := meta.Now()
	block := core.PersistentVolumeBlock
	owner := []meta.OwnerReference{{APIVersion: "v1", Kind: "Pod", Name: "old-writer", UID: "old-owner"}}
	cases := []struct {
		name   string
		change func(*apiFixture)
		reason string
	}{
		{name: "retained idle association"},
		{name: "namespace recreated", change: func(f *apiFixture) { f.namespace.UID = replacementIdentity }, reason: "namespace_mismatch_or_retiring"},
		{name: "namespace retiring", change: func(f *apiFixture) { f.namespace.DeletionTimestamp = &retiring }, reason: "namespace_mismatch_or_retiring"},
		{name: "same claim name different UID", change: func(f *apiFixture) { f.claim.UID = replacementIdentity }, reason: "claim_identity_mismatch"},
		{name: "claim points elsewhere", change: func(f *apiFixture) { f.claim.Spec.VolumeName = "other-volume" }, reason: "claim_identity_mismatch"},
		{name: "claim pending", change: func(f *apiFixture) { f.claim.Status.Phase = core.ClaimPending }, reason: "claim_not_bound_or_retiring"},
		{name: "claim retiring", change: func(f *apiFixture) { f.claim.DeletionTimestamp = &retiring }, reason: "claim_not_bound_or_retiring"},
		{name: "claim subject to garbage collection", change: func(f *apiFixture) { f.claim.OwnerReferences = owner }, reason: "claim_has_cleanup_owner"},
		{name: "RWO is insufficient", change: func(f *apiFixture) { f.claim.Spec.AccessModes = []core.PersistentVolumeAccessMode{core.ReadWriteOnce} }, reason: "claim_requires_filesystem_rwop"},
		{name: "raw block claim", change: func(f *apiFixture) { f.claim.Spec.VolumeMode = &block }, reason: "claim_requires_filesystem_rwop"},
		{name: "claim actual capacity below reserved minimum", change: func(f *apiFixture) { f.claim.Status.Capacity = core.ResourceList{} }, reason: "claim_capacity_insufficient"},
		{name: "same volume name different UID", change: func(f *apiFixture) { f.volume.UID = replacementIdentity }, reason: "volume_identity_mismatch"},
		{name: "unbound PV", change: func(f *apiFixture) { f.volume.Spec.ClaimRef = nil }, reason: "volume_claim_reference_mismatch"},
		{name: "PV retains old claim UID", change: func(f *apiFixture) { f.volume.Spec.ClaimRef.UID = "old-claim" }, reason: "volume_claim_reference_mismatch"},
		{name: "PV targets another namespace", change: func(f *apiFixture) { f.volume.Spec.ClaimRef.Namespace = "other-test" }, reason: "volume_claim_reference_mismatch"},
		{name: "released PV", change: func(f *apiFixture) { f.volume.Status.Phase = core.VolumeReleased }, reason: "volume_not_bound_or_retiring"},
		{name: "deleting PV", change: func(f *apiFixture) { f.volume.DeletionTimestamp = &retiring }, reason: "volume_not_bound_or_retiring"},
		{name: "Delete policy", change: func(f *apiFixture) { f.volume.Spec.PersistentVolumeReclaimPolicy = core.PersistentVolumeReclaimDelete }, reason: "volume_not_retained"},
		{name: "PV cleanup owner", change: func(f *apiFixture) { f.volume.OwnerReferences = owner }, reason: "volume_not_retained"},
		{name: "PV shared access", change: func(f *apiFixture) { f.volume.Spec.AccessModes = []core.PersistentVolumeAccessMode{core.ReadWriteMany} }, reason: "volume_requires_filesystem_rwop"},
		{name: "PV undersized", change: func(f *apiFixture) { f.volume.Spec.Capacity = core.ResourceList{} }, reason: "volume_capacity_insufficient"},
		{name: "storage class changed", change: func(f *apiFixture) { f.volume.Spec.StorageClassName = "other-class" }, reason: "storage_class_mismatch"},
		{name: "non CSI backing", change: func(f *apiFixture) { f.volume.Spec.CSI = nil }, reason: "csi_identity_or_access_mismatch"},
		{name: "CSI handle substituted", change: func(f *apiFixture) { f.volume.Spec.CSI.VolumeHandle = replacementIdentity }, reason: "csi_identity_or_access_mismatch"},
		{name: "CSI read only", change: func(f *apiFixture) { f.volume.Spec.CSI.ReadOnly = true }, reason: "csi_identity_or_access_mismatch"},
		{name: "driver retiring", change: func(f *apiFixture) { f.driver.DeletionTimestamp = &retiring }, reason: "driver_retiring"},
		{name: "driver absent", change: func(f *apiFixture) {
			f.errorPath = "/apis/storage.k8s.io/v1/csidrivers/storage.example.com"
			f.errorStatus = http.StatusNotFound
		}, reason: "driver_not_found"},
		{name: "pod scan forbidden", change: func(f *apiFixture) {
			f.errorPath = "/api/v1/namespaces/spool-test/pods"
			f.errorStatus = http.StatusForbidden
		}, reason: "pods_read_denied"},
		{name: "attachment observation failed", change: func(f *apiFixture) {
			f.errorPath = "/apis/storage.k8s.io/v1/volumeattachments"
			f.errorStatus = http.StatusBadGateway
		}, reason: "attachments_read_failed"},
		{name: "later pod page has completed claimant", change: func(f *apiFixture) {
			f.pods = []core.PodList{{}, {Items: []core.Pod{{Spec: core.PodSpec{Volumes: []core.Volume{{Name: "spool", VolumeSource: core.VolumeSource{PersistentVolumeClaim: &core.PersistentVolumeClaimVolumeSource{ClaimName: "recordings-camera-0"}}}}}, Status: core.PodStatus{Phase: core.PodSucceeded}}}}}
		}, reason: "claim_referenced_by_pod"},
		{name: "later attachment page has pending attach", change: func(f *apiFixture) {
			name := "volume-example"
			f.attachments = []storage.VolumeAttachmentList{{}, {Items: []storage.VolumeAttachment{{Spec: storage.VolumeAttachmentSpec{Source: storage.VolumeAttachmentSource{PersistentVolumeName: &name}}}}}}
		}, reason: "volume_attachment_present"},
		{name: "generic ephemeral claim consumer", change: func(f *apiFixture) {
			f.pods = []core.PodList{{Items: []core.Pod{{
				ObjectMeta: meta.ObjectMeta{Name: "recordings-camera"},
				Spec: core.PodSpec{Volumes: []core.Volume{{
					Name: "0", VolumeSource: core.VolumeSource{Ephemeral: &core.EphemeralVolumeSource{}},
				}}},
			}}}}
		}, reason: "claim_referenced_by_pod"},
		{name: "incomplete list cannot prove absence", change: func(f *apiFixture) { f.loopPages = true }, reason: "resource_scan_limit"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := fixture()
			if tc.change != nil {
				tc.change(f)
			}
			args, _ := serveFixture(t, f)
			assertCommand(t, args, tc.reason)
		})
	}
}

func TestExplicitInputBoundary(t *testing.T) {
	cases := []struct{ flag, value, reason string }{
		{"--context", "", "invalid_input"},
		{"--context", "missing-context", "kubeconfig_invalid"},
		{"--namespace", "../other", "invalid_input"},
		{"--claim-uid", "", "invalid_input"},
		{"--volume-uid", strings.Repeat("x", 129), "invalid_input"},
		{"--csi-handle", strings.Repeat("x", 1025), "invalid_input"},
		{"--minimum-bytes", "0", "invalid_input"},
		{"--minimum-bytes", "-1", "invalid_input"},
		{"--minimum-bytes", "9223372036854775808", "invalid_input"},
		{"--unknown", "true", "invalid_input"},
	}
	for _, tc := range cases {
		t.Run(tc.flag+tc.reason, func(t *testing.T) {
			args, requests := serveFixture(t, fixture())
			args = append(args, tc.flag, tc.value)
			assertCommand(t, args, tc.reason)
			if requests.Load() != 0 {
				t.Fatal("invalid input reached the Kubernetes API")
			}
		})
	}
}

func assertCommand(t *testing.T, args []string, reason string) {
	t.Helper()
	var out bytes.Buffer
	code := run(args, &out)
	want := result{Status: "association_verified"}
	wantCode := 0
	if reason != "" {
		want = result{Status: "refused", Reason: reason}
		wantCode = 1
	}
	var got result
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatalf("invalid result: %v: %s", err, out.String())
	}
	if code != wantCode || got != want {
		t.Fatalf("got exit %d %+v, want exit %d %+v", code, got, wantCode, want)
	}
}

func serveFixture(t *testing.T, f *apiFixture) ([]string, *atomic.Int64) {
	t.Helper()
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if r.Method != http.MethodGet {
			t.Errorf("unexpected mutation: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == f.errorPath {
			w.WriteHeader(f.errorStatus)
			return
		}
		var body any
		switch r.URL.Path {
		case "/api/v1/namespaces/spool-test":
			body = f.namespace
		case "/api/v1/namespaces/spool-test/persistentvolumeclaims/recordings-camera-0":
			body = f.claim
		case "/api/v1/persistentvolumes/volume-example":
			body = f.volume
		case "/apis/storage.k8s.io/v1/csidrivers/storage.example.com":
			body = f.driver
		case "/api/v1/namespaces/spool-test/pods":
			page := fixturePage(t, r, len(f.pods))
			pods := f.pods[page]
			if page+1 < len(f.pods) || f.loopPages {
				pods.Continue = strconv.Itoa((page + 1) % len(f.pods))
			}
			body = pods
		case "/apis/storage.k8s.io/v1/volumeattachments":
			page := fixturePage(t, r, len(f.attachments))
			attachments := f.attachments[page]
			if page+1 < len(f.attachments) {
				attachments.Continue = strconv.Itoa(page + 1)
			}
			body = attachments
		default:
			t.Errorf("unexpected API request %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if err := json.NewEncoder(w).Encode(body); err != nil {
			t.Errorf("encode API response: %v", err)
		}
	}))
	t.Cleanup(server.Close)
	config := map[string]any{
		"apiVersion": "v1", "kind": "Config", "current-context": "unused-context",
		"clusters": []any{map[string]any{"name": "example-cluster", "cluster": map[string]any{"server": server.URL}}},
		"contexts": []any{map[string]any{"name": "requested-context", "context": map[string]any{"cluster": "example-cluster"}}},
	}
	data, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	args := []string{
		"--kubeconfig", path, "--context", "requested-context",
		"--namespace", "spool-test", "--namespace-uid", "namespace-original",
		"--claim", "recordings-camera-0", "--claim-uid", "claim-original",
		"--volume", "volume-example", "--volume-uid", "volume-original",
		"--csi-driver", "storage.example.com", "--csi-handle", "invented-volume-lifetime-1",
		"--minimum-bytes", "1073741824",
	}
	return args, &requests
}

func fixturePage(t *testing.T, r *http.Request, count int) int {
	t.Helper()
	if r.URL.Query().Get("limit") != "100" {
		t.Error("resource list must request a bounded page")
	}
	page := 0
	if s := r.URL.Query().Get("continue"); s != "" {
		var err error
		page, err = strconv.Atoi(s)
		if err != nil || page < 0 || page >= count {
			t.Errorf("invalid continuation %q", s)
			return 0
		}
	}
	return page
}
