//go:build darwin

package cpufreq

func snapshotClone(src *Snapshot) *Snapshot {
	if src == nil {
		return nil
	}

	out := &Snapshot{
		Cores:    make([]CoreFrequency, len(src.Cores)),
		Clusters: make([]ClusterFrequency, len(src.Clusters)),
	}

	copy(out.Cores, src.Cores)
	copy(out.Clusters, src.Clusters)
	return out
}
