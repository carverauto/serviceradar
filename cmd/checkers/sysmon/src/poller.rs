use anyhow::Result;
use chrono::Utc;
use serde::Serialize;
use sysinfo::{System, Disks};

#[cfg(feature = "zfs")]
use libzetta::zpool::{ZpoolEngine, ZpoolOpen3};
#[cfg(feature = "zfs")]
use libzetta::zfs::{ZfsOpen3, DatasetKind};

#[derive(Debug, Serialize)]
pub struct CpuMetric {
    pub core_id: i32,
    pub usage_percent: f32,
}

#[derive(Debug, Serialize)]
pub struct DiskMetric {
    pub mount_point: String,
    pub used_bytes: u64,
    pub total_bytes: u64,
}

#[derive(Debug, Serialize)]
pub struct MemoryMetric {
    pub used_bytes: u64,
    pub total_bytes: u64,
}

#[derive(Debug, Serialize)]
pub struct MetricSample {
    pub timestamp: String,
    pub host_id: String,
    pub cpus: Vec<CpuMetric>,
    pub disks: Vec<DiskMetric>,
    pub memory: MemoryMetric,
}

#[derive(Debug)]
pub struct MetricsCollector {
    system: System,
    host_id: String,
    filesystems: Vec<String>,
    #[cfg(feature = "zfs")]
    zfs_pools: Vec<String>,
    #[cfg(feature = "zfs")]
    zfs_datasets: bool,
}

impl MetricsCollector {
    pub fn new(host_id: String, filesystems: Vec<String>, zfs_pools: Vec<String>, zfs_datasets: bool) -> Self {
        let system = System::new_all();
        Self {
            system,
            host_id,
            filesystems,
            #[cfg(feature = "zfs")]
            zfs_pools,
            #[cfg(feature = "zfs")]
            zfs_datasets,
        }
    }

    pub async fn collect(&mut self) -> Result<MetricSample> {
        self.system.refresh_all();
        let timestamp = Utc::now().to_rfc3339();

        // CPU metrics
        let mut cpus = Vec::new();
        for (idx, cpu) in self.system.cpus().iter().enumerate() {
            cpus.push(CpuMetric {
                core_id: idx as i32,
                usage_percent: cpu.cpu_usage(),
            });
        }

        // Memory metrics
        let memory = MemoryMetric {
            used_bytes: self.system.used_memory(),
            total_bytes: self.system.total_memory(),
        };

        // Disk metrics
        let mut disks = Vec::new();
        let disks_info = Disks::new_with_refreshed_list();
        for disk in &disks_info {
            if self.filesystems.is_empty() || self.filesystems.contains(&disk.mount_point().to_string_lossy().to_string()) {
                disks.push(DiskMetric {
                    mount_point: disk.mount_point().to_string_lossy().to_string(),
                    used_bytes: disk.total_space() - disk.available_space(),
                    total_bytes: disk.total_space(),
                });
            }
        }

        // ZFS metrics
        #[cfg(feature = "zfs")]
        {
            if !self.zfs_pools.is_empty() {
                let zpool_engine = ZpoolOpen3::with_cmd("/sbin/zpool");
                let zfs_engine = ZfsOpen3::new();

                for pool_name in &self.zfs_pools {
                    for attempt in 1..=3 {
                        match tokio::task::spawn_blocking({
                            let pool_name_clone = pool_name.clone();
                            move || {
                                zpool_engine.status(&pool_name_clone, libzetta::zpool::open3::StatusOptions::default())
                            }
                        }).await? {
                            Ok(pool) => {
                                let used = pool.used().unwrap_or(0) as u64;
                                let total = pool.size().unwrap_or(0) as u64;
                                disks.push(DiskMetric {
                                    mount_point: format!("zfs:{}", pool_name),
                                    used_bytes: used,
                                    total_bytes: total,
                                });

                                if self.zfs_datasets {
                                    match zfs_engine.list(pool_name).await {
                                        Ok(dataset_pairs) => {
                                            for (kind, path) in dataset_pairs {
                                                if kind == DatasetKind::Filesystem {
                                                    match zfs_engine.read_properties(&path).await {
                                                        Ok(props) => {
                                                            if let libzetta::zfs::Properties::Filesystem(fs_props) = props {
                                                                let used = fs_props.used();
                                                                let avail = (*fs_props.available()).max(0) as u64;
                                                                disks.push(DiskMetric {
                                                                    mount_point: format!("zfs:{}", path.to_string_lossy()),
                                                                    used_bytes: used,
                                                                    total_bytes: used + avail,
                                                                });
                                                            }
                                                        }
                                                        Err(e) => {
                                                            error!("Failed to read properties for dataset {}: {}", path.to_string_lossy(), e);
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
                                if attempt < 3 {
                                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                                } else {
                                    error!("Giving up on ZFS pool {}", pool_name);
                                }
                            }
                        }
                    }
                }
            }
        }

        // Sysinfo fallback for ZFS
        #[cfg(not(feature = "zfs"))]
        {
            for disk in &disks_info {
                if disk.file_system().to_string_lossy().contains("zfs") {
                    disks.push(DiskMetric {
                        mount_point: disk.mount_point().to_string_lossy().to_string(),
                        used_bytes: disk.total_space() - disk.available_space(),
                        total_bytes: disk.total_space(),
                    });
                }
            }
        }

        Ok(MetricSample {
            timestamp,
            host_id: self.host_id.clone(),
            cpus,
            disks,
            memory,
        })
    }
}