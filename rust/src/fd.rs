use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll, ready};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf, unix::AsyncFd};
use wasmtime_wasi::cli::{IsTerminal, StdinStream, StdoutStream};

const OUTPUT_PACKET_BYTES: usize = 64 * 1024;

#[derive(Clone)]
pub struct FdStream {
    backend: Backend,
    terminal: bool,
}
#[derive(Clone)]
enum Backend {
    Poll(Arc<AsyncFd<OwnedFd>>),
    File(Arc<OwnedFd>),
}

pub struct StatusFlags(Vec<(i32, i32)>);
impl StatusFlags {
    pub fn capture(fds: &[i32]) -> io::Result<Self> {
        fds.iter()
            .map(|fd| {
                let flags = unsafe { libc::fcntl(*fd, libc::F_GETFL) };
                if flags < 0 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok((*fd, flags))
                }
            })
            .collect::<io::Result<Vec<_>>>()
            .map(Self)
    }
}
impl Drop for StatusFlags {
    fn drop(&mut self) {
        // Standard descriptors may share one open file description. Restore
        // them together after the runtime and every stream have stopped.
        for (fd, flags) in &self.0 {
            unsafe {
                libc::fcntl(*fd, libc::F_SETFL, *flags);
            }
        }
    }
}

impl FdStream {
    pub fn new(fd: i32) -> io::Result<Self> {
        let terminal = unsafe { libc::isatty(fd) } == 1;
        let duplicate = unsafe { libc::dup(fd) };
        if duplicate < 0 {
            return Err(io::Error::last_os_error());
        }
        // dup creates a descriptor owned by this stream, kept open throughout
        // its AsyncFd registration.
        let owned = unsafe { OwnedFd::from_raw_fd(duplicate) };
        #[cfg(target_os = "linux")]
        if fd == 1 {
            // A larger pipe reduces partial writes. Ttys, files and restricted
            // pipe quotas reject this request and keep their existing behavior.
            unsafe {
                libc::fcntl(duplicate, libc::F_SETPIPE_SZ, 1024 * 1024);
            }
        }
        let flags = unsafe { libc::fcntl(duplicate, libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(duplicate, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
        {
            return Err(io::Error::last_os_error());
        }
        let mut metadata = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe { libc::fstat(duplicate, metadata.as_mut_ptr()) } < 0 {
            return Err(io::Error::last_os_error());
        }
        let mode = unsafe { metadata.assume_init() }.st_mode & libc::S_IFMT;
        // Regular files and non-terminal devices lack portable readiness events.
        let backend = if mode == libc::S_IFREG || (mode == libc::S_IFCHR && !terminal) {
            Backend::File(Arc::new(owned))
        } else {
            let registration =
                unsafe { AsyncFd::register(owned) }.map_err(|error| error.into_parts().1)?;
            Backend::Poll(Arc::new(registration))
        };
        Ok(Self { backend, terminal })
    }
}

impl IsTerminal for FdStream {
    fn is_terminal(&self) -> bool {
        self.terminal
    }
}
impl StdinStream for FdStream {
    fn async_stream(&self) -> Box<dyn AsyncRead + Send + Sync> {
        Box::new(self.clone())
    }
}
impl StdoutStream for FdStream {
    fn async_stream(&self) -> Box<dyn AsyncWrite + Send + Sync> {
        Box::new(self.clone())
    }
}

pub struct Output {
    sender: tokio::sync::mpsc::Sender<Vec<u8>>,
    terminal: bool,
}

pub fn output(fd: i32, packet: bool) -> io::Result<(Output, impl Future<Output = io::Result<()>>)> {
    use tokio::io::AsyncWriteExt;
    let mut destination = FdStream::new(fd)?;
    let terminal = destination.is_terminal();
    let (sender, mut receiver) = tokio::sync::mpsc::channel::<Vec<u8>>(2);
    let pump = async move {
        while let Some(bytes) = receiver.recv().await {
            if packet {
                for chunk in bytes.chunks(OUTPUT_PACKET_BYTES) {
                    destination.write_u32(chunk.len() as u32).await?;
                    destination.write_all(chunk).await?;
                }
            } else {
                destination.write_all(&bytes).await?;
            }
        }
        destination.flush().await
    };
    Ok((Output { sender, terminal }, pump))
}

impl IsTerminal for Output {
    fn is_terminal(&self) -> bool {
        self.terminal
    }
}
impl StdoutStream for Output {
    fn async_stream(&self) -> Box<dyn AsyncWrite + Send + Sync> {
        Box::new(OutputWriter(tokio_util::sync::PollSender::new(
            self.sender.clone(),
        )))
    }
}
struct OutputWriter(tokio_util::sync::PollSender<Vec<u8>>);
impl AsyncWrite for OutputWriter {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        if buf.is_empty() {
            return Poll::Ready(Ok(0));
        }
        ready!(self.0.poll_reserve(cx)).map_err(|_| io::ErrorKind::BrokenPipe)?;
        let count = buf.len().min(1024 * 1024);
        self.0
            .send_item(buf[..count].to_vec())
            .map_err(|_| io::ErrorKind::BrokenPipe)?;
        Poll::Ready(Ok(count))
    }
    // Accepted bytes drain on normal exit, within the execution deadline.
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

impl AsyncRead for FdStream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if buf.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }
        match &self.backend {
            Backend::File(file) => {
                let target = buf.initialize_unfilled();
                let n = unsafe {
                    libc::read(file.as_raw_fd(), target.as_mut_ptr().cast(), target.len())
                };
                if n < 0 {
                    return Poll::Ready(Err(io::Error::last_os_error()));
                }
                buf.advance(n as usize);
                Poll::Ready(Ok(()))
            }
            Backend::Poll(fd) => loop {
                let mut guard = ready!(fd.poll_read_ready(cx))?;
                match guard.try_io(|fd| {
                    let target = buf.initialize_unfilled();
                    let n = unsafe {
                        libc::read(fd.as_raw_fd(), target.as_mut_ptr().cast(), target.len())
                    };
                    if n < 0 {
                        Err(io::Error::last_os_error())
                    } else {
                        Ok(n as usize)
                    }
                }) {
                    Ok(Ok(n)) => {
                        buf.advance(n);
                        return Poll::Ready(Ok(()));
                    }
                    Ok(Err(error)) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Ok(Err(error)) => return Poll::Ready(Err(error)),
                    Err(_) => continue,
                }
            },
        }
    }
}

