package registry

import (
	"sort"
	"strings"
	"sync"

	"github.com/carverauto/serviceradar/pkg/logger"
)

// TrigramIndex maintains an in-memory trigram search index over device text fields.
type TrigramIndex struct {
	mu          sync.RWMutex
	trigramMap  map[string]map[string]struct{} // trigram -> device IDs
	deviceTexts map[string]string              // deviceID -> searchable text (lowercased)
	log         logger.Logger
}

// NewTrigramIndex creates a trigram index using the provided logger for warnings.
func NewTrigramIndex(log logger.Logger) *TrigramIndex {
	return &TrigramIndex{
		trigramMap:  make(map[string]map[string]struct{}),
		deviceTexts: make(map[string]string),
		log:         log,
	}
}

// TrigramMatch holds the score for a device ID returned by the trigram index.
type TrigramMatch struct {
	ID    string
	Score int
}

// Add indexes the given device text under the provided device ID.
func (t *TrigramIndex) Add(deviceID, text string) {
	if t == nil {
		return
	}

	t.mu.Lock()
	defer t.mu.Unlock()

	lowerID := strings.TrimSpace(deviceID)
	if lowerID == "" {
		return
	}

	normalized := normalizeSearchText(text)
	if existing, ok := t.deviceTexts[lowerID]; ok {
		if existing == normalized {
			return // nothing changed
		}
		t.removeLocked(lowerID)
	}

	if normalized == "" {
		t.deviceTexts[lowerID] = ""
		return
	}

	t.deviceTexts[lowerID] = normalized

	for trigram := range generateTrigrams(normalized) {
		set := t.trigramMap[trigram]
		if set == nil {
			set = make(map[string]struct{})
			t.trigramMap[trigram] = set
		}
		set[lowerID] = struct{}{}
	}
}

// Remove deletes the deviceID from the index.
func (t *TrigramIndex) Remove(deviceID string) {
	if t == nil {
		return
	}

	t.mu.Lock()
	defer t.mu.Unlock()
	t.removeLocked(strings.TrimSpace(deviceID))
}

// Search returns device IDs ordered by match strength for the query.
func (t *TrigramIndex) Search(query string) []TrigramMatch {
	if t == nil {
		return nil
	}

	normalized := normalizeSearchText(query)
	if normalized == "" {
		return nil
	}

	trigrams := generateTrigrams(normalized)

	t.mu.RLock()
	defer t.mu.RUnlock()

	score := make(map[string]int, len(t.deviceTexts))
	for trigram := range trigrams {
		if postings := t.trigramMap[trigram]; len(postings) > 0 {
			for deviceID := range postings {
				score[deviceID]++
			}
		}
	}

	// Fallback for extremely short queries: substring match over stored text.
	for deviceID, text := range t.deviceTexts {
		if strings.Contains(text, normalized) {
			score[deviceID]++
		}
	}

	if len(score) == 0 {
		return nil
	}

	type ranked struct {
		id    string
		score int
	}

	results := make([]ranked, 0, len(score))
	for id, sc := range score {
		results = append(results, ranked{id: id, score: sc})
	}

	sort.Slice(results, func(i, j int) bool {
		if results[i].score == results[j].score {
			return results[i].id < results[j].id
		}
		return results[i].score > results[j].score
	})

	matches := make([]TrigramMatch, 0, len(results))
	for _, r := range results {
		matches = append(matches, TrigramMatch{ID: r.id, Score: r.score})
	}

	return matches
}

// Reset clears all indexed entries.
func (t *TrigramIndex) Reset() {
	if t == nil {
		return
	}

	t.mu.Lock()
	defer t.mu.Unlock()

	t.trigramMap = make(map[string]map[string]struct{})
	t.deviceTexts = make(map[string]string)
}

func (t *TrigramIndex) removeLocked(deviceID string) {
	if deviceID == "" {
		return
	}

	text, ok := t.deviceTexts[deviceID]
	if !ok {
		return
	}
	delete(t.deviceTexts, deviceID)

	for trigram := range generateTrigrams(text) {
		if postings := t.trigramMap[trigram]; postings != nil {
			delete(postings, deviceID)
			if len(postings) == 0 {
				delete(t.trigramMap, trigram)
			}
		}
	}
}

func normalizeSearchText(text string) string {
	return strings.ToLower(strings.TrimSpace(text))
}

func generateTrigrams(text string) map[string]struct{} {
	trigrams := make(map[string]struct{})

	if text == "" {
		return trigrams
	}

	if len(text) < 3 {
		trigrams[text] = struct{}{}
		return trigrams
	}

	for i := 0; i <= len(text)-3; i++ {
		trigrams[text[i:i+3]] = struct{}{}
	}

	for _, token := range strings.Fields(text) {
		if len(token) < 3 {
			trigrams[token] = struct{}{}
			continue
		}
		for i := 0; i <= len(token)-3; i++ {
			trigrams[token[i:i+3]] = struct{}{}
		}
	}

	return trigrams
}
