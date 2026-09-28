package replayer

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sort"
	"strings"
	"testing"
	"time"
)

func TestBuildCanonicalRequestGolden(t *testing.T) {
	query := url.Values{}
	query.Set("list-type", "2")
	query.Set("prefix", "")
	got := buildCanonicalRequest(
		http.MethodGet,
		"/demo-bucket/clips/a.mp4",
		query,
		map[string]string{
			"host":                 "s3.example.com",
			"x-amz-content-sha256": emptyBodySHA256,
			"x-amz-date":           "20260102T030405Z",
		},
		"host;x-amz-content-sha256;x-amz-date",
		emptyBodySHA256,
	)
	want := "GET\n" +
		"/demo-bucket/clips/a.mp4\n" +
		"list-type=2&prefix=\n" +
		"host:s3.example.com\n" +
		"x-amz-content-sha256:" + emptyBodySHA256 + "\n" +
		"x-amz-date:20260102T030405Z\n" +
		"\n" +
		"host;x-amz-content-sha256;x-amz-date\n" +
		emptyBodySHA256
	if got != want {
		t.Fatalf("canonical request mismatch:\n got: %q\nwant: %q", got, want)
	}
}

func TestRFC3986Encode(t *testing.T) {
	cases := map[string]string{
		"abc-_.~09": "abc-_.~09",
		"a b":       "a%20b",
		"a+b":       "a%2Bb",
		"a/b":       "a%2Fb",
		"":          "",
	}
	for in, want := range cases {
		if got := rfc3986Encode(in); got != want {
			t.Errorf("rfc3986Encode(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSignV4Shape(t *testing.T) {
	req, _ := http.NewRequest(http.MethodGet, "https://s3.example.com/b/k", nil)
	when := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	signV4(req, "/b/k", nil, "us-ord-1", "AKID", "SECRET", when)

	auth := req.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "AWS4-HMAC-SHA256 Credential=AKID/20260102/us-ord-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=") {
		t.Fatalf("bad authorization header: %q", auth)
	}
	sig := strings.TrimPrefix(auth[strings.LastIndex(auth, "Signature="):], "Signature=")
	if len(sig) != 64 {
		t.Fatalf("signature is %d hex chars, want 64: %q", len(sig), sig)
	}
	if got := req.Header.Get("x-amz-date"); got != "20260102T030405Z" {
		t.Fatalf("bad x-amz-date: %q", got)
	}

	// Deterministic for fixed inputs, sensitive to the secret.
	req2, _ := http.NewRequest(http.MethodGet, "https://s3.example.com/b/k", nil)
	signV4(req2, "/b/k", nil, "us-ord-1", "AKID", "SECRET", when)
	if req2.Header.Get("Authorization") != auth {
		t.Fatalf("signing is not deterministic")
	}
	req3, _ := http.NewRequest(http.MethodGet, "https://s3.example.com/b/k", nil)
	signV4(req3, "/b/k", nil, "us-ord-1", "AKID", "OTHER", when)
	if req3.Header.Get("Authorization") == auth {
		t.Fatalf("signature ignores the secret")
	}
}

// fakeS3 serves ListObjectsV2 (paginated, one key per page) and object GETs.
type fakeS3 struct {
	t       *testing.T
	objects map[string][]byte
	gets    int
	auths   []string
}

func (f *fakeS3) handler(w http.ResponseWriter, r *http.Request) {
	f.auths = append(f.auths, r.Header.Get("Authorization"))
	if r.Header.Get("x-amz-date") == "" {
		f.t.Errorf("missing x-amz-date")
	}
	if r.URL.Query().Get("list-type") == "2" {
		var keys []string
		for k := range f.objects {
			keys = append(keys, k)
		}
		sort.Strings(keys) // stable across pages; map order would drop keys
		// Deliberately paginate one key per page.
		start := 0
		if tok := r.URL.Query().Get("continuation-token"); tok != "" {
			for i, k := range keys {
				if k == tok {
					start = i + 1
				}
			}
		}
		w.Header().Set("Content-Type", "application/xml")
		w.Write([]byte(`<?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">`))
		if start < len(keys) {
			w.Write([]byte(`<Contents><Key>` + keys[start] + `</Key></Contents>`))
		}
		if start+1 < len(keys) {
			w.Write([]byte(`<IsTruncated>true</IsTruncated><NextContinuationToken>` + keys[start] + `</NextContinuationToken>`))
		} else {
			w.Write([]byte(`<IsTruncated>false</IsTruncated>`))
		}
		w.Write([]byte(`</ListBucketResult>`))
		return
	}
	key := strings.TrimPrefix(r.URL.Path, "/b/")
	body, ok := f.objects[key]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte(`<Error><Code>NoSuchKey</Code><Message>nope</Message></Error>`))
		return
	}
	f.gets++
	w.Write(body)
}

