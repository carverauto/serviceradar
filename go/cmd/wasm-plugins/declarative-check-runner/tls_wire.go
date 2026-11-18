package main

import (
	"bytes"
	"crypto/aes"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/subtle"
	"encoding/asn1"
	"encoding/binary"
	"encoding/pem"
	"fmt"
	"hash"
	"io"
	"math/big"
	"strings"
	"time"
)

const (
	tlsVersion10 = 0x0301
	tlsVersion11 = 0x0302
	tlsVersion12 = 0x0303
	tlsVersion13 = 0x0304

	tlsRecordChangeCipherSpec = 20
	tlsRecordAlert            = 21
	tlsRecordHandshake        = 22
	tlsRecordApplicationData  = 23

	tlsHandshakeClientHello = 1
	tlsHandshakeServerHello = 2
	tlsHandshakeCertificate = 11
)

type ecPublicKey struct {
	Curve elliptic.Curve
	X     *big.Int
	Y     *big.Int
}

type rsaPublicKey struct {
	N *big.Int
	E int
}

type parsedX509Cert struct {
	RawTBS      []byte
	SigAlgOID   asn1.ObjectIdentifier
	Signature   []byte
	IssuerRaw   []byte
	SubjectRaw  []byte
	SubjectCN   string
	IssuerCN    string
	NotBefore   time.Time
	NotAfter    time.Time
	DNSNames    []string
	IPAddresses [][]byte
	PublicKey   any
}

type tlsHandshakeInfo struct {
	Version          uint16
	CipherSuite      uint16
	PeerCertificates []*parsedX509Cert
}

type blockEncrypter interface {
	Encrypt(dst, src []byte)
}

func performTLSClientHandshake(conn streamConn, serverName string) (*tlsHandshakeInfo, error) {
	var seedX [32]byte
	if err := fillRandomBytes(seedX[:]); err != nil {
		return nil, err
	}
	var basepoint [32]byte
	basepoint[0] = 9
	x25519Pub, err := x25519ScalarMult(seedX[:], basepoint[:])
	if err != nil {
		return nil, err
	}

	var seedP [32]byte
	if err := fillRandomBytes(seedP[:]); err != nil {
		return nil, err
	}
	seedP[0] &= 0x7f
	seedP[31] |= 1
	p256Curve := elliptic.P256()
	px, py := p256Curve.ScalarBaseMult(seedP[:])
	p256Pub := make([]byte, 65)
	p256Pub[0] = 0x04
	px.FillBytes(p256Pub[1:33])
	py.FillBytes(p256Pub[33:65])

	clientHelloMsg, err := buildTLSClientHello(serverName, x25519Pub, p256Pub)
	if err != nil {
		return nil, err
	}

	record := make([]byte, 5+len(clientHelloMsg))
	record[0] = tlsRecordHandshake
	binary.BigEndian.PutUint16(record[1:3], tlsVersion10)
	binary.BigEndian.PutUint16(record[3:5], uint16(len(clientHelloMsg)))
	copy(record[5:], clientHelloMsg)

	if err := writeAll(conn, record); err != nil {
		return nil, err
	}

	var hsBuf []byte
	for len(hsBuf) < 4 {
		recType, payload, rErr := readTLSRecord(conn)
		if rErr != nil {
			return nil, rErr
		}
		if recType == tlsRecordAlert {
			return nil, formatTLSAlert(payload)
		}
		if recType == tlsRecordHandshake {
			hsBuf = append(hsBuf, payload...)
		}
	}

	if hsBuf[0] != tlsHandshakeServerHello {
		return nil, sentinelError("tls unexpected handshake message before ServerHello")
	}
	shBodyLen := uint24(hsBuf[1:4])
	for len(hsBuf) < 4+shBodyLen {
		recType, payload, rErr := readTLSRecord(conn)
		if rErr != nil {
			return nil, rErr
		}
		if recType == tlsRecordAlert {
			return nil, formatTLSAlert(payload)
		}
		if recType == tlsRecordHandshake {
			hsBuf = append(hsBuf, payload...)
		}
	}

	serverHelloMsg := hsBuf[:4+shBodyLen]
	hsBuf = hsBuf[4+shBodyLen:]

	parsedSH, err := parseTLSServerHello(serverHelloMsg[4:])
	if err != nil {
		return nil, err
	}

	if parsedSH.Version == tlsVersion13 {
		return readTLS13Certificates(conn, clientHelloMsg, serverHelloMsg, parsedSH, seedX[:], seedP[:])
	}
	return readTLS12Certificates(conn, hsBuf, parsedSH)
}

type parsedServerHello struct {
	Version     uint16
	CipherSuite uint16
	KeyShareGrp uint16
	KeySharePub []byte
}

