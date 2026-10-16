// ternd is the device helper behind Tern. The Mac app launches it as a child
// process and talks to it over stdin/stdout with one JSON object per line.
//
// It wraps go-ios (MIT) so the app never has to speak usbmuxd, RSD or DTX
// itself. For iOS 17 and later it opens a userspace tunnel to the device, which
// needs no root privileges; for older versions it mounts the developer disk
// image and uses the classic simulatelocation service.
//
// Requests (stdin):
//
//	{"cmd":"devices"}
//	{"cmd":"connect","udid":"..."}
//	{"cmd":"set","lat":41.0,"lon":29.0}
//	{"cmd":"reset"}
//	{"cmd":"disconnect"}
//	{"cmd":"quit"}
//
// Replies (stdout) always carry "event"; see the emit* helpers below.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/Masterminds/semver"
	"github.com/danielpaulus/go-ios/ios"
	"github.com/danielpaulus/go-ios/ios/imagemounter"
	"github.com/danielpaulus/go-ios/ios/instruments"
	"github.com/danielpaulus/go-ios/ios/simlocation"
	"github.com/danielpaulus/go-ios/ios/tunnel"
)

const version = "0.1.0"

type request struct {
	Cmd  string  `json:"cmd"`
	UDID string  `json:"udid,omitempty"`
	Lat  float64 `json:"lat,omitempty"`
	Lon  float64 `json:"lon,omitempty"`
}

type deviceInfo struct {
	UDID        string `json:"udid"`
	Name        string `json:"name"`
	ProductType string `json:"productType"`
	Version     string `json:"version"`
	Connection  string `json:"connection"`
}

// session is the live link to one device: the tunnel (iOS 17+) and the
// location service kept open between updates. The instruments channel must
// stay connected for the simulated location to persist; closing it resets the
// device to its real position, which is also how "reset" works on iOS 17+.
type session struct {
	udid     string
	device   ios.DeviceEntry
	legacy   bool // iOS < 17: simulatelocation over usbmuxd
	cancel   context.CancelFunc
	tm       *tunnel.TunnelManager
	sim      *instruments.LocationSimulationService
	mu       sync.Mutex
	lastLat  float64
	lastLon  float64
	hasPoint bool
}

var (
	out     = bufio.NewWriter(os.Stdout)
	outMu   sync.Mutex
	current *session
)

func main() {
	pairDir := flag.String("pair-dir", defaultPairDir(), "directory for go-ios pair records")
	imageDir := flag.String("image-dir", defaultImageDir(), "cache directory for developer disk images (iOS < 17)")
	flag.Parse()

	// go-ios logs through slog; keep that on stderr so stdout stays pure protocol.
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo})))

	emit(map[string]any{"event": "hello", "version": version, "pid": os.Getpid()})

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var req request
		if err := json.Unmarshal(line, &req); err != nil {
			emitError("parse", fmt.Sprintf("bad request: %v", err))
			continue
		}
		if req.Cmd != "devices" { // the app polls devices every few seconds; keep the log readable
			slog.Info("request", "cmd", req.Cmd)
		}
		switch req.Cmd {
		case "devices":
			handleDevices()
		case "connect":
			handleConnect(req.UDID, *pairDir, *imageDir)
		case "set":
			handleSet(req.Lat, req.Lon)
		case "reset":
			handleReset()
		case "disconnect":
			handleDisconnect()
		case "quit":
			handleDisconnect()
			emit(map[string]any{"event": "bye"})
			return
		default:
			emitError("unknown", "unknown command: "+req.Cmd)
		}
	}
	// stdin closed: the app went away, so drop the simulation too.
	handleDisconnect()
}

