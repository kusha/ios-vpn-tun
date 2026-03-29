package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/bschaatsbergen/dnsdialer"
	"github.com/cbeuw/connutil"
	"github.com/pion/dtls/v3"
	"github.com/pion/dtls/v3/pkg/crypto/selfsign"
	"github.com/pion/logging"
	"github.com/pion/turn/v5"
)

type getCredsFunc func(string) (string, string, string, error)

type proxyConfig struct {
	Peer     string `json:"peer"`
	VKLink   string `json:"vkLink"`
	Listen   string `json:"listen"`
	Streams  int    `json:"streams"`
	UDP      bool   `json:"udp"`
	TurnHost string `json:"turnHost,omitempty"`
	TurnPort string `json:"turnPort,omitempty"`
	Direct   bool   `json:"direct,omitempty"`
}

type proxyInstance struct {
	handle    int32
	cfg       proxyConfig
	ctx       context.Context
	cancel    context.CancelFunc
	wg        sync.WaitGroup
	statusMu  sync.RWMutex
	state     string
	lastError string
}

type turnParams struct {
	host      string
	port      string
	link      string
	udp       bool
	getCreds  getCredsFunc
	reportErr func(error)
}

type connectedUDPConn struct {
	*net.UDPConn
}

func (c *connectedUDPConn) WriteTo(p []byte, _ net.Addr) (int, error) {
	return c.Write(p)
}

func newProxyInstance(cfg proxyConfig) (*proxyInstance, error) {
	if cfg.Peer == "" {
		return nil, errors.New("peer is required")
	}
	if cfg.VKLink == "" {
		return nil, errors.New("vkLink is required")
	}
	if cfg.Listen == "" {
		cfg.Listen = "127.0.0.1:9000"
	}
	if cfg.Streams <= 0 {
		cfg.Streams = 16
	}

	ctx, cancel := context.WithCancel(context.Background())
	return &proxyInstance{
		cfg:    cfg,
		ctx:    ctx,
		cancel: cancel,
		state:  "created",
	}, nil
}

func (p *proxyInstance) start() {
	p.setState("starting")
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		p.run()
	}()
}

func (p *proxyInstance) stop() {
	p.cancel()
	p.wg.Wait()
	p.setState("stopped")
}

func (p *proxyInstance) run() {
	peer, err := net.ResolveUDPAddr("udp", p.cfg.Peer)
	if err != nil {
		p.setError(fmt.Errorf("resolve peer: %w", err))
		return
	}

	link := normalizeVKLink(p.cfg.VKLink)
	if link == "" {
		p.setError(errors.New("invalid vkLink"))
		return
	}

	dialer := dnsdialer.New(
		dnsdialer.WithResolvers("77.88.8.8:53", "77.88.8.1:53", "8.8.8.8:53", "8.8.4.4:53", "1.1.1.1:53"),
		dnsdialer.WithStrategy(dnsdialer.Fallback{}),
		dnsdialer.WithCache(100, 10*time.Hour, 10*time.Hour),
	)

	params := &turnParams{
		host:      p.cfg.TurnHost,
		port:      p.cfg.TurnPort,
		link:      link,
		udp:       p.cfg.UDP,
		reportErr: p.setError,
		getCreds: func(s string) (string, string, string, error) {
			return getVKCreds(s, dialer)
		},
	}

	listenConn, err := net.ListenPacket("udp", p.cfg.Listen)
	if err != nil {
		p.setError(fmt.Errorf("listen: %w", err))
		return
	}
	defer func() {
		_ = listenConn.Close()
	}()

	go func() {
		<-p.ctx.Done()
		_ = listenConn.Close()
	}()

	listenConnChan := make(chan net.PacketConn)
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		for {
			select {
			case <-p.ctx.Done():
				return
			case listenConnChan <- listenConn:
			}
		}
	}()

	p.setState("running")

	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()

	var workers sync.WaitGroup
	if p.cfg.Direct {
		for i := 0; i < p.cfg.Streams; i++ {
			workers.Add(1)
			go func() {
				defer workers.Done()
				oneTurnConnectionLoop(p.ctx, params, peer, listenConnChan, ticker.C)
			}()
		}
	} else {
		okchan := make(chan struct{}, 1)
		connchan := make(chan net.PacketConn)

		workers.Add(1)
		go func() {
			defer workers.Done()
			oneDTLSConnectionLoop(p.ctx, peer, listenConnChan, connchan, okchan, p.setError)
		}()

		workers.Add(1)
		go func() {
			defer workers.Done()
			oneTurnConnectionLoop(p.ctx, params, peer, connchan, ticker.C)
		}()

		select {
		case <-okchan:
		case <-p.ctx.Done():
		}

		for i := 0; i < p.cfg.Streams-1; i++ {
			nextConnChan := make(chan net.PacketConn)
			workers.Add(1)
			go func(localConnChan chan net.PacketConn) {
				defer workers.Done()
				oneDTLSConnectionLoop(p.ctx, peer, listenConnChan, localConnChan, nil, p.setError)
			}(nextConnChan)

			workers.Add(1)
			go func(localConnChan chan net.PacketConn) {
				defer workers.Done()
				oneTurnConnectionLoop(p.ctx, params, peer, localConnChan, ticker.C)
			}(nextConnChan)
		}
	}

	<-p.ctx.Done()
	workers.Wait()
}