impl AsyncWrite for FdStream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        match &self.backend {
            Backend::File(file) => {
                let n = unsafe { libc::write(file.as_raw_fd(), buf.as_ptr().cast(), buf.len()) };
                Poll::Ready(if n < 0 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                })
            }
            Backend::Poll(fd) => loop {
                let mut guard = ready!(fd.poll_write_ready(cx))?;
                match guard.try_io(|fd| {
                    let n = unsafe { libc::write(fd.as_raw_fd(), buf.as_ptr().cast(), buf.len()) };
                    if n < 0 {
                        Err(io::Error::last_os_error())
                    } else {
                        Ok(n as usize)
                    }
                }) {
                    Ok(Err(error)) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Ok(result) => return Poll::Ready(result),
                    Err(_) => continue,
                }
            },
        }
    }
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn large_output_survives_partial_writes_and_backpressure() {
        for packet in [false, true] {
            let (writer, reader) = std::os::unix::net::UnixStream::pair().unwrap();
            let (stream, pump) = super::output(writer.as_raw_fd(), packet).unwrap();
            let mut output = Box::into_pin(StdoutStream::async_stream(&stream));
            drop(stream);
            reader.set_nonblocking(true).unwrap();
            let mut reader = tokio::net::UnixStream::from_std(reader).unwrap();
            let data = (0..3 * 1024 * 1024 + 17)
                .map(|n| (n % 251) as u8)
                .collect::<Vec<_>>();
            let mut received = vec![0; data.len()];
            let write = async {
                output.write_all(&data).await.unwrap();
                output.flush().await.unwrap();
                drop(output);
            };
            let read = async {
                if packet {
                    let mut offset = 0;
                    while offset < received.len() {
                        let count = reader.read_u32().await.unwrap() as usize;
                        assert!((1..=OUTPUT_PACKET_BYTES).contains(&count));
                        reader
                            .read_exact(&mut received[offset..offset + count])
                            .await
                            .unwrap();
                        offset += count;
                    }
                } else {
                    reader.read_exact(&mut received).await.unwrap();
                }
            };
            tokio::time::timeout(std::time::Duration::from_secs(5), async {
                tokio::join!(write, read, async {
                    pump.await.unwrap();
                });
            })
            .await
            .unwrap();
            assert_eq!(received, data);
        }
    }

    #[tokio::test]
    async fn restores_aliased_status_flags_after_all_streams_stop() {
        let file = tempfile::tempfile().unwrap();
        let original = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) };
        let alias = file.try_clone().unwrap();
        let flags = StatusFlags::capture(&[file.as_raw_fd(), alias.as_raw_fd()]).unwrap();
        let stream = FdStream::new(file.as_raw_fd()).unwrap();
        let other = FdStream::new(alias.as_raw_fd()).unwrap();
        drop(stream);
        assert_ne!(
            unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) } & libc::O_NONBLOCK,
            0
        );
        drop(other);
        drop(flags);
        assert_eq!(
            unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) },
            original
        );
    }
}
