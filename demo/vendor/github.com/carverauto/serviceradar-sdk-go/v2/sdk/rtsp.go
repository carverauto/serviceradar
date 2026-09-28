package sdk

import (
	"bytes"
	"crypto/md5"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"
)

var (
	ErrRTSPInvalidURL      = errors.New("invalid rtsp source url")
	ErrRTSPNoVideoTrack    = errors.New("no h264 video track in sdp")
	ErrRTSPBadResponse     = errors.New("invalid rtsp response")
	ErrRTSPBadInterleaved  = errors.New("invalid interleaved frame")
	ErrRTPPacketTooShort   = errors.New("rtp packet too short")
	ErrH264PayloadTooShort = errors.New("h264 payload too short")
	ErrH264UnsupportedNAL  = errors.New("unsupported h264 packetization")
	ErrRTSPNoSession       = errors.New("rtsp session header missing")
	ErrRTSPUnauthorized    = errors.New("rtsp unauthorized")
)

// RTSPEndpoint is a parsed RTSP connection target.
type RTSPEndpoint struct {
	RawURL     string
	Scheme     string
	Host       string
	Port       uint16
	RequestURI string
	BaseURL    string
	Username   string
	Password   string
}

// RTSPResponse is a parsed RTSP response.
type RTSPResponse struct {
	StatusCode    int
	StatusLine    string
	Headers       map[string]string
	Body          []byte
	ContentLength int
}

// RTSPH264Track identifies a selected H264 SDP track.
type RTSPH264Track struct {
	ControlURL  string
	PayloadType int
}

// RTSPInterleavedFrame is a parsed RTP-over-RTSP/TCP frame.
type RTSPInterleavedFrame struct {
	Channel uint8
	Payload []byte
}

// RTSPAuthState captures RTSP auth challenge state.
type RTSPAuthState struct {
	Scheme    string
	Realm     string
	Nonce     string
	Opaque    string
	Algorithm string
	QOP       string
	CNonce    string
	NC        uint32
}

// RTSPH264Depacketizer reconstructs H264 Annex B access units from RTP payloads.
type RTSPH264Depacketizer struct {
	sequence   uint64
	timestamp  uint32
	assembling bool
	fragments  [][]byte
	keyframe   bool
}

// RTSPClient provides a narrow RTSP-over-TCP client for camera plugins.
type RTSPClient struct {
	Conn     RTSPTransport
	Timeout  time.Duration
	Endpoint RTSPEndpoint
	Seq      int
	Session  string
	Auth     *RTSPAuthState
}

// RTSPTransport is the narrow transport contract used by the RTSP client.
type RTSPTransport interface {
	Read([]byte, time.Duration) (int, error)
	Write([]byte, time.Duration) (int, error)
	Close() error
}

// NewRTSPClient constructs an RTSP client with a default starting CSeq.
func NewRTSPClient(conn RTSPTransport, timeout time.Duration, endpoint RTSPEndpoint) *RTSPClient {
	return &RTSPClient{
		Conn:     conn,
		Timeout:  timeout,
		Endpoint: endpoint,
		Seq:      1,
	}
}

// DialRTSPTransport opens an RTSP or RTSPS transport from a parsed endpoint.
func DialRTSPTransport(endpoint RTSPEndpoint, timeout time.Duration, insecureSkipVerify bool) (RTSPTransport, error) {
	rawConn, err := TCPDial(endpoint.Host, endpoint.Port, timeout)
	if err != nil {
		return nil, err
	}

	baseConn := rawConn.NetConn()
	if endpoint.Scheme == "rtsps" {
		tlsConn := tls.Client(baseConn, &tls.Config{
			ServerName:         endpoint.Host,
			InsecureSkipVerify: insecureSkipVerify, //nolint:gosec
		})
		_ = tlsConn.SetDeadline(time.Now().Add(timeout))
		if err := tlsConn.Handshake(); err != nil {
			_ = tlsConn.Close()
			return nil, err
		}
		_ = tlsConn.SetDeadline(time.Time{})
		return &netRTSPConn{conn: tlsConn}, nil
	}

	return &netRTSPConn{conn: baseConn}, nil
}

