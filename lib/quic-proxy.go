// quic-proxy.go - Lightweight QUIC SNI transparent proxy
// Listens on UDP :443, extracts SNI from QUIC Initial packets (RFC 9000),
// then forwards UDP datagrams to the backend server.
//
// Pure Go standard library only (no external deps).
// Build: go build -o quic-proxy quic-proxy.go
// Run:   ./quic-proxy -l :443

package main

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	quicVersion1      = 0x00000001
	longHeaderForm    = 0x80
	initialPacketType = 0x00 // bits 4-5 of first byte = 00
	initialSaltV1     = "\x38\x76\x2c\xf7\xf5\x59\x34\xb3\x4d\x17\x9a\xe6\xa4\xc8\x0c\xad\xcc\xbb\x7f\x0a"
	tagSize           = 16

	// Resource limits. The listener is reachable from the public Internet and
	// UDP source addresses can be spoofed, so every per-client allocation is
	// bounded.
	defaultMaxSessions      = 4096 // total concurrent sessions
	defaultMaxSessionsPerIP = 64   // concurrent sessions per client IP
	defaultNewSessionRate   = 200  // new sessions per second (token bucket)
	maxPendingPackets       = 8    // datagrams queued while a session is being set up
	maxCryptoBytes          = 16 * 1024
	maxCryptoSegments       = 64
	pendingTimeout          = 3 * time.Second
	// QUIC datagrams never exceed the path MTU (RFC 9000 §14, at most 1500
	// bytes on every path this proxy sits on), so 2 KB is enough per session.
	datagramBufSize = 2048
	maxSNILogLen    = 253
	logInterval     = time.Minute
)

var (
	listenAddr  = flag.String("l", ":443", "Listen address (UDP)")
	idleTimeout = flag.Duration("idle-timeout", 300*time.Second, "UDP session idle timeout")
	dnsFile     = flag.String("dns-file", "/var/lib/simcard-dns-quic/remote-dns", "Overseas DNS configuration (plain IP or udp://IP:port only)")
	debug       = flag.Bool("debug", false, "Enable debug logging")

	// localIPs holds the addresses of this host; the proxy never relays to
	// itself. Filled once at startup by loadLocalIPs.
	localIPs = map[string]struct{}{}

	bufPool = sync.Pool{New: func() any {
		b := make([]byte, datagramBufSize)
		return &b
	}}

	// rejectLog limits "rejected / failed" log lines to one per minute per
	// client IP so a flood cannot fill the journal.
	rejectLog = newLogLimiter(logInterval)
)

type Session struct {
	clientAddr   *net.UDPAddr
	ipKey        string
	backendConn  *net.UDPConn // nil while the session is being established
	lastActivity time.Time
	created      time.Time
	mu           sync.Mutex

	// Establishing state (only meaningful while backendConn == nil).
	pending [][]byte         // datagrams waiting for the backend connection
	crypto  *cryptoAssembler // CRYPTO fragments collected from Initial packets
	sni     string           // set once the ClientHello yielded a server name
	failed  bool             // setup failed; kept briefly as a negative cache
}

type SessionManager struct {
	sessions map[string]*Session
	perIP    map[string]int
	mu       sync.RWMutex
	listener *net.UDPConn

	maxSessions      int
	maxSessionsPerIP int
	newSessionBucket *tokenBucket
	// connect establishes the backend side of a pending session; tests
	// replace it to observe the handoff without touching the network.
	connect func(sess *Session, key, sni string)
}

func newSessionManager(listener *net.UDPConn) *SessionManager {
	m := &SessionManager{
		sessions:         make(map[string]*Session),
		perIP:            make(map[string]int),
		listener:         listener,
		maxSessions:      defaultMaxSessions,
		maxSessionsPerIP: defaultMaxSessionsPerIP,
		newSessionBucket: newTokenBucket(defaultNewSessionRate, defaultNewSessionRate),
	}
	m.connect = m.connectSession
	return m
}