func buildTLSClientHello(serverName string, x25519Pub, p256Pub []byte) ([]byte, error) {
	var randomBytes [32]byte
	if err := fillRandomBytes(randomBytes[:]); err != nil {
		return nil, err
	}
	var sessionID [32]byte
	if err := fillRandomBytes(sessionID[:]); err != nil {
		return nil, err
	}

	var exts []byte
	sni := strings.TrimSuffix(strings.TrimSpace(serverName), ".")
	if sni != "" {
		if _, isIP := parseLiteralIP(sni); !isIP {
			sniBytes := []byte(sni)
			nameEntry := make([]byte, 3+len(sniBytes))
			nameEntry[0] = 0
			binary.BigEndian.PutUint16(nameEntry[1:3], uint16(len(sniBytes)))
			copy(nameEntry[3:], sniBytes)

			listBuf := make([]byte, 2+len(nameEntry))
			binary.BigEndian.PutUint16(listBuf[0:2], uint16(len(nameEntry)))
			copy(listBuf[2:], nameEntry)
			exts = appendTLSExt(exts, 0x0000, listBuf)
		}
	}

	exts = appendTLSExt(exts, 0x000a, []byte{0x00, 0x06, 0x00, 0x1d, 0x00, 0x17, 0x00, 0x18})
	exts = appendTLSExt(exts, 0x000b, []byte{0x01, 0x00})
	sigAlgs := []byte{
		0x00, 0x0e,
		0x04, 0x03,
		0x08, 0x04,
		0x04, 0x01,
		0x05, 0x03,
		0x08, 0x05,
		0x05, 0x01,
		0x08, 0x07,
	}
	exts = appendTLSExt(exts, 0x000d, sigAlgs)
	exts = appendTLSExt(exts, 0x002b, []byte{0x04, 0x03, 0x04, 0x03, 0x03})

	var ksEntries []byte
	ksEntries = appendKeyShareEntry(ksEntries, 0x001d, x25519Pub)
	ksEntries = appendKeyShareEntry(ksEntries, 0x0017, p256Pub)
	ksExt := make([]byte, 2+len(ksEntries))
	binary.BigEndian.PutUint16(ksExt[0:2], uint16(len(ksEntries)))
	copy(ksExt[2:], ksEntries)
	exts = appendTLSExt(exts, 0x0033, ksExt)

	ciphers := []uint16{
		0x1301,
		0x1302,
		0xc02b,
		0xc02f,
		0xc02c,
		0xc030,
		0x009c,
	}

	var body []byte
	body = append(body, 0x03, 0x03)
	body = append(body, randomBytes[:]...)
	body = append(body, byte(len(sessionID)))
	body = append(body, sessionID[:]...)

	var csBuf [2]byte
	binary.BigEndian.PutUint16(csBuf[:], uint16(len(ciphers)*2))
	body = append(body, csBuf[:]...)
	for _, cs := range ciphers {
		binary.BigEndian.PutUint16(csBuf[:], cs)
		body = append(body, csBuf[:]...)
	}
	body = append(body, 0x01, 0x00)

	binary.BigEndian.PutUint16(csBuf[:], uint16(len(exts)))
	body = append(body, csBuf[:]...)
	body = append(body, exts...)

	msg := make([]byte, 4+len(body))
	msg[0] = tlsHandshakeClientHello
	putUint24(msg[1:4], len(body))
	copy(msg[4:], body)
	return msg, nil
}

func parseTLSServerHello(body []byte) (parsedServerHello, error) {
	var out parsedServerHello
	if len(body) < 38 {
		return out, sentinelError("tls ServerHello truncated")
	}
	out.Version = binary.BigEndian.Uint16(body[0:2])
	pos := 34
	sidLen := int(body[pos])
	pos++
	if pos+sidLen+3 > len(body) {
		return out, sentinelError("tls ServerHello session_id out of bounds")
	}
	pos += sidLen
	out.CipherSuite = binary.BigEndian.Uint16(body[pos : pos+2])
	pos += 3

	if pos == len(body) {
		return out, nil
	}
	if pos+2 > len(body) {
		return out, sentinelError("tls ServerHello extensions truncated")
	}
	extTotal := int(binary.BigEndian.Uint16(body[pos : pos+2]))
	pos += 2
	if pos+extTotal > len(body) {
		return out, sentinelError("tls ServerHello extensions out of bounds")
	}
	end := pos + extTotal
	for pos+4 <= end {
		extType := binary.BigEndian.Uint16(body[pos : pos+2])
		extLen := int(binary.BigEndian.Uint16(body[pos+2 : pos+4]))
		pos += 4
		if pos+extLen > end {
			return out, sentinelError("tls ServerHello extension truncated")
		}
		extData := body[pos : pos+extLen]
		pos += extLen

		switch extType {
		case 0x002b:
			if len(extData) == 2 {
				out.Version = binary.BigEndian.Uint16(extData)
			}
		case 0x0033:
			if len(extData) >= 4 {
				grp := binary.BigEndian.Uint16(extData[0:2])
				kLen := int(binary.BigEndian.Uint16(extData[2:4]))
				if 4+kLen == len(extData) {
					out.KeyShareGrp = grp
					out.KeySharePub = append([]byte(nil), extData[4:]...)
				}
			}
		}
	}
	return out, nil
}

