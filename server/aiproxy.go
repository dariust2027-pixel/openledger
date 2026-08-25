package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"time"
)

// Hosted AI proxy: subscribers' apps call THIS endpoint instead of needing
// their own provider keys. We forward to our upstream LLM, meter usage per
// account, and gate free accounts on a monthly allowance.
//
// Env config:
//	AI_UPSTREAM_URL   e.g. https://api.openai.com/v1/chat/completions
//	AI_UPSTREAM_KEY   sk-...
//	AI_UPSTREAM_MODEL gpt-4o-mini
//	STRIPE_WEBHOOK_SECRET  (see stripe.go)

type proxyRequest struct {
	Messages []map[string]any `json:"messages"`
	Tools    []any            `json:"tools,omitempty"`
}

func (s *Store) handleAIProxy(w http.ResponseWriter, r *http.Request, dev Device) {
	upstreamURL := os.Getenv("AI_UPSTREAM_URL")
	upstreamKey := os.Getenv("AI_UPSTREAM_KEY")
	upstreamModel := os.Getenv("AI_UPSTREAM_MODEL")
	client := &http.Client{Timeout: 90 * time.Second}

	if upstreamURL == "" || upstreamKey == "" {
		writeJSON(w, http.StatusServiceUnavailable,
			map[string]string{"error": "hosted AI not configured on this server"})
		return
	}
	if !s.ConsumeAIQuota(dev.AccountID) {
		writeJSON(w, http.StatusPaymentRequired,
			map[string]string{"error": "monthly AI allowance exhausted — upgrade to Pro"})
		return
	}

	var req proxyRequest
	if err := decodeBody(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	payload := map[string]any{
		"model":       upstreamModel,
		"messages":    req.Messages,
		"temperature": 0.2,
	}
	if len(req.Tools) > 0 {
		payload["tools"] = req.Tools
	}
	body, _ := json.Marshal(payload)

	upReq, _ := http.NewRequestWithContext(r.Context(), http.MethodPost, upstreamURL, bytes.NewReader(body))
	upReq.Header.Set("Content-Type", "application/json")
	upReq.Header.Set("Authorization", "Bearer "+upstreamKey)

	resp, err := client.Do(upReq)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "upstream unreachable"})
		return
	}
	defer resp.Body.Close()

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	buf := new(bytes.Buffer)
	_, _ = buf.ReadFrom(io.LimitReader(resp.Body, 8<<20)) // 8 MB response cap
	_, _ = w.Write(buf.Bytes())
}
