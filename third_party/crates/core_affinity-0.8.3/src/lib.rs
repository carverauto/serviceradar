//! This crate manages CPU affinities.
//!
//! ## Example
//!
//! This example shows how to create a thread for each available processor and pin each thread to its corresponding processor.
//!
//! ```
//! extern crate core_affinity;
//!
//! use std::thread;
//!
//! // Retrieve the IDs of all active CPU cores.
//! let core_ids = core_affinity::get_core_ids().unwrap();
//!
//! // Create a thread for each active CPU core.
//! let handles = core_ids.into_iter().map(|id| {
//!     thread::spawn(move || {
//!         // Pin this thread to a single CPU core.
//!         let res = core_affinity::set_for_current(id);
//!         if (res) {
//!             // Do more work after this.
//!         }
//!     })
//! }).collect::<Vec<_>>();
//!
//! for handle in handles.into_iter() {
//!     handle.join().unwrap();
//! }
//! ```

#[cfg(any(
    target_os = "android",
    target_os = "linux",
    target_os = "macos",
    target_os = "freebsd",
    target_os = "netbsd"
))]
extern crate libc;

#[cfg_attr(all(not(test), not(target_os = "macos")), allow(unused_extern_crates))]
extern crate num_cpus;

/// This function tries to retrieve information
/// on all the "cores" on which the current thread 
/// is allowed to run.
pub fn get_core_ids() -> Option<Vec<CoreId>> {
    get_core_ids_helper()
}

/// This function tries to pin the current
/// thread to the specified core.
///
/// # Arguments
///
/// * core_id - ID of the core to pin
pub fn set_for_current(core_id: CoreId) -> bool {
    set_for_current_helper(core_id)
}

/// This represents a CPU core.
#[repr(transparent)]
#[derive(Copy, Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct CoreId {
    pub id: usize,
}

// Linux Section

#[cfg(any(target_os = "android", target_os = "linux"))]
#[inline]
fn get_core_ids_helper() -> Option<Vec<CoreId>> {
    linux::get_core_ids()
}

#[cfg(any(target_os = "android", target_os = "linux"))]
#[inline]
fn set_for_current_helper(core_id: CoreId) -> bool {
    linux::set_for_current(core_id)
}

#[cfg(any(target_os = "android", target_os = "linux"))]
mod linux {
    use std::mem;

    use libc::{CPU_ISSET, CPU_SET, CPU_SETSIZE, cpu_set_t, sched_getaffinity, sched_setaffinity};

    use super::CoreId;

    pub fn get_core_ids() -> Option<Vec<CoreId>> {
        if let Some(full_set) = get_affinity_mask() {
            let mut core_ids: Vec<CoreId> = Vec::new();

            for i in 0..CPU_SETSIZE as usize {
                if unsafe { CPU_ISSET(i, &full_set) } {
                    core_ids.push(CoreId{ id: i });
                }
            }

            Some(core_ids)
        }
        else {
            None
        }
    }

    pub fn set_for_current(core_id: CoreId) -> bool {
        // Turn `core_id` into a `libc::cpu_set_t` with only
        // one core active.
        let mut set = new_cpu_set();

        unsafe { CPU_SET(core_id.id, &mut set) };

        // Set the current thread's core affinity.
        let res = unsafe {
            sched_setaffinity(0, // Defaults to current thread
                              mem::size_of::<cpu_set_t>(),
                              &set)
        };
        res == 0
    }

    fn get_affinity_mask() -> Option<cpu_set_t> {
        let mut set = new_cpu_set();

        // Try to get current core affinity mask.
        let result = unsafe {
            sched_getaffinity(0, // Defaults to current thread
                              mem::size_of::<cpu_set_t>(),
                              &mut set)
        };

        if result == 0 {
            Some(set)
        }
        else {
            None
        }
    }

    fn new_cpu_set() -> cpu_set_t {
        unsafe { mem::zeroed::<cpu_set_t>() }
    }

    #[cfg(test)]
    mod tests {
        use num_cpus;

        use super::*;

        #[test]
        fn test_linux_get_affinity_mask() {
            match get_affinity_mask() {
                Some(_) => {},
                None => { assert!(false); },
            }
        }

        #[test]
        fn test_linux_get_core_ids() {
            match get_core_ids() {
                Some(set) => {
                    assert_eq!(set.len(), num_cpus::get());
                },
                None => { assert!(false); },
            }
        }