// DoRequest sends a single RTSP request and handles one auth challenge retry.
func (c *RTSPClient) DoRequest(method, requestURI string, extraHeaders map[string]string) (*RTSPResponse, error) {
	req := BuildRTSPRequest(c.Endpoint, method, requestURI, c.Seq, c.Session, c.Auth, extraHeaders)
	c.Seq++

	if _, err := c.Conn.Write([]byte(req), c.Timeout); err != nil {
		return nil, err
	}

	resp, err := ReadRTSPResponse(c.Conn, c.Timeout)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode == 401 && c.Endpoint.Username != "" {
		auth, authErr := ParseRTSPAuthenticateHeader(resp.Headers["www-authenticate"])
		if authErr != nil {
			return nil, ErrRTSPUnauthorized
		}
		c.Auth = auth

		req = BuildRTSPRequest(c.Endpoint, method, requestURI, c.Seq, c.Session, c.Auth, extraHeaders)
		c.Seq++
		if _, err := c.Conn.Write([]byte(req), c.Timeout); err != nil {
			return nil, err
		}
		resp, err = ReadRTSPResponse(c.Conn, c.Timeout)
		if err != nil {
			return nil, err
		}
	}

	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("%w: %s", ErrRTSPBadResponse, resp.StatusLine)
	}

	return resp, nil
}

// Teardown sends TEARDOWN if the session is active.
func (c *RTSPClient) Teardown() error {
	if c == nil || c.Session == "" {
		return nil
	}

	_, err := c.DoRequest("TEARDOWN", c.Endpoint.RequestURI, nil)
	return err
}

// ParseRTSPEndpoint parses an RTSP URL and optional credential overrides.
func ParseRTSPEndpoint(rawURL, username, password string) (RTSPEndpoint, error) {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	scheme := strings.ToLower(parsed.Scheme)
	if err != nil || parsed.Host == "" || (scheme != "rtsp" && scheme != "rtsps") {
		return RTSPEndpoint{}, ErrRTSPInvalidURL
	}

	host := parsed.Hostname()
	if host == "" {
		return RTSPEndpoint{}, ErrRTSPInvalidURL
	}

	port := uint16(554)
	if scheme == "rtsps" {
		port = 322
	}
	if parsed.Port() != "" {
		value, convErr := strconv.Atoi(parsed.Port())
		if convErr != nil || value <= 0 || value > 65535 {
			return RTSPEndpoint{}, ErrRTSPInvalidURL
		}
		port = uint16(value)
	}

	if parsed.User != nil {
		username = parsed.User.Username()
		if pwd, ok := parsed.User.Password(); ok {
			password = pwd
		}
	}

	requestURI := parsed.RequestURI()
	if requestURI == "" {
		requestURI = "/"
	}

	return RTSPEndpoint{
		RawURL:     rawURL,
		Scheme:     scheme,
		Host:       host,
		Port:       port,
		RequestURI: requestURI,
		BaseURL:    fmt.Sprintf("%s://%s", scheme, parsed.Host),
		Username:   username,
		Password:   password,
	}, nil
}

// BuildRTSPRequest formats a single RTSP request.
func BuildRTSPRequest(
	endpoint RTSPEndpoint,
	method, requestURI string,
	cseq int,
	session string,
	auth *RTSPAuthState,
	extraHeaders map[string]string,
) string {
	var builder strings.Builder

	builder.WriteString(method)
	builder.WriteString(" ")
	builder.WriteString(requestURI)
	builder.WriteString(" RTSP/1.0\r\n")
	builder.WriteString(fmt.Sprintf("CSeq: %d\r\n", cseq))
	builder.WriteString("User-Agent: ServiceRadar-Camera-WASM/0.1\r\n")

	if session != "" {
		builder.WriteString("Session: ")
		builder.WriteString(session)
		builder.WriteString("\r\n")
	}

	authHeader := BuildRTSPAuthorization(endpoint, method, requestURI, auth)
	if authHeader != "" {
		builder.WriteString("Authorization: ")
		builder.WriteString(authHeader)
		builder.WriteString("\r\n")
	}

	for key, value := range extraHeaders {
		if strings.TrimSpace(key) == "" || strings.TrimSpace(value) == "" {
			continue
		}
		builder.WriteString(key)
		builder.WriteString(": ")
		builder.WriteString(value)
		builder.WriteString("\r\n")
	}

	builder.WriteString("\r\n")
	return builder.String()
}

