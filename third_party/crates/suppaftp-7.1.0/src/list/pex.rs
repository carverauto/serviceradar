/// This enum is used to query about posix permissions on a file
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum PosixPexQuery {
    Owner,
    Group,
    Others,
}

/// Describes the permissions on POSIX system.
#[derive(Debug, Clone, Copy, Eq, PartialEq, Hash)]
pub struct PosixPex {
    read: bool,
    write: bool,
    execute: bool,
}

impl PosixPex {
    /// Returns whether read permission is true
    pub(crate) fn can_read(&self) -> bool {
        self.read
    }

    /// Returns whether write permission is true
    pub(crate) fn can_write(&self) -> bool {
        self.write
    }

    /// Returns whether execute permission is true
    pub(crate) fn can_execute(&self) -> bool {
        self.execute
    }
}

impl Default for PosixPex {
    fn default() -> Self {
        Self {
            read: true,
            write: true,
            execute: true,
        }
    }
}

impl From<u8> for PosixPex {
    fn from(bits: u8) -> Self {
        Self {
            read: ((bits >> 2) & 0x01) != 0,
            write: ((bits >> 1) & 0x01) != 0,
            execute: (bits & 0x01) != 0,
        }
    }
}

#[cfg(test)]
mod tests {

    use super::*;

    #[test]
    fn posix_pex_from_bits() {
        let pex: PosixPex = PosixPex::from(4);
        pretty_assertions::assert_eq!(pex.can_read(), true);
        pretty_assertions::assert_eq!(pex.can_write(), false);
        pretty_assertions::assert_eq!(pex.can_execute(), false);
        let pex: PosixPex = PosixPex::from(0);
        pretty_assertions::assert_eq!(pex.can_read(), false);
        pretty_assertions::assert_eq!(pex.can_write(), false);
        pretty_assertions::assert_eq!(pex.can_execute(), false);
        let pex: PosixPex = PosixPex::from(3);
        pretty_assertions::assert_eq!(pex.can_read(), false);
        pretty_assertions::assert_eq!(pex.can_write(), true);
        pretty_assertions::assert_eq!(pex.can_execute(), true);
        let pex: PosixPex = PosixPex::from(7);
        pretty_assertions::assert_eq!(pex.can_read(), true);
        pretty_assertions::assert_eq!(pex.can_write(), true);
        pretty_assertions::assert_eq!(pex.can_execute(), true);
    }
}