func main() {
	flag.Parse()
	if *debug {
		log.SetFlags(log.LstdFlags | log.Lshortfile)
	}

	addr, err := net.ResolveUDPAddr("udp", *listenAddr)
	if err != nil {
		log.Fatalf("ResolveUDPAddr error: %v", err)
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		log.Fatalf("ListenUDP error: %v", err)
	}
	defer conn.Close()

	loadLocalIPs()
	if _, err := parseDNSFile(*dnsFile); err != nil {
		log.Printf("dns-file %s: %v (lookups will fail until it is fixed)", *dnsFile, err)
	}

	log.Printf("QUIC SNI Proxy listening on UDP %s", *listenAddr)

	mgr := newSessionManager(conn)
	go mgr.gcLoop()
	go watchSIGHUP()

	buf := make([]byte, 65535)
	for {
		n, clientAddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			if !os.IsTimeout(err) {
				log.Printf("ReadFromUDP error: %v", err)
			}
			continue
		}
		// Hot path: forward to an existing session inline (no goroutine, no
		// per-packet allocation, preserves datagram order). Only the one-off
		// session setup (DNS + dial) is offloaded to a goroutine.
		key := clientAddr.String()
		mgr.mu.RLock()
		sess, exists := mgr.sessions[key]
		mgr.mu.RUnlock()
		if exists {
			sess.mu.Lock()
			sess.lastActivity = time.Now()
			bc := sess.backendConn
			sess.mu.Unlock()
			if bc != nil {
				if _, err := bc.Write(buf[:n]); err != nil {
					log.Printf("[%s] Write to backend error: %v", key, err)
				}
				continue
			}
			mgr.queuePacket(sess, key, buf[:n])
			continue
		}
		if !looksLikeInitial(buf[:n]) {
			if *debug {
				log.Printf("[%s] Not a QUIC Initial, drop", key)
			}
			continue
		}
		sess, ok := mgr.openPending(clientAddr)
		if !ok {
			continue
		}
		mgr.queuePacket(sess, key, buf[:n])
	}
}

// watchSIGHUP keeps `systemctl reload` from killing the process. The DNS file
// is read on every lookup, so a reload only re-validates it and logs the
// result.
func watchSIGHUP() {
	hup := make(chan os.Signal, 1)
	signal.Notify(hup, syscall.SIGHUP)
	for range hup {
		servers, err := parseDNSFile(*dnsFile)
		if err != nil {
			log.Printf("SIGHUP: dns-file %s invalid: %v", *dnsFile, err)
			continue
		}
		log.Printf("SIGHUP: reloaded dns-file %s (%d servers)", *dnsFile, len(servers))
	}
}

// loadLocalIPs records this host's own addresses so SNI can never steer a
// session back to the proxy host.
func loadLocalIPs() {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		log.Printf("InterfaceAddrs error: %v", err)
		return
	}
	for _, a := range addrs {
		var ip net.IP
		switch v := a.(type) {
		case *net.IPNet:
			ip = v.IP
		case *net.IPAddr:
			ip = v.IP
		}
		if ip != nil {
			localIPs[ip.String()] = struct{}{}
		}
	}
}

// looksLikeInitial is the cheap pre-check applied to datagrams from unknown
// clients before any session state is allocated for them.
func looksLikeInitial(data []byte) bool {
	if len(data) < 5 || data[0]&longHeaderForm == 0 {
		return false
	}
	if binary.BigEndian.Uint32(data[1:5]) != quicVersion1 {
		return false
	}
	return (data[0]&0x30)>>4 == initialPacketType
}

// openPending registers a new session in the establishing state. It enforces
// the new-session rate, the global and the per-IP limits.
func (m *SessionManager) openPending(clientAddr *net.UDPAddr) (*Session, bool) {
	key := clientAddr.String()
	ipKey := clientAddr.IP.String()
	if !m.newSessionBucket.allow() {
		if rejectLog.allow(ipKey) {
			log.Printf("[%s] New session rate limit reached, drop", key)
		}
		return nil, false
	}
	now := time.Now()
	sess := &Session{
		clientAddr:   clientAddr,
		ipKey:        ipKey,
		lastActivity: now,
		created:      now,
		crypto:       &cryptoAssembler{},
	}
	m.mu.Lock()
	if existing, ok := m.sessions[key]; ok {
		m.mu.Unlock()
		return existing, true
	}
	if len(m.sessions) >= m.maxSessions {
		m.mu.Unlock()
		if rejectLog.allow(ipKey) {
			log.Printf("[%s] Session limit (%d) reached, drop", key, m.maxSessions)
		}
		return nil, false
	}
	if m.perIP[ipKey] >= m.maxSessionsPerIP {
		m.mu.Unlock()
		if rejectLog.allow(ipKey) {
			log.Printf("[%s] Per-IP session limit (%d) reached, drop", key, m.maxSessionsPerIP)
		}
		return nil, false
	}
	m.sessions[key] = sess
	m.perIP[ipKey]++
	m.mu.Unlock()
	return sess, true
}

