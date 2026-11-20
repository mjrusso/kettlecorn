//! Bounded byte streams for embedding. No framing is added or removed.

use std::io;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncWrite, DuplexStream, ReadBuf, ReadHalf, WriteHalf};
use wasmtime_wasi::cli::{IsTerminal, StdinStream, StdoutStream};

pub struct Streams {
    pub(crate) stdin: Box<dyn StdinStream + Sync>,
    pub(crate) stdout: Box<dyn StdoutStream + Sync>,
    pub(crate) stderr: Box<dyn StdoutStream + Sync>,
}

impl Streams {
    /// Adapters must poll without blocking the Tokio worker that runs the guest.
    pub fn new(
        stdin: impl StdinStream + Sync + 'static,
        stdout: impl StdoutStream + Sync + 'static,
        stderr: impl StdoutStream + Sync + 'static,
    ) -> Self {
        Self {
            stdin: Box::new(stdin),
            stdout: Box::new(stdout),
            stderr: Box::new(stderr),
        }
    }

    /// Returns guest stdio and its host peer. Capacity bounds each direction;
    /// stderr is discarded. Closing the peer delivers stdin EOF without
    /// implicitly cancelling the guest.
    pub fn memory(capacity: std::num::NonZeroUsize) -> (Self, DuplexStream) {
        let (guest, peer) = tokio::io::duplex(capacity.get());
        let (reader, writer) = tokio::io::split(guest);
        (
            Self::new(
                MemoryInput(Arc::new(Mutex::new(reader))),
                MemoryOutput(Arc::new(Mutex::new(writer))),
                tokio::io::empty(),
            ),
            peer,
        )
    }
}

#[derive(Clone)]
struct MemoryInput(Arc<Mutex<ReadHalf<DuplexStream>>>);
#[derive(Clone)]
struct MemoryOutput(Arc<Mutex<WriteHalf<DuplexStream>>>);

impl IsTerminal for MemoryInput {
    fn is_terminal(&self) -> bool {
        false
    }
}
impl IsTerminal for MemoryOutput {
    fn is_terminal(&self) -> bool {
        false
    }
}
impl StdinStream for MemoryInput {
    fn async_stream(&self) -> Box<dyn AsyncRead + Send + Sync> {
        Box::new(self.clone())
    }
}
impl StdoutStream for MemoryOutput {
    fn async_stream(&self) -> Box<dyn AsyncWrite + Send + Sync> {
        Box::new(self.clone())
    }
}
impl AsyncRead for MemoryInput {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.0.lock().unwrap()).poll_read(cx, buf)
    }
}
impl AsyncWrite for MemoryOutput {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut *self.0.lock().unwrap()).poll_write(cx, buf)
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.0.lock().unwrap()).poll_flush(cx)
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.0.lock().unwrap()).poll_shutdown(cx)
    }
}
