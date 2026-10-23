package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"encoding/hex"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSelectBackendIPv4RejectsIPv6OnlyResults(t *testing.T) {
	backendIP, ok := selectBackendIPv4([]net.IP{
		net.ParseIP("2001:db8::443"),
		net.ParseIP("2606:4700:4700::1111"),
	})
	if ok {
		t.Fatalf("selectBackendIPv4 returned %s, want no IPv4 backend", backendIP)
	}
}

func TestSelectBackendIPv4ChoosesFirstIPv4Result(t *testing.T) {
	backendIP, ok := selectBackendIPv4([]net.IP{
		net.ParseIP("2001:db8::443"),
		net.ParseIP("203.0.113.10"),
		net.ParseIP("198.51.100.8"),
	})
	if !ok {
		t.Fatalf("selectBackendIPv4 returned ok=false")
	}
	if got, want := backendIP.String(), "203.0.113.10"; got != want {
		t.Fatalf("selectBackendIPv4 returned %s, want %s", got, want)
	}
}

func TestExtractSNIDoesNotMutateInitialPacket(t *testing.T) {
	packetHex := strings.Join([]string{
		"cf00000001080917f0960e7069db082640383fefc89e550041f1f3ee73e46d4b9708ecf630c4e0829991b650053db2713fce0ddae02cdf6ffe8a19a9b150bd70b63218aa13acb656c815276a16ae84b68f7ecdde2eed55e3ba0587edaba42f58e5661603b625ca1caec6d1b637e70cc6958f775bb41ffc4026c4f260a867e0c104fea23ed0fb4d3eb575cd41786a38d60f193d4dbdf7deb402bd1ea338e9f989ece0b1200ae500a5b3e13742cff7d362859fee0d6d7636649f97cec2bda186a4794d1f191cb47e0c9d11d8e6fbd6bfef611dcaff93afeb0c88a7782ee5f7550dc1c7f285033b95d1c36e794f56f9028a691a2994e5d8d27c9972bb41dfea7a8c32300603ef0d5a6e5fa8746d4f8fa1678596b3046c444cb5dc06617065f4298a4e12a4fa7a27dde2209ea6c91e991a9d8bcb350786c04ddb3549b27fe0cefdf2e1eb468144c37bb443a8b26d2024cccedf65c2ec73e1124ed91e9bb8cb3a35b2964b90547886597619b5b8bec4b6d567f1742298fd8542e9e6c0fdb769f5fe9d5284442c8b22a80e182e44f65d6b96e34744bccd1cb538960ee3afaffb2b8cb9205131dd62ff7dccbd1a547baa7ace2a07305cd3be2118fe26a1a889e2a606f27f5ec171488974c0befd79997adfdec0388928834c5011418370ac1e027bd3ecda56c4b00ebb676ca450b8fdf41136e70df75bc84484e9210484ce81390d1f2feb2ed3be5d54127b8bf309",
		"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
	}, "")
	packet, err := hex.DecodeString(packetHex)
	if err != nil {
		t.Fatalf("decode packet: %v", err)
	}
	original := append([]byte(nil), packet...)

	sni, ok := extractSNI(packet)
	if !ok {
		t.Fatalf("extractSNI returned ok=false")
	}
	if sni != "www.google.com" {
		t.Fatalf("extractSNI returned %q, want %q", sni, "www.google.com")
	}
	if !bytes.Equal(packet, original) {
		t.Fatalf("extractSNI mutated the packet")
	}
}