        #[test]
        fn test_linux_set_for_current() {
            let ids = get_core_ids().unwrap();

            assert!(ids.len() > 0);

            let res = set_for_current(ids[0]);
            assert_eq!(res, true);

            // Ensure that the system pinned the current thread
            // to the specified core.
            let mut core_mask = new_cpu_set();
            unsafe { CPU_SET(ids[0].id, &mut core_mask) };

            let new_mask = get_affinity_mask().unwrap();

            let mut is_equal = true;

            for i in 0..CPU_SETSIZE as usize {
                let is_set1 = unsafe {
                    CPU_ISSET(i, &core_mask)
                };
                let is_set2 = unsafe {
                    CPU_ISSET(i, &new_mask)
                };

                if is_set1 != is_set2 {
                    is_equal = false;
                }
            }

            assert!(is_equal);
        }
     }
}

// Windows Section

#[cfg(target_os = "windows")]
#[inline]
fn get_core_ids_helper() -> Option<Vec<CoreId>> {
    windows::get_core_ids()
}

#[cfg(target_os = "windows")]
#[inline]
fn set_for_current_helper(core_id: CoreId) -> bool {
    windows::set_for_current(core_id)
}

#[cfg(target_os = "windows")]
extern crate winapi;

#[cfg(target_os = "windows")]
mod windows {
    use winapi::shared::basetsd::{DWORD_PTR, PDWORD_PTR};
    use winapi::um::processthreadsapi::{GetCurrentProcess, GetCurrentThread};
    use winapi::um::winbase::{GetProcessAffinityMask, SetThreadAffinityMask};

    use super::CoreId;

    pub fn get_core_ids() -> Option<Vec<CoreId>> {
        if let Some(mask) = get_affinity_mask() {
            // Find all active cores in the bitmask.
            let mut core_ids: Vec<CoreId> = Vec::new();

            for i in 0..64 as u64 {
                let test_mask = 1 << i;

                if (mask & test_mask) == test_mask {
                    core_ids.push(CoreId { id: i as usize });
                }
            }

            Some(core_ids)
        }
        else {
            None
        }
    }

    pub fn set_for_current(core_id: CoreId) -> bool {
        // Convert `CoreId` back into mask.
        let mask: u64 = 1 << core_id.id;

        // Set core affinity for current thread.
        let res = unsafe {
            SetThreadAffinityMask(
                GetCurrentThread(),
                mask as DWORD_PTR
            )
        };
        res != 0
    }

    fn get_affinity_mask() -> Option<u64> {
        let mut system_mask: usize = 0;
        let mut process_mask: usize = 0;

        let res = unsafe {
            GetProcessAffinityMask(
                GetCurrentProcess(),
                &mut process_mask as PDWORD_PTR,
                &mut system_mask as PDWORD_PTR
            )
        };

        // Successfully retrieved affinity mask
        if res != 0 {
            Some(process_mask as u64)
        }
        // Failed to retrieve affinity mask
        else {
            None
        }
    }

    #[cfg(test)]
    mod tests {
        use num_cpus;

        use super::*;

        #[test]
        fn test_windows_get_core_ids() {
            match get_core_ids() {
                Some(set) => {
                    assert_eq!(set.len(), num_cpus::get());
                },
                None => { assert!(false); },
            }
        }

        #[test]
        fn test_windows_set_for_current() {
            let ids = get_core_ids().unwrap();

            assert!(ids.len() > 0);

            assert_ne!(set_for_current(ids[0]), 0);
        }
    }
}

// MacOS Section

#[cfg(target_os = "macos")]
#[inline]
fn get_core_ids_helper() -> Option<Vec<CoreId>> {
    macos::get_core_ids()
}

#[cfg(target_os = "macos")]
#[inline]
fn set_for_current_helper(core_id: CoreId) -> bool {
    macos::set_for_current(core_id)
}

#[cfg(target_os = "macos")]
mod macos {
    use std::mem;

    use libc::{c_int, c_uint, c_void, pthread_self};

    use num_cpus;

    use super::CoreId;

    type kern_return_t = c_int;
    type integer_t = c_int;
    type natural_t = c_uint;
    type thread_t = c_uint;
    type thread_policy_flavor_t = natural_t;
    type mach_msg_type_number_t = natural_t;

    #[repr(C)]
    struct thread_affinity_policy_data_t {
        affinity_tag: integer_t,
    }

    type thread_policy_t = *mut thread_affinity_policy_data_t;

    const THREAD_AFFINITY_POLICY: thread_policy_flavor_t = 4;

    extern {
        fn thread_policy_set(
            thread: thread_t,
            flavor: thread_policy_flavor_t,
            policy_info: thread_policy_t,
            count: mach_msg_type_number_t,
        ) -> kern_return_t;
    }

    pub fn get_core_ids() -> Option<Vec<CoreId>> {
        Some((0..(num_cpus::get())).into_iter()
             .map(|n| CoreId { id: n as usize })
             .collect::<Vec<_>>())
    }