// queuePacket handles a datagram for a session that is still being
// established: the datagram is queued for the backend and, until the SNI is
// known, its CRYPTO fragments are collected to reassemble the ClientHello.
func (m *SessionManager) queuePacket(sess *Session, key string, pkt []byte) {
	sess.mu.Lock()
	sess.lastActivity = time.Now()
	if bc := sess.backendConn; bc != nil {
		sess.mu.Unlock()
		if _, err := bc.Write(pkt); err != nil {
			log.Printf("[%s] Write to backend error: %v", key, err)
		}
		return
	}
	if sess.failed {
		sess.mu.Unlock()
		return
	}
	if len(sess.pending) < maxPendingPackets {
		sess.pending = append(sess.pending, append([]byte(nil), pkt...))
	} else if *debug {
		log.Printf("[%s] Pending queue full, drop", key)
	}
	if sess.sni != "" {
		sess.mu.Unlock()
		return
	}
	frags, ok := decryptInitialCrypto(pkt)
	if !ok {
		sess.mu.Unlock()
		return
	}
	for _, f := range frags {
		if !sess.crypto.add(f) {
			m.failPendingLocked(sess)
			sess.mu.Unlock()
			if rejectLog.allow(sess.ipKey) {
				log.Printf("[%s] CRYPTO data exceeds %d bytes, drop", key, maxCryptoBytes)
			}
			return
		}
	}
	sni, status := sess.crypto.clientHelloSNI()
	switch status {
	case helloComplete:
		sess.sni = sni
		sess.crypto = nil
		sess.mu.Unlock()
		go m.connect(sess, key, sni)
	case helloInvalid:
		m.failPendingLocked(sess)
		sess.mu.Unlock()
		if rejectLog.allow(sess.ipKey) {
			log.Printf("[%s] Invalid ClientHello, drop", key)
		}
	default:
		sess.mu.Unlock()
	}
}

// failPendingLocked marks a pending session as failed and drops its queue.
// The entry stays in the map until gcLoop removes it after pendingTimeout, so
// a retransmitting peer does not restart DNS lookups on every datagram.
func (m *SessionManager) failPendingLocked(sess *Session) {
	sess.failed = true
	sess.pending = nil
	sess.crypto = nil
}

func (m *SessionManager) failPending(sess *Session) {
	sess.mu.Lock()
	m.failPendingLocked(sess)
	sess.mu.Unlock()
}

// connectSession resolves the SNI and dials the backend for a pending session.
func (m *SessionManager) connectSession(sess *Session, key, sni string) {
	ips, err := lookupBackendIPv4(sni, *dnsFile)
	if err != nil || len(ips) == 0 {
		m.failPending(sess)
		if rejectLog.allow(sess.ipKey) {
			log.Printf("[%s] DNS lookup failed for %s: %v", key, sniForLog(sni), err)
		}
		return
	}
	backendIP, ok := selectBackendIPv4(ips)
	if !ok {
		m.failPending(sess)
		if rejectLog.allow(sess.ipKey) {
			log.Printf("[%s] DNS lookup for %s returned no usable IPv4 address", key, sniForLog(sni))
		}
		return
	}

	backendAddr := &net.UDPAddr{IP: backendIP, Port: 443}
	bc, err := net.DialUDP("udp", nil, backendAddr)
	if err != nil {
		m.failPending(sess)
		if rejectLog.allow(sess.ipKey) {
			log.Printf("[%s] DialUDP to %s error: %v", key, backendAddr, err)
		}
		return
	}
	if !m.attachBackend(sess, key, bc) {
		return
	}
	if *debug {
		log.Printf("[%s] New session to %s (%s)", key, sniForLog(sni), backendIP)
	}
}

// attachBackend switches a pending session to the established state and
// flushes the queued datagrams to the backend in arrival order.
func (m *SessionManager) attachBackend(sess *Session, key string, bc *net.UDPConn) bool {
	sess.mu.Lock()
	if sess.failed || sess.backendConn != nil {
		sess.mu.Unlock()
		bc.Close()
		return false
	}
	sess.backendConn = bc
	sess.lastActivity = time.Now()
	pending := sess.pending
	sess.pending = nil
	sess.crypto = nil
	for _, pkt := range pending {
		if _, err := bc.Write(pkt); err != nil {
			sess.mu.Unlock()
			log.Printf("[%s] First packet forward error: %v", key, err)
			m.removeSession(key)
			return false
		}
	}
	sess.mu.Unlock()
	go m.relayBackendToClient(sess, key)
	return true
}

