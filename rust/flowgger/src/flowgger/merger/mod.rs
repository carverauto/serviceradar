mod line_merger;
mod nul_merger;
mod syslen_merger;

pub use self::line_merger::LineMerger;
pub use self::nul_merger::NulMerger;
pub use self::syslen_merger::SyslenMerger;

pub trait CloneBoxedMerger {
    fn clone_boxed<'a>(&self) -> Box<dyn Merger + Send + 'a>
    where
        Self: 'a;
}

impl<T: Merger + Clone + Send> CloneBoxedMerger for T {
    fn clone_boxed<'a>(&self) -> Box<dyn Merger + Send + 'a>
    where
        Self: 'a,
    {
        Box::new(self.clone())
    }
}

impl Clone for Box<dyn Merger> {
    fn clone(&self) -> Box<dyn Merger> {
        self.clone_boxed()
    }
}

pub trait Merger: CloneBoxedMerger {
    fn frame(&self, bytes: &mut Vec<u8>);
}
