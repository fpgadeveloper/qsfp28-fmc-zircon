#!/usr/bin/env python3
"""
echo_test.py — host-side checker for the lwIP TCP echo server.

The standalone application of the Ethernet FMC designs (echo_server, TCP port 7)
echoes every byte it receives. This script is the judge for it: it sends random
payloads to a port's IP address, verifies that exactly the same bytes come back,
and prints a one-line summary plus `VERDICT: PASS` / `VERDICT: FAIL` (exit 0/1).

It is the baremetal counterpart of a design's in-image self-test: there is no
Linux and no SSH on a MicroBlaze target, so the test runs HERE and the board is
judged from the outside (see the design card's hw_test block, access: uart-only).

    echo_test.py 192.168.2.125                       # 100 x 1400 B
    echo_test.py 192.168.2.125 --size 64 --count 500
    echo_test.py 192.168.2.125 --sizes 1,64,1000,1460,20000   # size sweep

Sizes above the path MSS are read back until the whole payload has returned, so
the sweep also exercises segmentation and the receive path's buffering.

Non-interactive and standard-library only, so it runs unattended under
scripts/bench.py (its output lands in the board's transcript).
"""

import argparse
import os
import socket
import sys
import time

DEFAULT_SWEEP = "1,64,1000,1460,20000"


def echo_once(sock, payload, timeout):
    """Send one payload and read exactly len(payload) bytes back.

    Returns (ok, detail). A payload larger than the MSS comes back in several
    segments — keep reading until the full length has arrived or time runs out.
    """
    sock.sendall(payload)
    got = bytearray()
    deadline = time.time() + timeout
    while len(got) < len(payload):
        if time.time() > deadline:
            return False, (f"timeout after {timeout}s with {len(got)}/"
                           f"{len(payload)} bytes echoed back")
        try:
            chunk = sock.recv(min(65536, len(payload) - len(got)))
        except socket.timeout:
            return False, (f"timeout after {timeout}s with {len(got)}/"
                           f"{len(payload)} bytes echoed back")
        if not chunk:
            return False, (f"connection closed by the board after "
                           f"{len(got)}/{len(payload)} bytes")
        got += chunk
    if bytes(got) != payload:
        bad = next((i for i in range(len(payload)) if got[i] != payload[i]), 0)
        return False, (f"payload corrupted at byte {bad} "
                       f"(sent 0x{payload[bad]:02x}, got 0x{got[bad]:02x})")
    return True, ""


def run_size(ip, port, size, count, timeout):
    """One connection, `count` echo exchanges of `size` bytes.
    Returns (ok, exchanges_done, bytes_done, detail)."""
    try:
        sock = socket.create_connection((ip, port), timeout)
    except OSError as e:
        return False, 0, 0, f"cannot connect to {ip}:{port} — {e}"
    sock.settimeout(timeout)
    done = nbytes = 0
    try:
        for _ in range(count):
            payload = os.urandom(size)
            ok, detail = echo_once(sock, payload, timeout)
            if not ok:
                return False, done, nbytes, detail
            done += 1
            nbytes += size
    finally:
        sock.close()
    return True, done, nbytes, ""


def main():
    ap = argparse.ArgumentParser(
        prog="echo_test.py", description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ip", help="IP address of the echo server port to test")
    ap.add_argument("--port", type=int, default=7, help="TCP port (default 7)")
    ap.add_argument("--size", type=int, default=1400,
                    help="payload size in bytes (default 1400)")
    ap.add_argument("--sizes", nargs="?", const=DEFAULT_SWEEP, default=None,
                    metavar="N,N,…",
                    help=f"sweep these payload sizes instead of --size "
                         f"(bare --sizes uses {DEFAULT_SWEEP})")
    ap.add_argument("--count", type=int, default=None,
                    help="exchanges per size (default: 100 for one size, "
                         "3 for a sweep)")
    ap.add_argument("--timeout", type=float, default=5.0,
                    help="seconds to wait for one payload to come back "
                         "(default 5)")
    args = ap.parse_args()

    if args.sizes:
        try:
            sizes = [int(s) for s in args.sizes.replace(" ", "").split(",") if s]
        except ValueError:
            sys.exit(f"echo_test.py: --sizes must be a comma-separated list of "
                     f"byte counts, got {args.sizes!r}")
        if not sizes or min(sizes) < 1:
            sys.exit("echo_test.py: --sizes needs at least one size >= 1")
    else:
        sizes = [args.size]
    count = args.count if args.count is not None else (3 if args.sizes else 100)

    t0 = time.time()
    total_x = total_b = 0
    failure = None
    for size in sizes:
        ok, done, nbytes, detail = run_size(args.ip, args.port, size, count,
                                            args.timeout)
        total_x += done
        total_b += nbytes
        if len(sizes) > 1:
            print(f"  {size:>6} B x {count:<4} {'OK' if ok else 'FAIL: ' + detail}")
        if not ok:
            failure = f"{size} B payload: {detail}"
            break
    dt = max(time.time() - t0, 1e-6)

    target = f"{args.ip}:{args.port}"
    if failure:
        print(f"echo {target}: FAILED after {total_x} exchange(s), "
              f"{total_b} B in {dt:.2f} s — {failure}")
        print("VERDICT: FAIL")
        return 1
    if len(sizes) > 1:
        print(f"echo {target}: TCP echo OK {min(sizes)}..{max(sizes)} B "
              f"({len(sizes)} sizes, {total_x} exchanges, {total_b} B, {dt:.2f} s)")
    else:
        print(f"echo {target}: TCP echo OK {sizes[0]} B x {total_x} "
              f"({total_b} B in {dt:.2f} s, "
              f"{total_b * 8 / dt / 1e6:.1f} Mbit/s round trip)")
    print("VERDICT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
