/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// poller.rs

use anyhow::Result;
use chrono::Utc;
use serde::Serialize;
use sysinfo::{System, Disks, CpuRefreshKind};
use log::{debug, warn, info};
use std::sync::Arc;
use tokio::sync::{Mutex, RwLock};
use std::time::Duration;
use std::net::{UdpSocket, SocketAddr};

#[cfg(feature = "zfs")]
use libzetta::zpool::{ZpoolEngine, ZpoolOpen3};
#[cfg(feature = "zfs")]
use libzetta::zfs::{ZfsOpen3, DatasetKind, ZfsEngine};

#[derive(Debug, Serialize, Clone)]
pub struct CpuMetric {
    pub core_id: i32,
    pub usage_percent: f32,
}

#[derive(Debug, Serialize, Clone)]
pub struct DiskMetric {
    pub mount_point: String,
    pub used_bytes: u64,
    pub total_bytes: u64,
}

#[derive(Debug, Serialize, Clone)]
pub struct MemoryMetric {
    pub used_bytes: u64,
    pub total_bytes: u64,
}

#[derive(Debug, Serialize, Clone)]
pub struct MetricSample {
    pub timestamp: String,
    pub host_id: String,
    pub host_ip: String,
    pub cpus: Vec<CpuMetric>,
    pub disks: Vec<DiskMetric>,
    pub memory: MemoryMetric,
}

#[derive(Debug)]
pub struct MetricsCollector {
    host_id: String,
    host_ip: String,
    filesystems: Vec<String>,
    #[cfg(feature = "zfs")]
    zfs_pools: Vec<String>,
    #[cfg(feature = "zfs")]
    zfs_datasets: bool,
    latest_metrics: Arc<RwLock<Option<MetricSample>>>,
    system: Arc<Mutex<System>>,
}

impl MetricsCollector {
    pub fn new(host_id: String, filesystems: Vec<String>, zfs_pools: Vec<String>, zfs_datasets: bool) -> Self {
        let host_ip = Self::get_local_ip().unwrap_or_else(|| {
            warn!("Failed to determine local IP address, using 'unknown'");
            "unknown".to_string()
        });
        
        debug!("Creating MetricsCollector: host_id={}, host_ip={}, filesystems={:?}, zfs_pools={:?}, zfs_datasets={}",
            host_id, host_ip, filesystems, zfs_pools, zfs_datasets);
        let mut system = System::new_all();
        system.refresh_cpu_specifics(CpuRefreshKind::everything()); // Initial CPU refresh
        system.refresh_memory(); // Initial memory refresh
        let system = Arc::new(Mutex::new(system));
        Self {
            host_id,
            host_ip,
            filesystems,
            #[cfg(feature = "zfs")]
            zfs_pools,
            #[cfg(feature = "zfs")]
            zfs_datasets,
            latest_metrics: Arc::new(RwLock::new(None)),
            system,
        }
    }

    fn get_local_ip() -> Option<String> {
        // Try to connect to a remote address to determine the local IP
        // This doesn't actually send data, just determines which interface would be used
        match UdpSocket::bind("0.0.0.0:0") {
            Ok(socket) => {
                match socket.connect("8.8.8.8:80") {
                    Ok(_) => {
                        match socket.local_addr() {
                            Ok(addr) => {
                                let ip = addr.ip().to_string();
                                info!("Detected local IP address: {}", ip);
                                Some(ip)
                            }
                            Err(e) => {
                                warn!("Failed to get local address: {}", e);
                                None
                            }
                        }
                    }
                    Err(e) => {
                        warn!("Failed to connect to determine local IP: {}", e);
                        None
                    }
                }
            }
            Err(e) => {
                warn!("Failed to bind UDP socket: {}", e);
                None
            }
        }
    }