func handleDevices() {
	list, err := ios.ListDevices()
	if err != nil {
		emitError("devices", "usbmuxd unavailable: "+err.Error())
		return
	}
	// usbmuxd reports a device twice when it is reachable over USB and Wi-Fi.
	// Keep one entry per UDID and prefer USB: it is faster and survives Wi-Fi drops.
	byUDID := map[string]ios.DeviceEntry{}
	order := []string{}
	for _, d := range list.DeviceList {
		udid := d.Properties.SerialNumber
		existing, ok := byUDID[udid]
		if !ok {
			order = append(order, udid)
			byUDID[udid] = d
			continue
		}
		if existing.ConnectionTypeLabel() != "USB" && d.ConnectionTypeLabel() == "USB" {
			byUDID[udid] = d
		}
	}
	devices := make([]deviceInfo, 0, len(order))
	for _, udid := range order {
		d := byUDID[udid]
		info := deviceInfo{UDID: udid, Connection: d.ConnectionTypeLabel()}
		if values, err := ios.GetValues(d); err == nil {
			info.Name = values.Value.DeviceName
			info.ProductType = values.Value.ProductType
			info.Version = values.Value.ProductVersion
		}
		devices = append(devices, info)
	}
	emit(map[string]any{"event": "devices", "devices": devices})
}

func handleConnect(udid, pairDir, imageDir string) {
	handleDisconnect()

	device, err := ios.GetDevice(udid)
	if err != nil {
		emitError("connect", "device not found: "+err.Error())
		return
	}
	ver, err := ios.GetProductVersion(device)
	if err != nil {
		emitError("connect", "cannot read iOS version: "+err.Error())
		return
	}
	s := &session{udid: udid, device: device}
	emitStatus("connecting", fmt.Sprintf("iOS %s", ver.String()))

	if ver.LessThan(semver.MustParse("17.0.0")) {
		if err := prepareLegacy(s, imageDir); err != nil {
			emitError("connect", err.Error())
			return
		}
	} else {
		if err := prepareTunnel(s, pairDir); err != nil {
			emitError("connect", err.Error())
			return
		}
	}
	current = s
	emitStatus("ready", "")
}

// prepareLegacy mounts the developer disk image for iOS 16 and earlier so the
// com.apple.dt.simulatelocation service becomes available.
func prepareLegacy(s *session, imageDir string) error {
	s.legacy = true
	if err := os.MkdirAll(imageDir, 0o755); err != nil {
		return fmt.Errorf("image cache: %w", err)
	}
	mounter, err := imagemounter.NewImageMounter(s.device)
	if err != nil {
		return fmt.Errorf("image mounter: %w", err)
	}
	defer mounter.Close()
	images, err := mounter.ListImages()
	if err == nil && len(images) > 0 {
		return nil
	}
	emitStatus("mounting", "developer disk image")
	path, err := imagemounter.DownloadImageFor(s.device, imageDir)
	if err != nil {
		return fmt.Errorf("developer disk image download: %w", err)
	}
	if err := mounter.MountImage(path); err != nil {
		return fmt.Errorf("developer disk image mount: %w", err)
	}
	return nil
}

