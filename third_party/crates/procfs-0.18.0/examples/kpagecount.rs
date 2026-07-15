//
// Print the physical memory page with the most references
//
// Require CAP_SYS_ADMIN privilege, or root
//
// Sample output:
//
// Found RAM here: 0x1000-0x9fbff
// Lots of references to this locations: addr=0x9d000, pfn=157, refs=0
// Found RAM here: 0x100000-0xdffeffff
// Lots of references to this locations: addr=0x81ba3000, pfn=531363, refs=128
// Found RAM here: 0x100000000-0x11fffffff
// Lots of references to this locations: addr=0x1b575000, pfn=111989, refs=134
//

use procfs::prelude::*;

fn main() {
    if !rustix::process::geteuid().is_root() {
        panic!("ERROR: Access to /proc/iomem requires root, re-run with sudo");
    }

    let page_size = procfs::page_size();

    // /proc/iomem contain a list of memory mapping, but we're only interested in RAM mapping
    let iomem = procfs::iomem().expect("Can't open /proc/iomem");

    let ram = iomem
        .iter()
        .filter_map(|(_, map)| if map.name == "System RAM" { Some(map) } else { None });
    let mut kpagecount = procfs::KPageCount::new().expect("Can't open /proc/kpagecount");

    for map in ram {
        println!("Found RAM here: 0x{:x}-0x{:x}", map.address.0, map.address.1);

        // Physical memory is divided into pages of `page_size` bytes (usually 4kiB)
        // Each page is referenced by its Page Fram Number (PFN)
        let (start_pfn, end_pfn) = map.get_range().get();

        let page_references = kpagecount
            .get_count_in_range(start_pfn, end_pfn)
            .expect("Can't read from /proc/kpagecount");

        // find the page with most references
        let (pfn, refs) = page_references
            .iter()
            .enumerate()
            .max_by(|(_, a), (_, b)| a.cmp(b))
            .unwrap();

        println!(
            "Lots of references to this locations: addr=0x{:x}, pfn={}, refs={}",
            pfn * page_size as usize,
            pfn,
            refs
        );
    }
}
