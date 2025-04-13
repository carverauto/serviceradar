use anyhow::Result;
use chrono::Utc;
use serde::Serialize;
use sysinfo::{System, Disks};
use log::{debug};
use std::sync::Arc;
use tokio::sync::RwLock;

#[cfg(feature = "zfs")]
use libzetta::zpool::{ZpoolEngine, ZpoolOpen3};
#[cfg(feature = "zfs")]
use libzetta::zfs::{ZfsOpen3, DatasetKind};

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
    pub cpus: Vec<CpuMetric>,
    pub disks: Vec<DiskMetric>,
    pub memory: MemoryMetric,
}

#[derive(Debug)]
pub struct MetricsCollector {
    host_id: String,
    filesystems: Vec<String>,
    #[cfg(feature = "zfs")]
    zfs_pools: Vec<String>,
    #[cfg(feature = "zfs")]
    zfs_datasets: bool,
    latest_metrics: Arc<RwLock<Option<MetricSample>>>,
}

impl MetricsCollector {
    pub fn new(host_id: String, filesystems: Vec<String>, zfs_pools: Vec<String>, zfs_datasets: bool) -> Self {
        debug!("Creating MetricsCollector: host_id={}, filesystems={:?}, zfs_pools={:?}, zfs_datasets={}",
            host_id, filesystems, zfs_pools, zfs_datasets);
        Self {
            host_id,
            filesystems,
            #[cfg(feature = "zfs")]
            zfs_pools,
            #[cfg(feature = "zfs")]
            zfs_datasets,
            latest_metrics: Arc::new(RwLock::new(None)),
        }
    }

    pub async fn collect(&mut self) -> Result<MetricSample> {
        debug!("Collecting metrics for host_id={}", self.host_id);
        let mut system = System::new_all();
        system.refresh_all();
        let timestamp = Utc::now().to_rfc3339();
        debug!("Timestamp: {}", timestamp);

        // CPU metrics
        debug!("Collecting CPU metrics");
        let mut cpus = Vec::new();
        for (idx, cpu) in system.cpus().iter().enumerate() {
            let usage = cpu.cpu_usage();
            debug!("CPU core {}: usage={}%", idx, usage);
            cpus.push(CpuMetric {
                core_id: idx as i32,
                usage_percent: usage,
            });
        }

        // Memory metrics
        debug!("Collecting memory metrics");
        let memory = MemoryMetric {
            used_bytes: system.used_memory(),
            total_bytes: system.total_memory(),
        };
        debug!("Memory: used={} bytes, total={} bytes", memory.used_bytes, memory.total_bytes);

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
                                    let used = pool.used().unwrap_or(0) as u64;
                                    let total = pool.size().unwrap_or(0) as u64;
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
                                                                        used_bytes: used,
                                                                        total_bytes: used + avail,
                                                                    });
                                                                }
                                                            }
                                                            Err(e) => {
                                                                error!("Failed to read properties for dataset {}: {}",
                                                                    path.to_string_lossy(), e);
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                            Err(e) => {
                                                error!("Failed to list datasets for ZFS pool {}: {}", pool_name, e);
                                            }
                                        }
                                    }
                                    break;
                                }
                                Err(e) => {
                                    error!("Attempt {} failed for ZFS pool {}: {}", attempt, pool_name, e);
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