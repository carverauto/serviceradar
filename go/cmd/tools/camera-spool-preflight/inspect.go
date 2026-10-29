package main

import (
	"context"

	core "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	meta "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

func inspect(ctx context.Context, client kubernetes.Interface, o options) string {
	ns, err := client.CoreV1().Namespaces().Get(ctx, o.namespace, meta.GetOptions{})
	if err != nil {
		return readFailure("namespace", err)
	}
	if string(ns.UID) != o.namespaceUID || ns.DeletionTimestamp != nil || ns.Status.Phase != core.NamespaceActive {
		return "namespace_mismatch_or_retiring"
	}
	pvc, err := client.CoreV1().PersistentVolumeClaims(o.namespace).Get(ctx, o.claim, meta.GetOptions{})
	if err != nil {
		return readFailure("claim", err)
	}
	if reason := checkClaim(pvc, o); reason != "" {
		return reason
	}
	pv, err := client.CoreV1().PersistentVolumes().Get(ctx, o.volume, meta.GetOptions{})
	if err != nil {
		return readFailure("volume", err)
	}
	if reason := checkVolume(pv, pvc, o); reason != "" {
		return reason
	}
	driver, err := client.StorageV1().CSIDrivers().Get(ctx, o.driver, meta.GetOptions{})
	if err != nil {
		return readFailure("driver", err)
	}
	if driver.DeletionTimestamp != nil {
		return "driver_retiring"
	}
	if reason := checkPods(ctx, client, o); reason != "" {
		return reason
	}
	return checkAttachments(ctx, client, o)
}

func checkClaim(pvc *core.PersistentVolumeClaim, o options) string {
	if string(pvc.UID) != o.claimUID || pvc.Spec.VolumeName != o.volume {
		return "claim_identity_mismatch"
	}
	if pvc.DeletionTimestamp != nil || pvc.Status.Phase != core.ClaimBound {
		return "claim_not_bound_or_retiring"
	}
	if len(pvc.OwnerReferences) != 0 {
		return "claim_has_cleanup_owner"
	}
	if !filesystemRWOP(pvc.Spec.VolumeMode, pvc.Spec.AccessModes) {
		return "claim_requires_filesystem_rwop"
	}
	requested, actual := pvc.Spec.Resources.Requests[core.ResourceStorage], pvc.Status.Capacity[core.ResourceStorage]
	minimum := resource.NewQuantity(o.minimumBytes, resource.BinarySI)
	if requested.Cmp(*minimum) < 0 || actual.Cmp(*minimum) < 0 {
		return "claim_capacity_insufficient"
	}
	return ""
}

func checkVolume(pv *core.PersistentVolume, pvc *core.PersistentVolumeClaim, o options) string {
	if string(pv.UID) != o.volumeUID {
		return "volume_identity_mismatch"
	}
	ref := pv.Spec.ClaimRef
	if ref == nil || ref.Name != o.claim || ref.Namespace != o.namespace || string(ref.UID) != o.claimUID {
		return "volume_claim_reference_mismatch"
	}
	if pv.DeletionTimestamp != nil || pv.Status.Phase != core.VolumeBound {
		return "volume_not_bound_or_retiring"
	}
	if pv.Spec.PersistentVolumeReclaimPolicy != core.PersistentVolumeReclaimRetain || len(pv.OwnerReferences) != 0 {
		return "volume_not_retained"
	}
	if !filesystemRWOP(pv.Spec.VolumeMode, pv.Spec.AccessModes) {
		return "volume_requires_filesystem_rwop"
	}
	capacity := pv.Spec.Capacity[core.ResourceStorage]
	if capacity.Cmp(*resource.NewQuantity(o.minimumBytes, resource.BinarySI)) < 0 {
		return "volume_capacity_insufficient"
	}
	if pvc.Spec.StorageClassName == nil || pv.Spec.StorageClassName != *pvc.Spec.StorageClassName {
		return "storage_class_mismatch"
	}
	csi := pv.Spec.CSI
	if csi == nil || csi.Driver != o.driver || csi.VolumeHandle != o.handle || csi.ReadOnly {
		return "csi_identity_or_access_mismatch"
	}
	return ""
}

func filesystemRWOP(mode *core.PersistentVolumeMode, access []core.PersistentVolumeAccessMode) bool {
	return (mode == nil || *mode == core.PersistentVolumeFilesystem) &&
		len(access) == 1 && access[0] == core.ReadWriteOncePod
}

func checkPods(ctx context.Context, client kubernetes.Interface, o options) string {
	return scanPages(func(page meta.ListOptions) (string, string) {
		pods, err := client.CoreV1().Pods(o.namespace).List(ctx, page)
		if err != nil {
			return "", readFailure("pods", err)
		}
		for _, pod := range pods.Items {
			for _, volume := range pod.Spec.Volumes {
				claim := volume.PersistentVolumeClaim
				if claim != nil && claim.ClaimName == o.claim {
					return "", "claim_referenced_by_pod"
				}
				if volume.Ephemeral != nil && pod.Name+"-"+volume.Name == o.claim {
					return "", "claim_referenced_by_pod"
				}
			}
		}
		return pods.Continue, ""
	})
}

func checkAttachments(ctx context.Context, client kubernetes.Interface, o options) string {
	return scanPages(func(page meta.ListOptions) (string, string) {
		attachments, err := client.StorageV1().VolumeAttachments().List(ctx, page)
		if err != nil {
			return "", readFailure("attachments", err)
		}
		for _, attachment := range attachments.Items {
			volume := attachment.Spec.Source.PersistentVolumeName
			if volume != nil && *volume == o.volume {
				// A pending or detached object still represents unresolved ownership.
				return "", "volume_attachment_present"
			}
		}
		return attachments.Continue, ""
	})
}

// Bound work even if a server returns a nonadvancing continuation token. An
// exhausted scan refuses rather than treating incomplete observation as absence.
func scanPages(read func(meta.ListOptions) (string, string)) string {
	page := meta.ListOptions{Limit: 100}
	for range 100 {
		next, reason := read(page)
		if reason != "" || next == "" {
			return reason
		}
		page.Continue = next
	}
	return "resource_scan_limit"
}

func readFailure(kind string, err error) string {
	if apierrors.IsNotFound(err) {
		return kind + "_not_found"
	}
	if apierrors.IsForbidden(err) || apierrors.IsUnauthorized(err) {
		return kind + "_read_denied"
	}
	return kind + "_read_failed"
}
