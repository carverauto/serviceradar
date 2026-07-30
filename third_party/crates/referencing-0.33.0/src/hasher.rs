use core::hash::{BuildHasherDefault, Hasher};

pub(crate) type BuildNoHashHasher = BuildHasherDefault<NoHashHasher>;

#[derive(Default)]
pub(crate) struct NoHashHasher(u64);

impl Hasher for NoHashHasher {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, _: &[u8]) {
        unreachable!("Should not be used")
    }
    fn write_u8(&mut self, _: u8) {
        unreachable!("Should not be used")
    }
    fn write_u16(&mut self, _: u16) {
        unreachable!("Should not be used")
    }
    fn write_u32(&mut self, _: u32) {
        unreachable!("Should not be used")
    }
    fn write_u64(&mut self, n: u64) {
        self.0 = n;
    }
    fn write_usize(&mut self, _: usize) {
        unreachable!("Should not be used")
    }
    fn write_i8(&mut self, _: i8) {
        unreachable!("Should not be used")
    }
    fn write_i16(&mut self, _: i16) {
        unreachable!("Should not be used")
    }
    fn write_i32(&mut self, _: i32) {
        unreachable!("Should not be used")
    }
    fn write_i64(&mut self, _: i64) {
        unreachable!("Should not be used")
    }
    fn write_isize(&mut self, _: isize) {
        unreachable!("Should not be used")
    }
}

#[cfg(test)]
mod tests {
    use super::NoHashHasher;
    use std::hash::Hasher;

    macro_rules! test_panic {
        ($($method:ident),+ $(,)?) => {
            $(
                mod $method {
                    use super::NoHashHasher;
                    use std::hash::Hasher;

                    #[test]
                    #[should_panic(expected = "Should not be used")]
                    fn test_panic() {
                        let mut hasher = NoHashHasher::default();
                        hasher.$method(42);
                    }
                }
            )+
        };
    }

    test_panic!(
        write_u8,
        write_u16,
        write_u32,
        write_usize,
        write_i8,
        write_i16,
        write_i32,
        write_i64,
        write_isize
    );

    #[test]
    #[should_panic(expected = "Should not be used")]
    fn test_panic_write() {
        let mut hasher = NoHashHasher::default();
        hasher.write(b"a");
    }
}