func readTLS13Certificates(
	conn streamConn,
	clientHelloMsg []byte,
	serverHelloMsg []byte,
	sh parsedServerHello,
	x25519Seed []byte,
	p256Seed []byte,
) (*tlsHandshakeInfo, error) {
	var (
		sharedSecret []byte
		err          error
	)
	switch sh.KeyShareGrp {
	case 0x001d:
		if len(sh.KeySharePub) != 32 {
			return nil, sentinelError("tls 1.3 invalid x25519 peer public key")
		}
		sharedSecret, err = x25519ScalarMult(x25519Seed, sh.KeySharePub)
		if err != nil {
			return nil, err
		}
	case 0x0017:
		if len(sh.KeySharePub) != 65 || sh.KeySharePub[0] != 0x04 {
			return nil, sentinelError("tls 1.3 invalid P-256 peer public key")
		}
		curve := elliptic.P256()
		sx := new(big.Int).SetBytes(sh.KeySharePub[1:33])
		sy := new(big.Int).SetBytes(sh.KeySharePub[33:65])
		if !curve.IsOnCurve(sx, sy) {
			return nil, sentinelError("tls 1.3 P-256 peer key not on curve")
		}
		zx, _ := curve.ScalarMult(sx, sy, p256Seed)
		sharedSecret = make([]byte, 32)
		zx.FillBytes(sharedSecret)
	default:
		return nil, sentinelError("tls 1.3 unsupported server key_share group")
	}

	var (
		newHash func() hash.Hash
		keyLen  int
	)
	switch sh.CipherSuite {
	case 0x1301:
		newHash = sha256.New
		keyLen = 16
	case 0x1302:
		newHash = sha512.New384
		keyLen = 32
	default:
		return nil, sentinelError("tls 1.3 unsupported cipher suite")
	}

	hashSize := newHash().Size()
	zeros := make([]byte, hashSize)
	emptyHash := newHash().Sum(nil)

	th := newHash()
	_, _ = th.Write(clientHelloMsg)
	_, _ = th.Write(serverHelloMsg)
	transcriptHash := th.Sum(nil)

	earlySecret := hkdfExtract(newHash, zeros, zeros)
	derivedSecret := hkdfExpandLabel(newHash, earlySecret, "derived", emptyHash, hashSize)
	handshakeSecret := hkdfExtract(newHash, derivedSecret, sharedSecret)
	serverHSTraffic := hkdfExpandLabel(newHash, handshakeSecret, "s hs traffic", transcriptHash, hashSize)
	serverKey := hkdfExpandLabel(newHash, serverHSTraffic, "key", nil, keyLen)
	serverIV := hkdfExpandLabel(newHash, serverHSTraffic, "iv", nil, 12)

	block, err := aes.NewCipher(serverKey)
	if err != nil {
		return nil, err
	}

	var (
		seqNum uint64
		hsBuf  []byte
	)
	for records := 0; records < 32; records++ {
		recType, rawHeader, ciphertext, rErr := readTLSRecordWithHeader(conn)
		if rErr != nil {
			return nil, rErr
		}
		if recType == tlsRecordChangeCipherSpec {
			continue
		}
		if recType == tlsRecordAlert {
			return nil, formatTLSAlert(ciphertext)
		}
		if recType != tlsRecordApplicationData {
			return nil, sentinelError("tls 1.3 expected encrypted record")
		}

		nonce := make([]byte, 12)
		copy(nonce, serverIV)
		var seqBytes [8]byte
		binary.BigEndian.PutUint64(seqBytes[:], seqNum)
		for i := 0; i < 8; i++ {
			nonce[4+i] ^= seqBytes[i]
		}
		seqNum++

		plaintext, decErr := aesGCMOpen(block, nonce, ciphertext, rawHeader[:])
		if decErr != nil {
			return nil, decErr
		}

		idx := len(plaintext) - 1
		for idx >= 0 && plaintext[idx] == 0 {
			idx--
		}
		if idx < 0 {
			return nil, sentinelError("tls 1.3 inner record missing content type")
		}
		innerType := plaintext[idx]
		innerData := plaintext[:idx]

		if innerType == tlsRecordAlert {
			return nil, formatTLSAlert(innerData)
		}
		if innerType != tlsRecordHandshake {
			continue
		}
		hsBuf = append(hsBuf, innerData...)

		certs, done, pErr := tryExtractHandshakeCerts(hsBuf, true)
		if pErr != nil {
			return nil, pErr
		}
		if done {
			return &tlsHandshakeInfo{
				Version:          tlsVersion13,
				CipherSuite:      sh.CipherSuite,
				PeerCertificates: certs,
			}, nil
		}
	}
	return nil, sentinelError("tls 1.3 handshake did not yield server certificate")
}

func readTLS12Certificates(conn streamConn, initialBuf []byte, sh parsedServerHello) (*tlsHandshakeInfo, error) {
	hsBuf := initialBuf
	for records := 0; records < 32; records++ {
		certs, done, pErr := tryExtractHandshakeCerts(hsBuf, false)
		if pErr != nil {
			return nil, pErr
		}
		if done {
			return &tlsHandshakeInfo{
				Version:          sh.Version,
				CipherSuite:      sh.CipherSuite,
				PeerCertificates: certs,
			}, nil
		}
		recType, payload, rErr := readTLSRecord(conn)
		if rErr != nil {
			return nil, rErr
		}
		if recType == tlsRecordAlert {
			return nil, formatTLSAlert(payload)
		}
		if recType == tlsRecordHandshake {
			hsBuf = append(hsBuf, payload...)
		}
	}
	return nil, sentinelError("tls 1.2 handshake did not yield server certificate")
}

// Pure NIST SP 800-38D AES-GCM Open (12-byte nonce, 16-byte tag) without crypto/cipher drbg imports.
func aesGCMOpen(block blockEncrypter, nonce, ciphertextAndTag, aad []byte) ([]byte, error) {
	if len(nonce) != 12 || len(ciphertextAndTag) < 16 {
		return nil, sentinelError("tls 1.3 invalid AES-GCM input length")
	}
	ctLen := len(ciphertextAndTag) - 16
	ct := ciphertextAndTag[:ctLen]
	tag := ciphertextAndTag[ctLen:]

	var h [16]byte
	block.Encrypt(h[:], h[:])

	var j0 [16]byte
	copy(j0[:12], nonce)
	j0[15] = 1

	var encJ0 [16]byte
	block.Encrypt(encJ0[:], j0[:])

	s := ghashCompute(&h, aad, ct)
	var expectedTag [16]byte
	for i := 0; i < 16; i++ {
		expectedTag[i] = encJ0[i] ^ s[i]
	}
	if subtle.ConstantTimeCompare(tag, expectedTag[:]) != 1 {
		return nil, sentinelError("tls 1.3 handshake record authentication failed")
	}

	out := make([]byte, ctLen)
	ctr := j0
	var ks [16]byte
	for off := 0; off < ctLen; off += 16 {
		incGCMCounter(&ctr)
		block.Encrypt(ks[:], ctr[:])
		chunk := ctLen - off
		if chunk > 16 {
			chunk = 16
		}
		for i := 0; i < chunk; i++ {
			out[off+i] = ct[off+i] ^ ks[i]
		}
	}
	return out, nil
}

