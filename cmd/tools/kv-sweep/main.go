// kv-sweep is a maintenance tool for cleaning up legacy device_canonical_map/* entries in KV.
//
// DEPRECATION NOTICE: As of the remove-identity-kv-cache change, KV is no longer used for
// device identity resolution. CNPG is the authoritative source for identity. This tool
// remains useful only for cleaning up legacy KV entries from previous deployments.
// The -rehydrate flag has been removed since GetCanonicalDevice no longer writes to KV.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/nats-io/nats.go"

	"github.com/carverauto/serviceradar/pkg/identitymap"
)

type sweepConfig struct {
	natsURL         string
	natsUser        string
	natsPass        string
	natsCreds       string
	natsNKey        string
	natsTLSCert     string
	natsTLSKey      string
	natsTLSCA       string
	natsInsecureTLS bool
	jsDomain        string
	bucket          string
	prefix          string
	maxKeys         int
	deleteCorrupt   bool
	dryRun          bool
	reportPath      string
	dumpDir         string
	timeout         time.Duration
}

type corruptRecord struct {
	Key           string `json:"key"`
	Revision      uint64 `json:"revision"`
	Error         string `json:"error"`
	DumpedPayload string `json:"dump_path,omitempty"`
}

type sweepStats struct {
	totalKeys      int
	filteredKeys   int
	validRecords   int
	corruptRecords int
	deleted        int
	deleteFailures int
	startedAt      time.Time
}

var (
	errBucketRequired = errors.New("bucket is required")
)

func main() {
	cfg := parseFlags()
	if err := run(cfg); err != nil {
		log.Fatalf("kv-sweep failed: %v", err)
	}
}

func parseFlags() sweepConfig {
	var cfg sweepConfig
	flag.StringVar(&cfg.natsURL, "nats-url", getenvDefault("NATS_URL", "nats://serviceradar-nats:4222"), "NATS server URL")
	flag.StringVar(&cfg.natsUser, "nats-user", os.Getenv("NATS_USER"), "NATS username")
	flag.StringVar(&cfg.natsPass, "nats-pass", os.Getenv("NATS_PASSWORD"), "NATS password")
	flag.StringVar(&cfg.natsCreds, "nats-creds", os.Getenv("NATS_CREDS"), "path to NATS creds file")
	flag.StringVar(&cfg.natsNKey, "nats-nkey", os.Getenv("NATS_NKEY"), "path to NATS NKey seed file")
	flag.StringVar(&cfg.natsTLSCert, "nats-tls-cert", os.Getenv("NATS_TLS_CERT"), "path to TLS client certificate")
	flag.StringVar(&cfg.natsTLSKey, "nats-tls-key", os.Getenv("NATS_TLS_KEY"), "path to TLS client key")
	flag.StringVar(&cfg.natsTLSCA, "nats-tls-ca", os.Getenv("NATS_CA"), "path to TLS CA bundle")
	flag.BoolVar(&cfg.natsInsecureTLS, "nats-tls-insecure", false, "skip TLS verification (development only)")
	flag.StringVar(&cfg.jsDomain, "js-domain", os.Getenv("NATS_JS_DOMAIN"), "JetStream domain (optional)")

	flag.StringVar(&cfg.bucket, "bucket", getenvDefault("KV_BUCKET", "serviceradar-datasvc"), "KV bucket to scan")
	flag.StringVar(&cfg.prefix, "prefix", identitymap.DefaultNamespace+"/", "key prefix to filter (default: canonical map)")
	flag.IntVar(&cfg.maxKeys, "max-keys", 0, "limit number of keys to inspect (0 = no limit)")
	flag.BoolVar(&cfg.deleteCorrupt, "delete", false, "delete corrupt entries after recording them")
	flag.BoolVar(&cfg.dryRun, "dry-run", false, "log planned actions without performing mutations")
	flag.StringVar(&cfg.reportPath, "report", "", "optional path to write JSON report of corrupt keys")
	flag.StringVar(&cfg.dumpDir, "dump-dir", "", "directory to dump raw payloads for corrupt entries")
	flag.DurationVar(&cfg.timeout, "timeout", 5*time.Second, "per-key operation timeout")

	flag.Parse()

	return cfg
}

