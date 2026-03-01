#!/usr/bin/env python3
"""Generate test sFlow v5 and NetFlow v5 UDP packets for the flow-collector."""

import socket
import struct
import time
import random
import argparse


def build_sflow_v5_datagram(agent_ip, seq, samples):
    """Build a minimal sFlow v5 datagram with sampled IPv4 flow records."""
    agent_bytes = socket.inet_aton(agent_ip)

    # sFlow v5 header: version(4) + addr_type(4) + agent(4) + sub_agent(4) + seq(4) + uptime(4) + num_samples(4)
    header = struct.pack(
        "!IIIIIII",
        5,           # version
        1,           # address type (1=IPv4)
        struct.unpack("!I", agent_bytes)[0],
        0,           # sub-agent ID
        seq,         # sequence number
        int(time.time() * 1000) & 0xFFFFFFFF,  # uptime ms
        len(samples),
    )

    sample_data = b""
    for sample in samples:
        sample_data += sample

    return header + sample_data


def build_flow_sample(src_ip, dst_ip, src_port, dst_port, proto, byte_count, sampling_rate=512):
    """Build an sFlow v5 flow sample with a sampled IPv4 record."""
    # Sampled IPv4 record (enterprise=0, format=3)
    # All fields are 4-byte unsigned ints per sFlow v5 XDR spec
    ipv4_record = struct.pack(
        "!IIIIIIII",
        byte_count,   # length
        proto,        # protocol
        struct.unpack("!I", socket.inet_aton(src_ip))[0],
        struct.unpack("!I", socket.inet_aton(dst_ip))[0],
        src_port,     # src port (uint32)
        dst_port,     # dst port (uint32)
        0,            # tcp_flags (uint32)
        0,            # tos (uint32)
    )

    # Flow record header: enterprise_format(4) + length(4)
    record_hdr = struct.pack("!II", 3, len(ipv4_record))  # format=3 (sampled IPv4)
    full_record = record_hdr + ipv4_record

    # Flow sample header
    # enterprise_format(4) + sample_length(4) + seq(4) + source_id_type(1) + source_id_index(3)
    # + sampling_rate(4) + sample_pool(4) + drops(4) + input(4) + output(4) + num_records(4)
    seq_num = random.randint(1, 100000)
    inner = struct.pack(
        "!IIIIIIII",
        seq_num,
        (0 << 24) | 1,  # source_id: type=0, index=1
        sampling_rate,
        sampling_rate * 10,  # sample_pool
        0,              # drops
        random.randint(1, 48),   # input interface
        random.randint(1, 48),   # output interface
        1,              # num_records
    ) + full_record

    # Sample header: enterprise_format(4) + length(4)
    sample_hdr = struct.pack("!II", 1, len(inner))  # format=1 (flow sample)
    return sample_hdr + inner


def build_netflow_v5_packet(router_ip, flows):
    """Build a NetFlow v5 packet."""
    now = time.time()
    unix_secs = int(now)
    unix_nsecs = int((now - unix_secs) * 1e9)
    sys_uptime = int(now * 1000) & 0xFFFFFFFF

    # NetFlow v5 header (24 bytes)
    header = struct.pack(
        "!HHIIIIBBH",
        5,              # version
        len(flows),     # count
        sys_uptime,     # sys_uptime (ms)
        unix_secs,      # unix_secs
        unix_nsecs,     # unix_nsecs
        random.randint(1, 1000000),  # flow_sequence
        0,              # engine_type
        0,              # engine_id
        0,              # sampling_interval
    )

    flow_data = b""
    for f in flows:
        flow_data += struct.pack(
            "!IIIHHIIIIHHBBBBHHBBH",
            struct.unpack("!I", socket.inet_aton(f["src_ip"]))[0],
            struct.unpack("!I", socket.inet_aton(f["dst_ip"]))[0],
            struct.unpack("!I", socket.inet_aton(f.get("next_hop", "0.0.0.0")))[0],
            random.randint(1, 48),     # input
            random.randint(1, 48),     # output
            f.get("packets", random.randint(1, 1000)),
            f.get("bytes", random.randint(64, 1500000)),
            sys_uptime - random.randint(1000, 60000),  # first
            sys_uptime - random.randint(0, 999),        # last
            f["src_port"],
            f["dst_port"],
            0,                         # pad1
            f.get("tcp_flags", 0),
            f.get("proto", 6),
            f.get("tos", 0),
            f.get("src_as", 0),
            f.get("dst_as", 0),
            f.get("src_mask", 24),
            f.get("dst_mask", 24),
            0,                         # pad2
        )

    return header + flow_data


