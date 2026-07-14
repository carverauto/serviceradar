#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub(crate) use self::unix::ReadProcessor;

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub(crate) use self::windows::ReadProcessor;
