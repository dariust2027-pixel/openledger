package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func mustOp(t *testing.T, raw string) Op {
	t.Helper()
	var o Op
	if err := json.Unmarshal([]byte(raw), &o); err != nil {
		t.Fatalf("bad test json: %v", err)
	}
	return o
}

func TestValidateOp_AcceptsValidCreate(t *testing.T) {
	o := mustOp(t, `{"id":"op1","entity":"customers","entity_id":"c1","op_type":"create",
		"payload":{"id":"c1","name":"Acme Corp","email":"a@b.c"}}`)
	if err := validateOp(o); err != nil {
		t.Fatalf("valid op rejected: %v", err)
	}
}

func TestValidateOp_RejectsUnknownEntity(t *testing.T) {
	o := mustOp(t, `{"id":"op1","entity":"hax","entity_id":"x","op_type":"create",
		"payload":{"id":"x"}}`)
	if validateOp(o) == nil {
		t.Fatal("unknown entity accepted")
	}
}

func TestValidateOp_RejectsUnknownOpType(t *testing.T) {
	o := mustOp(t, `{"id":"op1","entity":"customers","entity_id":"c1","op_type":"drop_tables"}`)
	if validateOp(o) == nil {
		t.Fatal("unknown op_type accepted")
	}
}

func TestValidateOp_RejectsMissingPayloadOnCreate(t *testing.T) {
	o := mustOp(t, `{"id":"op1","entity":"customers","entity_id":"c1","op_type":"create"}`)
	if validateOp(o) == nil {
		t.Fatal("create without payload accepted")
	}
}

func TestValidateOp_AllowsDeleteWithoutPayload(t *testing.T) {
	o := mustOp(t, `{"id":"op1","entity":"customers","entity_id":"c1","op_type":"delete"}`)
	if err := validateOp(o); err != nil {
		t.Fatalf("delete without payload should pass: %v", err)
	}
}

func TestValidateOp_RejectsIdMismatch(t *testing.T) {
	o := mustOp(t, `{"id":"op1","entity":"customers","entity_id":"c1","op_type":"create",
		"payload":{"id":"OTHER","name":"X"}}`)
	if validateOp(o) == nil {
		t.Fatal("payload id mismatching entity_id accepted")
	}
}

func TestValidateOp_RejectsMissingRequiredField(t *testing.T) {
	o := mustOp(t, `{"id":"op1","entity":"invoices","entity_id":"i1","op_type":"create",
		"payload":{"id":"i1","number":"INV-1"}}`) // no customer_id/total
	if validateOp(o) == nil {
		t.Fatal("invoice create missing customer_id accepted")
	}
}

func TestValidateOp_RejectsNegativeAmount(t *testing.T) {
	o := mustOp(t, `{"id":"op1","entity":"expenses","entity_id":"e1","op_type":"create",
		"payload":{"id":"e1","amount":-500,"date":"2026-08-26"}}`)
	if validateOp(o) == nil {
		t.Fatal("negative amount accepted")
	}
}

func TestValidateOp_RejectsOversizedString(t *testing.T) {
	big := strings.Repeat("A", maxStringField+10)
	raw := `{"id":"op1","entity":"customers","entity_id":"c1","op_type":"create","payload":{"id":"c1","name":"` + big + `"}}`
	if validateOp(mustOp(t, raw)) == nil {
		t.Fatal("oversized string accepted")
	}
}

func TestValidateBatch_Limit(t *testing.T) {
	ops := make([]Op, maxOpsPerBatch+1)
	for i := range ops {
		ops[i] = Op{ID: "x", Entity: "customers", EntityID: "c", OpType: "delete"}
	}
	if err := validateBatch(ops); err == nil {
		t.Fatal("oversized batch accepted")
	}
}

func TestPushRejectsInvalidOpsWithoutConsumingSeq(t *testing.T) {
	s := NewStore("")
	d := s.RegisterDevice("phone")

	valid := Op{ID: "v1", Entity: "customers", EntityID: "c1", OpType: "create",
		Payload: json.RawMessage(`{"id":"c1","name":"Acme"}`)}
	invalid := Op{ID: "bad1", Entity: "not_an_entity", EntityID: "z", OpType: "create"}

	cursor, added, rejected := s.Push(d, []Op{invalid, valid})
	if added != 1 || rejected != 1 {
		t.Fatalf("added=%d rejected=%d (want 1/1)", added, rejected)
	}
	if cursor != 1 {
		t.Fatalf("cursor=%d — invalid op consumed a sequence number", cursor)
	}
	ops, _ := s.Pull(d, 0, 100)
	if len(ops) != 1 || ops[0].ID != "v1" {
		t.Fatalf("pull shows %d ops, want only the valid one", len(ops))
	}
}
