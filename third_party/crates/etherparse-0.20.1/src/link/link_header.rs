use crate::{Ethernet2Header, LinuxSllHeader};

/// The possible headers on the link layer
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LinkHeader {
    LinuxSll(LinuxSllHeader),
    Ethernet2(Ethernet2Header),
}

impl LinkHeader {
    /// Returns `Option::Some` containing the `Ethernet2Header` if self has the
    /// value Ethernet2. Otherwise `Option::None` is returned.
    pub fn ethernet2(self) -> Option<Ethernet2Header> {
        use crate::LinkHeader::*;
        if let Ethernet2(value) = self {
            Some(value)
        } else {
            None
        }
    }

    /// Returns `Option::Some` containing the `Ethernet2Header` if self has the
    /// value Ethernet2. Otherwise `Option::None` is returned.
    pub fn mut_ethernet2(&mut self) -> Option<&mut Ethernet2Header> {
        use crate::LinkHeader::*;
        if let Ethernet2(value) = self {
            Some(value)
        } else {
            None
        }
    }

    /// Returns `Option::Some` containing the `LinuxSllHeader` if self has the
    /// value LinuxSll. Otherwise `Option::None` is returned.
    pub fn linux_sll(self) -> Option<LinuxSllHeader> {
        use crate::LinkHeader::*;
        if let LinuxSll(value) = self {
            Some(value)
        } else {
            None
        }
    }

    /// Returns `Option::Some` containing the `LinuxSllHeader` if self has the
    /// value LinuxSll. Otherwise `Option::None` is returned.
    pub fn mut_linux_sll(&mut self) -> Option<&mut LinuxSllHeader> {
        use crate::LinkHeader::*;
        if let LinuxSll(value) = self {
            Some(value)
        } else {
            None
        }
    }

    /// Returns the size of the link header
    pub fn header_len(&self) -> usize {
        use crate::LinkHeader::*;
        match self {
            Ethernet2(_) => Ethernet2Header::LEN,
            LinuxSll(_) => LinuxSllHeader::LEN,
        }
    }

    /// Write the link header to the given writer.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn write<T: std::io::Write + Sized>(&self, writer: &mut T) -> Result<(), std::io::Error> {
        use crate::LinkHeader::*;
        match self {
            Ethernet2(value) => value.write(writer),
            LinuxSll(value) => value.write(writer),
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::{test_gens::*, *};
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;
    use std::io::Cursor;

    proptest! {
        #[test]
        fn debug(
            ethernet2 in ethernet_2_any(),
            linux_sll in linux_sll_any(),
        ) {
            assert_eq!(
                format!("Ethernet2({:?})", ethernet2),
                format!("{:?}", LinkHeader::Ethernet2(ethernet2.clone())),
            );
            assert_eq!(
                format!("LinuxSll({:?})", linux_sll),
                format!("{:?}", LinkHeader::LinuxSll(linux_sll.clone())),
            );
        }
    }

    proptest! {
        #[test]
        fn clone_eq(
            ethernet2 in ethernet_2_any(),
            linux_sll in linux_sll_any(),
        ) {
            let values = [
                LinkHeader::Ethernet2(ethernet2),
                LinkHeader::LinuxSll(linux_sll),
            ];
            for value in values {
                assert_eq!(value.clone(), value);
            }
        }
    }

    proptest! {
        #[test]
        fn ethernet2(
            ethernet2 in ethernet_2_any(),
            linux_sll in linux_sll_any()
        ) {
            assert_eq!(Some(ethernet2.clone()), LinkHeader::Ethernet2(ethernet2).ethernet2());
            assert_eq!(None, LinkHeader::LinuxSll(linux_sll).ethernet2());
        }

    }
    proptest! {
        #[test]
        fn mut_ethernet2(
            ethernet2 in ethernet_2_any(),
            linux_sll in linux_sll_any()
        ) {
            assert_eq!(Some(&mut ethernet2.clone()), LinkHeader::Ethernet2(ethernet2).mut_ethernet2());
            assert_eq!(None, LinkHeader::LinuxSll(linux_sll).mut_ethernet2());
        }
    }

    proptest! {
        #[test]
        fn linux_sll(
            ethernet2 in ethernet_2_any(),
            linux_sll in linux_sll_any()
        ) {
            assert_eq!(Some(linux_sll.clone()), LinkHeader::LinuxSll(linux_sll).linux_sll());
            assert_eq!(None, LinkHeader::Ethernet2(ethernet2).linux_sll());
        }

    }
    proptest! {
        #[test]
        fn mut_linux_sll(
            ethernet2 in ethernet_2_any(),
            linux_sll in linux_sll_any()
        ) {
            assert_eq!(Some(&mut linux_sll.clone()), LinkHeader::LinuxSll(linux_sll).mut_linux_sll());
            assert_eq!(None, LinkHeader::Ethernet2(ethernet2).mut_linux_sll());
        }
    }

    proptest! {
        #[test]
        fn header_size(
            ethernet2 in ethernet_2_any(),
            linux_sll in linux_sll_any()
        ) {
            assert_eq!(
                LinkHeader::Ethernet2(ethernet2).header_len(),
                Ethernet2Header::LEN
            );
            assert_eq!(
                LinkHeader::LinuxSll(linux_sll.clone()).header_len(),
                LinuxSllHeader::LEN
            );
        }
    }

    proptest! {
        #[test]
        fn write(
            ethernet2 in ethernet_2_any(),
            linux_sll in linux_sll_any()
        ) {
            // ethernet2
            {
                //write
                {
                    let result_input = {
                        let mut buffer = Vec::new();
                        ethernet2.write(&mut buffer).unwrap();
                        buffer
                    };
                    let result_transport = {
                        let mut buffer = Vec::new();
                        LinkHeader::Ethernet2(ethernet2.clone()).write(&mut buffer).unwrap();
                        buffer
                    };
                    assert_eq!(result_input, result_transport);
                }
                //trigger an error
                {
                    let mut a: [u8;0] = [];
                    assert!(
                        LinkHeader::Ethernet2(ethernet2.clone())
                        .write(&mut Cursor::new(&mut a[..]))
                        .is_err()
                    );
                }
            }
            // linux_sll
            {
                //write
                {
                    let result_input = {
                        let mut buffer = Vec::new();
                        linux_sll.write(&mut buffer).unwrap();
                        buffer
                    };
                    let result_transport = {
                        let mut buffer = Vec::new();
                        LinkHeader::LinuxSll(linux_sll.clone()).write(&mut buffer).unwrap();
                        buffer
                    };
                    assert_eq!(result_input, result_transport);
                }
                //trigger an error
                {
                    let mut a: [u8;0] = [];
                    assert!(
                        LinkHeader::LinuxSll(linux_sll.clone())
                        .write(&mut Cursor::new(&mut a[..]))
                        .is_err()
                    );
                }
            }
        }
    }
}
