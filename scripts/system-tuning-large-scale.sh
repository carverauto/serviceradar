#!/bin/bash

# System tuning script for large-scale ServiceRadar deployments
# Optimized for 50k devices, 600k ports scanning

echo "Applying system-level optimizations for large-scale ServiceRadar deployment..."

# Network buffer tuning for high throughput scanning
echo "Tuning network buffers..."
echo 'net.core.rmem_max = 134217728' >> /etc/sysctl.conf        # 128MB receive buffer
echo 'net.core.wmem_max = 134217728' >> /etc/sysctl.conf        # 128MB send buffer  
echo 'net.core.rmem_default = 65536' >> /etc/sysctl.conf
echo 'net.core.wmem_default = 65536' >> /etc/sysctl.conf
echo 'net.core.netdev_max_backlog = 30000' >> /etc/sysctl.conf   # Handle more packets in queue

# Socket and connection tuning
echo "Tuning socket limits..."
echo 'net.core.somaxconn = 32768' >> /etc/sysctl.conf           # More pending connections
echo 'net.ipv4.tcp_max_syn_backlog = 16384' >> /etc/sysctl.conf # More SYN backlog
echo 'net.netfilter.nf_conntrack_max = 1048576' >> /etc/sysctl.conf # More connection tracking

# Raw socket and packet processing limits
echo "Tuning packet processing..."
echo 'net.core.netdev_budget = 600' >> /etc/sysctl.conf         # More packets per CPU cycle
echo 'net.core.dev_weight = 64' >> /etc/sysctl.conf             # More work per device

# Memory and file descriptor limits
echo "Tuning system limits..."
echo 'fs.file-max = 2097152' >> /etc/sysctl.conf               # More file descriptors
echo 'vm.max_map_count = 524288' >> /etc/sysctl.conf           # More memory maps

# Apply sysctl changes
echo "Applying sysctl changes..."
sysctl -p

# Set process limits for serviceradar user
echo "Setting process limits..."
cat >> /etc/security/limits.conf << EOF
serviceradar soft nofile 1048576
serviceradar hard nofile 1048576  
serviceradar soft nproc 65536
serviceradar hard nproc 65536
EOF

# Docker/container resource recommendations
echo "Container resource recommendations:"
echo "  CPU: 8 cores minimum (4000m)"
echo "  Memory: 16GB minimum" 
echo "  Disk: SSD recommended for KV store"
echo ""

# Go runtime tuning recommendations
echo "Go runtime environment variables to set:"
echo "  export GOGC=200          # Reduce GC frequency for large heaps"
echo "  export GOMAXPROCS=8      # Match container CPU limits"  
echo "  export GOMEMLIMIT=14GiB  # Set memory limit (leave 2GB for system)"
echo ""

# ServiceRadar-specific tuning
echo "ServiceRadar configuration tuning:"
echo "  - Use the optimized sweep-config-optimized.json configuration"
echo "  - Monitor memory usage and adjust ring buffer settings if needed"
echo "  - Consider sharding across multiple instances if scanning >100k devices"
echo "  - Tune KV store (NATS/Redis) for high throughput operations"
echo ""

echo "System tuning complete. Reboot recommended to ensure all changes take effect."