// prepareTunnel opens a userspace tunnel (no root needed), resolves the RSD
// services behind it and opens the instruments location channel.
func prepareTunnel(s *session, pairDir string) error {
	if err := os.MkdirAll(pairDir, 0o700); err != nil {
		return fmt.Errorf("pair record dir: %w", err)
	}
	pm, err := tunnel.NewPairRecordManager(pairDir)
	if err != nil {
		return fmt.Errorf("pair records: %w", err)
	}
	basePort, err := freePort()
	if err != nil {
		return fmt.Errorf("port: %w", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	s.tm = tunnel.NewTunnelManagerForDevice(pm, true, s.udid, basePort)

	emitStatus("tunnel", "opening")
	var tun tunnel.Tunnel
	deadline := time.Now().Add(45 * time.Second)
	for {
		if err := s.tm.UpdateTunnels(ctx); err != nil {
			slog.Warn("tunnel update", "error", err)
		}
		tun, _ = s.tm.FindTunnel(s.udid)
		if tun.Address != "" {
			break
		}
		if time.Now().After(deadline) {
			cancel()
			return errors.New("tunnel did not come up in 45s; unlock the iPhone and tap Trust, then try again")
		}
		time.Sleep(time.Second)
	}
	// Keep the manager polling so it reconnects if the cable blips.
	go func() {
		t := time.NewTicker(2 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				_ = s.tm.UpdateTunnels(ctx)
			}
		}
	}()

	s.device.UserspaceTUN = true
	s.device.UserspaceTUNHost = ios.HttpApiHost()
	s.device.UserspaceTUNPort = tun.UserspaceTUNPort

	rsd, err := ios.NewWithAddrPortDevice(tun.Address, tun.RsdPort, s.device)
	if err != nil {
		cancel()
		return fmt.Errorf("rsd connect: %w", err)
	}
	provider, err := rsd.Handshake()
	rsd.Close()
	if err != nil {
		cancel()
		return fmt.Errorf("rsd handshake: %w", err)
	}
	dev, err := ios.GetDeviceWithAddress(s.udid, tun.Address, provider)
	if err != nil {
		cancel()
		return fmt.Errorf("device with rsd: %w", err)
	}
	dev.UserspaceTUN = true
	dev.UserspaceTUNHost = ios.HttpApiHost()
	dev.UserspaceTUNPort = tun.UserspaceTUNPort
	s.device = dev

	emitStatus("service", "location simulation")
	if err := s.openSim(); err != nil {
		cancel()
		return err
	}
	return nil
}

func (s *session) openSim() error {
	sim, err := instruments.NewLocationSimulationService(s.device)
	if err != nil {
		return fmt.Errorf("location service: %w (is Developer Mode on?)", err)
	}
	s.sim = sim
	return nil
}

func handleSet(lat, lon float64) {
	s := current
	if s == nil {
		emitError("set", "not connected")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var err error
	if s.legacy {
		err = simlocation.SetLocation(s.device, fmt.Sprintf("%.7f", lat), fmt.Sprintf("%.7f", lon))
	} else {
		if s.sim == nil {
			if err = s.openSim(); err != nil {
				emitError("set", err.Error())
				return
			}
		}
		err = s.sim.StartSimulateLocation(lat, lon)
		if err != nil {
			// The DTX channel may have dropped (cable, sleep); reopen once.
			s.sim.Close()
			s.sim = nil
			if err2 := s.openSim(); err2 == nil {
				err = s.sim.StartSimulateLocation(lat, lon)
			}
		}
	}
	if err != nil {
		emitError("set", err.Error())
		return
	}
	s.lastLat, s.lastLon, s.hasPoint = lat, lon, true
	emit(map[string]any{"event": "set", "lat": lat, "lon": lon})
}

func handleReset() {
	s := current
	if s == nil {
		emitError("reset", "not connected")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var err error
	if s.legacy {
		err = simlocation.ResetLocation(s.device)
	} else if s.sim != nil {
		err = s.sim.StopSimulateLocation() // closes the channel as well
		s.sim = nil
	}
	if err != nil {
		emitError("reset", err.Error())
		return
	}
	s.hasPoint = false
	emit(map[string]any{"event": "reset"})
}

func handleDisconnect() {
	s := current
	if s == nil {
		return
	}
	current = nil
	s.mu.Lock()
	if s.sim != nil {
		_ = s.sim.StopSimulateLocation()
		s.sim = nil
	}
	s.mu.Unlock()
	if s.cancel != nil {
		s.cancel()
	}
	if s.tm != nil {
		_ = s.tm.Close()
	}
	emitStatus("disconnected", "")
}

func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

func defaultPairDir() string {
	return filepath.Join(appSupport(), "pair")
}

func defaultImageDir() string {
	return filepath.Join(appSupport(), "images")
}

func appSupport() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return os.TempDir()
	}
	return filepath.Join(home, "Library", "Application Support", "Tern")
}

func emit(v map[string]any) {
	outMu.Lock()
	defer outMu.Unlock()
	b, _ := json.Marshal(v)
	out.Write(b)
	out.WriteByte('\n')
	out.Flush()
}

func emitStatus(state, detail string) {
	emit(map[string]any{"event": "status", "state": state, "detail": detail})
}

func emitError(scope, message string) {
	emit(map[string]any{"event": "error", "scope": scope, "message": message})
}