// parseDNSFile reads the overseas DNS list and returns validated host:port
// strings. Never silently fall back to the host resolver or strip an
// encrypted scheme. TCP/SNI and wa-shim currently require plain UDP DNS too;
// configuration validation rejects unsupported remote transports before
// changing live files.
func parseDNSFile(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	servers := strings.Fields(strings.ReplaceAll(string(data), ",", " "))
	if len(servers) == 0 {
		return nil, fmt.Errorf("empty overseas DNS list")
	}
	addresses := make([]string, 0, len(servers))
	for _, server := range servers {
		server = strings.TrimPrefix(server, "udp://")
		if strings.Contains(server, "://") {
			return nil, fmt.Errorf("unsupported remote DNS transport")
		}
		var ip net.IP
		var port = "53"
		if strings.HasPrefix(server, "[") {
			end := strings.Index(server, "]:")
			if end < 0 {
				return nil, fmt.Errorf("invalid remote DNS endpoint: %s", server)
			}
			ip = net.ParseIP(server[1:end])
			port = server[end+2:]
		} else if parsed := net.ParseIP(server); parsed != nil {
			ip = parsed
		} else {
			colon := strings.LastIndex(server, ":")
			if colon <= 0 {
				return nil, fmt.Errorf("remote DNS endpoint must use an IP address: %s", server)
			}
			ip = net.ParseIP(server[:colon])
			port = server[colon+1:]
		}
		if ip == nil || port == "" {
			return nil, fmt.Errorf("invalid remote DNS endpoint: %s", server)
		}
		portNum, scanErr := strconv.Atoi(port)
		if scanErr != nil || portNum < 1 || portNum > 65535 {
			return nil, fmt.Errorf("invalid remote DNS port: %s", port)
		}
		addresses = append(addresses, net.JoinHostPort(ip.String(), port))
	}
	return addresses, nil
}

func lookupBackendIPv4(host, path string) ([]net.IP, error) {
	addresses, err := parseDNSFile(path)
	if err != nil {
		return nil, err
	}
	var last error
	for _, address := range addresses {
		resolver := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, ignored string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "udp", address)
		}}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		ips, err := resolver.LookupIP(ctx, "ip4", host)
		cancel()
		if err == nil && len(ips) > 0 {
			return ips, nil
		}
		last = err
	}
	return nil, fmt.Errorf("configured overseas DNS lookup failed: %v", last)
}

// forbiddenBackend reports whether an SNI-derived destination must never be
// relayed to: loopback, private, link-local, unspecified, multicast,
// broadcast, and the proxy host's own addresses.
func forbiddenBackend(ip net.IP) bool {
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsUnspecified() || ip.IsMulticast() || ip.Equal(net.IPv4bcast) {
		return true
	}
	if ip4 := ip.To4(); ip4 != nil && ip4[0] == 0 {
		return true // 0.0.0.0/8 "this network"
	}
	_, local := localIPs[ip.String()]
	return local
}

func selectBackendIPv4(ips []net.IP) (net.IP, bool) {
	for _, ip := range ips {
		ip4 := ip.To4()
		if ip4 == nil || forbiddenBackend(ip4) {
			continue
		}
		return ip4, true
	}
	return nil, false
}

func (m *SessionManager) relayBackendToClient(sess *Session, key string) {
	bufp := bufPool.Get().(*[]byte)
	defer bufPool.Put(bufp)
	buf := *bufp
	for {
		n, err := sess.backendConn.Read(buf)
		if err != nil {
			if *debug {
				log.Printf("[%s] Backend read error: %v", key, err)
			}
			m.removeSession(key)
			return
		}
		sess.mu.Lock()
		sess.lastActivity = time.Now()
		sess.mu.Unlock()
		if _, err := m.listener.WriteToUDP(buf[:n], sess.clientAddr); err != nil {
			log.Printf("[%s] WriteToUDP error: %v", key, err)
			m.removeSession(key)
			return
		}
	}
}

