package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// Minimal Stripe integration with zero third-party dependencies:
// webhook signature verification per Stripe's scheme
// (t=timestamp,v1=hmac_sha256(timestamp.payload)) and just the two events
// the SaaS needs. Checkout session creation is a thin passthrough that the
// dashboard/payment link can trigger — see docs/BUILD.md for setup.
func handleStripeWebhook(s *Store) http.HandlerFunc {
	secret := os.Getenv("STRIPE_WEBHOOK_SECRET")
	return func(w http.ResponseWriter, r *http.Request) {
		if secret == "" {
			writeJSON(w, http.StatusServiceUnavailable,
				map[string]string{"error": "stripe not configured"})
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "read failed"})
			return
		}

		sig := r.Header.Get("Stripe-Signature")
		if !verifyStripeSignature(sig, body, secret, 5*time.Minute) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad signature"})
			return
		}

		var event struct {
			Type string          `json:"type"`
			Data json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal(body, &event); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad json"})
			return
		}

		var obj struct {
			Object struct {
			 Customer       string `json:"customer"`
			 Subscription   string `json:"subscription"`
			 CurrentPeriodEnd int64 `json:"current_period_end"`
			} `json:"object"`
		}
		_ = json.Unmarshal(event.Data, &obj)
		customer := strings.TrimSpace(obj.Object.Customer)

		switch event.Type {
		case "checkout.session.completed", "customer.subscription.updated":
			if a, ok := s.FindAccountByStripeCustomer(customer); ok {
				s.SetPlan(a.ID, PlanPro, customer, obj.Object.CurrentPeriodEnd)
			}
		case "customer.subscription.deleted":
			if a, ok := s.FindAccountByStripeCustomer(customer); ok {
				s.SetPlan(a.ID, PlanFree, customer, 0)
			}
		default:
			// Unhandled event types are acknowledged so Stripe stops retrying.
		}
		writeJSON(w, http.StatusOK, map[string]string{"received": "true"})
	}
}

func verifyStripeSignature(header string, payload []byte, secret string, tolerance time.Duration) bool {
	var t string
	v1 := ""
	for _, part := range strings.Split(header, ",") {
		kv := strings.SplitN(strings.TrimSpace(part), "=", 2)
		if len(kv) != 2 {
			continue
		}
		switch kv[0] {
		case "t":
			t = kv[1]
		case "v1":
			v1 = kv[1]
		}
	}
	if t == "" || v1 == "" {
		return false
	}
	ts, err := strconv.ParseInt(t, 10, 64)
	if err != nil || time.Since(time.Unix(ts, 0)) > tolerance {
		return false
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(t))
	mac.Write([]byte("."))
	mac.Write(payload)
	expected := hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(expected), []byte(v1))
}
