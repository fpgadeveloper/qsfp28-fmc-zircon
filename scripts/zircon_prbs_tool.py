#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""zircon_prbs_tool.py - host side of the zircon_nic 1.2.0 UDP generator / checker.

Standard library only, no root. The payload definition is the one in
docs/source/registers.md ("Payload") and DESIGN_SPEC section 10.1: bytes 0-7
carry the 64-bit sequence number S (little-endian), bytes 8.. eight xorshift64
lanes seeded from S.

  listen  receive datagrams from the board's generator and verify every one
          zircon_prbs_tool.py listen --port 6000 --count 1000 [--bind 192.168.21.1]
  send    send PRBS datagrams (sequence 0..N-1) to the board's checker
          zircon_prbs_tool.py send 192.168.21.162 --count 10000 --len 1000
          [--port 5001] [--start-seq 0] [--flip-bit SEQ:BIT]

Both print one summary line and 'VERDICT: PASS|FAIL' (exit code 0|1). For
`send`, the verdict only means that every datagram was handed to the kernel.
Judge the board by its CHK_* counters.
"""
import argparse
import socket
import sys
import time

M = (1 << 64) - 1
K = [((j + 1) * 0x9E3779B97F4A7C15) & M for j in range(8)]


def xs(x):
    x ^= (x << 13) & M
    x ^= x >> 7
    x ^= (x << 17) & M
    return x


def gen_payload(seq, n):
    """The generator's payload of length n (n >= 8) for sequence number seq."""
    x = [(seq ^ k) | (1 << 63) for k in K]
    out = bytearray()
    while len(out) < n:
        x = [xs(v) for v in x]
        out += b"".join(v.to_bytes(8, "little") for v in x)
    return seq.to_bytes(8, "little") + bytes(out[8:n])


def bit_errors(a, b):
    return sum(bin(x ^ y).count("1") for x, y in zip(a, b)) + 8 * abs(len(a) - len(b))


def cmd_listen(a):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
    s.bind((a.bind, a.port))
    s.settimeout(a.timeout)
    # Receive first, verify afterwards: generating the reference pattern in
    # Python is far slower than the wire, and the socket buffer is small
    # without root (net.core.rmem_max).
    pkts = []
    srcs = set()
    try:
        while len(pkts) < a.count:
            try:
                d, src = s.recvfrom(65535)
            except socket.timeout:
                break
            pkts.append(d)
            srcs.add(src)
    finally:
        s.close()
    got = len(pkts)
    bad = biterr = 0
    seqs = []
    lens = set()
    for d in pkts:
        lens.add(len(d))
        if len(d) < 8:
            bad += 1
            continue
        seq = int.from_bytes(d[:8], "little")
        seqs.append(seq)
        e = bit_errors(d, gen_payload(seq, len(d)))
        if e:
            bad += 1
            biterr += e
    in_order = all(seqs[i] + 1 == seqs[i + 1] for i in range(len(seqs) - 1))
    span = f"{seqs[0]}..{seqs[-1]}" if seqs else "-"
    ok = got == a.count and bad == 0 and in_order
    print(f"listen :{a.port}: received {got}/{a.count} datagrams, lengths {sorted(lens)}, "
          f"seq {span} ({'contiguous' if in_order else 'NOT contiguous'}), "
          f"payload mismatches {bad} ({biterr} bit errors), from {sorted(srcs)}")
    print(f"VERDICT: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def cmd_send(a):
    flip = None
    if a.flip_bit:
        fs, fb = a.flip_bit.split(":")
        flip = (int(fs), int(fb))
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if a.bind:
        s.bind((a.bind, 0))
    sent = 0
    for i in range(a.count):
        seq = a.start_seq + i
        p = bytearray(gen_payload(seq, a.len))
        if flip and flip[0] == seq:
            p[flip[1] // 8] ^= 1 << (flip[1] % 8)
        s.sendto(p, (a.ip, a.port))
        sent += 1
        if a.pace and (i + 1) % a.pace == 0:
            time.sleep(0.001)
    s.close()
    print(f"send: {sent} datagrams of {a.len} B to {a.ip}:{a.port}, seq {a.start_seq}.."
          f"{a.start_seq + a.count - 1}" + (f", bit {flip[1]} of seq {flip[0]} flipped" if flip else ""))
    print("VERDICT: PASS")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("listen", help="receive and verify generator datagrams")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--count", type=int, required=True)
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--timeout", type=float, default=10.0, help="give up after this idle time (s)")
    p.set_defaults(func=cmd_listen)
    p = sub.add_parser("send", help="send PRBS datagrams to the board's checker")
    p.add_argument("ip")
    p.add_argument("--port", type=int, default=5001, help="CHK_PORT (default 5001)")
    p.add_argument("--count", type=int, default=1000)
    p.add_argument("--len", type=int, default=1000, help="UDP payload bytes (>= 8)")
    p.add_argument("--start-seq", type=int, default=0)
    p.add_argument("--flip-bit", metavar="SEQ:BIT", help="flip payload bit BIT of datagram SEQ")
    p.add_argument("--bind", default=None)
    p.add_argument("--pace", type=int, default=64, help="sleep 1 ms every N datagrams (0 = never)")
    p.set_defaults(func=cmd_send)
    a = ap.parse_args()
    sys.exit(a.func(a))


if __name__ == "__main__":
    main()
