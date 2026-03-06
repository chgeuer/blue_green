use nix::sys::socket::{
    accept, bind, connect, listen, recvmsg, sendmsg, socket, AddressFamily, Backlog, ControlMessage,
    ControlMessageOwned, MsgFlags, SockFlag, SockType, UnixAddr,
};
use nix::unistd::close;
use rustler::{Atom, Error, NifResult};
use std::io::IoSlice;
use std::io::IoSliceMut;
use std::os::fd::AsRawFd;

mod atoms {
    rustler::atoms! {
        ok,
        error,
    }
}

/// Send a file descriptor over a Unix Domain Socket using SCM_RIGHTS.
///
/// Connects to the UDS at `path`, sends `fd` as ancillary data, then closes
/// the UDS connection. The sent FD remains valid in the calling process.
#[rustler::nif(schedule = "DirtyIo")]
fn send_fd(path: String, fd: i32) -> NifResult<Atom> {
    // Create a UDS stream socket
    let sock = socket(
        AddressFamily::Unix,
        SockType::Stream,
        SockFlag::empty(),
        None,
    )
    .map_err(|e| Error::Term(Box::new(format!("socket(): {e}"))))?;

    let addr = UnixAddr::new(path.as_str())
        .map_err(|e| Error::Term(Box::new(format!("UnixAddr: {e}"))))?;

    connect(sock.as_raw_fd(), &addr)
        .map_err(|e| Error::Term(Box::new(format!("connect(): {e}"))))?;

    // SCM_RIGHTS requires at least 1 byte of "real" data in the message
    let data = [0u8; 1];
    let iov = [IoSlice::new(&data)];

    // Build SCM_RIGHTS ancillary message carrying the target FD
    let fds = [fd];
    let cmsg = [ControlMessage::ScmRights(&fds)];

    sendmsg::<UnixAddr>(sock.as_raw_fd(), &iov, &cmsg, MsgFlags::empty(), None)
        .map_err(|e| Error::Term(Box::new(format!("sendmsg(): {e}"))))?;

    // Close the UDS connection socket (not the passed FD)
    drop(sock);

    Ok(atoms::ok())
}

/// Receive a file descriptor from a Unix Domain Socket using SCM_RIGHTS.
///
/// Binds and listens on a UDS at `path`, accepts one connection, extracts the
/// FD from SCM_RIGHTS ancillary data, cleans up the socket file, and returns
/// the received FD as an integer.
#[rustler::nif(schedule = "DirtyIo")]
fn recv_fd(path: String) -> NifResult<(Atom, i32)> {
    // Remove stale socket file if it exists
    let _ = std::fs::remove_file(&path);

    let listener = socket(
        AddressFamily::Unix,
        SockType::Stream,
        SockFlag::empty(),
        None,
    )
    .map_err(|e| Error::Term(Box::new(format!("socket(): {e}"))))?;

    let addr = UnixAddr::new(path.as_str())        .map_err(|e| Error::Term(Box::new(format!("UnixAddr: {e}"))))?;

    bind(listener.as_raw_fd(), &addr)
        .map_err(|e| Error::Term(Box::new(format!("bind(): {e}"))))?;

    listen(&listener, Backlog::new(1).unwrap())
        .map_err(|e| Error::Term(Box::new(format!("listen(): {e}"))))?;

    let conn_fd = accept(listener.as_raw_fd())
        .map_err(|e| Error::Term(Box::new(format!("accept(): {e}"))))?;

    // SCM_RIGHTS requires at least 1 byte of "real" data in the message
    let mut buf = [0u8; 1];
    let mut iov = [IoSliceMut::new(&mut buf)];
    let mut cmsg_buf = nix::cmsg_space!(std::os::unix::io::RawFd);

    let msg = recvmsg::<UnixAddr>(conn_fd, &mut iov, Some(&mut cmsg_buf), MsgFlags::empty())
        .map_err(|e| Error::Term(Box::new(format!("recvmsg(): {e}"))))?;

    // Extract the FD from SCM_RIGHTS
    let received_fd = msg
        .cmsgs()
        .expect("failed to parse cmsgs")
        .find_map(|cmsg| {
            if let ControlMessageOwned::ScmRights(fds) = cmsg {
                fds.into_iter().next()
            } else {
                None
            }
        })
        .ok_or_else(|| Error::Term(Box::new("no SCM_RIGHTS in message".to_string())))?;

    // Cleanup: close UDS sockets and remove socket file
    let _ = close(conn_fd);
    drop(listener);
    let _ = std::fs::remove_file(&path);

    Ok((atoms::ok(), received_fd))
}

/// Release the caller's reference to a socket FD after handoff.
///
/// Uses dup2() to atomically replace the FD with /dev/null. This:
/// 1. Decrements the kernel socket's refcount (so it fully closes when
///    the new owner is done — no lingering CLOSE_WAIT)
/// 2. Leaves the Erlang port/socket driver with a valid FD (/dev/null)
///    so GC doesn't accidentally close a reused FD number
///
/// We can't use gen_tcp.close or :socket.close because they call shutdown()
/// which sends TCP FIN and kills the connection for all FD holders.
#[rustler::nif]
fn release_fd(fd: i32) -> NifResult<Atom> {
    use std::os::fd::IntoRawFd;

    let devnull = std::fs::File::open("/dev/null")
        .map_err(|e| Error::Term(Box::new(format!("open /dev/null: {e}"))))?;
    let devnull_fd = devnull.into_raw_fd();

    nix::unistd::dup2(devnull_fd, fd)
        .map_err(|e| Error::Term(Box::new(format!("dup2(): {e}"))))?;

    close(devnull_fd)
        .map_err(|e| Error::Term(Box::new(format!("close(): {e}"))))?;

    Ok(atoms::ok())
}

rustler::init!("Elixir.BlueGreen.SocketHandoff");
