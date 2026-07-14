/// Operation field value in an ARP packet.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Ord, PartialOrd, Hash)]
pub struct ArpOperation(pub u16);

impl ArpOperation {
    pub const REQUEST: ArpOperation = ArpOperation(1);
    pub const REPLY: ArpOperation = ArpOperation(2);
}

impl From<u16> for ArpOperation {
    #[inline]
    fn from(raw: u16) -> Self {
        ArpOperation(raw)
    }
}

#[cfg(test)]
mod tests {
    use crate::ArpOperation;

    #[test]
    pub fn from_u16() {
        assert_eq!(ArpOperation::from(12), ArpOperation(12))
    }
}
