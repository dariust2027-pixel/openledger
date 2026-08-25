// OpenLedger self-hosted sync server.
//
// One static binary. Run it, register a device, point clients at it:
//
//	OPENLEDGER_ADDR=:8420 OPENLEDGER_DATA=./data.json openledger-server
//
// Endpoints:
//	GET  /health                 liveness + version
//	POST /v1/devices/register    {name} -> {device_id, token}
//	POST /v1/ops/push            {ops:[...]} -> {cursor, accepted}
//	GET  /v1/ops/pull?cursor=N   {ops:[...], new_cursor}
package main

import (
	"log"
	"net/http"
	"os"
	"time"
)

type Server struct {
	store     *Store
	startedAt time.Time
	version   string
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":  "ok",
		"version": version,
	})
}

const version = "0.2.0"

func main() {
	addr := os.Getenv("OPENLEDGER_ADDR")
	if addr == "" {
		addr = ":8420"
	}
	dataPath := os.Getenv("OPENLEDGER_DATA")
	if dataPath == "" {
		dataPath = "openledger-data.json"
	}

	s := &Server{store: NewStore(dataPath), startedAt: time.Now(), version: version}

	mux := http.NewServeMux()
	registerHandlers(mux, s.store)

	log.Printf("OpenLedger server v%s listening on %s (data: %s)", version, addr, dataPath)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}
