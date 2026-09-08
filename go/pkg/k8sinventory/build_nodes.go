package k8sinventory

import (
	"sort"
	"time"
)

const (
	labelControlPlane = "node-role.kubernetes.io/control-plane"
	labelMaster       = "node-role.kubernetes.io/master"
)

// BuildNodeSnapshot derives the current-state Node catalog from in-memory Node views.
func BuildNodeSnapshot(clusterID string, now time.Time, nodes []NodeView) NodeSnapshot {
	if now.IsZero() {
		now = time.Now().UTC()
	}

	out := make([]NodeInventory, 0, len(nodes))
	for _, n := range nodes {
		name := n.Name
		if name == "" {
			continue
		}
		out = append(out, NodeInventory{
			ClusterID:      clusterID,
			Name:           name,
			UID:            n.UID,
			Role:           nodeRole(n.Labels),
			Ready:          n.Ready,
			ReadyReason:    n.ReadyReason,
			ReadyMessage:   n.ReadyMessage,
			Unschedulable:  n.Unschedulable,
			InternalIP:     n.InternalIP,
			ExternalIP:     n.ExternalIP,
			KubeletVersion: n.KubeletVersion,
			OSImage:        n.OSImage,
			ObservedAt:     now,
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Name == out[j].Name {
			return out[i].UID < out[j].UID
		}
		return out[i].Name < out[j].Name
	})
	return NodeSnapshot{
		ClusterID:   clusterID,
		GeneratedAt: now,
		Nodes:       out,
	}
}

func nodeRole(labels map[string]string) string {
	if labels == nil {
		return NodeRoleWorker
	}
	if _, ok := labels[labelControlPlane]; ok {
		return NodeRoleControlPlane
	}
	if _, ok := labels[labelMaster]; ok {
		return NodeRoleControlPlane
	}
	return NodeRoleWorker
}
