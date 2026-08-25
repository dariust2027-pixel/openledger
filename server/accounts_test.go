package main

import "testing"

func TestTenantIsolation(t *testing.T) {
	s := NewStore("")

	d1 := s.RegisterDeviceForAccount("phone", defaultAccountID)
	a2 := s.CreateAccount("tenant-b")
	d2 := s.RegisterDeviceForAccount("phone-b", a2.ID)

	// Device 1 pushes an op.
	_, n := s.Push(d1, []Op{{ID: "iso1", Entity: "customers", EntityID: "c1", OpType: "create"}})
	if n != 1 {
		t.Fatalf("push failed")
	}

	// Device 2 (other tenant) must see nothing.
	ops, _ := s.Pull(d2, 0, 100)
	if len(ops) != 0 {
		t.Fatalf("cross-tenant leak: device2 saw %d ops", len(ops))
	}
	// Same tenant sees it.
	ops, _ = s.Pull(d1, 0, 100)
	if len(ops) != 1 {
		t.Fatalf("same-tenant pull failed: %d", len(ops))
	}

	// Free-plan quota enforcement.
	if !s.ConsumeAIQuota(a2.ID) {
		t.Fatal("first AI request should pass")
	}
	s.mu.Lock()
	a := s.accounts[a2.ID]
	a.AIRequestsUsed = int64(aiMonthlyLimit)
	s.accounts[a2.ID] = a
	s.persistLocked()
	s.mu.Unlock()
	if s.ConsumeAIQuota(a2.ID) {
		t.Fatal("quota should be exhausted")
	}
	// Pro plan bypasses quota.
	s.SetPlan(a2.ID, PlanPro, "", 0)
	if !s.ConsumeAIQuota(a2.ID) {
		t.Fatal("pro should bypass quota")
	}
}