func (p *proxyInstance) setState(state string) {
	p.statusMu.Lock()
	defer p.statusMu.Unlock()
	p.state = state
}

func (p *proxyInstance) setError(err error) {
	if err == nil {
		return
	}
	p.statusMu.Lock()
	defer p.statusMu.Unlock()
	p.lastError = err.Error()
}

func (p *proxyInstance) statusJSON() string {
	p.statusMu.RLock()
	defer p.statusMu.RUnlock()
	status := map[string]any{
		"state": p.state,
		"error": p.lastError,
	}
	b, err := json.Marshal(status)
	if err != nil {
		return `{"state":"error","error":"marshal status failed"}`
	}
	return string(b)
}

func normalizeVKLink(link string) string {
	part := link
	if strings.Contains(part, "join/") {
		split := strings.Split(part, "join/")
		part = split[len(split)-1]
	}
	if idx := strings.IndexAny(part, "/?#"); idx != -1 {
		part = part[:idx]
	}
	return strings.TrimSpace(part)
}

func dtlsFunc(ctx context.Context, conn net.PacketConn, peer *net.UDPAddr) (net.Conn, error) {
	certificate, err := selfsign.GenerateSelfSigned()
	if err != nil {
		return nil, err
	}
	config := &dtls.Config{
		Certificates:          []tls.Certificate{certificate},
		InsecureSkipVerify:    true,
		ExtendedMasterSecret:  dtls.RequireExtendedMasterSecret,
		CipherSuites:          []dtls.CipherSuiteID{dtls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256},
		ConnectionIDGenerator: dtls.OnlySendCIDGenerator(),
	}

	handshakeCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	dtlsConn, err := dtls.Client(conn, peer, config)
	if err != nil {
		return nil, err
	}

	if err := dtlsConn.HandshakeContext(handshakeCtx); err != nil {
		return nil, err
	}

	return dtlsConn, nil
}

func oneDTLSConnection(
	ctx context.Context,
	peer *net.UDPAddr,
	listenConn net.PacketConn,
	connchan chan<- net.PacketConn,
	okchan chan<- struct{},
) error {
	dtlsctx, dtlscancel := context.WithCancel(ctx)
	defer dtlscancel()

	conn1, conn2 := connutil.AsyncPacketPipe()

	go func() {
		for {
			select {
			case <-dtlsctx.Done():
				return
			case connchan <- conn2:
			}
		}
	}()

	dtlsConn, err := dtlsFunc(dtlsctx, conn1, peer)
	if err != nil {
		return fmt.Errorf("connect dtls: %w", err)
	}
	defer func() {
		_ = dtlsConn.Close()
	}()

	go func() {
		if okchan == nil {
			return
		}
		for {
			select {
			case <-dtlsctx.Done():
				return
			case okchan <- struct{}{}:
			}
		}
	}()

	var wg sync.WaitGroup
	wg.Add(2)
	context.AfterFunc(dtlsctx, func() {
		_ = listenConn.SetDeadline(time.Now())
		_ = dtlsConn.SetDeadline(time.Now())
	})

	var addr atomic.Value

	go func() {
		defer wg.Done()
		defer dtlscancel()
		buf := make([]byte, 1600)
		for {
			select {
			case <-dtlsctx.Done():
				return
			default:
			}
			n, addr1, readErr := listenConn.ReadFrom(buf)
			if readErr != nil {
				return
			}
			addr.Store(addr1)
			if _, writeErr := dtlsConn.Write(buf[:n]); writeErr != nil {
				return
			}
		}
	}()

	go func() {
		defer wg.Done()
		defer dtlscancel()
		buf := make([]byte, 1600)
		for {
			select {
			case <-dtlsctx.Done():
				return
			default:
			}
			n, readErr := dtlsConn.Read(buf)
			if readErr != nil {
				return
			}
			addr1, ok := addr.Load().(net.Addr)
			if !ok {
				continue
			}
			if _, writeErr := listenConn.WriteTo(buf[:n], addr1); writeErr != nil {
				return
			}
		}
	}()

	wg.Wait()
	_ = listenConn.SetDeadline(time.Time{})
	_ = dtlsConn.SetDeadline(time.Time{})
	return nil
}

