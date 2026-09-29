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
	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, "https://s3.example.com/b/k", nil)
	if err != nil {
		t.Fatal(err)
	}
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
	req2, err := http.NewRequestWithContext(t.Context(), http.MethodGet, "https://s3.example.com/b/k", nil)
	if err != nil {
		t.Fatal(err)
	}
	signV4(req2, "/b/k", nil, "us-ord-1", "AKID", "SECRET", when)
	if req2.Header.Get("Authorization") != auth {
		t.Fatalf("signing is not deterministic")
	}
	req3, err := http.NewRequestWithContext(t.Context(), http.MethodGet, "https://s3.example.com/b/k", nil)
	if err != nil {
		t.Fatal(err)
	}
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
		keys := make([]string, 0, len(f.objects))
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
		if _, err := w.Write([]byte(`<?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">`)); err != nil {
			f.t.Errorf("write response: %v", err)
			return
		}
		if start < len(keys) {
			if _, err := w.Write([]byte(`<Contents><Key>` + keys[start] + `</Key></Contents>`)); err != nil {
				f.t.Errorf("write response: %v", err)
				return
			}
		}
		if start+1 < len(keys) {
			if _, err := w.Write([]byte(`<IsTruncated>true</IsTruncated><NextContinuationToken>` + keys[start] + `</NextContinuationToken>`)); err != nil {
				f.t.Errorf("write response: %v", err)
				return
			}
		} else {
			if _, err := w.Write([]byte(`<IsTruncated>false</IsTruncated>`)); err != nil {
				f.t.Errorf("write response: %v", err)
				return
			}
		}
		if _, err := w.Write([]byte(`</ListBucketResult>`)); err != nil {
			f.t.Errorf("write response: %v", err)
			return
		}
		return
	}
	key := strings.TrimPrefix(r.URL.Path, "/b/")
	body, ok := f.objects[key]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		if _, err := w.Write([]byte(`<Error><Code>NoSuchKey</Code><Message>nope</Message></Error>`)); err != nil {
			f.t.Errorf("write response: %v", err)
			return
		}
		return
	}
	f.gets++
	if _, err := w.Write(body); err != nil {
		f.t.Errorf("write response: %v", err)
		return
	}
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

func TestS3RejectsWrongRegion(t *testing.T) {
	for _, operation := range []string{"list", "get"} {
		t.Run(operation, func(t *testing.T) {
			var scopes []string
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				scopes = append(scopes, r.Header.Get("Authorization"))
				w.WriteHeader(http.StatusBadRequest)
				if _, err := w.Write([]byte(`<Error><Code>AuthorizationHeaderMalformed</Code><Message>region wrong</Message><Region>region-other</Region></Error>`)); err != nil {
					t.Errorf("write response: %v", err)
					return
				}
			}))
			defer srv.Close()
			c := &S3Client{Endpoint: srv.URL, Bucket: "b", Region: "region-configured", AccessKey: "A", SecretKey: "S", HTTP: srv.Client()}
			var err error
			if operation == "list" {
				_, err = c.ListKeys(context.Background())
			} else {
				err = c.GetObject(context.Background(), "a.mp4", &strings.Builder{})
			}
			if err == nil || !strings.Contains(err.Error(), "AuthorizationHeaderMalformed") {
				t.Fatalf("expected signing error, got %v", err)
			}
			if len(scopes) != 1 || !strings.Contains(scopes[0], "/region-configured/s3/") {
				t.Fatalf("expected one request in configured region, got %v", scopes)
			}
		})
	}
}