func incGCMCounter(ctr *[16]byte) {
	c := binary.BigEndian.Uint32(ctr[12:16]) + 1
	binary.BigEndian.PutUint32(ctr[12:16], c)
}

func ghashCompute(h *[16]byte, aad, ct []byte) [16]byte {
	var y [16]byte
	ghashUpdate(&y, h, aad)
	ghashUpdate(&y, h, ct)
	var lengths [16]byte
	binary.BigEndian.PutUint64(lengths[0:8], uint64(len(aad))*8)
	binary.BigEndian.PutUint64(lengths[8:16], uint64(len(ct))*8)
	for i := 0; i < 16; i++ {
		y[i] ^= lengths[i]
	}
	y = ghashMul(y, *h)
	return y
}

func ghashUpdate(y *[16]byte, h *[16]byte, data []byte) {
	for off := 0; off < len(data); off += 16 {
		chunk := len(data) - off
		if chunk > 16 {
			chunk = 16
		}
		for i := 0; i < chunk; i++ {
			y[i] ^= data[off+i]
		}
		*y = ghashMul(*y, *h)
	}
}

func ghashMul(x, h [16]byte) [16]byte {
	var z [16]byte
	v := h
	for byteIdx := 0; byteIdx < 16; byteIdx++ {
		xb := x[byteIdx]
		for bit := 7; bit >= 0; bit-- {
			if (xb>>uint(bit))&1 != 0 {
				for i := 0; i < 16; i++ {
					z[i] ^= v[i]
				}
			}
			lsb := v[15] & 1
			for i := 15; i > 0; i-- {
				v[i] = (v[i] >> 1) | (v[i-1] << 7)
			}
			v[0] >>= 1
			if lsb != 0 {
				v[0] ^= 0xe1
			}
		}
	}
	return z
}

// RFC 7748 Section 5 X25519 scalar multiplication over GF(2^255 - 19).
func x25519ScalarMult(scalar, uBytes []byte) ([]byte, error) {
	if len(scalar) != 32 || len(uBytes) != 32 {
		return nil, sentinelError("invalid x25519 input length")
	}
	var k [32]byte
	copy(k[:], scalar)
	k[0] &= 248
	k[31] &= 127
	k[31] |= 64

	var uClamped [32]byte
	copy(uClamped[:], uBytes)
	uClamped[31] &= 127

	p := new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 255), big.NewInt(19))
	a24 := big.NewInt(121665)

	u := decodeLittleEndian256(uClamped[:])
	u.Mod(u, p)

	x1 := new(big.Int).Set(u)
	x2 := big.NewInt(1)
	z2 := big.NewInt(0)
	x3 := new(big.Int).Set(u)
	z3 := big.NewInt(1)
	swap := uint(0)

	modP := func(v *big.Int) *big.Int {
		v.Mod(v, p)
		if v.Sign() < 0 {
			v.Add(v, p)
		}
		return v
	}

	for t := 254; t >= 0; t-- {
		kt := uint((k[t/8] >> uint(t%8)) & 1)
		swap ^= kt
		if swap != 0 {
			x2, x3 = x3, x2
			z2, z3 = z3, z2
		}
		swap = kt

		a := modP(new(big.Int).Add(x2, z2))
		aa := modP(new(big.Int).Mul(a, a))
		b := modP(new(big.Int).Sub(x2, z2))
		bb := modP(new(big.Int).Mul(b, b))
		e := modP(new(big.Int).Sub(aa, bb))
		c := modP(new(big.Int).Add(x3, z3))
		d := modP(new(big.Int).Sub(x3, z3))
		da := modP(new(big.Int).Mul(d, a))
		cb := modP(new(big.Int).Mul(c, b))

		sum := modP(new(big.Int).Add(da, cb))
		x3 = modP(new(big.Int).Mul(sum, sum))
		diff := modP(new(big.Int).Sub(da, cb))
		diffSq := modP(new(big.Int).Mul(diff, diff))
		z3 = modP(new(big.Int).Mul(x1, diffSq))

		x2 = modP(new(big.Int).Mul(aa, bb))
		a24e := modP(new(big.Int).Mul(a24, e))
		inner := modP(new(big.Int).Add(aa, a24e))
		z2 = modP(new(big.Int).Mul(e, inner))
	}
	if swap != 0 {
		x2, _ = x3, x2
		z2, _ = z3, z2
	}

	z2Inv := new(big.Int).Exp(z2, new(big.Int).Sub(p, big.NewInt(2)), p)
	res := modP(new(big.Int).Mul(x2, z2Inv))
	out := encodeLittleEndian256(res)
	var zero [32]byte
	if subtle.ConstantTimeCompare(out, zero[:]) == 1 {
		return nil, sentinelError("x25519 low-order point rejected")
	}
	return out, nil
}

func decodeLittleEndian256(b []byte) *big.Int {
	var rev [32]byte
	for i := 0; i < 32; i++ {
		rev[31-i] = b[i]
	}
	return new(big.Int).SetBytes(rev[:])
}

