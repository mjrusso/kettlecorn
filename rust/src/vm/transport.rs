use crate::engine::expiration;
use crate::protocol::{self, Event};
use crate::{Error, Value};
use anyhow::{Context, Result, anyhow, bail};
use futures_util::{FutureExt, StreamExt, pin_mut, stream};
use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::panic::AssertUnwindSafe;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;
use tokio::io::{self, AsyncRead, AsyncReadExt, AsyncWriteExt, BufReader, DuplexStream, WriteHalf};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, broadcast, mpsc, oneshot};
use tokio::task::{AbortHandle, JoinSet};
use tokio::time::{Instant, timeout, timeout_at};

use super::HostFunction;

const REQUEST_BYTES: usize = 2 * (protocol::MAX_FRAME_BYTES + 4);
const REJECTIONS: usize = 8;
const EVENT_HISTORY: usize = 16;
const MAX_DRAIN_BYTES: usize = 64 * 1024 * 1024;
const MAX_SERVE_BATCH: usize = 16;

type Reply = oneshot::Sender<Result<Value, Error>>;

pub(super) struct Client {
    submit: mpsc::UnboundedSender<Request>,
    bytes: Arc<Semaphore>,
    active: Arc<Semaphore>,
    last_id: AtomicU32,
    events: broadcast::WeakSender<Value>,
}

pub(super) struct Inbox {
    requests: mpsc::UnboundedReceiver<Request>,
    events: broadcast::Sender<Value>,
}

struct Request {
    id: u32,
    frame: Frame,
    pending: Pending,
}

struct Frame {
    bytes: Vec<u8>,
    _permit: OwnedSemaphorePermit,
}

enum Outgoing {
    Request(Request),
    HostReply(Frame),
}

struct Writing {
    outgoing: Outgoing,
    deadline: Instant,
    offset: usize,
}

impl Writing {
    fn remaining(&self) -> &[u8] {
        let frame = match &self.outgoing {
            Outgoing::Request(request) => &request.frame,
            Outgoing::HostReply(frame) => frame,
        };
        &frame.bytes[self.offset..]
    }
}

struct Pending {
    reply: Reply,
    deadline: Instant,
    guest_budget: Duration,
    cast: bool,
    _active: OwnedSemaphorePermit,
}

impl Client {
    pub(super) fn new(capacity: usize, events: Option<broadcast::Sender<Value>>) -> (Self, Inbox) {
        let (submit, requests) = mpsc::unbounded_channel();
        let events = events.unwrap_or_else(|| broadcast::channel(EVENT_HISTORY).0);
        (
            Self {
                submit,
                bytes: Arc::new(Semaphore::new(REQUEST_BYTES)),
                active: Arc::new(Semaphore::new(capacity)),
                last_id: AtomicU32::new(0),
                events: events.downgrade(),
            },
            Inbox { requests, events },
        )
    }

    pub(super) fn subscribe(&self) -> broadcast::Receiver<Value> {
        self.events
            .upgrade()
            .map(|events| events.subscribe())
            .unwrap_or_else(|| broadcast::channel(1).1)
    }

    pub(super) async fn request(
        &self,
        deadline: Instant,
        guest_budget: Duration,
        cast: bool,
        encode: impl FnOnce(u32) -> Result<Vec<u8>>,
    ) -> Result<Value, Error> {
        if self.submit.is_closed() {
            return Err(Error::Stopped);
        }
        let (reply, response) = oneshot::channel();
        timeout_at(deadline, async {
            let active = self
                .active
                .clone()
                .acquire_owned()
                .await
                .map_err(|_| Error::Stopped)?;
            // Reserve enough for encoding before allocating a packet, then return the unused bytes.
            let mut capacity = self
                .bytes
                .clone()
                .acquire_many_owned((protocol::MAX_FRAME_BYTES + 4) as u32)
                .await
                .map_err(|_| Error::Stopped)?;
            let id = self.next_id()?;
            let bytes = encode(id).map_err(Error::InvalidRequest)?;
            let used = capacity
                .split(bytes.len())
                .expect("frame encoder enforces byte limit");
            drop(capacity);
            self.submit
                .send(Request {
                    id,
                    frame: Frame {
                        bytes,
                        _permit: used,
                    },
                    pending: Pending {
                        reply,
                        deadline,
                        guest_budget,
                        cast,
                        _active: active,
                    },
                })
                .map_err(|_| Error::Stopped)
        })
        .await
        .map_err(|_| Error::Backpressure)??;

        timeout_at(deadline, response)
            .await
            .map_err(|_| Error::Deadline)?
            .map_err(|_| Error::Stopped)?
    }

