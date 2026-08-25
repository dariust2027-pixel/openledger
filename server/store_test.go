package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRegisterAndPushPull(t *testing.T) {
	s := NewStore(t.TempDir() + "/data.json")

	mux := newTestMux(s)

	// Register device
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/v1/devices/register",
		bytes.NewReader([]byte(`{"name":"phone"}`)))
	mux.ServeHTTP(rec, req)
	if rec.Code != 201 {
		t.Fatalf("register: got %d want 201", rec.Code)
	}
	var reg struct {
		Token string `json:"token"`
	}
	json.Unmarshal(rec.Body.Bytes(), &reg)
	if reg.Token == "" {
		t.Fatal("no token returned")
	}

	auth := map[string]string{"Authorization": "Bearer " + reg.Token,
		"Content-Type": "application/json"}

	// Push two ops (one duplicate to test idempotency)
	ops := `{"ops":[
	  {"id":"op1","entity":"customers","entity_id":"c1","op_type":"create","lamport":1,"ts":1},
	  {"id":"op2","entity":"expenses","entity_id":"e1","op_type":"create","lamport":2,"ts":2},
	  {"id":"op1","entity":"customers","entity_id":"c1","op_type":"create","lamport":1,"ts":1}
	]}`
	rec = httptest.NewRecorder()
	req = httptest.NewRequest("POST", "/v1/ops/push", bytes.NewReader([]byte(ops)))
	for k, v := range auth {
		req.Header.Set(k, v)
	}
	mux.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("push: got %d want 200: %s", rec.Code, rec.Body.String())
	}
	var pushRes struct {
		Cursor   int64 `json:"cursor"`
		Accepted int   `json:"accepted"`
	}
	json.Unmarshal(rec.Body.Bytes(), &pushRes)
	if pushRes.Accepted != 2 || pushRes.Cursor != 2 {
		t.Fatalf("push result: %+v (want accepted=2 cursor=2)", pushRes)
	}

	// Pull from cursor 0
	rec = httptest.NewRecorder()
	req = httptest.NewRequest("GET", "/v1/ops/pull?cursor=0", nil)
	for k, v := range auth {
		req.Header.Set(k, v)
	}
	mux.ServeHTTP(rec, req)
	var pullRes struct {
		Count     int64 `json:"count"`
		NewCursor int64 `json:"new_cursor"`
	}
	json.Unmarshal(rec.Body.Bytes(), &pullRes)
	if pullRes.Count != 2 || pullRes.NewCursor != 2 {
		t.Fatalf("pull result: %+v", pullRes)
	}

	// Unauthenticated request rejected
	rec = httptest.NewRecorder()
	req = httptest.NewRequest("GET", "/v1/ops/pull?cursor=0", nil)
	mux.ServeHTTP(rec, req)
	if rec.Code != 401 {
		t.Fatalf("unauth: got %d want 401", rec.Code)
	}
}

func TestPersistenceAcrossRestart(t *testing.T) {
	path := t.TempDir() + "/data.json"
	s1 := NewStore(path)
	d := s1.RegisterDevice("desktop")
	s1.Push(d, []Op{{ID: "x1", Entity: "invoices", EntityID: "i1", OpType: "create"}})

	s2 := NewStore(path) // simulate restart
	if _, ok := s2.Auth(d.Token); !ok {
		t.Fatal("device token lost after restart")
	}
	ops, cursor := s2.Pull(0, 100)
	if len(ops) != 1 || cursor == 0 {
		t.Fatalf("ops lost after restart: %d ops, cursor %d", len(ops), cursor)
	}
}

func newTestMux(s *Store) *http.ServeMux {
	mux := http.NewServeMux()
	registerHandlers(mux, s)
	return mux
}
