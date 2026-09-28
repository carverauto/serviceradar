package replayer

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

// emptyBodySHA256 is the hex SHA-256 of the empty string: GET requests sign
// this as the payload hash instead of UNSIGNED-PAYLOAD, which not every
// S3-compatible store accepts.
const emptyBodySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

// S3Client is a minimal path-style S3 client (ListObjectsV2, GetObject) with
// SigV4 signing, stdlib only. The replayer fetches a handful of clips at
// startup; it does not need a full SDK.
type S3Client struct {
	Endpoint  string // e.g. https://us-ord-10.linodeobjects.com (no trailing slash)
	Bucket    string
	Region    string
	AccessKey string
	SecretKey string
	HTTP      *http.Client
}

func (c *S3Client) httpClient() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return &http.Client{Timeout: 10 * time.Minute}
}

// ListKeys returns every object key in the bucket (all pages).
func (c *S3Client) ListKeys(ctx context.Context) ([]string, error) {
	var keys []string
	var token string
	for {
		query := url.Values{}
		query.Set("list-type", "2")
		query.Set("prefix", "")
		if token != "" {
			query.Set("continuation-token", token)
		}
		body, err := c.do(ctx, http.MethodGet, "/"+c.Bucket+"/", query, nil)
		if err != nil {
			return nil, err
		}
		var out listObjectsV2Result
		if err := xml.Unmarshal(body, &out); err != nil {
			return nil, fmt.Errorf("s3 list: decode response: %w", err)
		}
		for _, item := range out.Contents {
			keys = append(keys, item.Key)
		}
		if !out.IsTruncated {
			return keys, nil
		}
		token = out.NextContinuationToken
		if token == "" {
			return nil, fmt.Errorf("s3 list: truncated response without continuation token")
		}
	}
}

// GetObject streams one object to w.
func (c *S3Client) GetObject(ctx context.Context, key string, w io.Writer) error {
	body, err := c.do(ctx, http.MethodGet, "/"+c.Bucket+"/"+key, nil, w)
	if err != nil {
		return err
	}
	_ = body
	return nil
}

type listObjectsV2Result struct {
	XMLName               xml.Name `xml:"ListBucketResult"`
	IsTruncated           bool     `xml:"IsTruncated"`
	NextContinuationToken string   `xml:"NextContinuationToken"`
	Contents              []struct {
		Key string `xml:"Key"`
	} `xml:"Contents"`
}

type s3Error struct {
	XMLName xml.Name `xml:"Error"`
	Code    string   `xml:"Code"`
	Message string   `xml:"Message"`
}

// do signs and sends one request. When w is nil the (small) response body is
// buffered and returned; otherwise the body streams to w.
func (c *S3Client) do(ctx context.Context, method, path string, query url.Values, w io.Writer) ([]byte, error) {
	rawURL := c.Endpoint + path
	if len(query) > 0 {
		rawURL += "?" + query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, rawURL, nil)
	if err != nil {
		return nil, fmt.Errorf("s3 %s %s: %w", method, path, err)
	}
	signV4(req, path, query, c.Region, c.AccessKey, c.SecretKey, time.Now().UTC())

	resp, err := c.httpClient().Do(req)
	if err != nil {
		return nil, fmt.Errorf("s3 %s %s: %w", method, path, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		var s3err s3Error
		if xml.Unmarshal(raw, &s3err) == nil && s3err.Code != "" {
			return nil, fmt.Errorf(
				"s3 %s %s: status %d code %s: %.200s",
				method, path, resp.StatusCode, s3err.Code, s3err.Message,
			)
		}
		return nil, fmt.Errorf("s3 %s %s: status %d: %.200s", method, path, resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	if w == nil {
		raw, err := io.ReadAll(io.LimitReader(resp.Body, 256<<20))
		if err != nil {
			return nil, fmt.Errorf("s3 %s %s: read body: %w", method, path, err)
		}
		return raw, nil
	}
	if _, err := io.Copy(w, resp.Body); err != nil {
		return nil, fmt.Errorf("s3 %s %s: stream body: %w", method, path, err)
	}
	return nil, nil
}

// signV4 attaches SigV4 Authorization, x-amz-date and x-amz-content-sha256 to
// req for a header-signed request with an empty body.
func signV4(req *http.Request, path string, query url.Values, region, accessKey, secretKey string, now time.Time) {
	amzDate := now.Format("20060102T150405Z")
	dateStamp := now.Format("20060102")
	host := req.URL.Host
	signedHeaders := "host;x-amz-content-sha256;x-amz-date"

	canonical := buildCanonicalRequest(req.Method, path, query, map[string]string{
		"host":                 host,
		"x-amz-content-sha256": emptyBodySHA256,
		"x-amz-date":           amzDate,
	}, signedHeaders, emptyBodySHA256)

	scope := dateStamp + "/" + region + "/s3/aws4_request"
	stringToSign := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + sha256Hex(canonical)

	signingKey := hmacSHA256(hmacSHA256(hmacSHA256(hmacSHA256(
		[]byte("AWS4"+secretKey), dateStamp), region), "s3"), "aws4_request")
	signature := hex.EncodeToString(hmacSHA256(signingKey, stringToSign))

	req.Header.Set("x-amz-date", amzDate)
	req.Header.Set("x-amz-content-sha256", emptyBodySHA256)
	req.Header.Set("Authorization", fmt.Sprintf(
		"AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		accessKey, scope, signedHeaders, signature,
	))
}

// buildCanonicalRequest renders the SigV4 canonical request. Header names and
// query keys sort ascending; values use RFC 3986 encoding.
func buildCanonicalRequest(method, path string, query url.Values, headers map[string]string, signedHeaders, payloadHash string) string {
	var b strings.Builder
	b.WriteString(method)
	b.WriteString("\n")
	b.WriteString(encodePath(path))
	b.WriteString("\n")
	b.WriteString(encodeQuery(query))
	b.WriteString("\n")
	names := make([]string, 0, len(headers))
	for name := range headers {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		b.WriteString(name)
		b.WriteString(":")
		b.WriteString(strings.TrimSpace(headers[name]))
		b.WriteString("\n")
	}
	b.WriteString("\n")
	b.WriteString(signedHeaders)
	b.WriteString("\n")
	b.WriteString(payloadHash)
	return b.String()
}

func encodePath(path string) string {
	segments := strings.Split(path, "/")
	for i, segment := range segments {
		segments[i] = rfc3986Encode(segment)
	}
	return strings.Join(segments, "/")
}

func encodeQuery(query url.Values) string {
	keys := make([]string, 0, len(query))
	for key := range query {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var parts []string
	for _, key := range keys {
		values := append([]string(nil), query[key]...)
		sort.Strings(values)
		for _, value := range values {
			parts = append(parts, rfc3986Encode(key)+"="+rfc3986Encode(value))
		}
	}
	return strings.Join(parts, "&")
}

func rfc3986Encode(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.' || c == '~' {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

func sha256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

func hmacSHA256(key []byte, s string) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(s))
	return mac.Sum(nil)
}
