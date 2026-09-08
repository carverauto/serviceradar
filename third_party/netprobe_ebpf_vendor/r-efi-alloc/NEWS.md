# r-efi-alloc - UEFI Memory Allocator Integration

## CHANGES WITH 2.1.0:

        * Remove the optional dependency on `compiler-builtins`, which was
          needed to build r-efi-alloc as part of rustc. This is no longer
          necessary.

        Contributions from: David Rheinsberg, Trevor Gross

        - Dußlingen, 2025-06-17

## CHANGES WITH 2.0.0:

        * Update to r-efi-5.2.0. Since `r_efi::efi::SystemTable` is re-exposed
          through `r-efi-alloc`, this requires a major version bump.

        * Set MSRV to 1.68 to synchronize with r-efi.

        Contributions from: Ayush Singh, David Rheinsberg

        - Dußlingen, 2025-04-25

## CHANGES WITH 1.0.0:

        * Initial release of r-efi-alloc.

        Contributions from: Ayush Singh, David Rheinsberg, Mizuho MORI,
                            Tom Gundersen

        - Dußlingen, 2022-12-02
