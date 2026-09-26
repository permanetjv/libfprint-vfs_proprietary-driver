#!/usr/bin/python3
"""Capture one VFS image through vfs_proprietary-capture-helper.

This is a diagnostic tool.  It does not enroll a fingerprint or modify the
sensor database.  By default it validates the helper protocol and discards
the captured image.  Pass --output to write a PGM image for local debugging.
"""

from __future__ import annotations

import argparse
import os
import selectors
import signal
import struct
import subprocess
import sys
import time
from pathlib import Path


READY_MAGIC = 0xAAAAAAAAAAAAAAAA
READY_STRUCT = struct.Struct("=Q")
METADATA_STRUCT = struct.Struct("=iii")
INPUT_STRUCT = struct.Struct("=iii")
MAX_DIMENSION = 1023
MAX_IMAGE_BYTES = MAX_DIMENSION * MAX_DIMENSION


class CaptureError(RuntimeError):
    """The capture helper returned invalid data or failed."""


def _read_available(fd: int, limit: int = 65536) -> bytes:
    chunks: list[bytes] = []
    used = 0
    os.set_blocking(fd, False)
    while used < limit:
        try:
            chunk = os.read(fd, min(8192, limit - used))
        except BlockingIOError:
            break
        if not chunk:
            break
        chunks.append(chunk)
        used += len(chunk)
    return b"".join(chunks)


def _read_exact(fd: int, size: int, deadline: float) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    selector = selectors.DefaultSelector()
    selector.register(fd, selectors.EVENT_READ)
    try:
        while remaining:
            timeout = deadline - time.monotonic()
            if timeout <= 0:
                raise CaptureError(f"timed out with {remaining} bytes still expected")
            if not selector.select(timeout):
                raise CaptureError(f"timed out with {remaining} bytes still expected")
            chunk = os.read(fd, remaining)
            if not chunk:
                raise CaptureError(f"unexpected EOF with {remaining} bytes still expected")
            chunks.append(chunk)
            remaining -= len(chunk)
    finally:
        selector.close()
    return b"".join(chunks)


def validate_metadata(length: int, width: int, height: int) -> None:
    if width <= 0 or height <= 0:
        raise CaptureError(f"invalid image dimensions: {width}x{height}")
    if width > MAX_DIMENSION or height > MAX_DIMENSION:
        raise CaptureError(f"image dimensions exceed {MAX_DIMENSION}: {width}x{height}")
    if length <= 0 or length > MAX_IMAGE_BYTES:
        raise CaptureError(f"invalid image length: {length}")
    if length != width * height:
        raise CaptureError(
            f"image length mismatch: received {length}, expected {width * height}"
        )


def capture(helper: Path, timeout: float) -> tuple[int, int, bytes]:
    pipes = [os.pipe() for _ in range(3)]
    read_fds = [pair[0] for pair in pipes]
    write_fds = [pair[1] for pair in pipes]
    proc: subprocess.Popen[bytes] | None = None
    deadline = time.monotonic() + timeout
    try:
        proc = subprocess.Popen(
            [str(helper)],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            pass_fds=tuple(write_fds),
            start_new_session=True,
        )
        assert proc.stdin is not None
        proc.stdin.write(INPUT_STRUCT.pack(*write_fds))
        proc.stdin.close()
        for fd in write_fds:
            os.close(fd)
        write_fds.clear()

        ready = READY_STRUCT.unpack(_read_exact(read_fds[0], READY_STRUCT.size, deadline))[0]
        if ready != READY_MAGIC:
            raise CaptureError(f"invalid helper-ready marker: 0x{ready:016x}")

        length, width, height = METADATA_STRUCT.unpack(
            _read_exact(read_fds[1], METADATA_STRUCT.size, deadline)
        )
        validate_metadata(length, width, height)
        image = _read_exact(read_fds[2], length, deadline)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise CaptureError("helper did not exit before the deadline")
        returncode = proc.wait(timeout=remaining)
        if returncode != 0:
            assert proc.stderr is not None
            detail = proc.stderr.read().decode(errors="replace").strip()
            raise CaptureError(f"helper exited with {returncode}: {detail}")
        return width, height, image
    except CaptureError as exc:
        detail = ""
        if proc is not None:
            if proc.poll() is None:
                try:
                    proc.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
            if proc.stderr is not None:
                detail = _read_available(proc.stderr.fileno()).decode(errors="replace").strip()
        if detail:
            raise CaptureError(f"{exc}; helper output: {detail}") from exc
        raise
    except subprocess.TimeoutExpired as exc:
        raise CaptureError("helper did not exit before the deadline") from exc
    finally:
        for fd in read_fds + write_fds:
            try:
                os.close(fd)
            except OSError:
                pass
        if proc is not None and proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()


def write_pgm(path: Path, width: int, height: int, image: bytes) -> None:
    with path.open("wb") as stream:
        stream.write(f"P5\n{width} {height}\n255\n".encode())
        stream.write(image)
    path.chmod(0o600)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", type=Path)
    parser.add_argument("--timeout", type=float, default=35.0)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    if not args.helper.is_file() or not os.access(args.helper, os.X_OK):
        parser.error(f"helper is not executable: {args.helper}")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    try:
        width, height, image = capture(args.helper, args.timeout)
        if args.output:
            write_pgm(args.output, width, height, image)
            print(f"captured {width}x{height} image to {args.output}")
        else:
            print(f"captured and validated {width}x{height} image; image discarded")
        return 0
    except CaptureError as exc:
        print(f"capture failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