func oneTurnConnection(ctx context.Context, params *turnParams, peer *net.UDPAddr, conn2 net.PacketConn) error {
	user, pass, url, err := params.getCreds(params.link)
	if err != nil {
		return fmt.Errorf("get turn credentials: %w", err)
	}

	urlhost, urlport, err := net.SplitHostPort(url)
	if err != nil {
		return fmt.Errorf("parse turn server address: %w", err)
	}
	if params.host != "" {
		urlhost = params.host
	}
	if params.port != "" {
		urlport = params.port
	}

	turnServerAddr := net.JoinHostPort(urlhost, urlport)
	turnServerUDPAddr, err := net.ResolveUDPAddr("udp", turnServerAddr)
	if err != nil {
		return fmt.Errorf("resolve turn server address: %w", err)
	}
	turnServerAddr = turnServerUDPAddr.String()

	dialCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var turnConn net.PacketConn
	if params.udp {
		conn, dialErr := net.DialUDP("udp", nil, turnServerUDPAddr)
		if dialErr != nil {
			return fmt.Errorf("connect turn server udp: %w", dialErr)
		}
		defer func() {
			_ = conn.Close()
		}()
		turnConn = &connectedUDPConn{conn}
	} else {
		conn, dialErr := (&net.Dialer{}).DialContext(dialCtx, "tcp", turnServerAddr)
		if dialErr != nil {
			return fmt.Errorf("connect turn server tcp: %w", dialErr)
		}
		defer func() {
			_ = conn.Close()
		}()
		turnConn = turn.NewSTUNConn(conn)
	}

	requestedAddrFamily := turn.RequestedAddressFamilyIPv6
	if peer.IP.To4() != nil {
		requestedAddrFamily = turn.RequestedAddressFamilyIPv4
	}

	client, err := turn.NewClient(&turn.ClientConfig{
		STUNServerAddr:         turnServerAddr,
		TURNServerAddr:         turnServerAddr,
		Conn:                   turnConn,
		Username:               user,
		Password:               pass,
		RequestedAddressFamily: requestedAddrFamily,
		LoggerFactory:          logging.NewDefaultLoggerFactory(),
	})
	if err != nil {
		return fmt.Errorf("create turn client: %w", err)
	}
	defer client.Close()

	if err := client.Listen(); err != nil {
		return fmt.Errorf("turn listen: %w", err)
	}

	relayConn, err := client.Allocate()
	if err != nil {
		return fmt.Errorf("turn allocate: %w", err)
	}
	defer func() {
		_ = relayConn.Close()
	}()

	turnCtx, turnCancel := context.WithCancel(ctx)
	defer turnCancel()

	context.AfterFunc(turnCtx, func() {
		_ = relayConn.SetDeadline(time.Now())
		_ = conn2.SetDeadline(time.Now())
	})

	var wg sync.WaitGroup
	wg.Add(2)

	var addr atomic.Value

	go func() {
		defer wg.Done()
		defer turnCancel()
		buf := make([]byte, 1600)
		for {
			select {
			case <-turnCtx.Done():
				return
			default:
			}
			n, addr1, readErr := conn2.ReadFrom(buf)
			if readErr != nil {
				return
			}
			addr.Store(addr1)
			if _, writeErr := relayConn.WriteTo(buf[:n], peer); writeErr != nil {
				return
			}
		}
	}()

	go func() {
		defer wg.Done()
		defer turnCancel()
		buf := make([]byte, 1600)
		for {
			select {
			case <-turnCtx.Done():
				return
			default:
			}
			n, _, readErr := relayConn.ReadFrom(buf)
			if readErr != nil {
				return
			}
			addr1, ok := addr.Load().(net.Addr)
			if !ok {
				continue
			}
			if _, writeErr := conn2.WriteTo(buf[:n], addr1); writeErr != nil {
				return
			}
		}
	}()

	wg.Wait()
	_ = relayConn.SetDeadline(time.Time{})
	_ = conn2.SetDeadline(time.Time{})
	return nil
}

func oneDTLSConnectionLoop(
	ctx context.Context,
	peer *net.UDPAddr,
	listenConnChan <-chan net.PacketConn,
	connchan chan<- net.PacketConn,
	okchan chan<- struct{},
	reportErr func(error),
) {
	for {
		select {
		case <-ctx.Done():
			return
		case listenConn := <-listenConnChan:
			if err := oneDTLSConnection(ctx, peer, listenConn, connchan, okchan); err != nil && reportErr != nil {
				reportErr(err)
			}
		}
	}
}

func oneTurnConnectionLoop(
	ctx context.Context,
	params *turnParams,
	peer *net.UDPAddr,
	connchan <-chan net.PacketConn,
	ticks <-chan time.Time,
) {
	for {
		select {
		case <-ctx.Done():
			return
		case conn2 := <-connchan:
			select {
			case <-ctx.Done():
				return
			case <-ticks:
				if err := oneTurnConnection(ctx, params, peer, conn2); err != nil && params.reportErr != nil {
					params.reportErr(err)
				}
			}
		}
	}
}