func (m *SessionManager) removeSession(key string) {
	m.mu.Lock()
	sess, ok := m.sessions[key]
	if ok {
		delete(m.sessions, key)
		if m.perIP[sess.ipKey] <= 1 {
			delete(m.perIP, sess.ipKey)
		} else {
			m.perIP[sess.ipKey]--
		}
	}
	m.mu.Unlock()
	if !ok {
		return
	}
	sess.mu.Lock()
	bc := sess.backendConn
	sess.failed = true
	sess.pending = nil
	sess.crypto = nil
	sess.mu.Unlock()
	if bc != nil {
		bc.Close()
	}
}

func (m *SessionManager) gcLoop() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for range ticker.C {
		m.gcOnce(time.Now())
		rejectLog.prune(time.Now())
	}
}

// gcOnce drops idle established sessions and pending sessions that did not
// finish (or failed) within pendingTimeout.
func (m *SessionManager) gcOnce(now time.Time) {
	var keys []string
	m.mu.RLock()
	for k, s := range m.sessions {
		s.mu.Lock()
		expired := false
		if s.backendConn == nil {
			expired = now.Sub(s.created) > pendingTimeout
		} else {
			expired = now.Sub(s.lastActivity) > *idleTimeout
		}
		s.mu.Unlock()
		if expired {
			keys = append(keys, k)
		}
	}
	m.mu.RUnlock()
	for _, k := range keys {
		m.removeSession(k)
		if *debug {
			log.Printf("[%s] GC session", k)
		}
	}
}

func (m *SessionManager) sessionCount() int {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return len(m.sessions)
}

// sniForLog renders a peer-supplied server name safely for the journal.
func sniForLog(sni string) string {
	if len(sni) > maxSNILogLen {
		sni = sni[:maxSNILogLen] + "..."
	}
	return strconv.Quote(sni)
}

// tokenBucket is a minimal rate limiter for new-session admission.
type tokenBucket struct {
	mu     sync.Mutex
	tokens float64
	burst  float64
	rate   float64 // tokens per second
	last   time.Time
}

func newTokenBucket(rate, burst float64) *tokenBucket {
	return &tokenBucket{tokens: burst, burst: burst, rate: rate, last: time.Now()}
}

func (b *tokenBucket) allow() bool {
	return b.allowAt(time.Now())
}

func (b *tokenBucket) allowAt(now time.Time) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.tokens += now.Sub(b.last).Seconds() * b.rate
	b.last = now
	if b.tokens > b.burst {
		b.tokens = b.burst
	}
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// logLimiter allows one log line per key per interval.
type logLimiter struct {
	mu       sync.Mutex
	interval time.Duration
	last     map[string]time.Time
}

func newLogLimiter(interval time.Duration) *logLimiter {
	return &logLimiter{interval: interval, last: make(map[string]time.Time)}
}

func (l *logLimiter) allow(key string) bool {
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	if t, ok := l.last[key]; ok && now.Sub(t) < l.interval {
		return false
	}
	if len(l.last) >= 8192 {
		l.pruneLocked(now)
	}
	l.last[key] = now
	return true
}

func (l *logLimiter) prune(now time.Time) {
	l.mu.Lock()
	l.pruneLocked(now)
	l.mu.Unlock()
}

func (l *logLimiter) pruneLocked(now time.Time) {
	for k, t := range l.last {
		if now.Sub(t) >= l.interval {
			delete(l.last, k)
		}
	}
}

// cryptoFragment is the payload of one CRYPTO frame at its stream offset.
type cryptoFragment struct {
	offset uint64
	data   []byte
}

// cryptoAssembler collects CRYPTO fragments (possibly out of order and spread
// over several Initial packets) and exposes the contiguous prefix.
type cryptoAssembler struct {
	segs []cryptoFragment
}

func (a *cryptoAssembler) add(f cryptoFragment) bool {
	if len(f.data) == 0 {
		return true
	}
	if f.offset > maxCryptoBytes || uint64(len(f.data)) > maxCryptoBytes-f.offset {
		return false
	}
	if len(a.segs) >= maxCryptoSegments {
		return false
	}
	a.segs = append(a.segs, cryptoFragment{offset: f.offset, data: append([]byte(nil), f.data...)})
	return true
}