func run(cfg sweepConfig) error {
	log.Println("NOTE: KV is no longer used for identity resolution. This tool cleans up legacy entries.")

	if err := validateSweepConfig(cfg); err != nil {
		return err
	}

	nc, err := connectNATS(cfg)
	if err != nil {
		return fmt.Errorf("connect to NATS: %w", err)
	}
	defer drainNATS(nc)

	jsOpts := []nats.JSOpt{}
	if cfg.jsDomain != "" {
		jsOpts = append(jsOpts, nats.Domain(cfg.jsDomain))
	}
	js, err := nc.JetStream(jsOpts...)
	if err != nil {
		return fmt.Errorf("init JetStream: %w", err)
	}

	kv, err := js.KeyValue(cfg.bucket)
	if err != nil {
		return fmt.Errorf("open bucket %q: %w", cfg.bucket, err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	stats := sweepStats{startedAt: time.Now()}
	var problems []corruptRecord

	if cfg.dumpDir != "" {
		if err := os.MkdirAll(cfg.dumpDir, 0o755); err != nil {
			return fmt.Errorf("create dump dir: %w", err)
		}
	}

	if err := scanBucket(ctx, kv, cfg, &stats, &problems); err != nil {
		return err
	}

	if cfg.reportPath != "" {
		report := map[string]any{
			"bucket":       cfg.bucket,
			"prefix":       cfg.prefix,
			"stats":        stats,
			"corrupt":      problems,
			"generated_at": time.Now().UTC().Format(time.RFC3339),
		}
		if err := writeJSON(cfg.reportPath, report); err != nil {
			return fmt.Errorf("write report: %w", err)
		}
	}

	log.Printf("Scanned %d keys (prefix match %d); valid=%d corrupt=%d deleted=%d (%d failures) in %s",
		stats.totalKeys,
		stats.filteredKeys,
		stats.validRecords,
		stats.corruptRecords,
		stats.deleted,
		stats.deleteFailures,
		time.Since(stats.startedAt).Round(time.Millisecond),
	)

	if cfg.dryRun && cfg.deleteCorrupt {
		log.Println("Dry-run mode was enabled; no keys were deleted.")
	}

	if len(problems) > 0 && cfg.reportPath == "" {
		output, _ := json.MarshalIndent(problems, "", "  ")
		fmt.Printf("%s\n", output)
	}

	return nil
}

func validateSweepConfig(cfg sweepConfig) error {
	if cfg.bucket == "" {
		return errBucketRequired
	}
	return nil
}

func scanBucket(
	ctx context.Context,
	kv nats.KeyValue,
	cfg sweepConfig,
	stats *sweepStats,
	problems *[]corruptRecord,
) error {
	lister, err := kv.ListKeys()
	if err != nil {
		return fmt.Errorf("list keys: %w", err)
	}
	defer stopLister(lister)

	for key := range lister.Keys() {
		stats.totalKeys++
		if cfg.prefix != "" && !strings.HasPrefix(key, cfg.prefix) {
			continue
		}

		stats.filteredKeys++
		if cfg.maxKeys > 0 && stats.filteredKeys > cfg.maxKeys {
			break
		}

		if err := processKey(ctx, kv, key, cfg, stats, problems); err != nil {
			log.Printf("WARN: %v", err)
		}
	}

	return nil
}

func processKey(
	ctx context.Context,
	kv nats.KeyValue,
	key string,
	cfg sweepConfig,
	stats *sweepStats,
	problems *[]corruptRecord,
) error {
	entry, err := kv.Get(key)
	if err != nil {
		return fmt.Errorf("failed to get key %s: %w", key, err)
	}

	value := entry.Value()
	if _, err := identitymap.UnmarshalRecord(value); err != nil {
		handleCorruptEntry(cfg, kv, key, entry, value, stats, problems, err)
		return nil
	}

	stats.validRecords++
	return nil
}

func handleCorruptEntry(
	cfg sweepConfig,
	kv nats.KeyValue,
	key string,
	entry nats.KeyValueEntry,
	value []byte,
	stats *sweepStats,
	problems *[]corruptRecord,
	parseErr error,
) {
	stats.corruptRecords++
	rec := corruptRecord{
		Key:      key,
		Revision: entry.Revision(),
		Error:    parseErr.Error(),
	}

	if cfg.dumpDir != "" {
		if path, dumpErr := dumpPayload(cfg.dumpDir, key, value); dumpErr != nil {
			log.Printf("WARN: failed to dump payload for %s: %v", key, dumpErr)
		} else {
			rec.DumpedPayload = path
		}
	}

	if cfg.deleteCorrupt {
		if cfg.dryRun {
			log.Printf("[dry-run] would delete %s (rev=%d)", key, entry.Revision())
		} else if err := kv.Delete(key); err != nil {
			stats.deleteFailures++
			log.Printf("ERROR: failed to delete %s: %v", key, err)
		} else {
			stats.deleted++
			log.Printf("Deleted %s (rev=%d)", key, entry.Revision())
		}
	}

	*problems = append(*problems, rec)
}

func drainNATS(nc *nats.Conn) {
	if nc == nil {
		return
	}

	if err := nc.Drain(); err != nil {
		log.Printf("WARN: failed to drain NATS connection: %v", err)
	}
}

func stopLister(lister nats.KeyLister) {
	if lister == nil {
		return
	}
	if err := lister.Stop(); err != nil {
		log.Printf("WARN: failed to stop key lister: %v", err)
	}
}

func connectNATS(cfg sweepConfig) (*nats.Conn, error) {
	opts := []nats.Option{
		nats.Name("serviceradar-kv-sweep"),
		nats.Timeout(10 * time.Second),
	}

	if cfg.natsUser != "" {
		opts = append(opts, nats.UserInfo(cfg.natsUser, cfg.natsPass))
	}
	if cfg.natsCreds != "" {
		opts = append(opts, nats.UserCredentials(cfg.natsCreds))
	}
	if cfg.natsNKey != "" {
		opt, err := nats.NkeyOptionFromSeed(cfg.natsNKey)
		if err != nil {
			return nil, fmt.Errorf("load NATS nkey seed: %w", err)
		}
		opts = append(opts, opt)
	}

	tlsConfig, err := buildTLSConfig(cfg)
	if err != nil {
		return nil, err
	}
	if tlsConfig != nil {
		opts = append(opts, nats.Secure(tlsConfig))
	}

	return nats.Connect(cfg.natsURL, opts...)
}

func buildTLSConfig(cfg sweepConfig) (*tls.Config, error) {
	if cfg.natsTLSCert == "" && cfg.natsTLSKey == "" && cfg.natsTLSCA == "" && !cfg.natsInsecureTLS {
		return nil, nil
	}

	tlsConfig := &tls.Config{
		MinVersion: tls.VersionTLS12,
	}
	if cfg.natsInsecureTLS {
		tlsConfig.InsecureSkipVerify = true
	}

	if cfg.natsTLSCA != "" {
		caCert, err := os.ReadFile(cfg.natsTLSCA)
		if err != nil {
			return nil, fmt.Errorf("read NATS CA file: %w", err)
		}
		cp := x509.NewCertPool()
		cp.AppendCertsFromPEM(caCert)
		tlsConfig.RootCAs = cp
	}

	if cfg.natsTLSCert != "" && cfg.natsTLSKey != "" {
		cert, err := tls.LoadX509KeyPair(cfg.natsTLSCert, cfg.natsTLSKey)
		if err != nil {
			return nil, fmt.Errorf("load client certificate: %w", err)
		}
		tlsConfig.Certificates = []tls.Certificate{cert}
	}

	return tlsConfig, nil
}

func dumpPayload(dir, key string, value []byte) (string, error) {
	safeName := strings.NewReplacer("/", "_", ":", "_").Replace(key)
	target := filepath.Join(dir, safeName+".b64")
	encoded := base64.StdEncoding.EncodeToString(value)
	if err := os.WriteFile(target, []byte(encoded+"\n"), fs.FileMode(0o644)); err != nil {
		return "", err
	}
	return target, nil
}

func writeJSON(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

func getenvDefault(key, fallback string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return fallback
}
