package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

// Store is the server-side op-log. Dependency-free (stdlib only) with
// file-backed persistence so a self-hosted single binary survives restarts.
// The Postgres/SQLite upgrade lands with Phase 5 multi-tenant hosting.
type Store struct {
	mu sync.Mutex

	path     string
	devices  map[string]Device // token -> device
	ops      []Op              // ordered by Seq
	seq      int64
}

type Device struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Token     string `json:"token,omitempty"` // persisted so devices survive restarts
	CreatedAt int64  `json:"created_at"`
}

// Op is one client operation. The server never interprets payloads —
// it only orders, stores and relays them. Validation of business rules
// happens on devices when applying.
type Op struct {
	Seq       int64           `json:"seq"`
	ID        string          `json:"id"`
	Entity    string          `json:"entity"`
	EntityID  string          `json:"entity_id"`
	OpType    string          `json:"op_type"`
	Payload   json.RawMessage `json:"payload,omitempty"`
	DeviceID  string          `json:"device_id"`
	Lamport   int64           `json:"lamport"`
	Ts        int64           `json:"ts"`
}

func NewStore(path string) *Store {
	s := &Store{path: path, devices: map[string]Device{}}
	s.load()
	return s
}

func (s *Store) load() {
	if s.path == "" {
		return
	}
	data, err := os.ReadFile(s.path)
	if err != nil {
		return // fresh store
	}
	var snapshot struct {
		Devices []Device `json:"devices"`
		Ops     []Op     `json:"ops"`
		Seq     int64    `json:"seq"`
	}
	if json.Unmarshal(data, &snapshot) != nil {
		return
	}
	for _, d := range snapshot.Devices {
		s.devices[d.Token] = d
	}
	s.ops = snapshot.Ops
	s.seq = snapshot.Seq
}

func (s *Store) persistLocked() {
	if s.path == "" {
		return
	}
	devices := make([]Device, 0, len(s.devices))
	for _, d := range s.devices {
		devices = append(devices, d)
	}
	snapshot := struct {
		Devices []Device `json:"devices"`
		Ops     []Op     `json:"ops"`
		Seq     int64    `json:"seq"`
	}{devices, s.ops, s.seq}

	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return
	}
	data, _ := json.Marshal(snapshot)
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return
	}
	_ = os.Rename(tmp, s.path)
}

func randomToken(prefix string) string {
	b := make([]byte, 24)
	_, _ = rand.Read(b)
	return prefix + hex.EncodeToString(b)
}

func (s *Store) RegisterDevice(name string) Device {
	s.mu.Lock()
	defer s.mu.Unlock()
	d := Device{
		ID:        randomToken("dev_"),
		Name:      name,
		Token:     randomToken("tok_"),
		CreatedAt: nowMillis(),
	}
	s.devices[d.Token] = d
	s.persistLocked()
	return d
}

// Auth checks the bearer token; returns the device.
func (s *Store) Auth(bearer string) (Device, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.devices[bearer]
	return d, ok
}

// Push appends operations idempotently (dedup by op ID), assigns sequence
// numbers, persists and returns the new cursor.
func (s *Store) Push(device Device, incoming []Op) (int64, int) {
	s.mu.Lock()
	defer s.mu.Unlock()

	seen := make(map[string]bool, len(s.ops))
	for _, o := range s.ops {
		seen[o.ID] = true
	}

	added := 0
	for _, o := range incoming {
		if seen[o.ID] {
			continue
		}
		seen[o.ID] = true
		s.seq++
		o.Seq = s.seq
		o.DeviceID = device.ID // stamped by server, not trusted from client
		if o.ID == "" || o.Entity == "" || o.EntityID == "" || o.OpType == "" {
			continue // reject malformed by skipping (client re-sends corrected)
		}
		s.ops = append(s.ops, o)
		added++
	}
	s.persistLocked()
	return s.seq, added
}

// Pull returns ops with Seq > cursor (oldest first), up to limit.
func (s *Store) Pull(cursor int64, limit int) ([]Op, int64) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if limit <= 0 || limit > 1000 {
		limit = 500
	}
	out := make([]Op, 0, limit)
	newCursor := cursor
	for _, o := range s.ops {
		if o.Seq > cursor && len(out) < limit {
			out = append(out, o)
			if o.Seq > newCursor {
				newCursor = o.Seq
			}
		}
	}
	return out, newCursor
}

func nowMillis() int64 {
	return timeNow().UnixMilli()
}

var _ = fmt.Sprintf // keep fmt for future use