    fn next_id(&self) -> Result<u32, Error> {
        self.last_id
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |last| {
                last.checked_add(1)
            })
            .map(|last| last + 1)
            .map_err(|_| Error::RequestIdsExhausted)
    }

    pub(super) fn close(&self) {
        self.active.close();
        self.bytes.close();
    }
}

pub(super) struct Callbacks {
    pub functions: HashMap<String, HostFunction>,
    pub deadline: Duration,
    pub capacity: usize,
}

#[derive(Default)]
pub(super) struct Output {
    pub stdout: Option<mpsc::Sender<Vec<u8>>>,
    pub stderr: Option<mpsc::Sender<Vec<u8>>>,
    pub late_loads: Option<mpsc::Sender<String>>,
}

impl Output {
    fn diagnostic(&self, message: fmt::Arguments<'_>) {
        if let Some(stderr) = &self.stderr
            && let Ok(slot) = stderr.try_reserve()
        {
            slot.send(format!("kettlecorn: {message}\n").into_bytes());
        }
    }
}

pub(super) async fn run(
    peer: DuplexStream,
    mut inbox: Inbox,
    ready: oneshot::Sender<()>,
    callbacks: Callbacks,
    write_timeout: Duration,
    output: Output,
    mut exited: oneshot::Receiver<()>,
) -> Result<()> {
    let (reader, mut writer) = tokio::io::split(peer);
    // The stream must keep a partial frame when another select branch wins.
    let frames = stream::unfold(BufReader::new(reader), |mut reader| async move {
        let frame = read_frame(&mut reader).await;
        Some((frame, reader))
    });
    pin_mut!(frames);
    let mut ready = Some(ready);
    let mut normal = VecDeque::new();
    let mut priority = VecDeque::new();
    let mut current: Option<Writing> = None;
    let mut pending: HashMap<u32, Pending> = HashMap::new();
    let mut calls = JoinSet::<(Vec<u8>, super::HostResult, OwnedSemaphorePermit)>::new();
    // Running callbacks by reply token, so a cancel notice can abort one. A
    // result is sent only while its task is still the token's entry.
    let mut running: HashMap<Vec<u8>, AbortHandle> = HashMap::new();
    let host_slots = Arc::new(Semaphore::new(callbacks.capacity));
    let rejection_slots = Arc::new(Semaphore::new(REJECTIONS));
    let mut reported_decode_error = false;
    let mut reported_oversize = false;
    let mut reported_overload = false;
    let mut served = 0;
    // After the guest exits, only its buffered output remains to read.
    let mut exiting = false;

    loop {
        if served == MAX_SERVE_BATCH {
            tokio::task::yield_now().await;
            served = 0;
        }
        served += 1;

        if guest_exited(&mut exiting, &mut exited) {
            current = None;
            // Their replies could not reach the guest.
            calls.abort_all();
        } else if current.is_none() {
            current = next_write(&mut normal, &mut priority, write_timeout)?;
        }
        let write_deadline = current.as_ref().map(|frame| frame.deadline);
        if write_deadline.is_some_and(|deadline| deadline <= Instant::now()) {
            let frame = current.take().unwrap();
            // Subsequent bytes would be interpreted as part of the incomplete frame.
            anyhow::ensure!(
                frame.offset == 0,
                "write deadline exceeded after a partial guest frame"
            );
            match frame.outgoing {
                Outgoing::Request(request) => {
                    let _ = request.pending.reply.send(Err(Error::Deadline));
                    continue;
                }
                Outgoing::HostReply(_) => {
                    bail!("guest stopped reading before accepting a host reply")
                }
            }
        }

        // Try a newly queued reply before yielding to the guest. When the pipe is
        // backpressured, the select still services reads and independent deadlines.
        let written = write_chunk(&mut writer, current.as_mut()).now_or_never();
        let written = if written.is_some() {
            written
        } else {
            let deadline = pending.values().map(|request| request.deadline).min();
            tokio::select! {
                count = write_chunk(&mut writer, current.as_mut()) => Some(count),
                _ = expiration(write_deadline) => None,
                _ = expiration(deadline) => {
                    let now = Instant::now();
                    for (_, request) in pending.extract_if(|_, request| request.deadline <= now) {
                        let _ = request.reply.send(Err(Error::Deadline));
                    }
                    None
                }
                _ = &mut exited, if !exiting => {
                    exiting = true;
                    None
                }
                request = inbox.requests.recv(), if !exiting => {
                    let Some(request) = request else { return Ok(()); };
                    if !request.pending.reply.is_closed() {
                        normal.push_back(request);
                    }
                    None
                }
                Some(completed) = calls.join_next_with_id(), if !exiting => {
                    match completed {
                        Ok((id, (token, result, slot))) => {
                            // Otherwise the call was cancelled after it finished.
                            if running.get(&token).is_some_and(|handle| handle.id() == id) {
                                running.remove(&token);
                                send_host_reply(&mut priority, &token, result, slot)?;
                            }
                        }
                        // Aborted by a cancel notice; dropping the call released its slot.
                        Err(error) if error.is_cancelled() => {}
                        Err(error) => return Err(error).context("join host callback"),
                    }
                    None
                }
                Some(frame) = frames.next() => {
                    let frame = match frame {
                        Err(_) if guest_exited(&mut exiting, &mut exited) => return Ok(()),
                        frame => frame.context("read guest frame")?,
                    };
                    let Some(frame) = frame else {
                        if !reported_oversize {
                            output.diagnostic(format_args!("discarded oversized guest frame"));
                            reported_oversize = true;
                        }
                        continue;
                    };
                    match protocol::event(&frame)? {
                        // These need a running guest.
                        Some(Event::Ready(_) | Event::HostCall { .. } | Event::RejectedHostCall(_))
                            if guest_exited(&mut exiting, &mut exited) => {}
                        Some(Event::Ready(version)) => {
                            anyhow::ensure!(
                                version == Some(protocol::EMBEDDED_API),
                                "runtime guest does not support embedded API version {} (advertised {version:?})",
                                protocol::EMBEDDED_API
                            );
                            if let Some(ready) = ready.take() {
                                let _ = ready.send(());
                            }
                        }
                        Some(Event::BootFailed) => bail!("guest applications failed to boot"),
                        Some(Event::LateLoad(module)) => match &output.late_loads {
                            Some(sender) => {
                                let _ = sender.try_send(module);
                            }
                            None => output.diagnostic(format_args!("{module} was loaded after preload")),
                        },
                        Some(Event::Undecodable(error)) if !reported_decode_error => {
                            output.diagnostic(format_args!("could not decode guest message: {error}"));
                            reported_decode_error = true;
                        }
                        Some(Event::GuestMessage(value)) => {
                            let _ = inbox.events.send(value);
                        }
                        Some(Event::Output { stderr, bytes }) => {
                            let sender = if stderr { &output.stderr } else { &output.stdout };
                            if let Some(sender) = sender
                                && let Ok(slot) = sender.try_reserve()
                            {
                                slot.send(bytes.to_vec());
                            }
                        }
                        Some(Event::SendResult { id, status }) => {
                            if status != 0 {
                                finish(&mut pending, id, Err(Error::Protocol(anyhow!("guest rejected send (status {status})"))));
                            } else if pending.get(&id).is_some_and(|request| request.cast) {
                                finish(&mut pending, id, Ok(Value::atom("ok")));
                            }
                        }
                        Some(Event::Reply { id, result }) => {
                            finish(&mut pending, id, result.map_err(Error::Protocol));
                        }
                        // Tokens come from the guest; a second call with a live
                        // token is dropped, accepted or not, since a reply would
                        // reach the first call's caller.
                        Some(Event::HostCall { token, .. } | Event::RejectedHostCall(token))
                            if running.contains_key(&token) => {}
                        Some(Event::HostCall { name, args, token }) => {
                            if let Ok(slot) = host_slots.clone().try_acquire_owned() {
                                let Some(function) = callbacks.functions.get(&name).cloned() else {
                                    send_host_reply(&mut priority, &token, Err("no host handler".into()), slot)?;
                                    continue;
                                };
                                let started = Instant::now();
                                let mut call = Box::pin(
                                    AssertUnwindSafe(async move { function(args).await })
                                        .catch_unwind()
                                        .map(|result| result.unwrap_or_else(|_| Err("host function panicked".into())))
                                );
                                if let Some(result) = call.as_mut().now_or_never() {
                                    send_host_reply(&mut priority, &token, result, slot)?;
                                } else {
                                    let waiting = timeout(callbacks.deadline.saturating_sub(started.elapsed()), call);
                                    let key = token.clone();
                                    let handle = calls.spawn(async move {
                                        let result = waiting.await
                                            .unwrap_or_else(|_| Err("host function deadline exceeded".into()));
                                        (token, result, slot)
                                    });
                                    running.insert(key, handle);
                                }
                            } else {
                                reject_host_call(&mut priority, &rejection_slots, &token, "host call capacity exhausted", &output, &mut reported_overload)?;
                            }
                        }
                        Some(Event::RejectedHostCall(token)) => {
                            reject_host_call(&mut priority, &rejection_slots, &token, "invalid or oversized host call arguments", &output, &mut reported_overload)?;
                        }
                        Some(Event::HostCallCancel(token)) => {
                            if let Some(handle) = running.remove(&token) {
                                handle.abort();
                            }
                        }
                        _ => {}
                    }
                    None
                }
            }
        };

        if let Some(written) = written {
            let frame = current.as_mut().unwrap();
            if written.is_err() && guest_exited(&mut exiting, &mut exited) {
                continue;
            }
            let count = written?;
            if count == 0 {
                current = None;
                continue;
            }
            frame.offset += count;
            if frame.remaining().is_empty() {
                let frame = current.take().unwrap();
                if let Outgoing::Request(Request {
                    id,
                    pending: mut request,
                    ..
                }) = frame.outgoing
                {
                    request.deadline = request.deadline.max(Instant::now() + request.guest_budget);
                    pending.insert(id, request);
                }
            }
        }
    }
}

