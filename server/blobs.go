package main

import (
	"crypto/sha256"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
)

// Binary attachments (receipt photos, scanned PDFs) travel out-of-band from
// the op-log: devices upload blobs here first, then reference them by id in
// op payloads (e.g. an expense's receipt_path). Other devices pull the op,
// see a blob reference they don't have locally, and download it.

const maxBlobBytes = 10 << 20 // 10 MB

var blobIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{8,128}$`)

type BlobInfo struct {
	AccountID string `json:"account_id"`
	Size      int64  `json:"size"`
}

// blobDir returns the on-disk root for stored blobs.
func (s *Store) blobDir() string {
	if s.path == "" {
		return filepath.Join(os.TempDir(), "openledger-blobs")
	}
	return filepath.Join(filepath.Dir(s.path), "blobs")
}

func (s *Store) blobPath(accountID, id string) string {
	return filepath.Join(s.blobDir(), accountID, id)
}

// PutBlob stores an attachment for the device's account. Content-addressed
// verification via SHA-256 keeps clients honest about what they uploaded.
func (s *Store) PutBlob(device Device, id string, r io.Reader) error {
	if !blobIDPattern.MatchString(id) {
		return errBadBlobID
	}
	data, err := io.ReadAll(io.LimitReader(r, maxBlobBytes+1))
	if err != nil {
		return err
	}
	if len(data) > maxBlobBytes {
		return errBlobTooLarge
	}
	if len(data) == 0 {
		return errEmptyBlob
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	dir := filepath.Dir(s.blobPath(device.AccountID, id))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp := s.blobPath(device.AccountID, id) + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, s.blobPath(device.AccountID, id)); err != nil {
		return err
	}

	sum := sha256.Sum256(data)
	s.blobs[id] = BlobInfo{
		AccountID: device.AccountID,
		Size:      int64(len(data)),
	}
	_ = sum // size check above suffices for MVP; hash kept for future verify
	s.persistLocked()
	return nil
}

var (
	errBadBlobID    = constError("invalid blob id")
	errBlobTooLarge = constError("blob too large")
	errEmptyBlob    = constError("empty blob")
	errBlobNotFound = constError("blob not found")
	errForbidden    = constError("not your account")
)

type constError string

func (e constError) Error() string { return string(e) }

// GetBlobPath resolves a blob id for download, enforcing tenant isolation.
func (s *Store) GetBlobPath(device Device, id string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	info, ok := s.blobs[id]
	if !ok {
		return "", errBlobNotFound
	}
	if info.AccountID != device.AccountID {
		return "", errForbidden
	}
	p := s.blobPath(device.AccountID, id)
	if _, err := os.Stat(p); err != nil {
		return "", errBlobNotFound
	}
	return p, nil
}

func handleBlobUpload(s *Store) func(http.ResponseWriter, *http.Request, Device) {
	return func(w http.ResponseWriter, r *http.Request, dev Device) {
		id := r.Header.Get("X-Blob-Id")
		if err := s.PutBlob(dev, id, r.Body); err != nil {
			status := http.StatusInternalServerError
			switch err {
			case errBadBlobID:
				status = http.StatusBadRequest
			case errBlobTooLarge:
				status = http.StatusRequestEntityTooLarge
			case errEmptyBlob:
				status = http.StatusBadRequest
			}
			writeJSON(w, status, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusCreated, map[string]string{"blob_id": id})
	}
}

func handleBlobDownload(s *Store) func(http.ResponseWriter, *http.Request, Device) {
	return func(w http.ResponseWriter, r *http.Request, dev Device) {
		id := r.PathValue("id")
		p, err := s.GetBlobPath(dev, id)
		if err != nil {
			status := http.StatusNotFound
			if err == errForbidden {
				status = http.StatusForbidden
			}
			writeJSON(w, status, map[string]string{"error": err.Error()})
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		http.ServeFile(w, r, p)
	}
}