func encodeLittleEndian256(v *big.Int) []byte {
	var be [32]byte
	v.FillBytes(be[:])
	out := make([]byte, 32)
	for i := 0; i < 32; i++ {
		out[i] = be[31-i]
	}
	return out
}

func tryExtractHandshakeCerts(hsBuf []byte, isTLS13 bool) ([]*parsedX509Cert, bool, error) {
	pos := 0
	for pos+4 <= len(hsBuf) {
		msgType := hsBuf[pos]
		msgLen := uint24(hsBuf[pos+1 : pos+4])
		if pos+4+msgLen > len(hsBuf) {
			return nil, false, nil
		}
		body := hsBuf[pos+4 : pos+4+msgLen]
		pos += 4 + msgLen

		if msgType == tlsHandshakeCertificate {
			certs, err := parseCertificateHandshakeBody(body, isTLS13)
			if err != nil {
				return nil, false, err
			}
			return certs, true, nil
		}
	}
	return nil, false, nil
}

func parseCertificateHandshakeBody(body []byte, isTLS13 bool) ([]*parsedX509Cert, error) {
	pos := 0
	if isTLS13 {
		if len(body) < 4 {
			return nil, sentinelError("tls 1.3 Certificate message truncated")
		}
		ctxLen := int(body[0])
		pos = 1 + ctxLen
	}
	if pos+3 > len(body) {
		return nil, sentinelError("tls Certificate list header truncated")
	}
	listLen := uint24(body[pos : pos+3])
	pos += 3
	if pos+listLen > len(body) {
		return nil, sentinelError("tls Certificate list truncated")
	}
	end := pos + listLen
	var certs []*parsedX509Cert
	for pos < end {
		if pos+3 > end {
			return nil, sentinelError("tls Certificate entry header truncated")
		}
		certLen := uint24(body[pos : pos+3])
		pos += 3
		if pos+certLen > end {
			return nil, sentinelError("tls Certificate entry truncated")
		}
		cert, err := parseDERCertificate(body[pos : pos+certLen])
		if err != nil {
			return nil, err
		}
		certs = append(certs, cert)
		pos += certLen

		if isTLS13 {
			if pos+2 > end {
				return nil, sentinelError("tls 1.3 Certificate extensions truncated")
			}
			extLen := int(binary.BigEndian.Uint16(body[pos : pos+2]))
			pos += 2 + extLen
			if pos > end {
				return nil, sentinelError("tls 1.3 Certificate extensions out of bounds")
			}
		}
	}
	return certs, nil
}

// ASN.1 DER X.509 parser and signature verifier (scheduler-free, WASI compatible)

type asn1Cert struct {
	TBS          asn1.RawValue
	SigAlgorithm asn1AlgID
	Signature    asn1.BitString
}

type asn1AlgID struct {
	Algorithm  asn1.ObjectIdentifier
	Parameters asn1.RawValue `asn1:"optional"`
}

type asn1Validity struct {
	NotBefore time.Time
	NotAfter  time.Time
}

type asn1PublicKeyInfo struct {
	Algorithm asn1AlgID
	PublicKey asn1.BitString
}

type asn1Ext struct {
	ExtnID    asn1.ObjectIdentifier
	Critical  bool `asn1:"optional"`
	ExtnValue []byte
}

type asn1ATV struct {
	Type  asn1.ObjectIdentifier
	Value asn1.RawValue
}

func parsePEMCertificates(pemBytes []byte) ([]*parsedX509Cert, error) {
	var certs []*parsedX509Cert
	rest := pemBytes
	for len(rest) > 0 {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			break
		}
		if block.Type != "CERTIFICATE" {
			continue
		}
		c, err := parseDERCertificate(block.Bytes)
		if err != nil {
			return nil, err
		}
		certs = append(certs, c)
	}
	if len(certs) == 0 {
		return nil, sentinelError("no valid PEM certificates found")
	}
	return certs, nil
}

func parseDERCertificate(der []byte) (*parsedX509Cert, error) {
	var top asn1Cert
	if _, err := asn1.Unmarshal(der, &top); err != nil {
		return nil, err
	}

	tbsRest := top.TBS.Bytes
	var first asn1.RawValue
	rest, err := asn1.Unmarshal(tbsRest, &first)
	if err != nil {
		return nil, err
	}
	if first.Class == asn1.ClassContextSpecific && first.Tag == 0 {
		rest, err = asn1.Unmarshal(rest, &first)
		if err != nil {
			return nil, err
		}
	}
	var sigAlg asn1AlgID
	rest, err = asn1.Unmarshal(rest, &sigAlg)
	if err != nil {
		return nil, err
	}
	var issuerRaw asn1.RawValue
	rest, err = asn1.Unmarshal(rest, &issuerRaw)
	if err != nil {
		return nil, err
	}
	var validity asn1Validity
	rest, err = asn1.Unmarshal(rest, &validity)
	if err != nil {
		return nil, err
	}
	var subjectRaw asn1.RawValue
	rest, err = asn1.Unmarshal(rest, &subjectRaw)
	if err != nil {
		return nil, err
	}
	var spki asn1PublicKeyInfo
	rest, err = asn1.Unmarshal(rest, &spki)
	if err != nil {
		return nil, err
	}

	pubKey, _ := parseSPKIPublicKey(spki)

	out := &parsedX509Cert{
		RawTBS:     top.TBS.FullBytes,
		SigAlgOID:  top.SigAlgorithm.Algorithm,
		Signature:  top.Signature.RightAlign(),
		IssuerRaw:  issuerRaw.FullBytes,
		SubjectRaw: subjectRaw.FullBytes,
		IssuerCN:   extractRDNCommonName(issuerRaw.FullBytes),
		SubjectCN:  extractRDNCommonName(subjectRaw.FullBytes),
		NotBefore:  validity.NotBefore.UTC(),
		NotAfter:   validity.NotAfter.UTC(),
		PublicKey:  pubKey,
	}

	for len(rest) > 0 {
		var opt asn1.RawValue
		var nextErr error
		rest, nextErr = asn1.Unmarshal(rest, &opt)
		if nextErr != nil {
			break
		}
		if opt.Class == asn1.ClassContextSpecific && opt.Tag == 3 {
			var exts []asn1Ext
			if _, extErr := asn1.Unmarshal(opt.Bytes, &exts); extErr == nil {
				for _, ext := range exts {
					if ext.ExtnID.Equal(asn1.ObjectIdentifier{2, 5, 29, 17}) {
						dnsNames, ips := parseSANExtension(ext.ExtnValue)
						out.DNSNames = dnsNames
						out.IPAddresses = ips
					}
				}
			}
		}
	}

	return out, nil
}

