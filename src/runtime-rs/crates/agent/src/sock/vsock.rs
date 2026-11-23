// Copyright (c) 2019-2022 Alibaba Cloud
// Copyright (c) 2019-2022 Ant Group
//
// SPDX-License-Identifier: Apache-2.0
//
use std::convert::TryFrom;
use std::os::fd::AsFd;
use std::os::unix::io::{AsRawFd, OwnedFd};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use nix::errno::Errno;
use nix::poll::{poll, PollFd, PollFlags};
use nix::sys::socket::{
    connect, getsockopt, socket, sockopt, AddressFamily, SockFlag, SockType, VsockAddr,
};
use tokio::net::UnixStream;

use super::{ConnectConfig, Sock, Stream};

/// Per-attempt dial budget for the single connect(2). The transport connect is
/// non-blocking (SOCK_NONBLOCK) and completed/abandoned via poll(POLLOUT) +
/// SO_ERROR, so a dead transport can never stall past this — the
/// reconnect_timeout_ms budget is honoured per attempt instead of only between
/// attempts.
const MAX_DIAL_TIMEOUT_MS: u64 = 2_000;
const MIN_DIAL_TIMEOUT_MS: u64 = 10;

/// Bounds the spawn_blocking closure that performs the connect. A connect(2) to
/// a dead vsock transport blocks forever inside the kernel (the VM is gone but
/// the port is not refused), so without a bound the blocking-pool thread leaks
/// and tokio's shared blocking pool starves — every later Task/* RPC then times
/// out (kata-containers#13746-class teardown wedge, reproduced 2026-11-23 on
/// lu-b300-39: shim alive, QEMU zombie, Task/State + Task/Kill "got error timed
/// out" storm, pod stuck Terminating, FailedKillPod).
fn bounded_dial_timeout_ms(config: &ConnectConfig, backoff: Duration) -> u64 {
    (backoff.as_millis() as u64)
        .clamp(MIN_DIAL_TIMEOUT_MS, MAX_DIAL_TIMEOUT_MS)
        .min(config.reconnect_timeout_ms)
}

/// Connect the vsock, finishing or abandoning the pending connect(2) within
/// `dial_timeout_ms`. Ok(None) means the attempt timed out (retryable).
fn connect_vsock_bounded(sa: &VsockAddr, dial_timeout_ms: u64) -> Result<Option<UnixStream>> {
    let fd = socket(
        AddressFamily::Vsock,
        SockType::Stream,
        SockFlag::SOCK_NONBLOCK | SockFlag::SOCK_CLOEXEC,
        None,
    )
    .context("failed to create vsock socket")?;

    // Non-blocking connect: 0 = connected immediately; EINPROGRESS/EALREADY =
    // in flight; EISCONN = connected; EAGAIN = try again. Anything else is a
    // real failure (e.g. ECONNREFUSED when the transport rejects the port).
    match connect(fd.as_raw_fd(), sa) {
        Ok(()) => return finish_connect(fd),
        Err(Errno::EINPROGRESS) | Err(Errno::EALREADY) | Err(Errno::EISCONN) => {}
        Err(Errno::EAGAIN) => return Ok(None),
        Err(e) => return Err(anyhow!("failed to connect to {sa}: {e}")),
    }

    // Complete or abandon the in-flight connect(2) within the dial budget.
    let mut pfds = [PollFd::new(fd.as_fd(), PollFlags::POLLOUT)];
    match poll(
        &mut pfds,
        u16::try_from(dial_timeout_ms).unwrap_or(u16::MAX),
    ) {
        Ok(n) if n > 0 => {}
        Ok(_) => {
            // Budget expired with the connect(2) still pending: dropping the fd
            // closes it, so no leak and no parked thread; the outer loop retries.
            return Ok(None);
        }
        Err(Errno::EINTR) => return Ok(None),
        Err(e) => return Err(anyhow!("vsock connect poll on {sa}: {e}")),
    }

    // POLLOUT (or POLLERR/POLLHUP): the connect(2) completed — success or
    // failure. SO_ERROR carries the result; 0 means connected.
    let so_err = getsockopt(&fd, sockopt::SocketError).context("getsockopt(SO_ERROR)")?;
    if so_err == 0 {
        return finish_connect(fd);
    }
    Err(anyhow!(
        "failed to connect to {sa}: {}",
        Errno::from_raw(so_err)
    ))
}

/// The connect(2) succeeded: hand the fd to tokio as a non-blocking UnixStream.
fn finish_connect(fd: OwnedFd) -> Result<Option<UnixStream>> {
    let socket = std::os::unix::net::UnixStream::from(fd);
    socket
        .set_nonblocking(true)
        .context("failed to set non-blocking")?;
    Ok(Some(UnixStream::from_std(socket).context("from_std")?))
}

#[derive(Debug, PartialEq)]
pub struct Vsock {
    vsock_cid: u32,
    port: u32,
}

impl Vsock {
    pub fn new(vsock_cid: u32, port: u32) -> Self {
        Self { vsock_cid, port }
    }
}

#[async_trait]
impl Sock for Vsock {
    async fn connect(&self, config: &ConnectConfig) -> Result<Stream> {
        let sock_addr = VsockAddr::new(self.vsock_cid, self.port);
        let deadline = Instant::now() + Duration::from_millis(config.reconnect_timeout_ms);

        let mut backoff = Duration::from_millis(config.dial_timeout_ms);

        let min_backoff = Duration::from_millis(10);
        let max_backoff = Duration::from_millis(500);
        if backoff < min_backoff {
            backoff = min_backoff;
        } else if backoff > max_backoff {
            backoff = max_backoff;
        }

        let mut last_err: Option<anyhow::Error> = None;
        let mut attempts: u64 = 0;

        while Instant::now() < deadline {
            attempts += 1;

            let sa = sock_addr;
            let dial_timeout_ms = bounded_dial_timeout_ms(config, backoff);
            let res: Result<Option<UnixStream>> = tokio::task::spawn_blocking(
                move || -> Result<Option<UnixStream>> {
                    connect_vsock_bounded(&sa, dial_timeout_ms)
                },
            )
            .await
            .context("vsock: connect task join failed")?;

            match res {
                Ok(Some(stream)) => {
                    info!(
                        sl!(),
                        "vsock: connected to {:?} after {} attempts", self, attempts
                    );
                    return Ok(Stream::Vsock(stream));
                }
                // Timed out this attempt (no error): retry until the deadline.
                Ok(None) => {}
                Err(e) => {
                    last_err = Some(e);

                    let now = Instant::now();
                    if now >= deadline {
                        break;
                    }

                    let remaining = deadline.saturating_duration_since(now);
                    let sleep_dur = std::cmp::min(backoff, remaining);

                    trace!(
                        sl!(),
                        "vsock: failed to connect to {:?}, attempts {}, retry after {:?}, err {:?}",
                        self,
                        attempts,
                        sleep_dur,
                        last_err.as_ref().unwrap(),
                    );

                    tokio::time::sleep(sleep_dur).await;

                    backoff = std::cmp::min(backoff.saturating_mul(2), max_backoff);
                }
            }
        }

        Err(anyhow!(
            "vsock: failed to connect to {:?} within {:?} (attempts={}), last_err={:?}",
            self,
            Duration::from_millis(config.reconnect_timeout_ms),
            attempts,
            last_err
        ))
    }
}