    pub fn set_for_current(core_id: CoreId) -> bool {
        let THREAD_AFFINITY_POLICY_COUNT: mach_msg_type_number_t =
            mem::size_of::<thread_affinity_policy_data_t>() as mach_msg_type_number_t /
            mem::size_of::<integer_t>() as mach_msg_type_number_t;

        let mut info = thread_affinity_policy_data_t {
            affinity_tag: core_id.id as integer_t,
        };

        let res = unsafe {
            thread_policy_set(
                pthread_self() as thread_t,
                THREAD_AFFINITY_POLICY,
                &mut info as thread_policy_t,
                THREAD_AFFINITY_POLICY_COUNT
            )
        };
        res == 0
    }

    #[cfg(test)]
    mod tests {
        use num_cpus;

        use super::*;

        #[test]
        fn test_macos_get_core_ids() {
            match get_core_ids() {
                Some(set) => {
                    assert_eq!(set.len(), num_cpus::get());
                },
                None => { assert!(false); },
            }
        }

        #[test]
        fn test_macos_set_for_current() {
            let ids = get_core_ids().unwrap();
            assert!(ids.len() > 0);
            assert!(set_for_current(ids[0]))
        }
    }
}


// FreeBSD Section

#[cfg(target_os = "freebsd")]
#[inline]
fn get_core_ids_helper() -> Option<Vec<CoreId>> {
    freebsd::get_core_ids()
}

#[cfg(target_os = "freebsd")]
#[inline]
fn set_for_current_helper(core_id: CoreId) -> bool {
    freebsd::set_for_current(core_id)
}

#[cfg(target_os = "freebsd")]
mod freebsd {
    use std::mem;

    use libc::{
        cpuset_getaffinity, cpuset_setaffinity, cpuset_t, CPU_ISSET,
        CPU_LEVEL_WHICH, CPU_SET, CPU_SETSIZE, CPU_WHICH_TID,
    };

    use super::CoreId;

    pub fn get_core_ids() -> Option<Vec<CoreId>> {
        if let Some(full_set) = get_affinity_mask() {
            let mut core_ids: Vec<CoreId> = Vec::new();

            for i in 0..CPU_SETSIZE as usize {
                if unsafe { CPU_ISSET(i, &full_set) } {
                    core_ids.push(CoreId { id: i });
                }
            }

            Some(core_ids)
        } else {
            None
        }
    }

    pub fn set_for_current(core_id: CoreId) -> bool {
        // Turn `core_id` into a `libc::cpuset_t` with only
        // one core active.
        let mut set = new_cpu_set();

        unsafe { CPU_SET(core_id.id, &mut set) };

        // Set the current thread's core affinity.
        let res = unsafe {
            // FreeBSD's sched_setaffinity currently operates on process id,
            // therefore using cpuset_setaffinity instead.
            cpuset_setaffinity(
                CPU_LEVEL_WHICH,
                CPU_WHICH_TID,
                -1, // -1 == current thread
                mem::size_of::<cpuset_t>(),
                &set,
            )
        };
        res == 0
    }

    fn get_affinity_mask() -> Option<cpuset_t> {
        let mut set = new_cpu_set();

        // Try to get current core affinity mask.
        let result = unsafe {
            // FreeBSD's sched_getaffinity currently operates on process id,
            // therefore using cpuset_getaffinity instead.
            cpuset_getaffinity(
                CPU_LEVEL_WHICH,
                CPU_WHICH_TID,
                -1, // -1 == current thread
                mem::size_of::<cpuset_t>(),
                &mut set,
            )
        };

        if result == 0 {
            Some(set)
        } else {
            None
        }
    }

    fn new_cpu_set() -> cpuset_t {
        unsafe { mem::zeroed::<cpuset_t>() }
    }

    #[cfg(test)]
    mod tests {
        use num_cpus;

        use super::*;

        #[test]
        fn test_freebsd_get_affinity_mask() {
            match get_affinity_mask() {
                Some(_) => {}
                None => {
                    assert!(false);
                }
            }
        }

        #[test]
        fn test_freebsd_get_core_ids() {
            match get_core_ids() {
                Some(set) => {
                    assert_eq!(set.len(), num_cpus::get());
                }
                None => {
                    assert!(false);
                }
            }
        }

        #[test]
        fn test_freebsd_set_for_current() {
            let ids = get_core_ids().unwrap();

            assert!(ids.len() > 0);

            let res = set_for_current(ids[0]);
            assert_eq!(res, true);

            // Ensure that the system pinned the current thread
            // to the specified core.
            let mut core_mask = new_cpu_set();
            unsafe { CPU_SET(ids[0].id, &mut core_mask) };

            let new_mask = get_affinity_mask().unwrap();

            let mut is_equal = true;

            for i in 0..CPU_SETSIZE as usize {
                let is_set1 = unsafe { CPU_ISSET(i, &core_mask) };
                let is_set2 = unsafe { CPU_ISSET(i, &new_mask) };

                if is_set1 != is_set2 {
                    is_equal = false;
                }
            }

            assert!(is_equal);
        }
    }
}

