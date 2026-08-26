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
	devices  map[string]Device   // token -> device
	accounts map[string]Account  // account id -> account
	blobs    map[string]BlobInfo // blob id -> metadata (files on disk)
	ops      []Op                // ordered by Seq, scoped by AccountID
	seq      int64
}

type Device struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Token     string `json:"token,omitempty"` // persisted so devices survive restarts
	AccountID string `json:"account_id"`
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
	AccountID string          `json:"account_id,omitempty"`
	Lamport   int64           `json:"lamport"`
	Ts        int64           `json:"ts"`
}

const defaultAccountID = "acc_default"

func NewStore(path string) *Store {
	s := &Store{
		path:     path,
		devices:  map[string]Device{},
		accounts: map[string]Account{},
		blobs:    map[string]BlobInfo{},
	}
	s.load()
	if _, ok := s.accounts[defaultAccountID]; !ok {
		// Self-hosted single-tenant default.
		s.accounts[defaultAccountID] = Account{
			ID:        defaultAccountID,
			Name:      "default",
			Plan:      PlanPro, // self-hosted = your hardware, your rules
			AIMonth:   monthBucket(timeNow()),
			CreatedAt: nowMillis(),
		}
	}
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
		Devices  []Device        `json:"devices"`
		Accounts []Account       `json:"accounts"`
		Blobs    map[string]BlobInfo `json:"blobs"`
		Ops      []Op            `json:"ops"`
		Seq      int64           `json:"seq"`
	}
	if json.Unmarshal(data, &snapshot) != nil {
		return
	}
	for _, d := range snapshot.Devices {
		s.devices[d.Token] = d
	}
	for _, a := range snapshot.Accounts {
		s.accounts[a.ID] = a
	}
	s.blobs = snapshot.Blobs
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
	accounts := make([]Account, 0, len(s.accounts))
	for _, a := range s.accounts {
		accounts = append(accounts, a)
	}
	snapshot := struct {
		Devices  []Device            `json:"devices"`
		Accounts []Account           `json:"accounts"`
		Blobs    map[string]BlobInfo `json:"blobs"`
		Ops      []Op                `json:"ops"`
		Seq      int64               `json:"seq"`
	}{devices, accounts, s.blobs, s.ops, s.seq}

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
	return s.RegisterDeviceForAccount(name, defaultAccountID)
}

// RegisterDeviceForAccount provisions a device under a tenant. Used by the
// self-host flow (default account) and by the SaaS account signup endpoint.
func (s *Store) RegisterDeviceForAccount(name, accountID string) Device {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.accounts[accountID]; !ok {
		accountID = defaultAccountID
	}
	d := Device{
		ID:        randomToken("dev_"),
		Name:      name,
		Token:     randomToken("tok_"),
		AccountID: accountID,
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
// numbers, persists and returns the new cursor. Invalid ops are rejected —
// they never enter the log and never consume sequence numbers.
func (s *Store) Push(device Device, incoming []Op) (int64, int, int) {
	s.mu.Lock()
	defer s.mu.Unlock()

	seen := make(map[string]bool, len(s.ops))
	for _, o := range s.ops {
		seen[o.ID] = true
	}

	added, rejected := 0, 0
	for _, o := range incoming {
		if seen[o.ID] {
			continue
		}
		// Server-side validation gate: unknown entities, malformed payloads
		// or oversized ops are dropped before they can poison other devices.
		if validateOp(o) != nil {
			rejected++
			continue
		}
		seen[o.ID] = true
		s.seq++
		o.Seq = s.seq
		o.DeviceID = device.ID // stamped by server, not trusted from client
		o.AccountID = device.AccountID
		s.ops = append(s.ops, o)
		added++
	}
	s.persistLocked()
	return s.seq, added, rejected
}

// Pull returns the caller's account ops with Seq > cursor (oldest first),
// up to limit.
func (s *Store) Pull(device Device, cursor int64, limit int) ([]Op, int64) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if limit <= 0 || limit > 1000 {
		limit = 500
	}
	out := make([]Op, 0, limit)
	newCursor := cursor
	for _, o := range s.ops {
		if o.AccountID != device.AccountID {
			continue
		}
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
