package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net"
	"os"
	"os/signal"
	"sort"
	"syscall"
	"time"

	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
)

var (
	ratelimit               = 1000 // Rate limiter: packets per second
	respondingIPs           = make(map[uint32]string)
	stopUpdating            = make(chan struct{})
	icmpEchoRequestTemplate []byte
	rawSocketFd             int
	configFile              = flag.String("config", "config.json", "Path to JSON config file containing IP list")
	timeout                 = flag.Duration("timeout", 5*time.Second, "Time to wait for replies before writing results")
)

type Config struct {
	IPs []string `json:"networks"` // List of /32 CIDRs (e.g., "10.0.3.42/32")
}

// loadConfig reads IPs from a JSON file
func loadConfig(filename string) ([]string, error) {
	file, err := os.Open(filename)
	if err != nil {
		return nil, fmt.Errorf("error opening config file: %w", err)
	}
	defer file.Close()

	data, err := io.ReadAll(file)
	if err != nil {
		return nil, fmt.Errorf("error reading config file: %w", err)
	}

	var config Config
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("error parsing config JSON: %w", err)
	}

	return config.IPs, nil
}

func buildPingPacket() {
	icmpEchoRequestTemplate = make([]byte, 8)
	icmpEchoRequestTemplate[0] = 8                             // Echo Request type
	icmpEchoRequestTemplate[1] = 0                             // Code 0
	binary.BigEndian.PutUint16(icmpEchoRequestTemplate[6:], 1) // Identifier

	// Calculate ICMP checksum
	var sum uint32
	for i := 0; i < len(icmpEchoRequestTemplate); i += 2 {
		sum += uint32(icmpEchoRequestTemplate[i])<<8 | uint32(icmpEchoRequestTemplate[i+1])
	}
	sum += (sum >> 16)
	checksum := ^uint16(sum)
	binary.BigEndian.PutUint16(icmpEchoRequestTemplate[2:], checksum)
}

func listenPingForReplies() {
	conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		log.Printf("Error creating ICMP listener: %v", err)
		return
	}
	defer conn.Close()

	packet := make([]byte, 1500)
	for {
		select {
		case <-stopUpdating:
			log.Println("Stopping ICMP reply listener")
			return
		default:
			n, src, err := conn.ReadFrom(packet)
			if err != nil {
				log.Printf("Error reading ICMP packet: %v", err)
				continue
			}

			message, err := icmp.ParseMessage(1, packet[:n])
			if err != nil {
				log.Printf("Error parsing ICMP message: %v", err)
				continue
			}

			switch message.Type {
			case ipv4.ICMPTypeEchoReply:
				echo, ok := message.Body.(*icmp.Echo)
				if !ok {
					log.Println("Got bad Echo Reply message")
					continue
				}
				ipStr := src.String()
				log.Printf("Received ICMP Echo Reply from %s (ID: %d, Seq: %d)", ipStr, echo.ID, echo.Seq)
				ipInt := ipToUint32(ipStr)
				respondingIPs[ipInt] = ipStr
			}
		}
	}
}

func expandCIDR(cidrStr string) ([]string, error) {
	ip, ipNet, err := net.ParseCIDR(cidrStr)
	if err != nil {
		return nil, err
	}

	var ips []string
	for ip := ip.Mask(ipNet.Mask); ipNet.Contains(ip); incrementIP(ip) {
		ips = append(ips, ip.String())
	}

	// For /32, no need to remove network/broadcast
	return ips, nil
}

func incrementIP(ip net.IP) {
	for i := len(ip) - 1; i >= 0; i-- {
		ip[i]++
		if ip[i] > 0 {
			break
		}
	}
}

func ipToUint32(ipStr string) uint32 {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return 0
	}
	ip = ip.To4()
	if ip == nil {
		return 0
	}
	return binary.BigEndian.Uint32(ip)
}

func humanizeNumber(num int64) string {
	if num < 0 {
		return fmt.Sprintf("-%s", humanizeNumber(-num))
	}
	if num < 1000 {
		return fmt.Sprintf("%d", num)
	}
	return fmt.Sprintf("%s,%03d", humanizeNumber(num/1000), num%1000)
}

func writeResults() {
	var keys []uint32
	for k := range respondingIPs {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })

	filename := fmt.Sprintf("ping_results_%d.txt", time.Now().Unix())
	logFile, err := os.Create(filename)
	if err != nil {
		log.Printf("Error creating results file: %v", err)
		return
	}
	defer logFile.Close()

	for _, k := range keys {
		_, err := logFile.WriteString(respondingIPs[k] + "\n")
		if err != nil {
			log.Printf("Error writing IP to results file: %v", err)
		}
	}
	log.Printf("Total number of responding IPs: %s", humanizeNumber(int64(len(keys))))
	log.Printf("Results written to %s", filename)
}

func initRawSocket() error {
	var err error
	rawSocketFd, err = syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_ICMP)
	if err != nil {
		return err
	}
	return nil
}

func sendICMPEchoRequest(ip string) {
	ipAddr := net.ParseIP(ip)
	if ipAddr == nil {
		log.Printf("Invalid IP address: %s", ip)
		return
	}

	var addr [4]byte
	copy(addr[:], ipAddr.To4())

	dest := syscall.SockaddrInet4{
		Addr: addr,
	}

	if err := syscall.Sendto(rawSocketFd, icmpEchoRequestTemplate, 0, &dest); err != nil {
		log.Printf("Error sending ICMP to %s: %v", ip, err)
	} else {
		log.Printf("Sent ICMP Echo Request to %s", ip)
	}
}

func pingTargets(ips []string) {
	interval := 10 // Check rate every 10ms
	targetPacketsPerInterval := ratelimit / (1000 / interval)

	ticker := time.NewTicker(time.Duration(interval) * time.Millisecond)
	defer ticker.Stop()

	ipIndex := 0
	for range ticker.C {
		select {
		case <-stopUpdating:
			log.Println("Stopping ping sender")
			return
		default:
			packetsThisInterval := 0
			for ipIndex < len(ips) && packetsThisInterval < targetPacketsPerInterval {
				ipAddress := ips[ipIndex]
				go sendICMPEchoRequest(ipAddress)
				packetsThisInterval++
				ipIndex++
			}
			if ipIndex >= len(ips) {
				return
			}
		}
	}
}

func main() {
	flag.Parse()

	// Load IPs from config
	cidrs, err := loadConfig(*configFile)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	var allIPs []string
	for _, cidr := range cidrs {
		ips, err := expandCIDR(cidr)
		if err != nil {
			log.Printf("Error expanding CIDR %s: %v", cidr, err)
			continue
		}
		allIPs = append(allIPs, ips...)
	}
	log.Printf("Loaded %d IPs from config", len(allIPs))

	// Signal handling
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		log.Println("\nInterrupt received, writing results...")
		close(stopUpdating)
		time.Sleep(10 * time.Millisecond)
		writeResults()
		os.Exit(0)
	}()

	// Start listener
	go listenPingForReplies()

	// Initialize raw socket
	err = initRawSocket()
	if err != nil {
		log.Fatalf("Error initializing raw socket: %v (run as root)", err)
	}

	// Build ICMP packet
	buildPingPacket()

	// Shuffle IPs to avoid subnet bias
	rand.Shuffle(len(allIPs), func(i, j int) { allIPs[i], allIPs[j] = allIPs[j], allIPs[i] })

	log.Printf("Sending ICMP Echo Requests to %d IPs", len(allIPs))
	pingTargets(allIPs)

	// Wait for replies
	time.Sleep(*timeout)

	// Write results
	writeResults()
}
