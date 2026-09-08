package trivysidecar

import "sync"

// RevisionDeduper tracks the last published resourceVersion per UID.
type RevisionDeduper struct {
	mu             sync.RWMutex
	revisionsByUID map[string]string
}

func NewRevisionDeduper() *RevisionDeduper {
	return &RevisionDeduper{revisionsByUID: make(map[string]string)}
}

func (d *RevisionDeduper) IsDuplicate(uid, resourceVersion string) bool {
	d.mu.RLock()
	defer d.mu.RUnlock()

	current, ok := d.revisionsByUID[uid]
	if !ok {
		return false
	}

	return current == resourceVersion
}

func (d *RevisionDeduper) MarkPublished(uid, resourceVersion string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.revisionsByUID[uid] = resourceVersion
}