fn next_write(
    normal: &mut VecDeque<Request>,
    priority: &mut VecDeque<Frame>,
    write_timeout: Duration,
) -> Result<Option<Writing>> {
    let now = Instant::now();
    let limit = now
        .checked_add(write_timeout)
        .context("frame write deadline exceeds the clock range")?;
    if let Some(frame) = priority.pop_front() {
        return Ok(Some(Writing {
            outgoing: Outgoing::HostReply(frame),
            deadline: limit,
            offset: 0,
        }));
    }
    while let Some(request) = normal.pop_front() {
        if request.pending.reply.is_closed() {
            continue;
        }
        if request.pending.deadline <= now {
            let _ = request.pending.reply.send(Err(Error::Deadline));
            continue;
        }
        return Ok(Some(Writing {
            deadline: limit.min(request.pending.deadline),
            outgoing: Outgoing::Request(request),
            offset: 0,
        }));
    }
    Ok(None)
}

async fn write_chunk(
    writer: &mut WriteHalf<DuplexStream>,
    frame: Option<&mut Writing>,
) -> Result<usize> {
    let Some(frame) = frame else {
        return std::future::pending().await;
    };
    let count = if let Outgoing::Request(request) = &mut frame.outgoing
        && frame.offset == 0
    {
        tokio::select! {
            biased;
            _ = request.pending.reply.closed() => return Ok(0),
            count = writer.write(&request.frame.bytes) => count,
        }
    } else {
        writer.write(frame.remaining()).await
    }
    .context("write guest frame")?;
    anyhow::ensure!(count != 0, "guest writer closed");
    Ok(count)
}

