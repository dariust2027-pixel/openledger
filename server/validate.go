package main

import (
	"encoding/json"
	"fmt"
	"math"
	"strings"
)

// Server-side op validation. The server stays business-rule agnostic, but it
// must never relay garbage: unknown entities, absurd sizes or payloads that
// aren't JSON objects would poison every device in the account on pull.

const (
	maxOpsPerBatch   = 500
	maxOpIDLen       = 128
	maxEntityIDLen   = 128
	maxPayloadBytes  = 256 << 10 // 256 KB per op payload
	maxStringField   = 4096      // any single string value inside a payload
)

// allowedEntities mirrors the client's logOp call sites exactly.
var allowedEntities = map[string]bool{
	"customers":       true,
	"invoices":        true,
	"expenses":        true,
	"payments":        true,
	"items":           true,
	"vendors":         true,
	"documents":       true,
	"journals":        true,
	"recurring_rules": true,
}

var allowedOpTypes = map[string]bool{
	"create": true,
	"update": true,
	"delete": true,
}

// validateBatch enforces batch-level limits.
func validateBatch(ops []Op) error {
	if len(ops) > maxOpsPerBatch {
		return fmt.Errorf("batch too large: %d ops (max %d)", len(ops), maxOpsPerBatch)
	}
	return nil
}

// validateOp checks one op's shape. Returns a descriptive error; the caller
// decides whether to reject or skip.
func validateOp(o Op) error {
	if o.ID == "" {
		return fmt.Errorf("missing op id")
	}
	if len(o.ID) > maxOpIDLen {
		return fmt.Errorf("op id too long")
	}
	if !allowedEntities[o.Entity] {
		return fmt.Errorf("unknown entity %q", o.Entity)
	}
	if o.EntityID == "" {
		return fmt.Errorf("missing entity_id")
	}
	if len(o.EntityID) > maxEntityIDLen {
		return fmt.Errorf("entity_id too long")
	}
	if !allowedOpTypes[o.OpType] {
		return fmt.Errorf("unknown op_type %q", o.OpType)
	}
	if o.Lamport < 0 || o.Ts < 0 {
		return fmt.Errorf("negative lamport/ts")
	}
	if len(o.Payload) > maxPayloadBytes {
		return fmt.Errorf("payload too large (%d bytes)", len(o.Payload))
	}
	if o.OpType == "delete" {
		// deletes may carry no payload
		return nil
	}
	if len(o.Payload) == 0 {
		return fmt.Errorf("missing payload")
	}
	return validatePayload(o.Entity, o.OpType, o.EntityID, o.Payload)
}

// validatePayload ensures the payload is a JSON object with sane field types
// and sizes, plus per-entity required fields for creates.
func validatePayload(entity, opType, entityID string, raw json.RawMessage) error {
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return fmt.Errorf("payload is not a JSON object")
	}

	// Every stored row carries its id; it must agree with EntityID so a
	// malicious/buggy client can't desync the op-log from row identity.
	if opType == "create" {
		idVal, ok := m["id"]
		if !ok {
			return fmt.Errorf("create payload missing id")
		}
		idStr, ok := idVal.(string)
		if !ok || idStr == "" {
			return fmt.Errorf("create payload id must be a non-empty string")
		}
		if idStr != entityID {
			return fmt.Errorf("create payload id %q does not match entity_id %q", idStr, entityID)
		}
		if len(idStr) > maxEntityIDLen {
			return fmt.Errorf("create payload id too long")
		}
	}

	for k, v := range m {
		switch t := v.(type) {
		case string:
			if len(t) > maxStringField {
				return fmt.Errorf("field %q: string too long", k)
			}
		case float64:
			// Money is integer minor units; NaN/Inf can't survive JSON but
			// absurd magnitudes can. Reject anything beyond int64 range-ish.
			if t != t || math.Abs(t) > math.MaxInt64/2 {
				return fmt.Errorf("field %q: number out of range", k)
			}
		case []any:
			// line arrays etc — bound their size
			if len(t) > 1000 {
				return fmt.Errorf("field %q: array too large", k)
			}
			for i, item := range t {
				if _, ok := item.(map[string]any); len(t) > 0 && !ok {
					return fmt.Errorf("field %q[%d]: expected object", k, i)
				}
				if err := boundNestedObject(item, k, i); err != nil {
					return err
				}
			}
		case map[string]any:
			if len(t) > 200 {
				return fmt.Errorf("field %q: object too large", k)
			}
		}
	}

	// Required fields for creates, per entity. Deletes/updates are looser —
	// updates are partial patches by design.
	if opType == "create" {
		req := requiredCreateFields(entity)
		for _, f := range req {
			if v, ok := m[f]; !ok || v == nil || v == "" {
				return fmt.Errorf("create %s missing field %q", strings.TrimSuffix(entity, "s"), f)
			}
		}
		// Amount fields, where present, must be non-negative integers-as-floats.
		for _, f := range []string{"amount", "total", "subtotal", "tax_total", "unit_price"} {
			if v, ok := m[f].(float64); ok && v < 0 {
				return fmt.Errorf("field %q must be >= 0", f)
			}
		}
	}
	return nil
}

// boundNestedObject checks objects inside arrays (document lines).
func boundNestedObject(item any, field string, idx int) error {
	m, ok := item.(map[string]any)
	if !ok {
		return nil
	}
	if len(m) > 50 {
		return fmt.Errorf("field %q[%d]: object too large", field, idx)
	}
	for k, v := range m {
		switch t := v.(type) {
		case string:
			if len(t) > maxStringField {
				return fmt.Errorf("field %q[%d].%s: string too long", field, idx, k)
			}
		case float64:
			if t != t || math.Abs(t) > math.MaxInt64/2 {
				return fmt.Errorf("field %q[%d].%s: number out of range", field, idx, k)
			}
			if (k == "unit_price" || k == "line_total") && t < 0 {
				return fmt.Errorf("field %q[%d].%s must be >= 0", field, idx, k)
			}
		}
	}
	return nil
}

func requiredCreateFields(entity string) []string {
	switch entity {
	case "customers":
		return []string{"name"}
	case "vendors":
		return []string{"name"}
	case "items":
		return []string{"name", "unit_price"}
	case "invoices":
		return []string{"customer_id", "number", "total"}
	case "documents":
		return []string{"doc_type", "party_id", "number", "total"}
	case "expenses":
		return []string{"amount", "date"}
	case "payments":
		return []string{"amount", "date"}
	case "journals":
		return []string{"narration", "amount"}
	default: // recurring_rules and future entities: structural checks only
		return nil
	}
}
