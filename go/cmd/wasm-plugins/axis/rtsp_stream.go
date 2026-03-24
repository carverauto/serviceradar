package main

import (
	"bytes"
	"crypto/md5"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/sdk"
)

var (
	errRTSPInvalidURL      = errors.New("invalid rtsp source url")
	errRTSPNoVideoTrack    = errors.New("no h264 video track in sdp")
	errRTSPBadResponse     = errors.New("invalid rtsp response")
	errRTSPBadInterleaved  = errors.New("invalid interleaved frame")
	errRTPPacketTooShort   = errors.New("rtp packet too short")
	errH264PayloadTooShort = errors.New("h264 payload too short")
	errH264UnsupportedNal  = errors.New("unsupported h264 packetization")
	errRTSPNoSession       = errors.New("rtsp session header missing")
	errRTSPStreamIdle      = errors.New("rtsp stream idle")
	errRTSPUnauthorized    = errors.New("rtsp unauthorized")
)

type rtspEndpoint struct {
	rawURL     string
	host       string
	port       uint16
	requestURI string
	baseURL    string
	username   string
	password   string
}

type rtspResponse struct {
	StatusCode    int
	StatusLine    string
	Headers       map[string]string
	Body          []byte
	ContentLength int
}

type rtspH264Track struct {
	controlURL string
	payloadTyp int
}

type rtspInterleavedFrame struct {
	channel uint8
	payload []byte
}

type rtspH264Depacketizer struct {
	sequence   uint64
	timestamp  uint32
	assembling bool
	fragments  [][]byte
	keyframe   bool
}

type rtspAuthState struct {
	scheme    string
	realm     string
	nonce     string
	opaque    string
	algorithm string
	qop       string
	cnonce    string
	nc        uint32
}

func streamAxisRTSP(cfg StreamConfig, timeout time.Duration) error {
	sourceURL := buildAxisStreamSourceURL(cfg)
	endpoint, err := parseRTSPEndpoint(sourceURL, cfg.Username, cfg.Password)
	if err != nil {
		return err
	}

	conn, err := sdk.TCPDial(endpoint.host, endpoint.port, timeout)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close() }()

	client := &rtspClient{
		conn:     conn,
		timeout:  timeout,
		endpoint: endpoint,
		seq:      1,
	}
	closeReason := "rtsp stream closed"
	defer func() {
		_ = client.teardown()
	}()

	if _, err := client.doRequest("OPTIONS", endpoint.requestURI, nil); err != nil {
		return err
	}

	describe, err := client.doRequest("DESCRIBE", endpoint.requestURI, map[string]string{
		"Accept": "application/sdp",
	})
	if err != nil {
		return err
	}

	track, err := parseH264TrackFromSDP(endpoint, describe.Body)
	if err != nil {
		return err
	}

	setup, err := client.doRequest("SETUP", track.controlURL, map[string]string{
		"Transport": "RTP/AVP/TCP;unicast;interleaved=0-1",
	})
	if err != nil {
		return err
	}

	session := parseSessionHeader(setup.Headers["session"])
	if session == "" {
		return errRTSPNoSession
	}
	client.session = session

	if _, err := client.doRequest("PLAY", endpoint.requestURI, nil); err != nil {
		return err
	}

	stream, err := openAxisMediaSession(axisMediaOpenRequest{
		TrackID:       "video",
		Codec:         "h264",
		PayloadFormat: "annexb",
	})
	if err != nil {
		return err
	}
	defer func() { _ = closeAxisMedia(stream, closeReason) }()

	depacketizer := &rtspH264Depacketizer{}
	buf := make([]byte, 64*1024)
	idleReads := 0
	lastHeartbeat := time.Now()

	for {
		n, err := conn.Read(buf, 1500*time.Millisecond)
		if err != nil {
			// In the current host bridge, canceled relay contexts surface as host errors too.
			// Treat repeated read errors as end-of-session instead of spinning forever.
			idleReads++
			if idleReads >= 5 {
				closeReason = "rtsp stream idle"
				return errRTSPStreamIdle
			}
			if time.Since(lastHeartbeat) >= time.Second {
				if err := heartbeatAxisMedia(stream, axisMediaHeartbeat{
					Sequence:      depacketizer.sequence,
					TimestampUnix: time.Now().Unix(),
				}); err != nil {
					closeReason = "rtsp heartbeat failed"
					return err
				}
				lastHeartbeat = time.Now()
			}
			continue
		}
		idleReads = 0

		frame, err := parseInterleavedFrame(buf[:n])
		if err != nil {
			continue
		}
		if frame.channel != 0 {
			continue
		}

		packet, marker, timestamp, err := parseRTPPacket(frame.payload)
		if err != nil {
			continue
		}

		accessUnit, keyframe, complete, err := depacketizer.push(packet, marker, timestamp)
		if err != nil || !complete || len(accessUnit) == 0 {
			continue
		}

		depacketizer.sequence++
		if err := writeAxisMedia(stream, axisMediaChunkMetadata{
			TrackID:       "video",
			Sequence:      depacketizer.sequence,
			PTS:           int64(timestamp),
			DTS:           int64(timestamp),
			Keyframe:      keyframe,
			Codec:         "h264",
			PayloadFormat: "annexb",
		}, accessUnit); err != nil {
			closeReason = "rtsp media write failed"
			return err
		}

		if time.Since(lastHeartbeat) >= time.Second {
			if err := heartbeatAxisMedia(stream, axisMediaHeartbeat{
				Sequence:      depacketizer.sequence,
				TimestampUnix: time.Now().Unix(),
			}); err != nil {
				closeReason = "rtsp heartbeat failed"
				return err
			}
			lastHeartbeat = time.Now()
		}
	}
}

