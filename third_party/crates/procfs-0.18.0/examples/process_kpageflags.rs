//
// Look for a value in the virtual memory of a process, and physical memory, then prints memory page details
// This shows how to go from virtual address to mapping, and from mapping to physical address.
//
// This requires CAP_SYS_ADMIN privilege, or root
//
// Sample output:
//
// Virtual address of `variable`: 0x7ffd2de4708f
// Found memory mapping
// MemoryMap { address: (140725373272064, 140725373407232), perms: "rw-p", offset: 0, dev: (0, 0), inode: 0, pathname: Stack }
// Found page
// virt_mem: 0x7ffd2de47000, pfn: 0x107b06, phys_addr: 0x107b06000, flags: UPTODATE | LRU | MMAP | ANON | SWAPBACKED
//

use procfs::process::Process;
use procfs::KPageFlags;

fn main() {
    if !rustix::process::geteuid().is_root() {
        // KpageFlags::new().unwrap() will panic either way
        panic!("ERROR: Access to /proc/kpageflags requires root, re-run with sudo");
    }

    let page_size = procfs::page_size();

    // We will inspect this process's own memory
    let process = Process::myself().expect("Unable to load myself!");
    let mut kpageflags = KPageFlags::new().expect("Can't open /proc/kpageflags");

    let mut pagemap = process.pagemap().unwrap();

    // The memory maps are read now, so the value we look for must already exist in RAM when we it this line
    // In this case it works, because the variables already exist in the executable
    // You probably want to put this right above the "for memory_map" loop
    let mem_map = process.maps().unwrap();

    // We allocate memory for a value. This is a trick to get a semi random value
    // The goal is to find this value in physical memory
    let chrono = std::time::Instant::now();
    let variable: u8 = chrono.elapsed().as_nanos() as u8;

    // We could do the same with a constant, the compiler will place this value in a different memory mapping with different properties
    //let constant = 42u8;

    // `ptr` is the virtual address we are looking for
    let ptr = &variable as *const u8;
    println!("Virtual address of `variable`: {:p}", ptr);

    for memory_map in mem_map {
        let mem_start = memory_map.address.0;
        let mem_end = memory_map.address.1;

        if (ptr as u64) < mem_start || (ptr as u64) >= mem_end {
            // pointer is not in this memory mapping
            continue;
        }

        // found the memory mapping where the value is stored
        println!("Found memory mapping\n{:?}", memory_map);

        // memory is split into pages (usually 4 kiB)
        let index_start = (mem_start / page_size) as usize;
        let index_end = (mem_end / page_size) as usize;

        for index in index_start..index_end {
            // we search for the exact page inside the memory mapping
            let virt_mem = index * page_size as usize;

            // ptr must be reside between this page and the next one
            if (ptr as usize) < virt_mem || (ptr as usize) >= virt_mem + page_size as usize {
                continue;
            }

            // we found the exact page where the value resides
            let page_info = pagemap.get_info(index).unwrap();
            match page_info {
                procfs::process::PageInfo::MemoryPage(memory_page) => {
                    let pfn = memory_page.get_page_frame_number();
                    let phys_addr = pfn.0 * page_size;

                    let physical_page_info = kpageflags.get_info(pfn).expect("Can't get kpageflags info");

                    println!(
                        "Found page\nvirt_mem: 0x{:x}, pfn: 0x{:x}, phys_addr: 0x{:x}, flags: {:?}",
                        virt_mem, pfn, phys_addr, physical_page_info
                    );
                }
                procfs::process::PageInfo::SwapPage(swap_page_flags) => {
                    let swap_type = swap_page_flags.get_swap_type();
                    let swap_offset = swap_page_flags.get_swap_offset();

                    println!(
                        "Found page\nvirt_mem: 0x{:x}, swap_type: {:}, swap_offset: 0x{:x}, flags: {:?}",
                        virt_mem, swap_type, swap_offset, swap_page_flags
                    );
                }
            }
        }
    }
}
