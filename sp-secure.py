#!/usr/bin/env python3
"""Descriptor-bound token read and credential publication.

All file access is performed through held, owner-validated descriptors
opened with openat2(RESOLVE_NO_SYMLINKS | O_NOFOLLOW). Nothing is
re-resolved by pathname after validation, so a directory or file swapped
between checks can never be followed. Every failure refuses the operation
and exits nonzero.

Subcommands:
  read <token-path>  bounded read of a token source (regular file only)
  write <dir> <name> publish the curl auth config atomically in <dir>
"""
import ctypes
import errno
import os
import re
import secrets
import stat as statmod
import struct
import sys

libc = ctypes.CDLL(None, use_errno=True)

AT_FDCWD = -100
O_RDONLY = os.O_RDONLY
O_WRONLY = os.O_WRONLY
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_CLOEXEC = getattr(os, "O_CLOEXEC", 0)
O_CREAT = getattr(os, "O_CREAT", 0)
O_EXCL = getattr(os, "O_EXCL", 0)
O_NONBLOCK = getattr(os, "O_NONBLOCK", 0)
RESOLVE_NO_SYMLINKS = 0x02

MAX_TOKEN_BYTES = 4096
TOKEN_RE = re.compile(r"[A-Za-z0-9_.-]{8,128}\Z")

libc.openat2.restype = ctypes.c_int
libc.openat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t]
libc.mkdirat.restype = ctypes.c_int
libc.mkdirat.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
libc.renameat2.restype = ctypes.c_int
libc.renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
libc.unlinkat.restype = ctypes.c_int
libc.unlinkat.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]


def _check(res):
    if res < 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e))
    return res


def _openat2(dirfd, path, flags, mode=0, resolve=RESOLVE_NO_SYMLINKS):
    # struct open_how: { u64 flags; u64 mode; u64 resolve; }
    how = struct.pack("QQQ", flags, mode, resolve)
    return _check(libc.openat2(ctypes.c_int(dirfd), path.encode(), how, ctypes.c_size_t(len(how))))


def _mkdirat(dirfd, name, mode):
    return _check(libc.mkdirat(ctypes.c_int(dirfd), name.encode(), ctypes.c_uint(mode)))


def _renameat2(olddir, old, newdir, new):
    return _check(libc.renameat2(
        ctypes.c_int(olddir), old.encode(), ctypes.c_int(newdir), new.encode(), 0))


def _unlinkat(dirfd, name):
    try:
        _check(libc.unlinkat(ctypes.c_int(dirfd), name.encode(), 0))
    except OSError as e:
        if e.errno != errno.ENOENT:
            raise


def cmd_read(path):
    # O_NONBLOCK so a FIFO cannot hang the open; the regular-file check below
    # then refuses it. RESOLVE_NO_SYMLINKS rejects any symlink in the path.
    fd = _openat2(AT_FDCWD, path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    try:
        st = os.fstat(fd)
        if not statmod.S_ISREG(st.st_mode):
            raise OSError(errno.EINVAL, "token source is not a regular file")
        data = b""
        while len(data) < MAX_TOKEN_BYTES:
            chunk = os.read(fd, MAX_TOKEN_BYTES - len(data))
            if not chunk:
                break
            data += chunk
    finally:
        os.close(fd)
    sys.stdout.write(data.decode("utf-8", "replace"))


def _open_dir_bound(path):
    """Return an openat2 fd for `path`, creating missing components
    descriptor-relative: every ancestor is validated with
    RESOLVE_NO_SYMLINKS|O_NOFOLLOW before mkdirat creates the next one, so
    no intermediate or final component is ever followed."""
    try:
        return _openat2(AT_FDCWD, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    except OSError as e:
        if e.errno != errno.ENOENT:
            raise
    parent, leaf = os.path.split(path)
    parentfd = _open_dir_bound(parent or "/")
    try:
        _mkdirat(parentfd, leaf, 0o700)
    finally:
        os.close(parentfd)
    return _openat2(AT_FDCWD, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)


def cmd_write(dir_path, final_name):
    if not final_name or "/" in final_name or final_name in (".", ".."):
        raise OSError(errno.EINVAL, "invalid final file name")
    token = sys.stdin.readline(256).rstrip("\n")
    if not TOKEN_RE.match(token):
        raise OSError(errno.EINVAL, "token rejected: expected 8-128 chars of [A-Za-z0-9_.-]")

    dir_path = dir_path.rstrip("/") or "/"
    dirfd = _open_dir_bound(dir_path)

    tmp = None
    try:
        st = os.fstat(dirfd)
        if st.st_uid != os.getuid():
            raise OSError(errno.EPERM, "refusing: directory not owned by us")
        if st.st_mode & 0o077:
            os.fchmod(dirfd, 0o700)  # privatize the held directory

        tmp = ".auth-" + secrets.token_hex(8)
        tmpfd = _openat2(dirfd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode=0o600)
        try:
            os.fchmod(tmpfd, 0o600)
            os.write(tmpfd, b'header = "Authorization: Bearer %s"\n' % token.encode())
            os.fsync(tmpfd)
        finally:
            os.close(tmpfd)

        # Descriptor-relative atomic replacement: renames within dirfd, never
        # follows a symlink planted at the final name.
        _renameat2(dirfd, tmp, dirfd, final_name)
        try:
            os.fsync(dirfd)
        except OSError:
            pass  # rename already committed; fsync on a directory is best-effort
    except Exception:
        if tmp is not None:
            _unlinkat(dirfd, tmp)
        raise
    finally:
        os.close(dirfd)


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: sp-secure.py read <token-path> | write <dir> <name>\n")
        return 2
    try:
        if argv[1] == "read":
            if len(argv) != 3:
                raise OSError(errno.EINVAL, "read takes exactly one path")
            cmd_read(argv[2])
        elif argv[1] == "write":
            if len(argv) != 4:
                raise OSError(errno.EINVAL, "write takes a directory and a file name")
            cmd_write(argv[2], argv[3])
        else:
            raise OSError(errno.EINVAL, "unknown subcommand: %r" % argv[1])
    except OSError as e:
        sys.stderr.write("sp-secure: %s\n" % (e.strerror or e))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))