// BuildRTSPAuthorization builds either Basic or Digest authorization headers.
func BuildRTSPAuthorization(endpoint RTSPEndpoint, method, requestURI string, auth *RTSPAuthState) string {
	if strings.TrimSpace(endpoint.Username) == "" && strings.TrimSpace(endpoint.Password) == "" {
		return ""
	}

	if auth != nil && strings.EqualFold(auth.Scheme, "digest") {
		auth.NC++
		nc := fmt.Sprintf("%08x", auth.NC)
		cnonce := auth.CNonce
		if cnonce == "" {
			cnonce = "serviceradar"
		}
		realm := auth.Realm
		nonce := auth.Nonce
		ha1 := md5Hex(endpoint.Username + ":" + realm + ":" + endpoint.Password)
		ha2 := md5Hex(method + ":" + requestURI)
		response := ""
		if auth.QOP != "" {
			response = md5Hex(ha1 + ":" + nonce + ":" + nc + ":" + cnonce + ":" + auth.QOP + ":" + ha2)
		} else {
			response = md5Hex(ha1 + ":" + nonce + ":" + ha2)
		}

		parts := []string{
			fmt.Sprintf(`username="%s"`, endpoint.Username),
			fmt.Sprintf(`realm="%s"`, realm),
			fmt.Sprintf(`nonce="%s"`, nonce),
			fmt.Sprintf(`uri="%s"`, requestURI),
			fmt.Sprintf(`response="%s"`, response),
		}
		if auth.Algorithm != "" {
			parts = append(parts, fmt.Sprintf("algorithm=%s", auth.Algorithm))
		}
		if auth.Opaque != "" {
			parts = append(parts, fmt.Sprintf(`opaque="%s"`, auth.Opaque))
		}
		if auth.QOP != "" {
			parts = append(parts, fmt.Sprintf("qop=%s", auth.QOP))
			parts = append(parts, fmt.Sprintf("nc=%s", nc))
			parts = append(parts, fmt.Sprintf(`cnonce="%s"`, cnonce))
		}
		return "Digest " + strings.Join(parts, ", ")
	}

	token := base64.StdEncoding.EncodeToString([]byte(endpoint.Username + ":" + endpoint.Password))
	return "Basic " + token
}

// ParseRTSPAuthenticateHeader parses Basic or Digest challenge headers.
func ParseRTSPAuthenticateHeader(header string) (*RTSPAuthState, error) {
	header = strings.TrimSpace(header)
	switch {
	case header == "":
		return nil, ErrRTSPUnauthorized
	case strings.HasPrefix(strings.ToLower(header), "digest "):
		params := parseAuthParams(strings.TrimSpace(header[len("Digest "):]))
		if params["realm"] == "" || params["nonce"] == "" {
			return nil, ErrRTSPUnauthorized
		}
		qop := ""
		if rawQOP := params["qop"]; rawQOP != "" {
			for _, candidate := range strings.Split(rawQOP, ",") {
				candidate = strings.Trim(strings.TrimSpace(candidate), `"`)
				if candidate == "auth" {
					qop = "auth"
					break
				}
				if qop == "" && candidate != "" {
					qop = candidate
				}
			}
		}
		return &RTSPAuthState{
			Scheme:    "digest",
			Realm:     params["realm"],
			Nonce:     params["nonce"],
			Opaque:    params["opaque"],
			Algorithm: firstNonBlank(params["algorithm"], "MD5"),
			QOP:       qop,
			CNonce:    "serviceradar",
		}, nil
	case strings.HasPrefix(strings.ToLower(header), "basic"):
		return &RTSPAuthState{Scheme: "basic"}, nil
	default:
		return nil, ErrRTSPUnauthorized
	}
}

func parseAuthParams(raw string) map[string]string {
	params := map[string]string{}
	for _, part := range splitCommaSeparated(raw) {
		key, value, ok := strings.Cut(part, "=")
		if !ok {
			continue
		}
		params[strings.ToLower(strings.TrimSpace(key))] = strings.Trim(strings.TrimSpace(value), `"`)
	}
	return params
}

func splitCommaSeparated(raw string) []string {
	parts := make([]string, 0, 8)
	var current strings.Builder
	inQuotes := false

	for _, r := range raw {
		switch r {
		case '"':
			inQuotes = !inQuotes
			current.WriteRune(r)
		case ',':
			if inQuotes {
				current.WriteRune(r)
			} else {
				parts = append(parts, strings.TrimSpace(current.String()))
				current.Reset()
			}
		default:
			current.WriteRune(r)
		}
	}
	if current.Len() > 0 {
		parts = append(parts, strings.TrimSpace(current.String()))
	}
	return parts
}

func md5Hex(value string) string {
	sum := md5.Sum([]byte(value))
	return fmt.Sprintf("%x", sum[:])
}

func firstNonBlank(values ...string) string {
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			return value
		}
	}
	return ""
}

// ReadRTSPResponse reads and parses a single RTSP response.
func ReadRTSPResponse(conn RTSPTransport, timeout time.Duration) (*RTSPResponse, error) {
	buf := make([]byte, 64*1024)
	n, err := conn.Read(buf, timeout)
	if err != nil {
		return nil, err
	}

	return ParseRTSPResponse(buf[:n])
}

