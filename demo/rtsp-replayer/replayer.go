package replayer

import (
	"context"
	"crypto/rand"
	_ "embed"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"text/template"
	"time"
)

//go:embed clips.lock.json
var defaultLock []byte

//go:embed paths.json
var defaultPaths []byte

//go:embed mediamtx.yml
var mediamtxTemplate string

// Config is the replayer's runtime configuration, read from the environment.
type Config struct {
	S3Endpoint string
	S3Bucket   string
	S3Region   string
	AccessKey  string
	SecretKey  string

	ClipsDir    string
	MediamtxBin string
	FFmpegBin   string
}

// ConfigFromEnv reads configuration from the environment. Credentials come
// from REPLAYER_S3_ACCESS_KEY / REPLAYER_S3_SECRET_KEY or their _FILE
// variants (Kubernetes secret mounts); nothing is committed anywhere.
func ConfigFromEnv() (Config, error) {
	cfg := Config{
		S3Endpoint:  strings.TrimSuffix(os.Getenv("REPLAYER_S3_ENDPOINT"), "/"),
		S3Bucket:    os.Getenv("REPLAYER_S3_BUCKET"),
		S3Region:    envOr("REPLAYER_S3_REGION", "us-ord"),
		ClipsDir:    envOr("REPLAYER_CLIPS_DIR", "/var/lib/replayer/clips"),
		MediamtxBin: envOr("REPLAYER_MEDIAMTX_BIN", "/usr/local/bin/mediamtx"),
		FFmpegBin:   envOr("REPLAYER_FFMPEG_BIN", "/usr/local/bin/ffmpeg"),
	}
	access, err := secretValue("REPLAYER_S3_ACCESS_KEY")
	if err != nil {
		return Config{}, err
	}
	secret, err := secretValue("REPLAYER_S3_SECRET_KEY")
	if err != nil {
		return Config{}, err
	}
	cfg.AccessKey, cfg.SecretKey = access, secret

	if cfg.S3Endpoint == "" {
		return Config{}, errors.New("REPLAYER_S3_ENDPOINT is required")
	}
	if cfg.S3Bucket == "" {
		return Config{}, errors.New("REPLAYER_S3_BUCKET is required")
	}
	if cfg.AccessKey == "" || cfg.SecretKey == "" {
		return Config{}, errors.New("S3 credentials are required (REPLAYER_S3_ACCESS_KEY/SECRET_KEY or _FILE variants)")
	}
	return cfg, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func secretValue(key string) (string, error) {
	if path := os.Getenv(key + "_FILE"); path != "" {
		raw, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("read %s_FILE: %w", key, err)
		}
		return strings.TrimSpace(string(raw)), nil
	}
	return os.Getenv(key), nil
}

