package main

import "net/http"

// collectAddresses fetches GPS coordinates for service lines that carry an
// addressReferenceId. Latitude/longitude are written back onto the matching
// service line entries in snap.ServiceLines. Best-effort: a missing address or
// failed request does not mark the snapshot incomplete; it is simply skipped.
func collectAddresses(c *apiClient, snap *inventorySnapshot) {
	seen := map[string]bool{}
	for _, sl := range snap.ServiceLines {
		if sl.AddressReferenceID != "" && jsonSafeID(sl.AddressReferenceID) {
			seen[sl.AddressReferenceID] = true
		}
	}
	if len(seen) == 0 {
		return
	}

	type coords struct{ lat, lon float64 }
	resolved := map[string]coords{}
	for addrID := range seen {
		content, err := c.call(http.MethodGet, "/addresses/"+addrID, nil, nil, 0)
		if err != nil {
			continue
		}
		lat := content.Get("latitude").Float()
		lon := content.Get("longitude").Float()
		if lat == 0 && lon == 0 {
			continue
		}
		resolved[addrID] = coords{lat: lat, lon: lon}
	}

	for num, sl := range snap.ServiceLines {
		if pt, ok := resolved[sl.AddressReferenceID]; ok {
			sl.Latitude = pt.lat
			sl.Longitude = pt.lon
			snap.ServiceLines[num] = sl
		}
	}
}
