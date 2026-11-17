use std::fs::File;
use std::os::fd::{AsRawFd, FromRawFd};

pub(crate) fn open_at(directory: &File, name: &str, flags: i32) -> std::io::Result<File> {
    if name.is_empty() || name == "." || name == ".." || name.contains('/') {
        return Err(std::io::ErrorKind::InvalidInput.into());
    }
    let name = std::ffi::CString::new(name)?;
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // openat transferred ownership of a new descriptor to this File.
    Ok(unsafe { File::from_raw_fd(fd) })
}