// Run fetches and verifies the locked clips, then supervises MediaMTX plus
// one ffmpeg publisher per RTSP path. With fetchOnly it stops after the
// fetch, for init containers and smoke checks. It returns the process exit
// code.
func Run(ctx context.Context, cfg Config, fetchOnly bool, stdout, stderr io.Writer) int {
	log := log.New(stdout, "replayer: ", log.LstdFlags)

	lock, err := ParseLock(defaultLock)
	if err != nil {
		fmt.Fprintf(stderr, "replayer: %v\n", err)
		return 1
	}
	paths, err := ParsePaths(defaultPaths, lock)
	if err != nil {
		fmt.Fprintf(stderr, "replayer: %v\n", err)
		return 1
	}

	s3 := &S3Client{
		Endpoint:  cfg.S3Endpoint,
		Bucket:    cfg.S3Bucket,
		Region:    cfg.S3Region,
		AccessKey: cfg.AccessKey,
		SecretKey: cfg.SecretKey,
	}
	log.Printf("fetching %d locked clips from s3://%s", len(lock.Clips), cfg.S3Bucket)
	if err := EnsureClips(ctx, log, s3, lock, cfg.ClipsDir); err != nil {
		fmt.Fprintf(stderr, "replayer: %v\n", err)
		return 1
	}
	if fetchOnly {
		log.Printf("fetch-only: all clips verified")
		return 0
	}

	configPath, publishURL, err := prepareMediaMTX(cfg.ClipsDir)
	if err != nil {
		fmt.Fprintf(stderr, "replayer: prepare mediamtx: %v\n", err)
		return 1
	}
	defer os.Remove(configPath)
	mediamtx := Child{Name: "mediamtx", Bin: cfg.MediamtxBin, Args: []string{configPath}}
	ffmpegChildren := make([]Child, 0, len(paths.Paths))
	for _, p := range paths.Paths {
		clip, _ := lock.ClipByName(p.Clip)
		ffmpegChildren = append(ffmpegChildren, Child{
			Name: "ffmpeg/" + p.Path,
			Bin:  cfg.FFmpegBin,
			Args: FFmpegArgs(
				filepath.Join(cfg.ClipsDir, filepath.Base(clip.Key)),
				publishURL.String(), p.Path,
			),
			StartAfter: time.Duration(p.StartOffsetSeconds * float64(time.Second)),
		})
	}

	// MediaMTX first: publishers have nowhere to push until its RTSP port
	// accepts. Either side failing later stops the other; the replayer never
	// serves a partial path set.
	runCtx, stopAll := context.WithCancel(ctx)
	defer stopAll()
	mediamtxErr := make(chan error, 1)
	go func() {
		mediamtxErr <- Supervise(runCtx, log, []Child{mediamtx})
	}()
	rtspAddr := publishURL.Host
	select {
	case err := <-mediamtxErr:
		fmt.Fprintf(stderr, "replayer: mediamtx failed to start: %v\n", err)
		return 1
	case <-time.After(45 * time.Second):
		stopAll()
		<-mediamtxErr
		fmt.Fprintf(stderr, "replayer: mediamtx did not become ready\n")
		return 1
	case <-waitTCPAsync(runCtx, rtspAddr):
	}
	log.Printf("mediamtx ready, starting %d publishers", len(ffmpegChildren))

	ffmpegErr := make(chan error, 1)
	go func() {
		ffmpegErr <- Supervise(runCtx, log, ffmpegChildren)
	}()
	select {
	case err := <-mediamtxErr:
		stopAll()
		<-ffmpegErr
		return exitFor(err, ctx, stderr)
	case err := <-ffmpegErr:
		stopAll()
		<-mediamtxErr
		return exitFor(err, ctx, stderr)
	case <-ctx.Done():
		stopAll()
		<-mediamtxErr
		<-ffmpegErr
		return 0
	}
}

func prepareMediaMTX(clipsDir string) (string, *url.URL, error) {
	var secret [32]byte
	if _, err := rand.Read(secret[:]); err != nil {
		return "", nil, err
	}
	password := hex.EncodeToString(secret[:])
	u := &url.URL{Scheme: "rtsp", Host: "127.0.0.1:8554", User: url.UserPassword("replayer", password)}
	tmpl, err := template.New("mediamtx").Parse(mediamtxTemplate)
	if err != nil {
		return "", nil, err
	}
	f, err := os.CreateTemp(filepath.Dir(filepath.Clean(clipsDir)), "mediamtx-*.yml")
	if err != nil {
		return "", nil, err
	}
	err = tmpl.Execute(f, password)
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		os.Remove(f.Name())
		return "", nil, err
	}
	return f.Name(), u, nil
}

// exitFor maps a supervision result to an exit code: a child that really
// failed is 1; anything racing an outer shutdown is a clean 0.
func exitFor(err error, ctx context.Context, stderr io.Writer) int {
	if ctx.Err() != nil || err == nil {
		return 0
	}
	fmt.Fprintf(stderr, "replayer: %v\n", err)
	return 1
}

// waitTCPAsync resolves when addr accepts TCP (or ctx ends).
func waitTCPAsync(ctx context.Context, addr string) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			if err := WaitTCP(ctx, addr, 5*time.Second); err == nil {
				return
			}
			if ctx.Err() != nil {
				return
			}
		}
	}()
	return done
}
