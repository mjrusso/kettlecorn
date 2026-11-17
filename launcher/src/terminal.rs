use std::fs::{File, OpenOptions};
use std::io;
use std::os::unix::fs::{FileExt, OpenOptionsExt};
use std::path::Path;

pub struct Terminal {
    file: File,
    fd: i32,
    pub guest_path: String,
}

impl Terminal {
    pub fn new(root: &Path) -> io::Result<Option<Self>> {
        let Some(fd) = [1, 0]
            .into_iter()
            .find(|fd| unsafe { libc::isatty(*fd) } == 1)
        else {
            return Ok(None);
        };
        let name = format!(".kettlecorn-tty-{}", std::process::id());
        let directory = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC)
            .open(root)?;
        let temporary =
            crate::unix::open_at(&directory, "tmp", libc::O_RDONLY | libc::O_DIRECTORY)?;
        let file = crate::unix::open_at(
            &temporary,
            &name,
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
        )?;
        let terminal = Self {
            file,
            fd,
            guest_path: format!("/tmp/{name}"),
        };
        terminal.update()?;
        Ok(Some(terminal))
    }

    pub fn update(&self) -> io::Result<()> {
        let mut size = std::mem::MaybeUninit::<libc::winsize>::zeroed();
        if unsafe { libc::ioctl(self.fd, libc::TIOCGWINSZ, size.as_mut_ptr()) } < 0 {
            return Err(io::Error::last_os_error());
        }
        let size = unsafe { size.assume_init() };
        // Retain the opened file: a guest can replace its path with a symlink.
        self.file.write_all_at(
            format!("{:05} {:05}\n", size.ws_col, size.ws_row).as_bytes(),
            0,
        )
    }
}
