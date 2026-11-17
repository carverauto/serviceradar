package main

import (
	"net/url"
	"strings"
)

// protectStreamAliasMetadataKeys are the profile metadata keys that carry a
// raw controller stream alias.
var protectStreamAliasMetadataKeys = []string{"rtsp_alias", "rtsps_alias"}

// omitProtectStreamAddresses rewrites an inventory report for a host that
// resolves stream addresses at open time (design D8): every profile and
// stream reports only its origin, and no stream URL, alias or raw controller
// channel or response body is left anywhere in the details.
func omitProtectStreamAddresses(details *ResultDetails) {
	if len(details.Cameras) > 0 {
		cameras := make([]ProtectCamera, len(details.Cameras))
		for i, camera := range details.Cameras {
			camera.Channels = nil
			cameras[i] = camera
		}
		details.Cameras = cameras
	}

	streams := make([]StreamInfo, len(details.Streams))
	for i, stream := range details.Streams {
		stream.SourceOrigin = streamOrigin(stream.URL)
		stream.URL = ""
		streams[i] = stream
	}
	details.Streams = streams

	descriptors := make([]CameraDescriptor, len(details.CameraDescriptors))
	for i, descriptor := range details.CameraDescriptors {
		descriptor.SourceURL = ""
		profiles := make([]CameraStreamProfile, len(descriptor.StreamProfiles))
		for j, profile := range descriptor.StreamProfiles {
			profile.SourceOrigin = streamOrigin(profile.SourceURLOverride)
			profile.SourceURLOverride = ""
			profile.Metadata = withoutKeys(profile.Metadata, protectStreamAliasMetadataKeys)
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

func withoutKeys(in map[string]interface{}, keys []string) map[string]interface{} {
	if in == nil {
		return nil
	}
	out := make(map[string]interface{}, len(in))
	for key, value := range in {
		out[key] = value
	}
	for _, key := range keys {
		delete(out, key)
	}
	return out
}