func TestConfiguredDNS(t *testing.T) {
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	go func() {
		buf := make([]byte, 1500)
		for {
			n, peer, err := conn.ReadFrom(buf)
			if err != nil {
				return
			}
			if n < 12 {
				continue
			}
			end := 12
			for end < n && buf[end] != 0 {
				end += int(buf[end]) + 1
			}
			if end+5 > n {
				continue
			}
			end += 5
			response := append([]byte(nil), buf[:end]...)
			response[2], response[3] = 0x81, 0x80
			response[6], response[7] = 0, 1
			response[8], response[9], response[10], response[11] = 0, 0, 0, 0
			response = append(response, 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0, 113, 9)
			_, _ = conn.WriteTo(response, peer)
		}
	}()
	path := filepath.Join(t.TempDir(), "remote_dns")
	dead, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	deadAddr := dead.LocalAddr().String()
	dead.Close()
	if err := os.WriteFile(path, []byte(deadAddr+" "+conn.LocalAddr().String()), 0600); err != nil {
		t.Fatal(err)
	}
	ips, err := lookupBackendIPv4("routing-test.invalid", path)
	if err != nil || len(ips) != 1 || ips[0].String() != "203.0.113.9" {
		t.Fatalf("ips=%v err=%v", ips, err)
	}
	for _, invalid := range []string{"", "localhost:53", "https://127.0.0.1/dns-query", "tls://1.1.1.1", "127.0.0.1:65536"} {
		if err := os.WriteFile(path, []byte(invalid), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := lookupBackendIPv4("localhost", path); err == nil {
			t.Errorf("accepted unsupported endpoint %q", invalid)
		}
	}
	if _, err := lookupBackendIPv4("localhost", path+".absent"); err == nil {
		t.Fatal("missing file must not use system resolver")
	}
}

// buildClientHello returns a TLS 1.3 ClientHello handshake message (type +
// 24-bit length + body) that carries only a server_name extension.
func buildClientHello(sni string) []byte {
	body := []byte{0x03, 0x03}
	body = append(body, make([]byte, 32)...) // random
	body = append(body, 0x00)                // session id length
	body = append(body, 0x00, 0x02, 0x13, 0x01)
	body = append(body, 0x01, 0x00) // compression methods
	name := []byte(sni)
	sniList := append([]byte{0x00, byte(len(name) >> 8), byte(len(name))}, name...)
	ext := append([]byte{byte(len(sniList) >> 8), byte(len(sniList))}, sniList...)
	extBlock := append([]byte{0x00, 0x00, byte(len(ext) >> 8), byte(len(ext))}, ext...)
	body = append(body, byte(len(extBlock)>>8), byte(len(extBlock)))
	body = append(body, extBlock...)
	hs := []byte{0x01, byte(len(body) >> 16), byte(len(body) >> 8), byte(len(body))}
	return append(hs, body...)
}

func putVarint(v uint64) []byte {
	switch {
	case v < 64:
		return []byte{byte(v)}
	case v < 16384:
		return []byte{0x40 | byte(v>>8), byte(v)}
	default:
		return []byte{0x80 | byte(v>>24), byte(v >> 16), byte(v >> 8), byte(v)}
	}
}

func cryptoFrame(offset uint64, data []byte) []byte {
	out := []byte{0x06}
	out = append(out, putVarint(offset)...)
	out = append(out, putVarint(uint64(len(data)))...)
	return append(out, data...)
}

// buildInitial seals a QUIC v1 Initial packet with the client Initial keys
// derived from dcid (RFC 9001 §5.2), the inverse of decryptInitialCrypto.
func buildInitial(t *testing.T, dcid []byte, pn byte, payload []byte) []byte {
	t.Helper()
	return buildInitialVersion(t, quicVersion1, dcid, pn, payload)
}

// buildInitialVersion is buildInitial for any version the proxy accepts
// (salt, labels and Initial type bits differ per version).
func buildInitialVersion(t *testing.T, version uint32, dcid []byte, pn byte, payload []byte) []byte {
	t.Helper()
	for len(payload) < 64 {
		payload = append(payload, 0x00) // PADDING so a 16-byte sample exists
	}
	info, ok := versionInfo(version)
	if !ok {
		t.Fatalf("version %#x is not supported by the proxy", version)
	}
	initialSecret := hkdfExtract([]byte(info.salt), dcid)
	clientSecret := hkdfExpandLabel(initialSecret, "client in", nil, 32)
	key := hkdfExpandLabel(clientSecret, info.keyLabel, nil, 16)
	iv := hkdfExpandLabel(clientSecret, info.ivLabel, nil, 12)
	hp := hkdfExpandLabel(clientSecret, info.hpLabel, nil, 16)

	header := []byte{0xc0 | info.initialType<<4} // long header, Initial, pn length 1
	header = append(header, byte(version>>24), byte(version>>16), byte(version>>8), byte(version))
	header = append(header, byte(len(dcid)))
	header = append(header, dcid...)
	header = append(header, 0x00)        // scid length
	header = append(header, 0x00)        // token length
	length := 1 + len(payload) + tagSize // pn + ciphertext
	header = append(header, 0x40|byte(length>>8), byte(length))
	pnOffset := len(header)
	header = append(header, pn)

	nonce := append([]byte(nil), iv...)
	nonce[11] ^= pn
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	packet := append(append([]byte(nil), header...), aead.Seal(nil, nonce, payload, header)...)

	hpBlock, err := aes.NewCipher(hp)
	if err != nil {
		t.Fatal(err)
	}
	mask := make([]byte, 16)
	hpBlock.Encrypt(mask, packet[pnOffset+4:pnOffset+20])
	packet[0] ^= mask[0] & 0x0f
	packet[pnOffset] ^= mask[1]
	return packet
}

func TestParseCryptoFramesTreatsPingAsFieldless(t *testing.T) {
	ch := buildClientHello("ping.example")
	plaintext := []byte{0x01} // PING, then CRYPTO
	plaintext = append(plaintext, cryptoFrame(0, ch)...)
	plaintext = append(plaintext, 0x00, 0x00)
	frags, ok := parseCryptoFrames(plaintext)
	if !ok || len(frags) != 1 {
		t.Fatalf("frags=%v ok=%v, want one CRYPTO fragment after PING", frags, ok)
	}
	if frags[0].offset != 0 || !bytes.Equal(frags[0].data, ch) {
		t.Fatalf("CRYPTO fragment mismatch: offset=%d len=%d", frags[0].offset, len(frags[0].data))
	}
}

// TikTok's client still speaks draft-29; Chrome may offer v2. Both must be
// decrypted, and anything else must be refused before a session exists.
func TestExtractSNIAcrossQUICVersions(t *testing.T) {
	ch := buildClientHello("versioned.example")
	payload := cryptoFrame(0, ch)
	for _, version := range []uint32{quicVersion1, quicDraft29, quicDraft32, quicDraft33, quicDraft34, quicVersion2} {
		packet := buildInitialVersion(t, version, []byte{9, 8, 7, 6, 5, 4, 3, 2}, 0x01, payload)
		if !looksLikeInitial(packet) {
			t.Fatalf("version %#x: looksLikeInitial=false", version)
		}
		sni, ok := extractSNI(packet)
		if !ok || sni != "versioned.example" {
			t.Fatalf("version %#x: extractSNI=%q ok=%v", version, sni, ok)
		}
	}
	// A v2 Initial carries type 01; a v1 packet with those bits is a 0-RTT
	// packet, not an Initial, and must not be mistaken for one.
	v2 := buildInitialVersion(t, quicVersion2, []byte{1, 1, 1, 1, 1, 1, 1, 1}, 0x01, payload)
	v2[1], v2[2], v2[3], v2[4] = 0x00, 0x00, 0x00, 0x01
	if looksLikeInitial(v2) {
		t.Fatalf("v1 packet with type bits 01 accepted as Initial")
	}
	for _, version := range []uint32{0x00000000, 0xff00001c, 0xff000023, 0x1a2a3a4a} {
		packet := buildInitialVersion(t, quicVersion1, []byte{2, 2, 2, 2, 2, 2, 2, 2}, 0x01, payload)
		packet[1], packet[2], packet[3], packet[4] = byte(version>>24), byte(version>>16), byte(version>>8), byte(version)
		if looksLikeInitial(packet) {
			t.Fatalf("version %#x must be refused", version)
		}
	}
}

func TestExtractSNIFromBuiltInitialWithPing(t *testing.T) {
	ch := buildClientHello("built.example")
	payload := append([]byte{0x01}, cryptoFrame(0, ch)...)
	packet := buildInitial(t, []byte{1, 2, 3, 4, 5, 6, 7, 8}, 0x05, payload)
	sni, ok := extractSNI(packet)
	if !ok || sni != "built.example" {
		t.Fatalf("extractSNI=%q ok=%v", sni, ok)
	}
}

func TestFragmentedClientHelloReassembly(t *testing.T) {
	ch := buildClientHello("fragmented.example")
	split := len(ch) / 2
	a := &cryptoAssembler{}
	if !a.add(cryptoFragment{offset: uint64(split), data: ch[split:]}) {
		t.Fatal("second half rejected")
	}
	if sni, st := a.clientHelloSNI(); st != helloIncomplete {
		t.Fatalf("only tail present: sni=%q status=%v, want incomplete", sni, st)
	}
	if !a.add(cryptoFragment{offset: 0, data: ch[:split]}) {
		t.Fatal("first half rejected")
	}
	sni, st := a.clientHelloSNI()
	if st != helloComplete || sni != "fragmented.example" {
		t.Fatalf("sni=%q status=%v", sni, st)
	}
	if a.add(cryptoFragment{offset: maxCryptoBytes - 1, data: []byte{1, 2}}) {
		t.Fatal("fragment beyond maxCryptoBytes accepted")
	}
	if _, st := parseClientHelloSNI([]byte{0x02, 0, 0, 4, 1, 2, 3, 4}); st != helloInvalid {
		t.Fatalf("non-ClientHello status=%v, want invalid", st)
	}
}

func TestFragmentedClientHelloAcrossInitialPackets(t *testing.T) {
	ch := buildClientHello("multi-packet.example")
	split := 40
	dcid := []byte{9, 8, 7, 6, 5, 4, 3, 2}
	first := buildInitial(t, dcid, 0x00, cryptoFrame(0, ch[:split]))
	second := buildInitial(t, dcid, 0x01, cryptoFrame(uint64(split), ch[split:]))
	if sni, ok := extractSNI(first); ok {
		t.Fatalf("first packet alone yielded %q", sni)
	}

	m := newSessionManager(nil)
	var got string
	done := make(chan struct{})
	m.connect = func(sess *Session, key, sni string) { got = sni; close(done) }
	addr := &net.UDPAddr{IP: net.ParseIP("203.0.113.77"), Port: 4433}
	sess, ok := m.openPending(addr)
	if !ok {
		t.Fatal("openPending refused")
	}
	m.queuePacket(sess, addr.String(), second)
	m.queuePacket(sess, addr.String(), first)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("connect was never called")
	}
	if got != "multi-packet.example" {
		t.Fatalf("connect got %q", got)
	}
	sess.mu.Lock()
	defer sess.mu.Unlock()
	if len(sess.pending) != 2 || !bytes.Equal(sess.pending[0], second) || !bytes.Equal(sess.pending[1], first) {
		t.Fatalf("pending queue does not hold both packets in arrival order (len=%d)", len(sess.pending))
	}
}

