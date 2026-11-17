package main

import (
	"net/url"
	"strings"
)

// omitAxisStreamAddresses rewrites an inventory report for a host that
// resolves stream addresses at open time (design D8): every stream and profile
// reports only its origin, and no media path, query or raw VAPIX response body
// is left in the details.
func omitAxisStreamAddresses(details *ResultDetails) {
	streams := make([]StreamInfo, len(details.Streams))
	for i, stream := range details.Streams {
		stream.SourceOrigin = streamOrigin(stream.URL)
		stream.URL = ""
		streams[i] = stream
	}
	details.Streams = streams
	if details.Enrichment != nil {
		details.Enrichment["streams"] = streams
	}

	descriptors := make([]CameraDescriptor, len(details.CameraDescriptors))
	for i, descriptor := range details.CameraDescriptors {
		descriptor.SourceURL = ""
		profiles := make([]CameraStreamProfile, len(descriptor.StreamProfiles))
		for j, profile := range descriptor.StreamProfiles {
			profile.SourceOrigin = streamOrigin(profile.SourceURLOverride)
			profile.SourceURLOverride = ""
			profiles[j] = profile
		}
		descriptor.StreamProfiles = profiles
		descriptors[i] = descriptor
	}
	details.CameraDescriptors = descriptors

	endpoints := make([]EndpointResult, len(details.Endpoints))
	for i, endpoint := range details.Endpoints {
		endpoint.Body = ""
		endpoints[i] = endpoint
	}
	details.Endpoints = endpoints
}

// streamOrigin returns scheme://host[:port] of a stream address, without
// userinfo, path or query, or "" when the address has no scheme and host.
func streamOrigin(raw string) string {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return ""
	}
	return strings.ToLower(parsed.Scheme) + "://" + parsed.Host
}
