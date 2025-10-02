package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"time"
)

func main() {
	var (
		host     = flag.String("host", "", "host to check")
		port     = flag.Int("port", 0, "port to check")
		attempts = flag.Int("attempts", 30, "number of attempts before failing (0 for infinite)")
		interval = flag.Duration("interval", 2*time.Second, "delay between attempts")
		timeout  = flag.Duration("timeout", 2*time.Second, "per-attempt dial timeout")
		quiet    = flag.Bool("quiet", false, "suppress progress logs")
	)
	flag.Parse()

	if *host == "" || *port <= 0 {
		fmt.Fprintln(os.Stderr, "wait-for-port: both --host and --port must be provided")
		os.Exit(2)
	}

	addr := fmt.Sprintf("%s:%d", *host, *port)
	maxAttempts := *attempts

	for attempt := 1; maxAttempts == 0 || attempt <= maxAttempts; attempt++ {
		if !*quiet {
			fmt.Fprintf(os.Stderr, "wait-for-port: attempting %s (attempt %d)\n", addr, attempt)
		}

		conn, err := net.DialTimeout("tcp", addr, *timeout)
		if err == nil {
			conn.Close()
			if !*quiet {
				fmt.Fprintf(os.Stderr, "wait-for-port: %s is available\n", addr)
			}
			return
		}

		if maxAttempts != 0 && attempt >= maxAttempts {
			fmt.Fprintf(os.Stderr, "wait-for-port: timed out waiting for %s after %d attempts: %v\n", addr, maxAttempts, err)
			os.Exit(1)
		}

		time.Sleep(*interval)
	}
}