func TestSelectBackendIPv4RejectsPrivateAndLocal(t *testing.T) {
	for _, s := range []string{"127.0.0.1", "10.1.2.3", "172.16.0.9", "192.168.1.1", "169.254.1.1", "0.0.0.0", "224.0.0.1", "255.255.255.255"} {
		if ip, ok := selectBackendIPv4([]net.IP{net.ParseIP(s)}); ok {
			t.Errorf("%s accepted as backend (%s)", s, ip)
		}
	}
	ip, ok := selectBackendIPv4([]net.IP{net.ParseIP("10.0.0.1"), net.ParseIP("203.0.113.5")})
	if !ok || ip.String() != "203.0.113.5" {
		t.Fatalf("got %v ok=%v, want 203.0.113.5", ip, ok)
	}
	localIPs["203.0.113.5"] = struct{}{}
	defer delete(localIPs, "203.0.113.5")
	if ip, ok := selectBackendIPv4([]net.IP{net.ParseIP("203.0.113.5")}); ok {
		t.Fatalf("own address accepted as backend (%s)", ip)
	}
}

func TestSessionLimits(t *testing.T) {
	m := newSessionManager(nil)
	m.maxSessions = 5
	m.maxSessionsPerIP = 3
	m.newSessionBucket = newTokenBucket(1000, 1000)
	ip := net.ParseIP("198.51.100.1")
	for port := 1; port <= 3; port++ {
		if _, ok := m.openPending(&net.UDPAddr{IP: ip, Port: port}); !ok {
			t.Fatalf("session %d from one IP refused", port)
		}
	}
	if _, ok := m.openPending(&net.UDPAddr{IP: ip, Port: 4}); ok {
		t.Fatal("per-IP limit not enforced")
	}
	m.removeSession((&net.UDPAddr{IP: ip, Port: 1}).String())
	if _, ok := m.openPending(&net.UDPAddr{IP: ip, Port: 4}); !ok {
		t.Fatal("slot not released after removeSession")
	}
	other := net.ParseIP("198.51.100.2")
	for port := 1; port <= 2; port++ {
		if _, ok := m.openPending(&net.UDPAddr{IP: other, Port: port}); !ok {
			t.Fatalf("session %d from second IP refused", port)
		}
	}
	if _, ok := m.openPending(&net.UDPAddr{IP: other, Port: 3}); ok {
		t.Fatal("global limit not enforced")
	}
	if got := m.sessionCount(); got != 5 {
		t.Fatalf("sessionCount=%d, want 5", got)
	}

	bucket := newTokenBucket(10, 2)
	now := time.Now()
	if !bucket.allowAt(now) || !bucket.allowAt(now) || bucket.allowAt(now) {
		t.Fatal("token bucket burst not enforced")
	}
	if !bucket.allowAt(now.Add(100 * time.Millisecond)) {
		t.Fatal("token bucket did not refill")
	}

	m.gcOnce(time.Now().Add(pendingTimeout + time.Second))
	if got := m.sessionCount(); got != 0 {
		t.Fatalf("pending sessions survived gc: %d", got)
	}
}

