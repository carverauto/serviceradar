use anyhow::Result;
use chrono::Utc;
use serde::Serialize;
use sysinfo::{System, Disks};

#[cfg(feature = "zfs")]
use libzetta::zpool::{ZpoolEngine, ZpoolOpen3};
#[cfg(feature = "zfs")]
use libzetta::zfs::{ZfsOpen3, DatasetKind};
use log::{debug, info};

#[derive(Debug, Serialize)]
#[derive(Clone)]
pub struct CpuMetric {
    pub core_id: i32,
    pub usage_percent: f32,
}

#[derive(Debug, Serialize)]
#[derive(Clone)]
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
        debug!("Creating MetricsCollector: host_id={}, filesystems={:?}, zfs_pools={:?}, zfs_datasets={}",
            host_id, filesystems, zfs_pools, zfs_datasets);

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
        debug!("Collecting metrics for host_id={}", self.host_id);

        self.system.refresh_all();
        let timestamp = Utc::now().to_rfc3339();
        debug!("Timestamp: {}", timestamp);

        // CPU metrics
        debug!("Collecting CPU metrics");

        let mut cpus = Vec::new();
        for (idx, cpu) in self.system.cpus().iter().enumerate() {
            let usage = cpu.cpu_usage();
            debug!("CPU core {}: usage={}%", idx, usage);

            cpus.push(CpuMetric {
                core_id: idx as i32,
                usage_percent: cpu.cpu_usage(),
            });
        }

        // Memory metrics
        debug!("Collecting memory metrics");

        let memory = MemoryMetric {
            used_bytes: self.system.used_memory(),
            total_bytes: self.system.total_memory(),
        };
        debug!("Memory: used={} bytes, total={} bytes", memory.used_bytes, memory.total_bytes);

        // Disk metrics
        debug!("Collecting disk metrics for filesystems: {:?}", self.filesystems);

        let mut disks = Vec::new();
        let disks_info = Disks::new_with_refreshed_list();
        for disk in &disks_info {
            let mount_point = disk.mount_point().to_string_lossy().to_string();

            if self.filesystems.is_empty() || self.filesystems.contains(&disk.mount_point().to_string_lossy().to_string()) {
                let used = disk.total_space() - disk.available_space();

                debug!("Disk {}: used={} bytes, total={} bytes", mount_point, used, disk.total_space());

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
                debug!("Collecting ZFS metrics for pools: {:?}", self.zfs_pools);

                let zpool_engine = ZpoolOpen3::with_cmd("/sbin/zpool");
                let zfs_engine = ZfsOpen3::new();

                for pool_name in &self.zfs_pools {
                    for attempt in 1..=3 {
                        debug!("Attempt {} to collect ZFS pool {}", attempt, pool_name);

                        match tokio::task::spawn_blocking({
                            let pool_name_clone = pool_name.clone();
                            move || {
                                zpool_engine.status(&pool_name_clone, libzetta::zpool::open3::StatusOptions::default())
                            }
                        }).await? {
                            Ok(pool) => {
                                let used = pool.used().unwrap_or(0) as u64;
                                let total = pool.size().unwrap_or(0) as u64;
                                debug!("ZFS pool {}: used={} bytes, total={} bytes", pool_name, used, total);

                                disks.push(DiskMetric {
                                    mount_point: format!("zfs:{}", pool_name),
                                    used_bytes: used,
                                    total_bytes: total,
                                });

                                if self.zfs_datasets {
                                    debug!("Collecting datasets for ZFS pool {}", pool_name);

                                    match zfs_engine.list(pool_name).await {
                                        Ok(dataset_pairs) => {
                                            for (kind, path) in dataset_pairs {
                                                if kind == DatasetKind::Filesystem {
                                                    debug!("Processing dataset: {}", path.to_string_lossy());

                                                    match zfs_engine.read_properties(&path).await {
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
            debug!("Collecting ZFS fallback metrics via sysinfo");

            for disk in &disks_info {
                if disk.file_system().to_string_lossy().contains("zfs") {
                    let used = disk.total_space() - disk.available_space();
                    debug!("ZFS disk {}: used={} bytes, total={} bytes", 
                        disk.mount_point().to_string_lossy(), used, disk.total_space());

                    disks.push(DiskMetric {
                        mount_point: disk.mount_point().to_string_lossy().to_string(),
                        used_bytes: disk.total_space() - disk.available_space(),
                        total_bytes: disk.total_space(),
                    });
                }
            }
        }

        debug!("Metrics collected: {} CPUs, {} disks, memory used={} bytes", 
            cpus.len(), disks.len(), memory.used_bytes);

        Ok(MetricSample {
            timestamp,
            host_id: self.host_id.clone(),
            cpus,
            disks,
            memory,
        })
    }
}