func TestS3ListAndGetRoundTrip(t *testing.T) {
	fake := &fakeS3{t: t, objects: map[string][]byte{"a.mp4": []byte("AAA"), "b.mp4": []byte("BBBB")}}
	srv := httptest.NewServer(http.HandlerFunc(fake.handler))
	defer srv.Close()

	c := &S3Client{Endpoint: srv.URL, Bucket: "b", Region: "us-ord-1", AccessKey: "A", SecretKey: "S", HTTP: srv.Client()}
	ctx := context.Background()

	keys, err := c.ListKeys(ctx)
	if err != nil {
		t.Fatalf("ListKeys: %v", err)
	}
	if len(keys) != 2 {
		t.Fatalf("ListKeys = %v, want 2 keys across pages", keys)
	}
	var sb strings.Builder
	if err := c.GetObject(ctx, "b.mp4", &sb); err != nil {
		t.Fatalf("GetObject: %v", err)
	}
	if sb.String() != "BBBB" {
		t.Fatalf("GetObject body = %q", sb.String())
	}
	for _, auth := range fake.auths {
		if !strings.HasPrefix(auth, "AWS4-HMAC-SHA256 Credential=A/") {
			t.Fatalf("bad auth header: %q", auth)
		}
	}
}

func TestS3GetMissingKey(t *testing.T) {
	fake := &fakeS3{t: t, objects: map[string][]byte{}}
	srv := httptest.NewServer(http.HandlerFunc(fake.handler))
	defer srv.Close()

	c := &S3Client{Endpoint: srv.URL, Bucket: "b", Region: "us-ord-1", AccessKey: "A", SecretKey: "S", HTTP: srv.Client()}
	if err := c.GetObject(context.Background(), "missing.mp4", &strings.Builder{}); err == nil {
		t.Fatalf("expected error, got nil")
	} else if !strings.Contains(err.Error(), "NoSuchKey") {
		t.Fatalf("error should carry the S3 code: %v", err)
	}
}

func TestS3RetriesOnceWithReturnedRegion(t *testing.T) {
	var scopes []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		scopes = append(scopes, auth)
		if !strings.Contains(auth, "/us-west-1/") {
			w.WriteHeader(http.StatusBadRequest)
			w.Write([]byte(`<Error><Code>AuthorizationHeaderMalformed</Code><Message>region wrong</Message><Region>us-west-1</Region></Error>`))
			return
		}
		w.Write([]byte("OK"))
	}))
	defer srv.Close()

	c := &S3Client{Endpoint: srv.URL, Bucket: "b", Region: "us-ord-1", AccessKey: "A", SecretKey: "S", HTTP: srv.Client()}
	var sb strings.Builder
	if err := c.GetObject(context.Background(), "a.mp4", &sb); err != nil {
		t.Fatalf("GetObject: %v", err)
	}
	if sb.String() != "OK" {
		t.Fatalf("body = %q", sb.String())
	}
	if len(scopes) != 2 {
		t.Fatalf("expected 2 attempts, got %d", len(scopes))
	}
	if !strings.Contains(scopes[1], "/us-west-1/") {
		t.Fatalf("retry did not adopt the returned region: %q", scopes[1])
	}
}
