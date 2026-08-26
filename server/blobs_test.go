package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestBlobUploadDownloadTenantIsolation(t *testing.T) {
	s := NewStore(t.TempDir() + "/data.json")
	mux := newTestMux(s)

	reg := func(name string) string {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest("POST", "/v1/devices/register",
			bytes.NewReader([]byte(`{"name":"`+name+`"}`)))
		mux.ServeHTTP(rec, req)
		var out struct {
			Token string `json:"token"`
		}
		json.Unmarshal(rec.Body.Bytes(), &out)
		return out.Token
	}
	tokA := reg("device-a")
	accB := s.CreateAccount("tenant-b")
	dB := s.RegisterDeviceForAccount("device-b", accB.ID)
	tokB := dB.Token

	hdr := func(tok string) map[string]string {
		return map[string]string{"Authorization": "Bearer " + tok}
	}

	// Upload
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/v1/blobs", bytes.NewReader([]byte("fake-jpeg-bytes")))
	for k, v := range hdr(tokA) {
		req.Header.Set(k, v)
	}
	req.Header.Set("X-Blob-Id", "abc12345")
	mux.ServeHTTP(rec, req)
	if rec.Code != 201 {
		t.Fatalf("upload: got %d want 201: %s", rec.Code, rec.Body.String())
	}

	// Same account downloads fine.
	rec = httptest.NewRecorder()
	req = httptest.NewRequest("GET", "/v1/blobs/abc12345", nil)
	for k, v := range hdr(tokA) {
		req.Header.Set(k, v)
	}
	mux.ServeHTTP(rec, req)
	if rec.Code != 200 || rec.Body.String() != "fake-jpeg-bytes" {
		t.Fatalf("download: got %d %q", rec.Code, rec.Body.String())
	}

	// Other account is forbidden.
	rec = httptest.NewRecorder()
	req = httptest.NewRequest("GET", "/v1/blobs/abc12345", nil)
	for k, v := range hdr(tokB) {
		req.Header.Set(k, v)
	}
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("cross-tenant blob download: got %d want 403", rec.Code)
	}

	// Invalid ids rejected.
	rec = httptest.NewRecorder()
	req = httptest.NewRequest("POST", "/v1/blobs", bytes.NewReader([]byte("x")))
	for k, v := range hdr(tokA) {
		req.Header.Set(k, v)
	}
	req.Header.Set("X-Blob-Id", "bad id with spaces!")
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("invalid blob id: got %d want 400", rec.Code)
	}

	// Survives restart.
	s2 := NewStore(s.path)
	d, _ := s2.Auth(tokB)
	if _, err := s2.GetBlobPath(d, "abc12345"); err == nil {
		t.Fatal("blob registry lost after restart (or wrong account resolved)")
	}
	devA, _ := s2.Auth(tokA)
	if _, err := s2.GetBlobPath(devA, "abc12345"); err != nil {
		t.Fatalf("blob lost after restart: %v", err)
	}
}