// contiguous returns the bytes available from offset 0 up to the first gap.
func (a *cryptoAssembler) contiguous() []byte {
	segs := append([]cryptoFragment(nil), a.segs...)
	sort.Slice(segs, func(i, j int) bool { return segs[i].offset < segs[j].offset })
	var out []byte
	for _, s := range segs {
		end := uint64(len(out))
		if s.offset > end {
			break
		}
		if s.offset+uint64(len(s.data)) <= end {
			continue
		}
		out = append(out, s.data[end-s.offset:]...)
	}
	return out
}

func (a *cryptoAssembler) clientHelloSNI() (string, helloStatus) {
	return parseClientHelloSNI(a.contiguous())
}

type helloStatus int

const (
	helloIncomplete helloStatus = iota // need more CRYPTO data
	helloComplete                      // SNI found
	helloInvalid                       // not a ClientHello or no server name
)

// extractSNI decrypts a single QUIC v1 Initial packet and returns the SNI
// hostname when the whole ClientHello is inside it.
func extractSNI(data []byte) (string, bool) {
	frags, ok := decryptInitialCrypto(data)
	if !ok {
		return "", false
	}
	a := &cryptoAssembler{}
	for _, f := range frags {
		if !a.add(f) {
			return "", false
		}
	}
	sni, status := a.clientHelloSNI()
	return sni, status == helloComplete
}

// decryptInitialCrypto decrypts a QUIC v1 Initial packet and returns the
// CRYPTO fragments it carries. The input is never modified.
func decryptInitialCrypto(data []byte) ([]cryptoFragment, bool) {
	if !looksLikeInitial(data) {
		return nil, false
	}

	off := 5
	if len(data) < off+1 {
		return nil, false
	}
	dcidLen := int(data[off])
	off++
	if len(data) < off+dcidLen {
		return nil, false
	}
	dcid := data[off : off+dcidLen]
	off += dcidLen

	if len(data) < off+1 {
		return nil, false
	}
	scidLen := int(data[off])
	off++
	if len(data) < off+scidLen {
		return nil, false
	}
	off += scidLen

	tokenLen, n := readVarint(data[off:])
	if n == 0 || uint64(len(data)-off-n) < tokenLen {
		return nil, false
	}
	off += n + int(tokenLen)

	length, n := readVarint(data[off:])
	if n == 0 || uint64(len(data)-off-n) < length {
		return nil, false
	}
	off += n
	protected := data[off : off+int(length)]

	// Derive keys
	initialSecret := hkdfExtract([]byte(initialSaltV1), dcid)
	clientInitialSecret := hkdfExpandLabel(initialSecret, "client in", nil, 32)
	key := hkdfExpandLabel(clientInitialSecret, "quic key", nil, 16)
	iv := hkdfExpandLabel(clientInitialSecret, "quic iv", nil, 12)
	hp := hkdfExpandLabel(clientInitialSecret, "quic hp", nil, 16)

	// Header protection (AES-128-ECB)
	hpCipher, err := aes.NewCipher(hp)
	if err != nil {
		return nil, false
	}
	if len(protected) < 5 {
		return nil, false
	}
	sampleOffset := 4
	if len(protected) < sampleOffset+16 {
		sampleOffset = 0
	}
	if sampleOffset+16 > len(protected) {
		return nil, false
	}
	sample := protected[sampleOffset : sampleOffset+16]
	mask := make([]byte, 16)
	hpCipher.Encrypt(mask, sample)

	// RFC 9001 §5.4.1: long headers only protect the low 4 bits.
	firstByte := data[0] ^ (mask[0] & 0x0f)
	pnLen := int(firstByte&0x03) + 1
	if len(protected) < pnLen {
		return nil, false
	}
	packetNumber := make([]byte, pnLen)
	for i := 0; i < pnLen; i++ {
		packetNumber[i] = protected[i] ^ mask[1+i]
	}

	// Nonce = iv XOR packet_number (left-padded)
	nonce := make([]byte, 12)
	copy(nonce, iv)
	for i := 0; i < pnLen; i++ {
		nonce[11-i] ^= packetNumber[pnLen-1-i]
	}

	// AEAD decrypt
	aesBlock, err := aes.NewCipher(key)
	if err != nil {
		return nil, false
	}
	aead, err := cipher.NewGCM(aesBlock)
	if err != nil {
		return nil, false
	}

	aad := make([]byte, off+pnLen)
	copy(aad, data[:off+pnLen])
	aad[0] = firstByte
	copy(aad[off:], packetNumber)

	ciphertext := protected[pnLen:]
	if len(ciphertext) < tagSize {
		return nil, false
	}
	plaintext, err := aead.Open(nil, nonce, ciphertext, aad)
	if err != nil {
		return nil, false
	}

	return parseCryptoFrames(plaintext)
}