func extractRDNCommonName(rawName []byte) string {
	var rdns []asn1.RawValue
	if _, err := asn1.Unmarshal(rawName, &rdns); err != nil {
		return ""
	}
	cnOID := asn1.ObjectIdentifier{2, 5, 4, 3}
	for _, rdnSet := range rdns {
		setBytes := rdnSet.Bytes
		for len(setBytes) > 0 {
			var atv asn1ATV
			var err error
			setBytes, err = asn1.Unmarshal(setBytes, &atv)
			if err != nil {
				break
			}
			if atv.Type.Equal(cnOID) {
				var s string
				if _, sErr := asn1.Unmarshal(atv.Value.FullBytes, &s); sErr == nil {
					return s
				}
				return string(atv.Value.Bytes)
			}
		}
	}
	return ""
}

func parseSANExtension(extValue []byte) ([]string, [][]byte) {
	var seq asn1.RawValue
	if _, err := asn1.Unmarshal(extValue, &seq); err != nil {
		return nil, nil
	}
	var (
		dnsNames []string
		ips      [][]byte
		rest     = seq.Bytes
	)
	for len(rest) > 0 {
		var gn asn1.RawValue
		var err error
		rest, err = asn1.Unmarshal(rest, &gn)
		if err != nil {
			break
		}
		if gn.Class != asn1.ClassContextSpecific {
			continue
		}
		switch gn.Tag {
		case 2:
			dnsNames = append(dnsNames, string(gn.Bytes))
		case 7:
			if len(gn.Bytes) == 4 || len(gn.Bytes) == 16 {
				ips = append(ips, append([]byte(nil), gn.Bytes...))
			}
		}
	}
	return dnsNames, ips
}

func parseSPKIPublicKey(spki asn1PublicKeyInfo) (any, error) {
	rsaOID := asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 1, 1}
	ecOID := asn1.ObjectIdentifier{1, 2, 840, 10045, 2, 1}

	keyBytes := spki.PublicKey.RightAlign()
	if spki.Algorithm.Algorithm.Equal(rsaOID) {
		var pub rsaPublicKey
		if _, err := asn1.Unmarshal(keyBytes, &pub); err != nil {
			return nil, err
		}
		return &pub, nil
	}
	if spki.Algorithm.Algorithm.Equal(ecOID) {
		var curveOID asn1.ObjectIdentifier
		if _, err := asn1.Unmarshal(spki.Algorithm.Parameters.FullBytes, &curveOID); err != nil {
			return nil, err
		}
		var curve elliptic.Curve
		switch {
		case curveOID.Equal(asn1.ObjectIdentifier{1, 2, 840, 10045, 3, 1, 7}):
			curve = elliptic.P256()
		case curveOID.Equal(asn1.ObjectIdentifier{1, 3, 132, 0, 34}):
			curve = elliptic.P384()
		default:
			return nil, sentinelError("unsupported EC curve")
		}
		if len(keyBytes) == 0 || keyBytes[0] != 4 {
			return nil, sentinelError("invalid uncompressed EC point")
		}
		byteLen := (curve.Params().BitSize + 7) / 8
		if len(keyBytes) != 1+2*byteLen {
			return nil, sentinelError("unexpected EC point length")
		}
		x := new(big.Int).SetBytes(keyBytes[1 : 1+byteLen])
		y := new(big.Int).SetBytes(keyBytes[1+byteLen:])
		if !curve.IsOnCurve(x, y) {
			return nil, sentinelError("EC point not on curve")
		}
		return &ecPublicKey{Curve: curve, X: x, Y: y}, nil
	}
	return nil, sentinelError("unsupported public key algorithm")
}

func (c *parsedX509Cert) verifyHostname(host string) error {
	trimmed := strings.TrimSuffix(strings.TrimSpace(host), ".")
	if trimmed == "" {
		return nil
	}
	if ipBytes, isIP := parseLiteralIP(trimmed); isIP {
		for _, candidate := range c.IPAddresses {
			if equalBytes(candidate, ipBytes) {
				return nil
			}
		}
		return sentinelError("certificate IP SAN mismatch")
	}

	lowerHost := strings.ToLower(trimmed)
	names := c.DNSNames
	if len(names) == 0 && c.SubjectCN != "" {
		names = []string{c.SubjectCN}
	}
	for _, pattern := range names {
		if matchCertHostnamePattern(strings.ToLower(strings.TrimSuffix(pattern, ".")), lowerHost) {
			return nil
		}
	}
	return sentinelError("certificate DNS SAN mismatch")
}