// ParseRTSPResponse parses a raw RTSP response.
func ParseRTSPResponse(data []byte) (*RTSPResponse, error) {
	head, body, found := bytes.Cut(data, []byte("\r\n\r\n"))
	if !found {
		return nil, ErrRTSPBadResponse
	}

	lines := strings.Split(string(head), "\r\n")
	if len(lines) == 0 || !strings.HasPrefix(lines[0], "RTSP/1.0 ") {
		return nil, ErrRTSPBadResponse
	}

	statusParts := strings.SplitN(lines[0], " ", 3)
	if len(statusParts) < 2 {
		return nil, ErrRTSPBadResponse
	}

	statusCode, err := strconv.Atoi(statusParts[1])
	if err != nil {
		return nil, ErrRTSPBadResponse
	}

	headers := map[string]string{}
	contentLength := 0
	for _, line := range lines[1:] {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		normalizedKey := strings.ToLower(strings.TrimSpace(key))
		normalizedValue := strings.TrimSpace(value)
		headers[normalizedKey] = normalizedValue
		if normalizedKey == "content-length" {
			contentLength, _ = strconv.Atoi(normalizedValue)
		}
	}

	if contentLength > 0 && len(body) > contentLength {
		body = body[:contentLength]
	}

	return &RTSPResponse{
		StatusCode:    statusCode,
		StatusLine:    lines[0],
		Headers:       headers,
		Body:          body,
		ContentLength: contentLength,
	}, nil
}

// ParseH264TrackFromSDP selects the first H264 video track from SDP.
func ParseH264TrackFromSDP(endpoint RTSPEndpoint, body []byte) (RTSPH264Track, error) {
	lines := strings.Split(string(body), "\n")
	inVideo := false
	payloadType := 0
	control := ""

	for _, raw := range lines {
		line := strings.TrimSpace(raw)
		switch {
		case strings.HasPrefix(line, "m=video "):
			inVideo = true
			payloadType = 0
			control = ""
		case strings.HasPrefix(line, "m="):
			inVideo = false
		case inVideo && strings.HasPrefix(line, "a=rtpmap:") && strings.Contains(line, "H264/90000"):
			parts := strings.SplitN(strings.TrimPrefix(line, "a=rtpmap:"), " ", 2)
			if len(parts) == 2 {
				payloadType, _ = strconv.Atoi(parts[0])
			}
		case inVideo && strings.HasPrefix(line, "a=control:"):
			control = strings.TrimSpace(strings.TrimPrefix(line, "a=control:"))
		}

		if inVideo && payloadType != 0 && control != "" {
			return RTSPH264Track{
				ControlURL:  ResolveRTSPControlURL(endpoint, control),
				PayloadType: payloadType,
			}, nil
		}
	}

	return RTSPH264Track{}, ErrRTSPNoVideoTrack
}

// ResolveRTSPControlURL resolves an SDP control attribute against the RTSP endpoint.
func ResolveRTSPControlURL(endpoint RTSPEndpoint, control string) string {
	control = strings.TrimSpace(control)
	if control == "" {
		return endpoint.RequestURI
	}
	if strings.HasPrefix(control, "rtsp://") || strings.HasPrefix(control, "rtsps://") {
		return control
	}
	if strings.HasPrefix(control, "/") {
		return endpoint.BaseURL + control
	}
	base := strings.TrimSuffix(endpoint.RequestURI, "/")
	return endpoint.BaseURL + base + "/" + control
}

// ParseSessionHeader extracts the RTSP session id before any attributes.
func ParseSessionHeader(value string) string {
	session, _, _ := strings.Cut(strings.TrimSpace(value), ";")
	return strings.TrimSpace(session)
}

// ParseInterleavedFrame parses a single RTP-over-RTSP/TCP interleaved frame.
func ParseInterleavedFrame(data []byte) (RTSPInterleavedFrame, error) {
	if len(data) < 4 || data[0] != '$' {
		return RTSPInterleavedFrame{}, ErrRTSPBadInterleaved
	}

	size := int(binary.BigEndian.Uint16(data[2:4]))
	if len(data) < 4+size {
		return RTSPInterleavedFrame{}, ErrRTSPBadInterleaved
	}

	payload := make([]byte, size)
	copy(payload, data[4:4+size])

	return RTSPInterleavedFrame{
		Channel: data[1],
		Payload: payload,
	}, nil
}

type netRTSPConn struct {
	conn net.Conn
}

func (c *netRTSPConn) Read(buf []byte, timeout time.Duration) (int, error) {
	if timeout > 0 {
		_ = c.conn.SetReadDeadline(time.Now().Add(timeout))
	} else {
		_ = c.conn.SetReadDeadline(time.Time{})
	}

	return c.conn.Read(buf)
}