    pub async fn collect(&mut self) -> Result<MetricSample> {
        debug!("Collecting metrics for host_id={}", self.host_id);

        // CPU metrics with double refresh and delay
        debug!("Collecting CPU metrics");
        let system = Arc::clone(&self.system);
        let cpus = tokio::task::spawn_blocking(move || {
            let mut system = system.blocking_lock();
            system.refresh_cpu_specifics(CpuRefreshKind::everything());
            std::thread::sleep(Duration::from_millis(200)); // Wait 200ms for tick accumulation
            system.refresh_cpu_specifics(CpuRefreshKind::everything());
            let mut cpus = Vec::new();
            for (idx, cpu) in system.cpus().iter().enumerate() {
                let usage = cpu.cpu_usage();
                debug!("CPU core {}: usage={:.2}% (raw={})", idx, usage, usage);
                cpus.push(CpuMetric {
                    core_id: idx as i32,
                    usage_percent: usage,
                });
            }
            cpus
        }).await.map_err(|e| anyhow::anyhow!("Failed to collect CPU metrics: {}", e))?;

        if cpus.is_empty() {
            warn!("No CPU metrics collected, sysinfo returned empty CPU list");
        }

        // Memory metrics
        debug!("Collecting memory metrics");
        let system = Arc::clone(&self.system);
        let memory = tokio::task::spawn_blocking(move || {
            let mut system = system.blocking_lock();
            system.refresh_memory();
            MemoryMetric {
                used_bytes: system.used_memory(),
                total_bytes: system.total_memory(),
            }
        }).await.map_err(|e| anyhow::anyhow!("Failed to collect memory metrics: {}", e))?;
        debug!("Memory: used={} bytes, total={} bytes", memory.used_bytes, memory.total_bytes);

        let timestamp = Utc::now().to_rfc3339();
        debug!("Timestamp: {}", timestamp);

        // Disk metrics (run in spawn_blocking to avoid Send issues)
        debug!("Collecting disk metrics for filesystems: {:?}", self.filesystems);
        let filesystems = self.filesystems.clone();
        let disk_metrics = tokio::task::spawn_blocking(move || {
            let mut disks = Vec::new();
            let disks_info = Disks::new_with_refreshed_list();
            for disk in &disks_info {
                let mount_point = disk.mount_point().to_string_lossy().to_string();
                if filesystems.is_empty() || filesystems.contains(&mount_point) {
                    let used = disk.total_space() - disk.available_space();
                    debug!("Disk {}: used={} bytes, total={} bytes", mount_point, used, disk.total_space());
                    disks.push(DiskMetric {
                        mount_point,
                        used_bytes: used,
                        total_bytes: disk.total_space(),
                    });
                }
            }
            disks
        })
            .await
            .map_err(|e| anyhow::anyhow!("Failed to collect disk metrics: {}", e))?;

        let mut disks = disk_metrics;

        // ZFS metrics
        #[cfg(feature = "zfs")]
        {
            if !self.zfs_pools.is_empty() {
                debug!("Collecting ZFS metrics for pools: {:?}", self.zfs_pools);
                let zfs_pools = self.zfs_pools.clone();
                let zfs_datasets = self.zfs_datasets;
                let zfs_result = tokio::task::spawn_blocking(move || {
                    let mut disks = Vec::new();
                    let zpool_engine = ZpoolOpen3::with_cmd("/sbin/zpool");
                    let zfs_engine = ZfsOpen3::new();

                    for pool_name in &zfs_pools {
                        for attempt in 1..=3 {
                            debug!("Attempt {} to collect ZFS pool {}", attempt, pool_name);
                            match zpool_engine.status(pool_name, libzetta::zpool::open3::StatusOptions::default()) {
                                Ok(pool) => {
                                    let engine = ZpoolOpen3::default();
                                    let props = engine.read_properties(&pool.name())?;
                                    let used = *props.alloc() as u64; // `alloc` is the allocated space (used)
                                    let total = *props.size() as u64; // `size` is the total pool size
                                    debug!("ZFS pool {}: used={} bytes, total={} bytes", pool_name, used, total);
                                    disks.push(DiskMetric {
                                        mount_point: format!("zfs:{}", pool_name),
                                        used_bytes: used,
                                        total_bytes: total,
                                    });

                                    if zfs_datasets {
                                        debug!("Collecting datasets for ZFS pool {}", pool_name);
                                        match zfs_engine.list(pool_name) {
                                            Ok(dataset_pairs) => {
                                                for (kind, path) in dataset_pairs {
                                                    if kind == DatasetKind::Filesystem {
                                                        debug!("Processing dataset: {}", path.to_string_lossy());
                                                        match zfs_engine.read_properties(&path) {
                                                            Ok(props) => {
                                                                if let libzetta::zfs::Properties::Filesystem(fs_props) = props {
                                                                    let used = fs_props.used();
                                                                    let avail = (*fs_props.available()).max(0) as u64;
                                                                    debug!("Dataset {}: used={} bytes, total={} bytes",
                                                                        path.to_string_lossy(), used, used + avail);
                                                                    disks.push(DiskMetric {
                                                                        mount_point: format!("zfs:{}", path.to_string_lossy()),
                                                                        used_bytes: *used,
                                                                        total_bytes: used + avail,
                                                                    });
                                                                }
                                                            }
                                                            Err(e) => {
                                                                warn!("Failed to read properties for dataset {}: {}",
                                                                    path.to_string_lossy(), e);
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                            Err(e) => {
                                                warn!("Failed to list datasets for ZFS pool {}: {}", pool_name, e);
                                            }
                                        }
                                    }
                                    break;
                                }
                                Err(e) => {
                                    warn!("Attempt {} failed for ZFS pool {}: {}", attempt, pool_name, e);
                                    if attempt == 3 {
                                        warn!("Giving up on ZFS pool {}", pool_name);
                                    }
                                }
                            }
                        }
                    }
                    Ok::<Vec<DiskMetric>, anyhow::Error>(disks)
                })
                    .await??;
                disks.extend(zfs_result);
            }
        }

        // Sysinfo fallback for ZFS
        #[cfg(not(feature = "zfs"))]
        {
            debug!("Collecting ZFS fallback metrics via sysinfo");
            let zfs_fallback = tokio::task::spawn_blocking(|| {
                let mut disks = Vec::new();
                let disks_info = Disks::new_with_refreshed_list();
                for disk in &disks_info {
                    if disk.file_system().to_string_lossy().contains("zfs") {
                        let used = disk.total_space() - disk.available_space();
                        debug!(
                            "ZFS disk {}: used={} bytes, total={} bytes",
                            disk.mount_point().to_string_lossy(),
                            used,
                            disk.total_space()
                        );
                        disks.push(DiskMetric {
                            mount_point: disk.mount_point().to_string_lossy().to_string(),
                            used_bytes: used,
                            total_bytes: disk.total_space(),
                        });
                    }
                }
                disks
            })
                .await
                .map_err(|e| anyhow::anyhow!("Failed to collect ZFS fallback metrics: {}", e))?;
            disks.extend(zfs_fallback);
        }

        let sample = MetricSample {
            timestamp,
            host_id: self.host_id.clone(),
            host_ip: self.host_ip.clone(),
            cpus,
            disks,
            memory,
        };
        debug!(
            "Metrics collected: {} CPUs, {} disks, memory used={} bytes",
            sample.cpus.len(),
            sample.disks.len(),
            sample.memory.used_bytes
        );

        // Store the latest metrics
        let mut latest = self.latest_metrics.write().await;
        *latest = Some(sample.clone());
        debug!("Stored latest metrics with timestamp {}", sample.timestamp);

        Ok(sample)
    }

    pub async fn get_latest_metrics(&self) -> Option<MetricSample> {
        let latest = self.latest_metrics.read().await;
        latest.clone()
    }
}