type rtspClient struct {
	conn     *sdk.TCPConn
	timeout  time.Duration
	endpoint rtspEndpoint
	seq      int
	session  string
	auth     *rtspAuthState
}

func (c *rtspClient) doRequest(method, requestURI string, extraHeaders map[string]string) (*rtspResponse, error) {
	req := buildRTSPRequest(c.endpoint, method, requestURI, c.seq, c.session, c.auth, extraHeaders)
	c.seq++

	if _, err := c.conn.Write([]byte(req), c.timeout); err != nil {
		return nil, err
	}

	resp, err := readRTSPResponse(c.conn, c.timeout)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode == 401 && c.endpoint.username != "" {
		auth, authErr := parseRTSPAuthenticateHeader(resp.Headers["www-authenticate"])
		if authErr != nil {
			return nil, errRTSPUnauthorized
		}
		c.auth = auth

		req = buildRTSPRequest(c.endpoint, method, requestURI, c.seq, c.session, c.auth, extraHeaders)
		c.seq++
		if _, err := c.conn.Write([]byte(req), c.timeout); err != nil {
			return nil, err
		}
		resp, err = readRTSPResponse(c.conn, c.timeout)
		if err != nil {
			return nil, err
		}
	}

	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("%w: %s", errRTSPBadResponse, resp.StatusLine)
	}

	return resp, nil
}

func (c *rtspClient) teardown() error {
	if c == nil || c.session == "" {
		return nil
	}

	_, err := c.doRequest("TEARDOWN", c.endpoint.requestURI, nil)
	return err
}