func matchCertHostnamePattern(pattern, host string) bool {
	if pattern == "" || host == "" {
		return false
	}
	if pattern == host {
		return true
	}
	if strings.HasPrefix(pattern, "*.") {
		suffix := pattern[1:]
		if strings.HasSuffix(host, suffix) {
			prefix := strings.TrimSuffix(host, suffix)
			return prefix != "" && !strings.Contains(prefix, ".")
		}
	}
	return false
}

func verifyCertChainAgainstRoots(chain []*parsedX509Cert, roots []*parsedX509Cert, sni string, now time.Time) error {
	if len(chain) == 0 {
		return sentinelError("empty certificate chain")
	}
	leaf := chain[0]
	if now.Before(leaf.NotBefore) || !now.Before(leaf.NotAfter) {
		return sentinelError("leaf certificate outside validity window")
	}
	if err := leaf.verifyHostname(sni); err != nil {
		return err
	}

	cur := leaf
	for depth := 0; depth < 8; depth++ {
		for _, root := range roots {
			if bytes.Equal(cur.IssuerRaw, root.SubjectRaw) {
				if now.Before(root.NotBefore) || !now.Before(root.NotAfter) {
					continue
				}
				if verifyCertSignature(cur, root) == nil {
					return nil
				}
			}
		}
		var nextIssuer *parsedX509Cert
		for _, cand := range chain[1:] {
			if bytes.Equal(cur.IssuerRaw, cand.SubjectRaw) && !bytes.Equal(cur.SubjectRaw, cand.SubjectRaw) {
				if !now.Before(cand.NotBefore) && now.Before(cand.NotAfter) && verifyCertSignature(cur, cand) == nil {
					nextIssuer = cand
					break
				}
			}
		}
		if nextIssuer == nil {
			break
		}
		cur = nextIssuer
	}
	return sentinelError("certificate chain not trusted by configured ca_bundle_pem")
}

func verifyCertSignature(child, issuer *parsedX509Cert) error {
	switch pub := issuer.PublicKey.(type) {
	case *ecPublicKey:
		var digest []byte
		switch {
		case child.SigAlgOID.Equal(asn1.ObjectIdentifier{1, 2, 840, 10045, 4, 3, 2}):
			sum := sha256.Sum256(child.RawTBS)
			digest = sum[:]
		case child.SigAlgOID.Equal(asn1.ObjectIdentifier{1, 2, 840, 10045, 4, 3, 3}):
			sum := sha512.Sum384(child.RawTBS)
			digest = sum[:]
		default:
			return sentinelError("unsupported ECDSA signature OID")
		}
		return verifyECDSASignature(pub, digest, child.Signature)
	case *rsaPublicKey:
		switch {
		case child.SigAlgOID.Equal(asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 1, 11}):
			sum := sha256.Sum256(child.RawTBS)
			prefix := []byte{0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20}
			return verifyRSAPKCS1v15(pub, prefix, sum[:], child.Signature)
		case child.SigAlgOID.Equal(asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 1, 12}):
			sum := sha512.Sum384(child.RawTBS)
			prefix := []byte{0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30}
			return verifyRSAPKCS1v15(pub, prefix, sum[:], child.Signature)
		default:
			return sentinelError("unsupported RSA signature OID")
		}
	default:
		return sentinelError("issuer public key unavailable")
	}
}

func verifyECDSASignature(pub *ecPublicKey, digest, sigDER []byte) error {
	var sig struct {
		R, S *big.Int
	}
	if _, err := asn1.Unmarshal(sigDER, &sig); err != nil {
		return err
	}
	params := pub.Curve.Params()
	n := params.N
	if sig.R.Sign() <= 0 || sig.S.Sign() <= 0 || sig.R.Cmp(n) >= 0 || sig.S.Cmp(n) >= 0 {
		return sentinelError("ECDSA signature out of range")
	}
	e := hashToCurveScalar(digest, params.BitSize)
	w := new(big.Int).ModInverse(sig.S, n)
	if w == nil {
		return sentinelError("ECDSA non-invertible s")
	}
	u1 := new(big.Int).Mul(e, w)
	u1.Mod(u1, n)
	u2 := new(big.Int).Mul(sig.R, w)
	u2.Mod(u2, n)

	x1, y1 := pub.Curve.ScalarBaseMult(u1.Bytes())
	x2, y2 := pub.Curve.ScalarMult(pub.X, pub.Y, u2.Bytes())
	if x1.Cmp(x2) == 0 && y1.Cmp(y2) != 0 {
		return sentinelError("ECDSA point at infinity")
	}
	var rx *big.Int
	if x1.Sign() == 0 && y1.Sign() == 0 {
		rx = x2
	} else if x2.Sign() == 0 && y2.Sign() == 0 {
		rx = x1
	} else {
		rx, _ = pub.Curve.Add(x1, y1, x2, y2)
	}
	rx.Mod(rx, n)
	if rx.Cmp(sig.R) != 0 {
		return sentinelError("ECDSA signature verification failed")
	}
	return nil
}

func hashToCurveScalar(hashBytes []byte, orderBits int) *big.Int {
	orderBytes := (orderBits + 7) / 8
	if len(hashBytes) > orderBytes {
		hashBytes = hashBytes[:orderBytes]
	}
	ret := new(big.Int).SetBytes(hashBytes)
	excess := len(hashBytes)*8 - orderBits
	if excess > 0 {
		ret.Rsh(ret, uint(excess))
	}
	return ret
}