def generate_sflow_traffic(host, port, count, interval):
    """Send sFlow v5 test packets."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    agent_ips = ["10.0.0.1", "10.0.0.2", "10.0.0.3", "172.16.0.1"]
    src_ips = ["192.168.1.10", "192.168.1.20", "192.168.2.30", "10.1.1.100", "10.2.2.200"]
    dst_ips = ["8.8.8.8", "1.1.1.1", "172.217.14.206", "151.101.1.140", "104.16.132.229"]
    protocols = [6, 17, 1]  # TCP, UDP, ICMP
    services = [
        (80, "HTTP"), (443, "HTTPS"), (53, "DNS"), (22, "SSH"),
        (3306, "MySQL"), (5432, "PostgreSQL"), (6379, "Redis"),
    ]

    print(f"Sending {count} sFlow v5 datagrams to {host}:{port}...")
    for i in range(count):
        num_samples = random.randint(1, 4)
        samples = []
        for _ in range(num_samples):
            src = random.choice(src_ips)
            dst = random.choice(dst_ips)
            proto = random.choice(protocols)
            svc = random.choice(services)
            src_port = random.randint(1024, 65535)
            dst_port = svc[0]
            byte_count = random.randint(64, 9000)
            samples.append(build_flow_sample(src, dst, src_port, dst_port, proto, byte_count))

        agent = random.choice(agent_ips)
        datagram = build_sflow_v5_datagram(agent, i + 1, samples)
        sock.sendto(datagram, (host, port))

        if (i + 1) % 50 == 0:
            print(f"  sFlow: sent {i + 1}/{count} datagrams")
        time.sleep(interval)

    sock.close()
    print(f"sFlow: done sending {count} datagrams")


def generate_netflow_traffic(host, port, count, interval):
    """Send NetFlow v5 test packets."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    src_ips = ["10.10.0.5", "10.10.0.15", "10.10.0.25", "172.20.1.50", "172.20.2.100"]
    dst_ips = ["93.184.216.34", "13.107.42.14", "140.82.121.4", "52.85.83.31", "199.232.69.194"]
    services = [
        (80, 6, "HTTP"), (443, 6, "HTTPS"), (53, 17, "DNS"),
        (22, 6, "SSH"), (8080, 6, "Alt-HTTP"), (123, 17, "NTP"),
    ]

    print(f"Sending {count} NetFlow v5 packets to {host}:{port}...")
    for i in range(count):
        num_flows = random.randint(1, 10)
        flows = []
        for _ in range(num_flows):
            svc = random.choice(services)
            flows.append({
                "src_ip": random.choice(src_ips),
                "dst_ip": random.choice(dst_ips),
                "src_port": random.randint(1024, 65535),
                "dst_port": svc[0],
                "proto": svc[1],
                "tcp_flags": 0x1B if svc[1] == 6 else 0,
                "packets": random.randint(1, 500),
                "bytes": random.randint(64, 1500000),
                "src_as": random.choice([0, 64512, 65001]),
                "dst_as": random.choice([0, 15169, 13335, 16509]),
            })

        packet = build_netflow_v5_packet("10.0.0.1", flows)
        sock.sendto(packet, (host, port))

        if (i + 1) % 50 == 0:
            print(f"  NetFlow: sent {i + 1}/{count} packets")
        time.sleep(interval)

    sock.close()
    print(f"NetFlow: done sending {count} packets")


def main():
    parser = argparse.ArgumentParser(description="Generate test sFlow + NetFlow traffic")
    parser.add_argument("--host", default="127.0.0.1", help="Target host")
    parser.add_argument("--sflow-port", type=int, default=6343, help="sFlow UDP port")
    parser.add_argument("--netflow-port", type=int, default=2055, help="NetFlow UDP port")
    parser.add_argument("--count", type=int, default=200, help="Number of packets per protocol")
    parser.add_argument("--interval", type=float, default=0.05, help="Seconds between packets")
    parser.add_argument("--protocol", choices=["both", "sflow", "netflow"], default="both")
    args = parser.parse_args()

    if args.protocol in ("both", "sflow"):
        generate_sflow_traffic(args.host, args.sflow_port, args.count, args.interval)

    if args.protocol in ("both", "netflow"):
        generate_netflow_traffic(args.host, args.netflow_port, args.count, args.interval)

    print("\nDone! Check the flow-collector logs and NATS for ingested data.")


if __name__ == "__main__":
    main()