func (c *netRTSPConn) Write(data []byte, timeout time.Duration) (int, error) {
	if timeout > 0 {
		_ = c.conn.SetWriteDeadline(time.Now().Add(timeout))
	} else {
		_ = c.conn.SetWriteDeadline(time.Time{})
	}

	return c.conn.Write(data)
}

func (c *netRTSPConn) Close() error {
	return c.conn.Close()
}

// ParseRTPPacket extracts RTP payload, marker bit, and timestamp.
func ParseRTPPacket(data []byte) ([]byte, bool, uint32, error) {
	if len(data) < 12 {
		return nil, false, 0, ErrRTPPacketTooShort
	}

	cc := int(data[0] & 0x0F)
	extension := (data[0] & 0x10) != 0
	marker := (data[1] & 0x80) != 0
	offset := 12 + cc*4
	if len(data) < offset {
		return nil, false, 0, ErrRTPPacketTooShort
	}

	if extension {
		if len(data) < offset+4 {
			return nil, false, 0, ErrRTPPacketTooShort
		}
		extLen := int(binary.BigEndian.Uint16(data[offset+2:offset+4])) * 4
		offset += 4 + extLen
		if len(data) < offset {
			return nil, false, 0, ErrRTPPacketTooShort
		}
	}

	payload := make([]byte, len(data[offset:]))
	copy(payload, data[offset:])
	timestamp := binary.BigEndian.Uint32(data[4:8])
	return payload, marker, timestamp, nil
}

// Push feeds an H264 RTP payload into the depacketizer.
func (d *RTSPH264Depacketizer) Push(payload []byte, marker bool, timestamp uint32) ([]byte, bool, bool, error) {
	if len(payload) == 0 {
		return nil, false, false, ErrH264PayloadTooShort
	}

	if !d.assembling || d.timestamp != timestamp {
		d.fragments = d.fragments[:0]
		d.keyframe = false
		d.timestamp = timestamp
		d.assembling = true
	}

	nalType := payload[0] & 0x1F
	switch {
	case nalType >= 1 && nalType <= 23:
		d.fragments = append(d.fragments, annexBUnit(payload))
		d.keyframe = d.keyframe || nalType == 5

	case nalType == 24:
		offset := 1
		for offset+2 <= len(payload) {
			size := int(binary.BigEndian.Uint16(payload[offset : offset+2]))
			offset += 2
			if size <= 0 || offset+size > len(payload) {
				return nil, false, false, ErrH264PayloadTooShort
			}
			nal := payload[offset : offset+size]
			offset += size
			if len(nal) == 0 {
				continue
			}
			d.fragments = append(d.fragments, annexBUnit(nal))
			d.keyframe = d.keyframe || (nal[0]&0x1F) == 5
		}

	case nalType == 28:
		if len(payload) < 2 {
			return nil, false, false, ErrH264PayloadTooShort
		}
		fuIndicator := payload[0]
		fuHeader := payload[1]
		start := (fuHeader & 0x80) != 0
		end := (fuHeader & 0x40) != 0
		reconstructed := []byte{(fuIndicator & 0xE0) | (fuHeader & 0x1F)}
		reconstructed = append(reconstructed, payload[2:]...)
		if start {
			d.fragments = append(d.fragments, annexBUnit(reconstructed))
		} else if len(d.fragments) > 0 {
			last := d.fragments[len(d.fragments)-1]
			d.fragments[len(d.fragments)-1] = append(last, reconstructed[1:]...)
		} else {
			return nil, false, false, ErrH264PayloadTooShort
		}
		d.keyframe = d.keyframe || (fuHeader&0x1F) == 5
		if !end && !marker {
			return nil, false, false, nil
		}

	default:
		return nil, false, false, ErrH264UnsupportedNAL
	}

	if !marker {
		return nil, false, false, nil
	}

	accessUnit := joinFragments(d.fragments)
	keyframe := d.keyframe
	d.fragments = d.fragments[:0]
	d.keyframe = false
	d.assembling = false
	return accessUnit, keyframe, true, nil
}

func annexBUnit(nal []byte) []byte {
	unit := make([]byte, 4+len(nal))
	copy(unit[:4], []byte{0x00, 0x00, 0x00, 0x01})
	copy(unit[4:], nal)
	return unit
}

func joinFragments(parts [][]byte) []byte {
	size := 0
	for _, part := range parts {
		size += len(part)
	}
	out := make([]byte, 0, size)
	for _, part := range parts {
		out = append(out, part...)
	}
	return out
}
