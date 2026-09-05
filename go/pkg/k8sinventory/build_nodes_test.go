package k8sinventory

import (
	"testing"
	"time"
)

func TestBuildNodeSnapshot_ReadyWorkerAndNotReadyControlPlane(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	snap := BuildNodeSnapshot("cluster-a", now, []NodeView{
		{
			Name:           "node-worker-1.example.com",
			UID:            "uid-worker-1",
			Ready:          true,
			InternalIP:     "192.0.2.11",
			KubeletVersion: "v1.34.0",
		},
		{
			Name:         "node-control-1.example.com",
			UID:          "uid-control-1",
			Labels:       map[string]string{labelControlPlane: ""},
			Ready:        false,
			ReadyReason:  "KubeletNotReady",
			ReadyMessage: "node is not ready",
			InternalIP:   "192.0.2.2",
		},
		{
			Name:  "", // dropped
			Ready: true,
		},
	})

	if snap.ClusterID != "cluster-a" {
		t.Fatalf("cluster: %q", snap.ClusterID)
	}
	if !snap.GeneratedAt.Equal(now) {
		t.Fatalf("generated_at: %v", snap.GeneratedAt)
	}
	if len(snap.Nodes) != 2 {
		t.Fatalf("nodes: %+v", snap.Nodes)
	}

	control := snap.Nodes[0]
	if control.Name != "node-control-1.example.com" {
		t.Fatalf("expected control-plane first after sort, got %q", control.Name)
	}
	if control.Role != NodeRoleControlPlane {
		t.Fatalf("control role: %q", control.Role)
	}
	if control.Ready {
		t.Fatal("control-plane should be NotReady")
	}
	if control.ReadyReason != "KubeletNotReady" {
		t.Fatalf("reason: %q", control.ReadyReason)
	}
	if control.InternalIP != "192.0.2.2" {
		t.Fatalf("control ip: %q", control.InternalIP)
	}

	worker := snap.Nodes[1]
	if worker.Name != "node-worker-1.example.com" {
		t.Fatalf("worker: %q", worker.Name)
	}
	if worker.Role != NodeRoleWorker {
		t.Fatalf("worker role: %q", worker.Role)
	}
	if !worker.Ready {
		t.Fatal("worker should be Ready")
	}
	if worker.InternalIP != "192.0.2.11" {
		t.Fatalf("worker ip: %q", worker.InternalIP)
	}
}

func TestNodeRole_MasterLabelIsControlPlane(t *testing.T) {
	t.Parallel()
	if got := nodeRole(map[string]string{labelMaster: "true"}); got != NodeRoleControlPlane {
		t.Fatalf("got %q", got)
	}
	if got := nodeRole(nil); got != NodeRoleWorker {
		t.Fatalf("nil labels: %q", got)
	}
}
