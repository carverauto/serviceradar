//
// Print physical memory location for each page for each memory mapping
// This requires CAP_SYS_ADMIN privilege, or root, otherwise physical memory addresses will be zero
//
// Vocabulary
// VA = Virtual Address: memory address from a process point of view
// VPN = Virtual Page Number: page number of the a Virtual Memory address
// PA = Physical Address: memory address in physical memory
// PFN = Page Frame Number: page number of a Physical Address
//

use procfs::process::MMapPath;
use procfs::process::Process;

fn main() {
    if !rustix::process::geteuid().is_root() {
        println!("WARNING: Access to /proc/<PID>/pagemap requires root, re-run with sudo");
    }

    let page_size = procfs::page_size();

    let process = Process::myself().expect("Unable to load myself!");

    let mut pagemap = process.pagemap().unwrap();
    let mem_map = process.maps().unwrap();

    for memory_map in mem_map {
        let va_start = memory_map.address.0;
        let va_end = memory_map.address.1;

        let vpn_start = (va_start / page_size) as usize;
        let vpn_end = (va_end / page_size) as usize;

        // can't scan Vsyscall, so skip it
        if memory_map.pathname == MMapPath::Vsyscall {
            continue;
        }

        println!("Memory mapping {:?}", memory_map);

        for vpn in vpn_start..vpn_end {
            let va = vpn * page_size as usize;
            let page_info = pagemap.get_info(vpn).unwrap();
            match page_info {
                procfs::process::PageInfo::MemoryPage(memory_page) => {
                    let pfn = memory_page.get_page_frame_number();
                    let pa = pfn.0 * page_size;
                    println!("virt_mem: 0x{:x}, pfn: 0x{:x}, phys_addr: 0x{:x}", va, pfn, pa);
                }
                procfs::process::PageInfo::SwapPage(swap_page_flags) => {
                    let swap_type = swap_page_flags.get_swap_type();
                    let swap_offset = swap_page_flags.get_swap_offset();
                    println!(
                        "virt_mem: 0x{:x}, swap: {:}, offset: 0x{:x}",
                        va, swap_type, swap_offset
                    );
                }
            }
        }
    }

    if !rustix::process::geteuid().is_root() {
        println!("\n\nWARNING: Access to /proc/<PID>/pagemap requires root, re-run with sudo");
    }
}
