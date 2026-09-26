/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package datasvc

import (
	"fmt"
	"strconv"
	"strings"
)

const (
	jetStreamEnvPrefix         = "SERVICERADAR_JS_"
	jetStreamEnvMaxBytesSuffix = "MAX_BYTES"
	jetStreamEnvReplicasSuffix = "REPLICAS"
	maxJetStreamReplicas       = 5
)

// kvStreamName is the JetStream stream that backs a KV bucket.
func kvStreamName(bucket string) string {
	return "KV_" + bucket
}

// objectStoreStreamName is the JetStream stream that backs an object store bucket.
func objectStoreStreamName(bucket string) string {
	return "OBJ_" + bucket
}

// jetStreamEnvName returns SERVICERADAR_JS_<STREAM>_<suffix>, where <STREAM> is
// the stream name upper-cased with every non-alphanumeric character replaced by
// '_'. For the default buckets that is
// SERVICERADAR_JS_KV_SERVICERADAR_DATASVC_MAX_BYTES and
// SERVICERADAR_JS_OBJ_SERVICERADAR_OBJECTS_MAX_BYTES.
func jetStreamEnvName(stream, suffix string) string {
	var b strings.Builder

	b.WriteString(jetStreamEnvPrefix)

	for _, r := range strings.ToUpper(stream) {
		if (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}

	b.WriteByte('_')
	b.WriteString(suffix)

	return b.String()
}

// applyJetStreamEnvOverrides resolves the size and replica count of the KV
// bucket and the object store. The precedence is the environment, then the
// JSON value, then the compiled default; the JSON value and the default are
// already on c when this runs. A variable that is set to something other than
// a positive integer (or, for replicas, an integer from 1 to 5) is an error
// naming the variable, so a bad preset fails startup instead of silently
// falling back. A variable set to the empty string counts as unset.
func (c *Config) applyJetStreamEnvOverrides(lookup func(string) (string, bool)) error {
	kvStream := kvStreamName(c.Bucket)
	objStream := objectStoreStreamName(c.ObjectBucket)

	bucketMaxBytes, err := lookupPositiveInt(lookup, jetStreamEnvName(kvStream, jetStreamEnvMaxBytesSuffix), c.BucketMaxBytes)
	if err != nil {
		return err
	}

	objectStoreBytes, err := lookupPositiveInt(lookup, jetStreamEnvName(objStream, jetStreamEnvMaxBytesSuffix), c.ObjectStoreBytes)
	if err != nil {
		return err
	}

	bucketReplicas, err := lookupReplicas(lookup, jetStreamEnvName(kvStream, jetStreamEnvReplicasSuffix), c.JetStreamReplicas)
	if err != nil {
		return err
	}

	objectStoreReplicas, err := lookupReplicas(lookup, jetStreamEnvName(objStream, jetStreamEnvReplicasSuffix), c.JetStreamReplicas)
	if err != nil {
		return err
	}

	c.BucketMaxBytes = bucketMaxBytes
	c.ObjectStoreBytes = objectStoreBytes
	c.BucketReplicas = bucketReplicas
	c.ObjectStoreReplicas = objectStoreReplicas

	return nil
}

func lookupPositiveInt(lookup func(string) (string, bool), name string, fallback int64) (int64, error) {
	raw, ok := lookup(name)
	raw = strings.TrimSpace(raw)

	if !ok || raw == "" {
		return fallback, nil
	}

	value, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || value <= 0 {
		return 0, fmt.Errorf("%w: %s=%q must be a positive integer number of bytes", errJetStreamEnvInvalid, name, raw)
	}

	return value, nil
}

func lookupReplicas(lookup func(string) (string, bool), name string, fallback int) (int, error) {
	raw, ok := lookup(name)
	raw = strings.TrimSpace(raw)

	if !ok || raw == "" {
		return fallback, nil
	}

	value, err := strconv.Atoi(raw)
	if err != nil || value < 1 || value > maxJetStreamReplicas {
		return 0, fmt.Errorf("%w: %s=%q must be an integer from 1 to %d", errJetStreamEnvInvalid, name, raw, maxJetStreamReplicas)
	}

	return value, nil
}

// stateBucketMaxBytes decides the max_bytes a discard-new state bucket (the
// datasvc KV bucket and object store) reconciles to. A discard-new bucket
// refuses every write once it is full and holds state that cannot be
// regenerated, so a configured cap below the bytes already stored is not
// applied: the current max_bytes (which may be unlimited) is kept and held is
// true so the caller can log it. The cap is never set to the stored size,
// because a cap equal to the stored bytes would refuse every later write. A
// non-positive configured value means no cap is configured and the current
// value is kept.
func stateBucketMaxBytes(current int64, stored uint64, configured int64) (target int64, held bool) {
	if configured <= 0 || current == configured {
		return current, false
	}

	if stored > uint64(configured) {
		return current, true
	}

	return configured, false
}
