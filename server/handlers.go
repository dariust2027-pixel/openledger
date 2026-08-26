package main

import (
	"net/http"
	"strings"
)

// registerHandlers wires the sync API onto the mux.
func registerHandlers(mux *http.ServeMux, s *Store) {
	mux.HandleFunc("/health", requireMethod(http.MethodGet, healthHandler))

	mux.HandleFunc("/v1/devices/register",
		requireMethod(http.MethodPost, func(w http.ResponseWriter, r *http.Request) {
			var req struct {
				Name string `json:"name"`
			}
			if err := decodeBody(r, &req); err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
				return
			}
			d := s.RegisterDevice(req.Name)
			writeJSON(w, http.StatusCreated, map[string]string{
				"device_id": d.ID,
				"token":     d.Token, // shown once — client stores it securely
				"name":      d.Name,
			})
		}))

	mux.HandleFunc("/v1/ops/push", requireMethod(http.MethodPost, withAuth(s,
		func(w http.ResponseWriter, r *http.Request, dev Device) {
			var req struct {
				Ops []Op `json:"ops"`
			}
			if err := decodeBody(r, &req); err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
				return
			}
			if err := validateBatch(req.Ops); err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
				return
			}
			cursor, added, rejected := s.Push(dev, req.Ops)
			writeJSON(w, http.StatusOK, map[string]any{
				"cursor":    cursor,
				"accepted":  added,
				"rejected":  rejected,
				"submitted": len(req.Ops),
			})
		})))

	mux.HandleFunc("/v1/ops/pull", requireMethod(http.MethodGet, withAuth(s,
		func(w http.ResponseWriter, r *http.Request, dev Device) {
			cursor := queryInt(r, "cursor")
			limit := int(queryInt(r, "limit"))
			ops, newCursor := s.Pull(dev, cursor, limit)
			writeJSON(w, http.StatusOK, map[string]any{
				"ops":        ops,
				"new_cursor": newCursor,
				"count":      len(ops),
			})
		})))

	mux.HandleFunc("/v1/ai/proxy", requireMethod(http.MethodPost, withAuth(s, s.handleAIProxy)))

	mux.HandleFunc("/v1/stripe/webhook", requireMethod(http.MethodPost, handleStripeWebhook(s)))

	mux.HandleFunc("/v1/account", requireMethod(http.MethodGet, withAuth(s,
		func(w http.ResponseWriter, r *http.Request, dev Device) {
			a, ok := s.GetAccount(dev.AccountID)
			if !ok {
				writeJSON(w, http.StatusNotFound, map[string]string{"error": "account not found"})
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{
				"account_id":       a.ID,
				"plan":             a.Plan,
				"ai_requests_used": a.AIRequestsUsed,
				"ai_month":         a.AIMonth,
			})
		})))
}

// withAuth enforces Bearer token auth and injects the device.
func withAuth(s *Store, next func(http.ResponseWriter, *http.Request, Device)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		token := strings.TrimPrefix(h, "Bearer ")
		if token == "" || token == h {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "missing bearer token"})
			return
		}
		dev, ok := s.Auth(token)
		if !ok {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unknown device"})
			return
		}
		next(w, r, dev)
	}
}