func readVarint(buf []byte) (uint64, int) {
	if len(buf) == 0 {
		return 0, 0
	}
	first := buf[0]
	prefix := first >> 6
	length := 1 << prefix
	if len(buf) < length {
		return 0, 0
	}
	var val uint64
	switch length {
	case 1:
		val = uint64(first & 0x3f)
	case 2:
		val = uint64(first&0x3f)<<8 | uint64(buf[1])
	case 4:
		val = uint64(first&0x3f)<<24 | uint64(buf[1])<<16 | uint64(buf[2])<<8 | uint64(buf[3])
	case 8:
		val = binary.BigEndian.Uint64(buf)
		val &= 0x3fffffffffffffff
	}
	return val, length
}

// HKDF-Extract with SHA-256 (RFC 5869)
func hkdfExtract(salt, ikm []byte) []byte {
	mac := hmac.New(sha256.New, salt)
	mac.Write(ikm)
	return mac.Sum(nil)
}

// HKDF-Expand (RFC 5869)
func hkdfExpand(prk []byte, info []byte, length int) []byte {
	var okm []byte
	var prev []byte
	n := (length + sha256.Size - 1) / sha256.Size
	for i := 1; i <= n; i++ {
		mac := hmac.New(sha256.New, prk)
		mac.Write(prev)
		mac.Write(info)
		mac.Write([]byte{byte(i)})
		prev = mac.Sum(nil)
		okm = append(okm, prev...)
	}
	return okm[:length]
}

// HKDF-Expand-Label (RFC 8446)
func hkdfExpandLabel(secret []byte, label string, context []byte, length int) []byte {
	qlabel := "tls13 " + label
	lbl := make([]byte, 0, 2+1+len(qlabel)+1+len(context))
	lbl = append(lbl, byte(length>>8), byte(length))
	lbl = append(lbl, byte(len(qlabel)))
	lbl = append(lbl, qlabel...)
	lbl = append(lbl, byte(len(context)))
	lbl = append(lbl, context...)
	return hkdfExpand(secret, lbl, length)
}

// skipVarints advances over count varints; returns the new offset or -1.
func skipVarints(buf []byte, off, count int) int {
	for i := 0; i < count; i++ {
		_, n := readVarint(buf[off:])
		if n == 0 {
			return -1
		}
		off += n
	}
	return off
}

// parseCryptoFrames walks the frames of a decrypted Initial payload and
// returns every CRYPTO fragment with its offset (RFC 9000 §19.6). Parsing
// stops at the first malformed or unexpected frame; fragments gathered before
// that point are still returned.
func parseCryptoFrames(plaintext []byte) ([]cryptoFragment, bool) {
	var frags []cryptoFragment
	off := 0
	for off < len(plaintext) {
		frameType := plaintext[off]
		off++
		switch frameType {
		case 0x00: // PADDING
			for off < len(plaintext) && plaintext[off] == 0x00 {
				off++
			}
		case 0x01: // PING: no fields (RFC 9000 §19.2)
		case 0x06: // CRYPTO
			offset, n := readVarint(plaintext[off:])
			if n == 0 {
				return frags, len(frags) > 0
			}
			off += n
			dataLen, n := readVarint(plaintext[off:])
			if n == 0 || uint64(len(plaintext)-off-n) < dataLen {
				return frags, len(frags) > 0
			}
			off += n
			frags = append(frags, cryptoFragment{offset: offset, data: plaintext[off : off+int(dataLen)]})
			off += int(dataLen)
		case 0x02, 0x03: // ACK, ACK with ECN
			// Largest Acknowledged, ACK Delay
			if off = skipVarints(plaintext, off, 2); off < 0 {
				return frags, len(frags) > 0
			}
			ackRangeCount, n := readVarint(plaintext[off:])
			if n == 0 {
				return frags, len(frags) > 0
			}
			off += n
			// First ACK Range
			if off = skipVarints(plaintext, off, 1); off < 0 {
				return frags, len(frags) > 0
			}
			if ackRangeCount > uint64(len(plaintext)) {
				return frags, len(frags) > 0
			}
			for i := uint64(0); i < ackRangeCount; i++ {
				if off = skipVarints(plaintext, off, 2); off < 0 {
					return frags, len(frags) > 0
				}
			}
			if frameType == 0x03 {
				if off = skipVarints(plaintext, off, 3); off < 0 {
					return frags, len(frags) > 0
				}
			}
		case 0x1c, 0x1d: // CONNECTION_CLOSE
			return frags, len(frags) > 0
		default:
			if frameType&0x08 != 0 { // STREAM (not allowed in Initial, tolerated)
				if off = skipVarints(plaintext, off, 1); off < 0 {
					return frags, len(frags) > 0
				}
				if frameType&0x04 != 0 {
					if off = skipVarints(plaintext, off, 1); off < 0 {
						return frags, len(frags) > 0
					}
				}
				var dataLen uint64
				if frameType&0x02 != 0 {
					var n int
					dataLen, n = readVarint(plaintext[off:])
					if n == 0 {
						return frags, len(frags) > 0
					}
					off += n
				} else {
					dataLen = uint64(len(plaintext) - off)
				}
				if uint64(len(plaintext)-off) < dataLen {
					return frags, len(frags) > 0
				}
				off += int(dataLen)
			} else {
				return frags, len(frags) > 0
			}
		}
	}
	return frags, len(frags) > 0
}

