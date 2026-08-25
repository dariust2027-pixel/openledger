package main

import (
	"sync"
	"time"
)

// Account is a SaaS tenant. Self-hosted setups use a single implicit
// "default" account; the hosted deployment provisions one per subscriber.
type Account struct {
	ID                string `json:"id"`
	Name              string `json:"name"`
	Plan              string `json:"plan"` // free | pro
	StripeCustomerID  string `json:"stripe_customer_id,omitempty"`
	SubscriptionEnds  int64  `json:"subscription_ends,omitempty"`
	AIRequestsUsed    int64  `json:"ai_requests_used"`
	AIMonth           string `json:"ai_month"` // "2026-08" bucket for metering reset
	CreatedAt         int64  `json:"created_at"`
}

const (
	PlanFree = "free"
	PlanPro  = "pro"

	// Free tier hosted-AI allowance per calendar month. Pro is unlimited
	// (fair-use throttling handled at the gateway later).
	freeAIMonthlyLimit = 200

	defaultAIBudget = freeAIMonthlyLimit
)

var aiMonthlyLimit = defaultAIBudget // overridable via env in main.go

func monthBucket(t time.Time) string { return t.Format("2006-01") }

// --- Store extensions for multi-tenancy (store fields live in store.go) ---

func (s *Store) CreateAccount(name string) Account {
	s.mu.Lock()
	defer s.mu.Unlock()
	a := Account{
		ID:        randomToken("acc_"),
		Name:      name,
		Plan:      PlanFree,
		AIMonth:   monthBucket(timeNow()),
		CreatedAt: nowMillis(),
	}
	s.accounts[a.ID] = a
	s.persistLocked()
	return a
}

func (s *Store) GetAccount(id string) (Account, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	a, ok := s.accounts[id]
	return a, ok
}

func (s *Store) FindAccountByStripeCustomer(custID string) (Account, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, a := range s.accounts {
		if a.StripeCustomerID == custID {
			return a, true
		}
	}
	return Account{}, false
}

func (s *Store) SetPlan(accountID, plan, stripeCustID string, endsAt int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	a, ok := s.accounts[accountID]
	if !ok {
		return false
	}
	a.Plan = plan
	a.StripeCustomerID = stripeCustID
	a.SubscriptionEnds = endsAt
	s.accounts[accountID] = a
	s.persistLocked()
	return true
}

// ConsumeAIQuota meters one hosted-AI request. Returns false when the
// free-tier monthly limit is exhausted.
func (s *Store) ConsumeAIQuota(accountID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	a, ok := s.accounts[accountID]
	if !ok {
		return false
	}
	bucket := monthBucket(timeNow())
	if a.AIMonth != bucket {
		a.AIMonth = bucket
		a.AIRequestsUsed = 0
	}
	if a.Plan == PlanFree && a.AIRequestsUsed >= int64(aiMonthlyLimit) {
		return false
	}
	a.AIRequestsUsed++
	s.accounts[accountID] = a
	s.persistLocked()
	return true
}

// accountOpsLocked filters ops visible to one account (caller holds mu).
func accountOpsLocked(ops []Op, accountID string) []Op {
	out := make([]Op, 0, len(ops))
	for _, o := range ops {
		if o.AccountID == accountID {
			out = append(out, o)
		}
	}
	return out
}

var _ sync.Mutex // keep import symmetry when store.go changes