// NetBSD Section

#[cfg(target_os = "netbsd")]
#[inline]
fn get_core_ids_helper() -> Option<Vec<CoreId>> {
    netbsd::get_core_ids()
}

#[cfg(target_os = "netbsd")]
#[inline]
fn set_for_current_helper(core_id: CoreId) -> bool {
    netbsd::set_for_current(core_id)
}

#[cfg(target_os = "netbsd")]
mod netbsd {
    use libc::{
        pthread_getaffinity_np, pthread_setaffinity_np, pthread_self, cpuset_t,
        _cpuset_create, _cpuset_size, _cpuset_set, _cpuset_isset, _cpuset_destroy
    };
    use num_cpus;

    use super::CoreId;

    pub fn get_core_ids() -> Option<Vec<CoreId>> {
        if let Some(full_set) = get_affinity_mask() {
            let mut core_ids: Vec<CoreId> = Vec::new();

            let num_cpus = num_cpus::get();
            for i in 0..num_cpus {
                if unsafe { _cpuset_isset(i as u64, full_set) } >= 0 {
                    core_ids.push(CoreId { id: i });
                }
            }
            unsafe { _cpuset_destroy(full_set) };
            Some(core_ids)
        } else {
            None
        }
    }

    pub fn set_for_current(core_id: CoreId) -> bool {
        let set = unsafe { _cpuset_create() };
        unsafe { _cpuset_set(core_id.id as u64, set) } ;

        let result = unsafe {
            pthread_setaffinity_np(pthread_self(), _cpuset_size(set), set)
        };
        unsafe { _cpuset_destroy(set) };

        match result {
            0 => true,
            _ => false,
        }
    }

    fn get_affinity_mask() -> Option<*mut cpuset_t> {
        let set = unsafe { _cpuset_create() };

        match unsafe {
            pthread_getaffinity_np(pthread_self(), _cpuset_size(set), set)
        } {
            0 => Some(set),
            _ => None,
        }
    }

    #[cfg(test)]
    mod tests {
        use num_cpus;

        use super::*;

        #[test]
        fn test_netbsd_get_affinity_mask() {
            match get_affinity_mask() {
                Some(set) => unsafe { _cpuset_destroy(set); },
                None => {
                    assert!(false);
                }
            }
        }

        #[test]
        fn test_netbsd_get_core_ids() {
            match get_core_ids() {
                Some(set) => {
                    assert_eq!(set.len(), num_cpus::get());
                }
                None => {
                    assert!(false);
                }
            }
        }

        #[test]
        fn test_netbsd_set_for_current() {
            let ids = get_core_ids().unwrap();

            assert!(ids.len() > 0);

            let ci = ids[ids.len() - 1]; // use the last reported core
            let res = set_for_current(ci);
            assert_eq!(res, true);

            // Ensure that the system pinned the current thread
            // to the specified core.
            let new_mask = get_affinity_mask().unwrap();
            assert!(unsafe { _cpuset_isset(ci.id as u64, new_mask) > 0 });
            let num_cpus = num_cpus::get();
            for i in 0..num_cpus {
                if i != ci.id {
                    assert_eq!(0, unsafe { _cpuset_isset(i as u64, new_mask) });
                }
            }
            unsafe { _cpuset_destroy(new_mask) };
        }
    }
}

// Stub Section

#[cfg(not(any(
    target_os = "linux",
    target_os = "android",
    target_os = "windows",
    target_os = "macos",
    target_os = "freebsd",
    target_os = "netbsd"
)))]
#[inline]
fn get_core_ids_helper() -> Option<Vec<CoreId>> {
    None
}

#[cfg(not(any(
    target_os = "linux",
    target_os = "android",
    target_os = "windows",
    target_os = "macos",
    target_os = "freebsd",
    target_os = "netbsd"
)))]
#[inline]
fn set_for_current_helper(_core_id: CoreId) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use num_cpus;

    use super::*;

    // #[test]
    // fn test_num_cpus() {
    //     println!("Num CPUs: {}", num_cpus::get());
    //     println!("Num Physical CPUs: {}", num_cpus::get_physical());
    // }

    #[test]
    fn test_get_core_ids() {
        match get_core_ids() {
            Some(set) => {
                assert_eq!(set.len(), num_cpus::get());
            },
            None => { assert!(false); },
        }
    }

    #[test]
    fn test_set_for_current() {
        let ids = get_core_ids().unwrap();
        assert!(ids.len() > 0);
        assert!(set_for_current(ids[0]))
    }
}