func TestPendingQueueFlushesInOrder(t *testing.T) {
	backend, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	listener, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	m := newSessionManager(listener)
	addr := &net.UDPAddr{IP: net.ParseIP("203.0.113.9"), Port: 5000}
	key := addr.String()
	sess, ok := m.openPending(addr)
	if !ok {
		t.Fatal("openPending refused")
	}
	for i := 0; i < maxPendingPackets+2; i++ {
		m.queuePacket(sess, key, []byte{0xc0, 0, 0, 0, 1, byte(i)}) // Initial-like but undecryptable
	}
	sess.mu.Lock()
	queued := len(sess.pending)
	sess.mu.Unlock()
	if queued != maxPendingPackets {
		t.Fatalf("pending=%d, want %d", queued, maxPendingPackets)
	}

	bc, err := net.DialUDP("udp", nil, backend.LocalAddr().(*net.UDPAddr))
	if err != nil {
		t.Fatal(err)
	}
	if !m.attachBackend(sess, key, bc) {
		t.Fatal("attachBackend failed")
	}
	defer m.removeSession(key)
	buf := make([]byte, 64)
	for i := 0; i < maxPendingPackets; i++ {
		backend.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, _, err := backend.ReadFromUDP(buf)
		if err != nil {
			t.Fatalf("packet %d: %v", i, err)
		}
		if n != 6 || int(buf[5]) != i {
			t.Fatalf("packet %d arrived out of order: %x", i, buf[:n])
		}
	}
	sess.mu.Lock()
	leftover := len(sess.pending)
	sess.mu.Unlock()
	if leftover != 0 {
		t.Fatalf("pending queue not cleared: %d", leftover)
	}
	// Established sessions forward directly.
	m.queuePacket(sess, key, []byte{0xc0, 0, 0, 0, 1, 0xff})
	backend.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, _, err := backend.ReadFromUDP(buf)
	if err != nil || n != 6 || buf[5] != 0xff {
		t.Fatalf("direct forward failed: n=%d err=%v", n, err)
	}
}