func verifyRSAPKCS1v15(pub *rsaPublicKey, asn1Prefix, digest, sig []byte) error {
	if pub.N == nil || pub.N.Sign() <= 0 || pub.E < 3 {
		return sentinelError("invalid RSA public key")
	}
	k := (pub.N.BitLen() + 7) / 8
	if len(sig) != k {
		return sentinelError("invalid RSA signature length")
	}
	s := new(big.Int).SetBytes(sig)
	if s.Cmp(pub.N) >= 0 {
		return sentinelError("RSA signature representative out of range")
	}
	m := new(big.Int).Exp(s, big.NewInt(int64(pub.E)), pub.N)
	em := make([]byte, k)
	m.FillBytes(em)

	tLen := len(asn1Prefix) + len(digest)
	if k < tLen+11 {
		return sentinelError("RSA modulus too short")
	}
	if em[0] != 0x00 || em[1] != 0x01 {
		return sentinelError("RSA PKCS#1 padding header mismatch")
	}
	psEnd := k - tLen - 1
	for i := 2; i < psEnd; i++ {
		if em[i] != 0xff {
			return sentinelError("RSA PKCS#1 padding byte mismatch")
		}
	}
	if em[psEnd] != 0x00 {
		return sentinelError("RSA PKCS#1 separator mismatch")
	}
	if !bytes.Equal(em[psEnd+1:psEnd+1+len(asn1Prefix)], asn1Prefix) {
		return sentinelError("RSA digest OID mismatch")
	}
	if subtle.ConstantTimeCompare(em[psEnd+1+len(asn1Prefix):], digest) != 1 {
		return sentinelError("RSA signature digest mismatch")
	}
	return nil
}

func readTLSRecord(conn streamConn) (byte, []byte, error) {
	recType, _, payload, err := readTLSRecordWithHeader(conn)
	return recType, payload, err
}

func readTLSRecordWithHeader(conn streamConn) (byte, [5]byte, []byte, error) {
	var hdr [5]byte
	if _, err := io.ReadFull(conn, hdr[:]); err != nil {
		return 0, hdr, nil, err
	}
	recLen := int(binary.BigEndian.Uint16(hdr[3:5]))
	if recLen > 18432 {
		return 0, hdr, nil, sentinelError("tls record exceeds maximum size")
	}
	payload := make([]byte, recLen)
	if _, err := io.ReadFull(conn, payload); err != nil {
		return 0, hdr, nil, err
	}
	return hdr[0], hdr, payload, nil
}

func hkdfExtract(newHash func() hash.Hash, salt, ikm []byte) []byte {
	mac := hmac.New(newHash, salt)
	_, _ = mac.Write(ikm)
	return mac.Sum(nil)
}

func hkdfExpandLabel(newHash func() hash.Hash, secret []byte, label string, context []byte, length int) []byte {
	fullLabel := "tls13 " + label
	var hkdfLabel []byte
	hkdfLabel = append(hkdfLabel, byte(length>>8), byte(length))
	hkdfLabel = append(hkdfLabel, byte(len(fullLabel)))
	hkdfLabel = append(hkdfLabel, fullLabel...)
	hkdfLabel = append(hkdfLabel, byte(len(context)))
	hkdfLabel = append(hkdfLabel, context...)

	var out []byte
	var prev []byte
	counter := byte(1)
	for len(out) < length {
		mac := hmac.New(newHash, secret)
		_, _ = mac.Write(prev)
		_, _ = mac.Write(hkdfLabel)
		_, _ = mac.Write([]byte{counter})
		prev = mac.Sum(nil)
		out = append(out, prev...)
		counter++
	}
	return out[:length]
}

func appendTLSExt(buf []byte, extType uint16, data []byte) []byte {
	var hdr [4]byte
	binary.BigEndian.PutUint16(hdr[0:2], extType)
	binary.BigEndian.PutUint16(hdr[2:4], uint16(len(data)))
	buf = append(buf, hdr[:]...)
	return append(buf, data...)
}

func appendKeyShareEntry(buf []byte, group uint16, pub []byte) []byte {
	var hdr [4]byte
	binary.BigEndian.PutUint16(hdr[0:2], group)
	binary.BigEndian.PutUint16(hdr[2:4], uint16(len(pub)))
	buf = append(buf, hdr[:]...)
	return append(buf, pub...)
}

func uint24(b []byte) int {
	return (int(b[0]) << 16) | (int(b[1]) << 8) | int(b[2])
}

func putUint24(b []byte, v int) {
	b[0] = byte(v >> 16)
	b[1] = byte(v >> 8)
	b[2] = byte(v)
}

func formatTLSAlert(payload []byte) error {
	if len(payload) >= 2 {
		return fmt.Errorf("tls handshake alert (%d, %d)", payload[0], payload[1])
	}
	return sentinelError("tls handshake alert")
}

func tlsCipherSuiteName(id uint16) string {
	switch id {
	case 0x1301:
		return "TLS_AES_128_GCM_SHA256"
	case 0x1302:
		return "TLS_AES_256_GCM_SHA384"
	case 0x1303:
		return "TLS_CHACHA20_POLY1305_SHA256"
	case 0xc02b:
		return "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
	case 0xc02f:
		return "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
	case 0xc02c:
		return "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
	case 0xc030:
		return "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
	case 0x009c:
		return "TLS_RSA_WITH_AES_128_GCM_SHA256"
	default:
		return fmt.Sprintf("0x%04X", id)
	}
}