func parseRTSPEndpoint(rawURL, username, password string) (rtspEndpoint, error) {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || parsed.Host == "" || parsed.Scheme != "rtsp" {
		return rtspEndpoint{}, errRTSPInvalidURL
	}

	host := parsed.Hostname()
	if host == "" {
		return rtspEndpoint{}, errRTSPInvalidURL
	}

	port := uint16(554)
	if parsed.Port() != "" {
		value, convErr := strconv.Atoi(parsed.Port())
		if convErr != nil || value <= 0 || value > 65535 {
			return rtspEndpoint{}, errRTSPInvalidURL
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

	return rtspEndpoint{
		rawURL:     rawURL,
		host:       host,
		port:       port,
		requestURI: requestURI,
		baseURL:    fmt.Sprintf("rtsp://%s", parsed.Host),
		username:   username,
		password:   password,
	}, nil
}

func buildRTSPRequest(
	endpoint rtspEndpoint,
	method, requestURI string,
	cseq int,
	session string,
	auth *rtspAuthState,
	extraHeaders map[string]string,
) string {
	var builder strings.Builder

	builder.WriteString(method)
	builder.WriteString(" ")
	builder.WriteString(requestURI)
	builder.WriteString(" RTSP/1.0\r\n")
	builder.WriteString(fmt.Sprintf("CSeq: %d\r\n", cseq))
	builder.WriteString("User-Agent: ServiceRadar-AXIS-WASM/0.1\r\n")

	if session != "" {
		builder.WriteString("Session: ")
		builder.WriteString(session)
		builder.WriteString("\r\n")
	}

	authHeader := buildRTSPAuthorization(endpoint, method, requestURI, auth)
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

func buildRTSPAuthorization(endpoint rtspEndpoint, method, requestURI string, auth *rtspAuthState) string {
	if strings.TrimSpace(endpoint.username) == "" && strings.TrimSpace(endpoint.password) == "" {
		return ""
	}

	if auth != nil && strings.EqualFold(auth.scheme, "digest") {
		auth.nc++
		nc := fmt.Sprintf("%08x", auth.nc)
		cnonce := auth.cnonce
		if cnonce == "" {
			cnonce = "serviceradar"
		}
		realm := auth.realm
		nonce := auth.nonce
		ha1 := md5Hex(endpoint.username + ":" + realm + ":" + endpoint.password)
		ha2 := md5Hex(method + ":" + requestURI)
		response := ""
		if auth.qop != "" {
			response = md5Hex(ha1 + ":" + nonce + ":" + nc + ":" + cnonce + ":" + auth.qop + ":" + ha2)
		} else {
			response = md5Hex(ha1 + ":" + nonce + ":" + ha2)
		}

		parts := []string{
			fmt.Sprintf(`username="%s"`, endpoint.username),
			fmt.Sprintf(`realm="%s"`, realm),
			fmt.Sprintf(`nonce="%s"`, nonce),
			fmt.Sprintf(`uri="%s"`, requestURI),
			fmt.Sprintf(`response="%s"`, response),
		}
		if auth.algorithm != "" {
			parts = append(parts, fmt.Sprintf("algorithm=%s", auth.algorithm))
		}
		if auth.opaque != "" {
			parts = append(parts, fmt.Sprintf(`opaque="%s"`, auth.opaque))
		}
		if auth.qop != "" {
			parts = append(parts, fmt.Sprintf("qop=%s", auth.qop))
			parts = append(parts, fmt.Sprintf("nc=%s", nc))
			parts = append(parts, fmt.Sprintf(`cnonce="%s"`, cnonce))
		}
		return "Digest " + strings.Join(parts, ", ")
	}

	token := base64.StdEncoding.EncodeToString([]byte(endpoint.username + ":" + endpoint.password))
	return "Basic " + token
}

func parseRTSPAuthenticateHeader(header string) (*rtspAuthState, error) {
	header = strings.TrimSpace(header)
	switch {
	case header == "":
		return nil, errRTSPUnauthorized
	case strings.HasPrefix(strings.ToLower(header), "digest "):
		params := parseAuthParams(strings.TrimSpace(header[len("Digest "):]))
		if params["realm"] == "" || params["nonce"] == "" {
			return nil, errRTSPUnauthorized
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
		return &rtspAuthState{
			scheme:    "digest",
			realm:     params["realm"],
			nonce:     params["nonce"],
			opaque:    params["opaque"],
			algorithm: firstNonBlank(params["algorithm"], "MD5"),
			qop:       qop,
			cnonce:    "serviceradar",
		}, nil
	case strings.HasPrefix(strings.ToLower(header), "basic"):
		return &rtspAuthState{scheme: "basic"}, nil
	default:
		return nil, errRTSPUnauthorized
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

func readRTSPResponse(conn *sdk.TCPConn, timeout time.Duration) (*rtspResponse, error) {
	buf := make([]byte, 64*1024)
	n, err := conn.Read(buf, timeout)
	if err != nil {
		return nil, err
	}

	return parseRTSPResponse(buf[:n])
}

func parseRTSPResponse(data []byte) (*rtspResponse, error) {
	head, body, found := bytes.Cut(data, []byte("\r\n\r\n"))
	if !found {
		return nil, errRTSPBadResponse
	}

	lines := strings.Split(string(head), "\r\n")
	if len(lines) == 0 || !strings.HasPrefix(lines[0], "RTSP/1.0 ") {
		return nil, errRTSPBadResponse
	}

	statusParts := strings.SplitN(lines[0], " ", 3)
	if len(statusParts) < 2 {
		return nil, errRTSPBadResponse
	}

	statusCode, err := strconv.Atoi(statusParts[1])
	if err != nil {
		return nil, errRTSPBadResponse
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

	return &rtspResponse{
		StatusCode:    statusCode,
		StatusLine:    lines[0],
		Headers:       headers,
		Body:          body,
		ContentLength: contentLength,
	}, nil
}

func parseH264TrackFromSDP(endpoint rtspEndpoint, body []byte) (rtspH264Track, error) {
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
			return rtspH264Track{
				controlURL: resolveRTSPControlURL(endpoint, control),
				payloadTyp: payloadType,
			}, nil
		}
	}

	return rtspH264Track{}, errRTSPNoVideoTrack
}

func resolveRTSPControlURL(endpoint rtspEndpoint, control string) string {
	control = strings.TrimSpace(control)
	if control == "" {
		return endpoint.requestURI
	}
	if strings.HasPrefix(control, "rtsp://") {
		return control
	}
	if strings.HasPrefix(control, "/") {
		return endpoint.baseURL + control
	}
	base := strings.TrimSuffix(endpoint.requestURI, "/")
	return endpoint.baseURL + base + "/" + control
}

func parseSessionHeader(value string) string {
	session, _, _ := strings.Cut(strings.TrimSpace(value), ";")
	return strings.TrimSpace(session)
}

func parseInterleavedFrame(data []byte) (rtspInterleavedFrame, error) {
	if len(data) < 4 || data[0] != '$' {
		return rtspInterleavedFrame{}, errRTSPBadInterleaved
	}

	size := int(binary.BigEndian.Uint16(data[2:4]))
	if len(data) < 4+size {
		return rtspInterleavedFrame{}, errRTSPBadInterleaved
	}

	payload := make([]byte, size)
	copy(payload, data[4:4+size])

	return rtspInterleavedFrame{
		channel: data[1],
		payload: payload,
	}, nil
}

func parseRTPPacket(data []byte) ([]byte, bool, uint32, error) {
	if len(data) < 12 {
		return nil, false, 0, errRTPPacketTooShort
	}

	cc := int(data[0] & 0x0F)
	extension := (data[0] & 0x10) != 0
	marker := (data[1] & 0x80) != 0
	offset := 12 + cc*4
	if len(data) < offset {
		return nil, false, 0, errRTPPacketTooShort
	}

	if extension {
		if len(data) < offset+4 {
			return nil, false, 0, errRTPPacketTooShort
		}
		extLen := int(binary.BigEndian.Uint16(data[offset+2:offset+4])) * 4
		offset += 4 + extLen
		if len(data) < offset {
			return nil, false, 0, errRTPPacketTooShort
		}
	}

	payload := make([]byte, len(data[offset:]))
	copy(payload, data[offset:])
	timestamp := binary.BigEndian.Uint32(data[4:8])
	return payload, marker, timestamp, nil
}

func (d *rtspH264Depacketizer) push(payload []byte, marker bool, timestamp uint32) ([]byte, bool, bool, error) {
	if len(payload) == 0 {
		return nil, false, false, errH264PayloadTooShort
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
				return nil, false, false, errH264PayloadTooShort
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
			return nil, false, false, errH264PayloadTooShort
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
			return nil, false, false, errH264PayloadTooShort
		}
		d.keyframe = d.keyframe || (fuHeader&0x1F) == 5
		if !end && !marker {
			return nil, false, false, nil
		}

	default:
		return nil, false, false, errH264UnsupportedNal
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
