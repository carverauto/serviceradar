/*
 * Copyright (C) 2021 Evtech Solutions, Ltd., dba 3D-P
 * Copyright (C) 2021 Neil Tallim <neiltallim@3d-p.com>
 *
 * This file is part of rperf.
 *
 * rperf is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * rperf is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with rperf.  If not, see <https://www.gnu.org/licenses/>.
 */

use std::error::Error;
type BoxResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

pub struct CpuAffinityManager {
    enabled_cores: Vec<core_affinity::CoreId>,
    last_core_pointer: usize,
}

impl CpuAffinityManager {
    pub fn new(cores: &str) -> BoxResult<CpuAffinityManager> {
        let core_ids = core_affinity::get_core_ids().unwrap_or_default();
        log::debug!(
            "enumerated CPU cores: {:?}",
            core_ids.iter().map(|c| c.id).collect::<Vec<usize>>()
        );

        let mut enabled_cores = Vec::new();
        for cid in cores.split(',') {
            if cid.is_empty() {
                continue;
            }
            let cid_usize: usize = cid
                .parse()
                .map_err(|e| Box::new(e) as Box<dyn Error + Send + Sync>)?;
            let mut cid_valid = false;
            for core_id in &core_ids {
                if core_id.id == cid_usize {
                    enabled_cores.push(core_id.clone());
                    cid_valid = true;
                }
            }
            if !cid_valid {
                log::warn!("unrecognised CPU core: {}", cid_usize);
            }
        }
        if enabled_cores.len() > 0 {
            log::debug!("selecting from CPU cores {:?}", enabled_cores);
        } else {
            log::debug!("not applying CPU core affinity");
        }

        Ok(CpuAffinityManager {
            enabled_cores,
            last_core_pointer: 0,
        })
    }

    pub fn set_affinity(&mut self) {
        if self.enabled_cores.len() > 0 {
            let core_id = self.enabled_cores[self.last_core_pointer];
            log::debug!("setting CPU affinity to {}", core_id.id);
            core_affinity::set_for_current(core_id);
            if self.last_core_pointer == self.enabled_cores.len() - 1 {
                self.last_core_pointer = 0;
            } else {
                self.last_core_pointer += 1;
            }
        } else {
            log::debug!("CPU affinity is not configured; not doing anything");
        }
    }
}
