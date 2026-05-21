//go:build tinygo

package main

import (
	"strconv"
	"strings"
)

func marshalProxmoxDetails(details proxmoxDetails) ([]byte, error) {
	var b strings.Builder
	b.WriteString(`{"schema":`)
	b.WriteString(strconv.Quote(details.Schema))
	b.WriteString(`,"summary":`)
	appendCheckSummaryJSON(&b, details.Summary)
	if !emptyResourceSummary(details.ResourceSummary) {
		b.WriteString(`,"resource_summary":`)
		appendResourceSummaryJSON(&b, details.ResourceSummary)
	}
	if len(details.Errors) > 0 {
		b.WriteString(`,"errors":`)
		appendStringMapJSON(&b, details.Errors)
	}
	b.WriteString(`,"targets":[`)
	for i, target := range details.Targets {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"base_url":`)
		b.WriteString(strconv.Quote(target.BaseURL))
		b.WriteString(`,"summary":`)
		appendResourceSummaryJSON(&b, target.Summary)
		if len(target.Warnings) > 0 {
			b.WriteString(`,"warnings":`)
			appendStringMapJSON(&b, target.Warnings)
		}
		if len(target.Meta) > 0 {
			b.WriteString(`,"metadata":`)
			appendStringMapJSON(&b, target.Meta)
		}
		b.WriteByte('}')
	}
	b.WriteString(`]}`)

	return []byte(b.String()), nil
}

func appendCheckSummaryJSON(b *strings.Builder, summary checkSummary) {
	b.WriteString(`{"targets":`)
	b.WriteString(strconv.Itoa(summary.Targets))
	b.WriteString(`,"nodes":`)
	b.WriteString(strconv.Itoa(summary.Nodes))
	b.WriteString(`,"guests":`)
	b.WriteString(strconv.Itoa(summary.Guests))
	b.WriteString(`,"qemu":`)
	b.WriteString(strconv.Itoa(summary.QEMU))
	b.WriteString(`,"lxc":`)
	b.WriteString(strconv.Itoa(summary.LXC))
	b.WriteString(`,"storage":`)
	b.WriteString(strconv.Itoa(summary.Storage))
	b.WriteString(`,"network_interfaces":`)
	b.WriteString(strconv.Itoa(summary.NetworkInterfaces))
	b.WriteString(`,"disks":`)
	b.WriteString(strconv.Itoa(summary.Disks))
	b.WriteString(`,"ceph_enabled_nodes":`)
	b.WriteString(strconv.Itoa(summary.CephEnabledNodes))
	b.WriteString(`,"bottleneck_events":`)
	b.WriteString(strconv.Itoa(summary.Bottleneck))
	b.WriteByte('}')
}

func appendResourceSummaryJSON(b *strings.Builder, summary resourceSummary) {
	b.WriteByte('{')
	first := true
	appendFloatField := func(name string, value float64) {
		if value == 0 {
			return
		}
		appendComma(b, &first)
		b.WriteString(strconv.Quote(name))
		b.WriteByte(':')
		b.WriteString(strconv.FormatFloat(value, 'f', -1, 64))
	}
	appendIntField := func(name string, value int) {
		if value == 0 {
			return
		}
		appendComma(b, &first)
		b.WriteString(strconv.Quote(name))
		b.WriteByte(':')
		b.WriteString(strconv.Itoa(value))
	}

	appendFloatField("max_node_cpu_ratio", summary.MaxNodeCPURatio)
	appendFloatField("max_node_mem_ratio", summary.MaxNodeMemRatio)
	appendFloatField("max_node_io_wait_ratio", summary.MaxNodeIOWaitRatio)
	appendFloatField("max_node_storage_ratio", summary.MaxNodeStorageRatio)
	appendFloatField("max_guest_cpu_ratio", summary.MaxGuestCPURatio)
	appendFloatField("max_guest_mem_ratio", summary.MaxGuestMemRatio)
	appendFloatField("max_guest_disk_ratio", summary.MaxGuestDiskRatio)
	appendIntField("running_guests", summary.RunningGuests)
	appendIntField("stopped_guests", summary.StoppedGuests)
	appendIntField("online_nodes", summary.OnlineNodes)
	appendIntField("offline_nodes", summary.OfflineNodes)
	appendIntField("storage_count", summary.StorageCount)
	appendIntField("network_interface_count", summary.NetworkInterfaceCount)
	appendIntField("disk_count", summary.DiskCount)
	appendIntField("ceph_enabled_nodes", summary.CephEnabledNodes)
	appendIntField("ceph_warn_nodes", summary.CephWarnNodes)
	appendIntField("ceph_error_nodes", summary.CephErrorNodes)
	appendIntField("resource_bottleneck_events", summary.ResourceBottleneck)
	b.WriteByte('}')
}

func appendStringMapJSON(b *strings.Builder, values map[string]string) {
	b.WriteByte('{')
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sortStrings(keys)
	for i, key := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.Quote(key))
		b.WriteByte(':')
		b.WriteString(strconv.Quote(values[key]))
	}
	b.WriteByte('}')
}

func appendComma(b *strings.Builder, first *bool) {
	if *first {
		*first = false
		return
	}
	b.WriteByte(',')
}

func emptyResourceSummary(summary resourceSummary) bool {
	return summary == resourceSummary{}
}

func sortStrings(values []string) {
	for i := 1; i < len(values); i++ {
		for j := i; j > 0 && values[j] < values[j-1]; j-- {
			values[j], values[j-1] = values[j-1], values[j]
		}
	}
}