async fn read_frame(reader: &mut (impl AsyncRead + Unpin)) -> Result<Option<Vec<u8>>> {
    let len = reader.read_u32().await.context("read guest frame length")? as usize;
    if len <= protocol::MAX_FRAME_BYTES {
        let mut frame = vec![0; len];
        reader
            .read_exact(&mut frame)
            .await
            .context("read guest frame body")?;
        return Ok(Some(frame));
    }
    anyhow::ensure!(
        len <= MAX_DRAIN_BYTES,
        "guest frame exceeds drain limit: {len} bytes"
    );
    let drained = io::copy(&mut reader.take(len as u64), &mut io::sink()).await?;
    anyhow::ensure!(drained == len as u64, "truncated oversized guest frame");
    Ok(None)
}

// Records an exit signalled while another branch was ready.
fn guest_exited(exiting: &mut bool, exited: &mut oneshot::Receiver<()>) -> bool {
    *exiting = *exiting || exited.try_recv().is_ok();
    *exiting
}

fn finish(pending: &mut HashMap<u32, Pending>, id: u32, result: Result<Value, Error>) {
    if let Some(request) = pending.remove(&id) {
        let _ = request.reply.send(result);
    }
}

fn send_host_reply(
    priority: &mut VecDeque<Frame>,
    token: &[u8],
    result: Result<Value, String>,
    slot: OwnedSemaphorePermit,
) -> Result<()> {
    let bytes = protocol::reply(token, result).or_else(|_| {
        protocol::reply(
            token,
            Err("host function result exceeds protocol limits".into()),
        )
    })?;
    priority.push_back(Frame {
        bytes,
        _permit: slot,
    });
    Ok(())
}

fn reject_host_call(
    priority: &mut VecDeque<Frame>,
    slots: &Arc<Semaphore>,
    token: &[u8],
    reason: &str,
    output: &Output,
    reported_overload: &mut bool,
) -> Result<()> {
    if let Ok(slot) = slots.clone().try_acquire_owned() {
        send_host_reply(priority, token, Err(reason.into()), slot)?;
    } else if !*reported_overload {
        output.diagnostic(format_args!("guest host-call rejection queue full"));
        *reported_overload = true;
    }
    Ok(())
}

#[cfg(test)]
mod tests;
