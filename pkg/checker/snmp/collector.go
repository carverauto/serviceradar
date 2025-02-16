// pkg/checker/snmp/collector.go

package snmp

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/gosnmp/gosnmp"
)

// Collector handles SNMP data collection for a target.
type Collector struct {
	target     *Target
	client     *gosnmp.GoSNMP
	dataChan   chan DataPoint
	done       chan struct{}
	bufferPool *sync.Pool
}

func NewCollector(target *Target) (*Collector, error) {
	client := &gosnmp.GoSNMP{
		Target:    target.Host,
		Port:      target.Port,
		Community: target.Community,
		Version:   gosnmp.Version2c, // Default to v2c
		Timeout:   time.Duration(target.Timeout),
		Retries:   target.Retries,
	}

	// Set SNMP version based on config
	switch target.Version {
	case Version1:
		client.Version = gosnmp.Version1
	case Version2c:
		client.Version = gosnmp.Version2c
	case Version3:
		// TODO: Add SNMPv3 configuration
		return nil, fmt.Errorf("SNMPv3 not yet implemented")
	}

	return &Collector{
		target:   target,
		client:   client,
		dataChan: make(chan DataPoint, len(target.OIDs)),
		done:     make(chan struct{}),
		bufferPool: &sync.Pool{
			New: func() interface{} {
				return make([]byte, 0, 1024)
			},
		},
	}, nil
}

func (c *Collector) Start(ctx context.Context) error {
	if err := c.client.Connect(); err != nil {
		return fmt.Errorf("failed to connect: %w", err)
	}

	go c.collect(ctx)

	return nil
}

func (c *Collector) Stop() error {
	close(c.done)
	err := c.client.Conn.Close()
	if err != nil {
		return err
	}

	return nil
}

func (c *Collector) collect(ctx context.Context) {
	ticker := time.NewTicker(time.Duration(c.target.Interval))
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-c.done:
			return
		case <-ticker.C:
			if err := c.pollOIDs(ctx); err != nil {
				log.Printf("Error polling OIDs for %s: %v", c.target.Name, err)
			}
		}
	}
}

func (c *Collector) pollOIDs(ctx context.Context) error {
	oids := make([]string, len(c.target.OIDs))
	for i, oid := range c.target.OIDs {
		oids[i] = oid.OID
	}

	result, err := c.client.Get(oids)
	if err != nil {
		return fmt.Errorf("SNMP get failed: %w", err)
	}

	for _, variable := range result.Variables {
		if err := c.processVariable(ctx, variable); err != nil {
			log.Printf("Error processing variable %s: %v", variable.Name, err)
		}
	}

	return nil
}

func (c *Collector) processVariable(ctx context.Context, variable gosnmp.SnmpPDU) error {
	// Find the OID config for this variable
	var oidConfig *OIDConfig
	for _, oid := range c.target.OIDs {
		if oid.OID == variable.Name {
			oidConfig = &oid
			break
		}
	}

	if oidConfig == nil {
		return fmt.Errorf("no configuration found for OID %s", variable.Name)
	}

	value, err := c.convertValue(variable, oidConfig)
	if err != nil {
		return fmt.Errorf("failed to convert value: %w", err)
	}

	data := DataPoint{
		OIDName:   oidConfig.Name,
		Timestamp: time.Now(),
		Value:     value,
	}

	select {
	case c.dataChan <- data:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-c.done:
		return fmt.Errorf("collector stopped")
	}
}

func (c *Collector) convertValue(variable gosnmp.SnmpPDU, config *OIDConfig) (interface{}, error) {
	var value interface{}

	switch config.DataType {
	case TypeCounter:
		value = uint64(gosnmp.ToBigInt(variable.Value).Uint64())
		if config.Delta {
			// TODO: Implement delta calculation
		}
	case TypeGauge:
		value = uint64(gosnmp.ToBigInt(variable.Value).Uint64())
	case TypeBoolean:
		value = variable.Value.(int) != 0
	case TypeBytes:
		value = uint64(gosnmp.ToBigInt(variable.Value).Uint64())
	case TypeString:
		value = string(variable.Value.([]byte))
	default:
		return nil, fmt.Errorf("unsupported data type: %v", config.DataType)
	}

	// Apply scaling if configured
	if config.Scale != 0 && config.Scale != 1 {
		switch v := value.(type) {
		case uint64:
			value = float64(v) * config.Scale
		case float64:
			value = v * config.Scale
		}
	}

	return value, nil
}

// GetResults returns a channel that provides data points.
func (c *Collector) GetResults() <-chan DataPoint {
	return c.dataChan
}