// parseClientHelloSNI parses a TLS ClientHello from a TLS record or from QUIC
// CRYPTO handshake bytes. It distinguishes "not enough bytes yet" from
// "malformed" so a caller can keep collecting fragments.
func parseClientHelloSNI(data []byte) (string, helloStatus) {
	if len(data) == 0 {
		return "", helloIncomplete
	}
	hs := data
	if data[0] == 0x16 {
		if len(data) < 5 {
			return "", helloIncomplete
		}
		recordLen := int(binary.BigEndian.Uint16(data[3:5]))
		if len(data) < 5+recordLen {
			return "", helloIncomplete
		}
		hs = data[5 : 5+recordLen]
		if len(hs) == 0 {
			return "", helloInvalid
		}
	}
	if hs[0] != 0x01 {
		return "", helloInvalid
	}
	if len(hs) < 4 {
		return "", helloIncomplete
	}
	hsLen := int(hs[1])<<16 | int(hs[2])<<8 | int(hs[3])
	if hsLen > maxCryptoBytes {
		return "", helloInvalid
	}
	if len(hs) < 4+hsLen {
		return "", helloIncomplete
	}
	hello := hs[4 : 4+hsLen]
	if len(hello) < 34 {
		return "", helloInvalid
	}
	off := 34
	sessionIDLen := int(hello[off])
	off++
	if len(hello) < off+sessionIDLen+2 {
		return "", helloInvalid
	}
	off += sessionIDLen
	csLen := int(binary.BigEndian.Uint16(hello[off : off+2]))
	off += 2
	if len(hello) < off+csLen+1 {
		return "", helloInvalid
	}
	off += csLen
	cmLen := int(hello[off])
	off++
	if len(hello) < off+cmLen+2 {
		return "", helloInvalid
	}
	off += cmLen
	extLen := int(binary.BigEndian.Uint16(hello[off : off+2]))
	off += 2
	if len(hello) < off+extLen {
		return "", helloInvalid
	}
	extensions := hello[off : off+extLen]
	eo := 0
	for eo+4 <= len(extensions) {
		extType := binary.BigEndian.Uint16(extensions[eo : eo+2])
		extDataLen := int(binary.BigEndian.Uint16(extensions[eo+2 : eo+4]))
		if eo+4+extDataLen > len(extensions) {
			return "", helloInvalid
		}
		extData := extensions[eo+4 : eo+4+extDataLen]
		if extType == 0x0000 {
			if len(extData) < 2 {
				return "", helloInvalid
			}
			sniListLen := int(binary.BigEndian.Uint16(extData[0:2]))
			if sniListLen > len(extData)-2 {
				return "", helloInvalid
			}
			sniData := extData[2 : 2+sniListLen]
			if len(sniData) < 3 || sniData[0] != 0x00 {
				return "", helloInvalid
			}
			sniLen := int(binary.BigEndian.Uint16(sniData[1:3]))
			if sniLen == 0 || sniLen > len(sniData)-3 {
				return "", helloInvalid
			}
			return string(sniData[3 : 3+sniLen]), helloComplete
		}
		eo += 4 + extDataLen
	}
	return "", helloInvalid
}
