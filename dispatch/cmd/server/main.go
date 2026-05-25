// Local-dev entry point. Wraps the same handler the Scaleway runtime
// invokes per request and serves it via http.ListenAndServe.
//
// Run: `go run ./cmd/server` from the dispatch/ directory.
package main

import (
	"log"
	"net/http"
	"os"
	"time"

	function "github.com/coreyleavitt/tianguis/dispatch"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           function.NewLocalHandler(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("tianguis-dispatch listening on :%s", port)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
