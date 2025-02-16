package agent

import (
	"context"
	"fmt"
	"log"
	"net"
	"time"
)

// SNMPChecker implements the checker.Checker interface.
type SNMPChecker struct {
	address string
}

func (c *SNMPChecker) Check(ctx context.Context) (bool, string) {
	// Try to connect to the SNMP service
	conn, err := net.DialTimeout("tcp", c.address, 5*time.Second)
	if err != nil {
		return false, fmt.Sprintf("Failed to connect to SNMP service: %v", err)
	}
	defer func(conn net.Conn) {
		err := conn.Close()
		if err != nil {
			log.Printf("Failed to close connection: %v", err)
		}
	}(conn)

	return true, fmt.Sprintf("SNMP service is running at %s", c.address)
}
