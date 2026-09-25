#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""
zircon_echo_test.py — host-side judge for the qsfp28-fmc-zircon echo server.

The bare-metal application of the 2x QSFP28 FMC Zircon design (VCK190, 100G
QSFP ports 0 and 1) offers three services on each port's 100G address:

  (a) UDP port 7    — echoed by HARDWARE (zircon UI1): headers swapped and
                      rebuilt, checksums inserted, payload untouched
  (b) TCP port 7    — echoed by SOFTWARE (lwIP on the zircon raw path, UI0)
  (c) UDP port 5000 — the hardware UDP socket (zircon UI2): the payload reaches
                      software without headers, is bounced back through the
                      socket TX channel, and the headers are built by hardware

This script tests all three from this host and prints `VERDICT: PASS` or
`VERDICT: FAIL` (exit code 0 / 1). Standard library only, no root, no raw
sockets: header checksums are judged through the kernel's own counters
(/proc/net/snmp Udp InCsumErrors, Ip InHdrErrors), since the kernel drops a
datagram with a bad checksum before any socket sees it.

Interface / addresses:
  * The local interface is picked automatically among the host's 100G ports
    (default ens6f0np0, ens6f1np1): the one with carrier (and, when the board
    IP is known, the one whose subnet contains it). Its IPv4 address is used as
    the source address. --bind ADDR overrides the local address, --iface the
    interface.
  * The board IP is the positional argument. It may also be given as the line
    the board prints on its UART ("Port 0: IP 192.168.20.23 mask ... (DHCP)"),
    read from a log file with --from-log FILE (the last such line wins), or
    discovered from the kernel ARP table (/proc/net/arp) or a NetworkManager
    dnsmasq lease file by the board's MAC (--mac, default 00:0a:35:06:21:a0
    + the port number).
  * --port N (default 0) selects the QSFP port under test: the "Port N: IP"
    UART line and the default MAC 00:0a:35:06:21:a0 + N. Both ports run the
    same services, so everything else is identical.

    zircon_echo_test.py 192.168.20.23
    zircon_echo_test.py "Port 0: IP 192.168.20.23 mask 255.255.255.0 gw 192.168.20.1 (DHCP)"
    zircon_echo_test.py --from-log logs/_bench/vck190_journal.log
    zircon_echo_test.py --port 1 --from-log logs/_bench/vck190_journal.log
    zircon_echo_test.py 192.168.20.23 --only udp --udp-sizes all --jumbo

Latency (zircon_nic 1.3.0): the board measures, with the MRMAC's IEEE 1588
timestamps, the time from the first PCS block of a request on RX to the first
PCS block of its reply on TX, for the hardware UDP echo (bank 0) and the
software TCP echo (bank 1), and serves the statistics on UDP port 5002
(Vitis/common/src/latency_wire.h). With --latency the script, after the
normal tests, runs per size: clear the banks, N UDP and N TCP request/response
exchanges with one request in flight (TCP_NODELAY), read the banks, and prints
the host round-trip time next to the two board latencies:

    zircon_echo_test.py 192.168.20.23 --latency --lat-sizes 64,512,1472 --lat-count 2000
    zircon_echo_test.py 192.168.20.23 --latency-only       # dump the board's banks
"""

import argparse
import fcntl
import glob
import ipaddress
import os
import re
import socket
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
try:
    from echo_test import echo_once as tcp_echo_once   # scripts/echo_test.py
except Exception:                                       # pragma: no cover
    tcp_echo_once = None

DEFAULT_IFACES = "ens6f0np0,ens6f1np1"
DEFAULT_MAC = "00:0a:35:06:21:a0"        # port 0; port n = last byte + n
UDP_ECHO_PORT = 7
TCP_ECHO_PORT = 7
SOCK_PORT = 5000
LAT_PORT = 5002
# latency_wire.h (LAT_WIRE_VERSION 1): lat_wire_hdr_t, lat_wire_bank_t
LAT_MAGIC = 0x5A4C4154           # "ZLAT"
LAT_VERSION = 1
LAT_NBINS = 64
LAT_HDR_FMT = "<IHBBBBHIIIII%dI" % LAT_NBINS       # 288 bytes
LAT_BANK_FMT = "<QQQIIII%dQ" % LAT_NBINS           # 552 bytes
LAT_F_EN, LAT_F_RAW_TS_DESC, LAT_F_SNAP_FAIL, LAT_F_NO_LAT = 1, 2, 4, 8
LAT_BANK_NAMES = ("hardware UDP echo", "software TCP echo")
MAX_TCP_SEG = 1460           # one segment on a 1500-MTU link
MAX_UDP_1500 = 1472          # 1500 - 20 (IPv4) - 8 (UDP)
IP_LINE_RE_FMT = r"Port\s+{port}:\s+IP\s+(\d+\.\d+\.\d+\.\d+)"
IP_LINE_RE = re.compile(IP_LINE_RE_FMT.format(port=0))   # set from --port in main()
IPV4_RE = re.compile(r"^\d+\.\d+\.\d+\.\d+$")
SIOCGIFADDR = 0x8915
SIOCGIFNETMASK = 0x891B


# --------------------------------------------------------------------------
# Host interface helpers (all unprivileged)
# --------------------------------------------------------------------------
def read_sys(iface, name, default=""):
    try:
        with open(f"/sys/class/net/{iface}/{name}") as f:
            return f.read().strip()
    except OSError:
        return default


def iface_ipv4(iface):
    """(address, netmask) of an interface via ioctl, or (None, None)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        req = struct.pack("256s", iface.encode()[:15])
        addr = socket.inet_ntoa(fcntl.ioctl(s.fileno(), SIOCGIFADDR, req)[20:24])
        mask = socket.inet_ntoa(fcntl.ioctl(s.fileno(), SIOCGIFNETMASK, req)[20:24])
        return addr, mask
    except OSError:
        return None, None
    finally:
        s.close()


def iface_has_carrier(iface):
    return read_sys(iface, "carrier", "0") == "1" and \
        read_sys(iface, "operstate", "down") in ("up", "unknown")


def pick_iface(candidates, board_ip):
    """Return (iface, local_ip, network) or raise SystemExit with a reason."""
    report = []
    usable = []
    for ifc in candidates:
        if not os.path.isdir(f"/sys/class/net/{ifc}"):
            report.append(f"{ifc}: not present")
            continue
        carrier = iface_has_carrier(ifc)
        addr, mask = iface_ipv4(ifc)
        speed = read_sys(ifc, "speed", "?") if carrier else "-"
        report.append(f"{ifc}: carrier {'yes' if carrier else 'no'}, "
                      f"operstate {read_sys(ifc, 'operstate', '?')}, speed {speed}, "
                      f"IPv4 {addr or 'none'}")
        if carrier and addr:
            net = ipaddress.IPv4Network(f"{addr}/{mask}", strict=False)
            usable.append((ifc, addr, net))
    for line in report:
        print(f"  host {line}")
    if board_ip:
        bip = ipaddress.IPv4Address(board_ip)
        for u in usable:
            if bip in u[2]:
                return u
        if usable:
            print(f"  note: no carrier interface has {board_ip} on-link; using {usable[0][0]}")
    if usable:
        return usable[0]
    raise SystemExit("no candidate interface has carrier and an IPv4 address "
                     "(is the 100G link up? see the board's UART)")


def iface_of_addr(addr, candidates):
    for ifc in candidates + sorted(os.listdir("/sys/class/net")):
        a, m = iface_ipv4(ifc)
        if a == addr:
            return ifc, ipaddress.IPv4Network(f"{a}/{m}", strict=False)
    return None, None


def snmp_counters():
    """{'Udp': {...}, 'Ip': {...}} from /proc/net/snmp."""
    out = {}
    try:
        with open("/proc/net/snmp") as f:
            lines = f.read().splitlines()
        for i in range(0, len(lines) - 1, 2):
            k1, *names = lines[i].split()
            k2, *vals = lines[i + 1].split()
            if k1 == k2:
                out[k1.rstrip(":")] = dict(zip(names, (int(v) for v in vals)))
    except (OSError, ValueError):
        pass
    return out


# --------------------------------------------------------------------------
# Board IP discovery
# --------------------------------------------------------------------------
def port_mac(port):
    b = DEFAULT_MAC.split(":")
    b[5] = f"{(int(b[5], 16) + port) & 0xFF:02x}"
    return ":".join(b)


def ip_from_text(text):
    last = None
    for m in IP_LINE_RE.finditer(text):
        last = m.group(1)
    return last


def ip_from_arp(mac):
    try:
        with open("/proc/net/arp") as f:
            for line in f.read().splitlines()[1:]:
                p = line.split()
                if len(p) >= 4 and p[3].lower() == mac.lower() and p[2] != "0x0":
                    return p[0]
    except OSError:
        pass
    return None


def ip_from_leases(mac):
    for path in glob.glob("/var/lib/NetworkManager/dnsmasq-*.leases") + \
            glob.glob("/var/lib/misc/dnsmasq*.leases"):
        try:
            with open(path) as f:
                for line in f:
                    p = line.split()
                    if len(p) >= 3 and p[1].lower() == mac.lower():
                        return p[2]
        except OSError:
            continue
    return None


def resolve_board_ip(args):
    if args.board:
        if IPV4_RE.match(args.board.strip()):
            return args.board.strip(), "argument"
        ip = ip_from_text(args.board)
        if ip:
            return ip, "UART line"
        raise SystemExit(f"cannot find a board IP in {args.board!r}")
    if args.from_log:
        try:
            with open(args.from_log, errors="replace") as f:
                ip = ip_from_text(f.read())
        except OSError as e:
            raise SystemExit(f"cannot read {args.from_log}: {e}")
        if ip:
            return ip, f"log {args.from_log}"
        raise SystemExit(f"no 'Port {args.port}: IP a.b.c.d' line in {args.from_log}")
    ip = ip_from_arp(args.mac)
    if ip:
        return ip, f"ARP table ({args.mac})"
    ip = ip_from_leases(args.mac)
    if ip:
        return ip, f"DHCP lease ({args.mac})"
    raise SystemExit(f"board IP unknown: pass it (or the UART 'Port {args.port}: IP' line), "
                     "or --from-log FILE")


# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------
class Result:
    def __init__(self, name):
        self.name = name
        self.ok = True
        self.lines = []

    def fail(self, msg):
        self.ok = False
        self.lines.append("FAIL " + msg)

    def info(self, msg):
        self.lines.append(msg)


def parse_sizes(spec, maximum):
    if spec == "all":
        return list(range(1, maximum + 1))
    sizes = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            sizes.extend(range(int(a), int(b) + 1))
        else:
            sizes.append(int(part))
    return sizes


def udp_socket(local_ip, timeout, rcvbuf=4 << 20):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, rcvbuf)
    except OSError:
        pass
    s.bind((local_ip, 0))
    s.settimeout(timeout)
    return s


def udp_roundtrip(s, dest, payload, timeout, retries):
    """Send one datagram, wait for the matching reply. Returns
    (ok, rtt_seconds, detail)."""
    for attempt in range(retries + 1):
        t0 = time.perf_counter()
        s.sendto(payload, dest)
        deadline = t0 + timeout
        while True:
            left = deadline - time.perf_counter()
            if left <= 0:
                break
            s.settimeout(left)
            try:
                data, src = s.recvfrom(65535)
            except socket.timeout:
                break
            rtt = time.perf_counter() - t0
            if data == payload:
                if src != dest:
                    return False, rtt, (f"reply came from {src[0]}:{src[1]}, "
                                        f"expected {dest[0]}:{dest[1]}")
                return True, rtt, ""
            # stale reply of an earlier (retried) datagram: keep waiting
    return False, None, f"no reply after {retries + 1} attempt(s) of {timeout}s"


def rtt_summary(rtts):
    if not rtts:
        return "no samples"
    r = sorted(rtts)
    pct = lambda p: r[min(len(r) - 1, int(p * len(r)))]
    return (f"RTT min {r[0]*1e6:.0f} us, median {pct(0.5)*1e6:.0f} us, "
            f"p99 {pct(0.99)*1e6:.0f} us, max {r[-1]*1e6:.0f} us")


def test_udp_sweep(name, local_ip, dest, sizes, timeout, retries, count):
    """Request/response sweep over sizes (count datagrams per size)."""
    res = Result(name)
    s = udp_socket(local_ip, timeout)
    rtts = []
    bad = 0
    try:
        for size in sizes:
            for _ in range(count):
                payload = os.urandom(size)
                ok, rtt, detail = udp_roundtrip(s, dest, payload, timeout, retries)
                if not ok:
                    bad += 1
                    if bad <= 5:
                        res.fail(f"size {size}: {detail}")
                    continue
                rtts.append(rtt)
    finally:
        s.close()
    total = len(sizes) * count
    if bad > 5:
        res.fail(f"... {bad} failures in total")
    res.info(f"{total - bad}/{total} datagrams echoed intact, sizes "
             f"{min(sizes)}..{max(sizes)} ({len(sizes)} sizes x {count}); {rtt_summary(rtts)}")
    return res


def test_udp_burst(name, local_ip, dest, size, n, window, timeout, max_loss):
    """Windowed burst: at most `window` datagrams in flight; measures pps and
    loss. Every datagram carries a sequence number and a checkable pattern."""
    res = Result(name)
    s = udp_socket(local_ip, timeout, rcvbuf=16 << 20)
    s.setblocking(False)
    size = max(size, 12)
    body = os.urandom(size - 8)
    pending = {}                 # seq -> send time
    received = corrupt = wrong_src = expired = 0
    sent = 0
    t_start = time.perf_counter()
    try:
        while sent < n or pending:
            # fill the window
            while sent < n and len(pending) < window:
                pkt = struct.pack("!Q", sent) + body
                try:
                    s.sendto(pkt, dest)
                except BlockingIOError:
                    break
                pending[sent] = time.perf_counter()
                sent += 1
            # drain replies
            got_any = False
            while True:
                try:
                    data, src = s.recvfrom(65535)
                except BlockingIOError:
                    break
                got_any = True
                if src != dest:
                    wrong_src += 1
                    continue
                if len(data) != size or data[8:] != body:
                    corrupt += 1
                    continue
                seq = struct.unpack("!Q", data[:8])[0]
                if pending.pop(seq, None) is not None:
                    received += 1
            if not got_any and pending:
                # expire datagrams that have been out for longer than timeout
                limit = time.perf_counter() - timeout
                stale = [q for q, t in pending.items() if t < limit]
                for q in stale:
                    del pending[q]
                expired += len(stale)
                time.sleep(0)
    finally:
        s.close()
    elapsed = time.perf_counter() - t_start
    lost = n - received
    pps = received / elapsed if elapsed > 0 else 0.0
    mbps = pps * size * 8 / 1e6
    res.info(f"{received}/{n} datagrams of {size} B back in {elapsed:.2f} s "
             f"({pps:,.0f} pps, {mbps:,.1f} Mb/s payload each way, window {window}); "
             f"lost {lost}, corrupt {corrupt}, wrong source {wrong_src}")
    if corrupt or wrong_src:
        res.fail(f"{corrupt} corrupt / {wrong_src} wrong-source replies")
    if lost > n * max_loss:
        res.fail(f"lost {lost}/{n} (> {max_loss*100:.2f}% allowed)")
    return res


def test_tcp(name, local_ip, board_ip, port, sizes, count, timeout):
    res = Result(name)
    if tcp_echo_once is None:
        res.fail("scripts/echo_test.py not importable")
        return res
    total = done = 0
    t0 = time.perf_counter()
    nbytes = 0
    for size in sizes:
        try:
            sock = socket.create_connection((board_ip, port), timeout,
                                            source_address=(local_ip, 0))
        except OSError as e:
            res.fail(f"cannot connect to {board_ip}:{port}: {e}")
            return res
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.settimeout(timeout)
        try:
            for _ in range(count):
                total += 1
                payload = os.urandom(size)
                ok, detail = tcp_echo_once(sock, payload, timeout)
                if not ok:
                    res.fail(f"size {size}: {detail}")
                    break
                done += 1
                nbytes += size
        finally:
            sock.close()
    el = time.perf_counter() - t0
    res.info(f"{done}/{total} exchanges echoed intact, sizes {sizes} x {count}, "
             f"{nbytes/1e6:.2f} MB in {el:.2f} s ({nbytes*8/el/1e6 if el else 0:.1f} Mb/s)")
    return res


# --------------------------------------------------------------------------
# Latency (zircon_nic 1.3.0, UDP 5002 statistics service)
# --------------------------------------------------------------------------
def lat_request(local_ip, board_ip, req, timeout=1.0, retries=2):
    """Send an ASCII request to the statistics service; returns the reply."""
    s = udp_socket(local_ip, timeout)
    try:
        for _ in range(retries + 1):
            s.sendto(req.encode(), (board_ip, LAT_PORT))
            try:
                data, src = s.recvfrom(65535)
            except socket.timeout:
                continue
            if src[0] == board_ip:
                return data
    finally:
        s.close()
    raise RuntimeError(f"no reply from {board_ip}:{LAT_PORT} to {req!r} "
                       "(zircon_nic 1.3.0 echo server?)")


def lat_parse(blob):
    """Decode a STAT? reply into a dict (see latency_wire.h)."""
    hsz = struct.calcsize(LAT_HDR_FMT)
    bsz = struct.calcsize(LAT_BANK_FMT)
    if len(blob) < hsz:
        raise ValueError(f"short reply ({len(blob)} B): {blob[:16]!r}")
    h = struct.unpack_from(LAT_HDR_FMT, blob, 0)
    magic, version, nbanks, nbins, port, flags, hdr_len = h[:7]
    if magic != LAT_MAGIC or version != LAT_VERSION or nbins != LAT_NBINS:
        raise ValueError(f"unexpected reply: magic 0x{magic:08x} version {version} "
                         f"nbins {nbins}")
    if len(blob) < hdr_len + nbanks * bsz:
        raise ValueError(f"short reply ({len(blob)} B for {nbanks} banks)")
    out = {"port": port, "flags": flags, "bin_base": h[7], "bin_width": h[8],
           "version": h[9], "status": h[10], "uptime_ms": h[11],
           "edges": list(h[12:12 + nbins]), "banks": []}
    for b in range(nbanks):
        v = struct.unpack_from(LAT_BANK_FMT, blob, hdr_len + b * bsz)
        out["banks"].append({"count": v[0], "sum": v[1], "sumsq": v[2], "min": v[3],
                             "max": v[4], "implausible": v[5], "last": v[6],
                             "bins": list(v[7:7 + nbins])})
    return out


def lat_stats(bank, edges):
    """count, min, mean, stddev, max and histogram percentiles of a bank.
    Percentiles are the upper edge of the bin holding them (capped at max),
    as the board's 'T' command prints them."""
    n = bank["count"]
    if n == 0:
        return None
    mean = bank["sum"] / n
    var = max(0.0, bank["sumsq"] / n - mean * mean)
    bins = bank["bins"]
    total = sum(bins)

    def pct(q):
        if total == 0:
            return None
        target = max(1, -(-total * q // 10000))
        cum = 0
        for i, c in enumerate(bins):
            cum += c
            if cum >= target:
                break
        if i >= len(bins) - 1:
            return bank["max"]
        return min(edges[i + 1], bank["max"])
    return {"count": n, "min": bank["min"], "mean": mean, "sd": var ** 0.5,
            "max": bank["max"], "p50": pct(5000), "p90": pct(9000), "p99": pct(9900),
            "p999": pct(9990), "implausible": bank["implausible"]}


def lat_hist_text(bank, edges, width=6):
    """Compact histogram: 'lo-hi:count' for every non-empty bin."""
    parts = []
    for i, c in enumerate(bank["bins"]):
        if not c:
            continue
        if i == len(bank["bins"]) - 1:
            parts.append(f">={edges[i]}:{c}")
        else:
            parts.append(f"{edges[i]}-{edges[i + 1]}:{c}")
    if not parts:
        return "(empty)"
    lines = []
    for k in range(0, len(parts), width):
        lines.append(" ".join(parts[k:k + width]))
    return "\n                ".join(lines)


def host_stats(samples_s):
    """Same columns for host round-trip times (seconds -> ns), exact."""
    if not samples_s:
        return None
    r = sorted(x * 1e9 for x in samples_s)
    n = len(r)
    mean = sum(r) / n
    pick = lambda q: r[min(n - 1, max(0, -(-n * q // 10000) - 1))]
    return {"count": n, "min": r[0], "mean": mean,
            "sd": (sum((x - mean) ** 2 for x in r) / n) ** 0.5, "max": r[-1],
            "p50": pick(5000), "p90": pick(9000), "p99": pick(9900), "p999": pick(9990)}


def lat_row(label, st):
    if st is None:
        return f"  {label:<22} {'no samples':>8}"
    f = lambda v: "-" if v is None else f"{v:,.0f}"
    return (f"  {label:<22} {st['count']:>8} {f(st['min']):>10} {f(st['mean']):>10} "
            f"{f(st['p50']):>10} {f(st['p99']):>10} {f(st['p999']):>10} {f(st['max']):>11}")


LAT_HEAD = (f"  {'':<22} {'count':>8} {'min':>10} {'mean':>10} {'p50':>10} {'p99':>10} "
            f"{'p99.9':>10} {'max':>11}   (ns)")


def lat_print_board(stat, indent="  "):
    print(f"{indent}board port {stat['port']}: zircon_nic "
          f"{stat['version'] >> 16}.{(stat['version'] >> 8) & 0xFF}.{stat['version'] & 0xFF}, "
          f"LAT_CTRL EN {int(bool(stat['flags'] & LAT_F_EN))} RAW_TS_DESC "
          f"{int(bool(stat['flags'] & LAT_F_RAW_TS_DESC))}, LAT_STATUS 0x{stat['status']:08x}, "
          f"bins {stat['bin_width']} ns from {stat['bin_base']} ns")
    print(LAT_HEAD)
    for b, bank in enumerate(stat["banks"]):
        st = lat_stats(bank, stat["edges"])
        name = LAT_BANK_NAMES[b] if b < len(LAT_BANK_NAMES) else f"bank {b}"
        print(lat_row(f"board {name}", st))
    for b, bank in enumerate(stat["banks"]):
        if bank["count"]:
            print(f"{indent}bank {b} hist: {lat_hist_text(bank, stat['edges'])}")


def tcp_rtt_run(local_ip, board_ip, size, count, timeout):
    """One connection, TCP_NODELAY, `count` request/response exchanges with
    one request in flight. Returns (rtts, detail)."""
    rtts = []
    sock = socket.create_connection((board_ip, TCP_ECHO_PORT), timeout,
                                    source_address=(local_ip, 0))
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.settimeout(timeout)
    try:
        for _ in range(count):
            payload = os.urandom(size)
            t0 = time.perf_counter()
            sock.sendall(payload)
            got = bytearray()
            while len(got) < size:
                chunk = sock.recv(size - len(got))
                if not chunk:
                    return rtts, "connection closed by the board"
                got += chunk
            rtts.append(time.perf_counter() - t0)
            if bytes(got) != payload:
                return rtts, "payload corrupted"
    except (OSError, socket.timeout) as e:
        return rtts, f"{e}"
    finally:
        sock.close()
    return rtts, ""


def test_latency(local_ip, board_ip, sizes, count, timeout):
    res = Result("Latency (MRMAC 1588 timestamps, UDP 5002 statistics)")
    try:
        stat = lat_parse(lat_request(local_ip, board_ip, "STAT?", timeout))
    except (RuntimeError, ValueError) as e:
        res.fail(str(e))
        return res
    if stat["flags"] & LAT_F_NO_LAT:
        res.fail("the board's zircon_nic has no latency measurement (needs 1.3.0)")
        return res
    if not stat["flags"] & LAT_F_RAW_TS_DESC:
        res.info("note: RAW_TS_DESC is off on the board: the software TCP echo is not measured")
    s = udp_socket(local_ip, timeout)
    try:
        for size in sizes:
            tsize = min(size, MAX_TCP_SEG)
            try:
                lat_request(local_ip, board_ip, "CLR", timeout)
            except RuntimeError as e:
                res.fail(str(e))
                return res
            udp_rtts, lost = [], 0
            for _ in range(count):
                ok, rtt, _d = udp_roundtrip(s, (board_ip, UDP_ECHO_PORT), os.urandom(size),
                                            timeout, 0)
                if ok:
                    udp_rtts.append(rtt)
                else:
                    lost += 1
            try:
                tcp_rtts, tdetail = tcp_rtt_run(local_ip, board_ip, tsize, count, max(timeout, 3.0))
            except OSError as e:
                tcp_rtts, tdetail = [], f"cannot connect: {e}"
            try:
                stat = lat_parse(lat_request(local_ip, board_ip, "STAT?", timeout))
            except (RuntimeError, ValueError) as e:
                res.fail(f"size {size}: {e}")
                continue
            hw, sw = stat["banks"][0], stat["banks"][1]
            print(f"\nLatency, {size} B UDP / {tsize} B TCP payload, {count} request/response "
                  f"exchanges each, one in flight:")
            print(LAT_HEAD)
            print(lat_row("host RTT, UDP echo", host_stats(udp_rtts)))
            print(lat_row("board HW UDP echo", lat_stats(hw, stat["edges"])))
            print(lat_row("host RTT, TCP echo", host_stats(tcp_rtts)))
            print(lat_row("board SW TCP echo", lat_stats(sw, stat["edges"])))
            print(f"  HW hist (ns:count) {lat_hist_text(hw, stat['edges'])}")
            print(f"  SW hist (ns:count) {lat_hist_text(sw, stat['edges'])}")
            if hw["implausible"] or sw["implausible"] or stat["status"]:
                print(f"  implausible HW {hw['implausible']} SW {sw['implausible']}, "
                      f"LAT_STATUS 0x{stat['status']:08x}")
            hs, ss = lat_stats(hw, stat["edges"]), lat_stats(sw, stat["edges"])
            res.info(f"{size} B: HW echo {hw['count']}/{len(udp_rtts)} measured"
                     + (f" (min {hs['min']} mean {hs['mean']:.0f} p99 {hs['p99']} max {hs['max']} ns)"
                        if hs else "")
                     + f"; SW echo {sw['count']}/{len(tcp_rtts)} measured"
                     + (f" (min {ss['min']} mean {ss['mean']:.0f} p99 {ss['p99']} max {ss['max']} ns)"
                        if ss else ""))
            if lost:
                res.info(f"{size} B: {lost} UDP requests without a reply")
            if tdetail:
                res.fail(f"{size} B: TCP exchange failed after {len(tcp_rtts)}: {tdetail}")
            if udp_rtts and hw["count"] == 0:
                res.fail(f"{size} B: {len(udp_rtts)} hardware echoes but bank 0 counted none")
            if (tcp_rtts and stat["flags"] & LAT_F_RAW_TS_DESC and sw["count"] == 0):
                res.fail(f"{size} B: {len(tcp_rtts)} TCP echoes but bank 1 counted none")
            if hw["count"] > len(udp_rtts) + lost:
                res.info(f"{size} B: bank 0 counted {hw['count']} > {len(udp_rtts) + lost} requests "
                         "sent (other traffic to the hardware echo?)")
    finally:
        s.close()
    return res


def check_snmp(before, after, res):
    def d(proto, key):
        return after.get(proto, {}).get(key, 0) - before.get(proto, {}).get(key, 0)
    csum = d("Udp", "InCsumErrors")
    hdr = d("Ip", "InHdrErrors")
    res.info(f"host kernel counters during the run: Udp InCsumErrors +{csum}, "
             f"Ip InHdrErrors +{hdr}, Udp InDatagrams +{d('Udp', 'InDatagrams')}")
    if csum:
        res.fail(f"{csum} UDP datagrams arrived with a bad checksum "
                 "(kernel Udp InCsumErrors; may include other host traffic)")
    if hdr:
        res.fail(f"{hdr} IPv4 packets arrived with a bad header "
                 "(kernel Ip InHdrErrors; may include other host traffic)")


def run_ping(iface, board_ip, count=3):
    import subprocess
    try:
        r = subprocess.run(["ping", "-c", str(count), "-W", "1", "-I", iface, board_ip],
                           capture_output=True, text=True, timeout=count * 2 + 5)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, str(e)
    tail = [l for l in r.stdout.splitlines() if "packet" in l or "rtt" in l]
    return r.returncode == 0, "; ".join(tail) or r.stderr.strip()


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        epilog=__doc__[__doc__.index("This script"):],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("board", nargs="?",
                    help="board IP, or the UART line 'Port N: IP a.b.c.d ...'")
    ap.add_argument("--port", type=int, default=0, choices=(0, 1),
                    help="QSFP port under test (default 0): selects the 'Port N: IP' "
                         "line and the default MAC")
    ap.add_argument("--from-log", metavar="FILE",
                    help="take the board IP from the last 'Port N: IP' line in FILE")
    ap.add_argument("--mac", default=None,
                    help=f"board MAC for ARP/lease discovery (default {DEFAULT_MAC} + port)")
    ap.add_argument("--bind", metavar="ADDR",
                    help="local IPv4 address to send from (default: the carrier interface's)")
    ap.add_argument("--iface", metavar="IF",
                    help="local interface (default: auto among --ifaces)")
    ap.add_argument("--ifaces", default=DEFAULT_IFACES,
                    help=f"candidate interfaces for auto-pick (default {DEFAULT_IFACES})")
    ap.add_argument("--only", choices=("udp", "tcp", "sock"), action="append",
                    help="run only this test (repeatable); default: all three")
    ap.add_argument("--udp-sizes", default="1-1472",
                    help="UDP echo sweep sizes: 'all' (1..1472), 'a-b', or 'a,b,c' "
                         "(default 1-1472)")
    ap.add_argument("--udp-count", type=int, default=1,
                    help="datagrams per size in the sweeps (default 1)")
    ap.add_argument("--jumbo", action="store_true",
                    help="also sweep jumbo sizes up to 8972 (needs a >= 9000 MTU "
                         "on the host interface)")
    ap.add_argument("--burst", type=int, default=20000,
                    help="UDP echo burst length for the pps measurement (0 = skip; default 20000)")
    ap.add_argument("--burst-size", type=int, default=1472, help="burst datagram size")
    ap.add_argument("--window", type=int, default=64,
                    help="datagrams in flight during the burst (default 64)")
    ap.add_argument("--max-loss", type=float, default=0.001,
                    help="tolerated burst loss fraction (default 0.001)")
    ap.add_argument("--tcp-sizes", default="1,64,1000,1460,20000",
                    help="TCP echo sizes (default 1,64,1000,1460,20000)")
    ap.add_argument("--tcp-count", type=int, default=20,
                    help="exchanges per TCP size (default 20)")
    ap.add_argument("--sock-sizes", default="1,2,17,63,64,65,128,512,1000,1400,1472",
                    help="socket demo sizes")
    ap.add_argument("--sock-count", type=int, default=5, help="datagrams per socket size")
    ap.add_argument("--timeout", type=float, default=1.0,
                    help="per-datagram / per-exchange timeout, s (default 1.0)")
    ap.add_argument("--retries", type=int, default=1,
                    help="UDP resends before a datagram counts as lost (default 1)")
    ap.add_argument("--ping", action="store_true",
                    help="also run the system ping (informational)")
    ap.add_argument("--latency", action="store_true",
                    help="after the tests, measure latency per size: host RTT vs the board's "
                         "hardware UDP echo and software TCP echo latency (zircon_nic 1.3.0)")
    ap.add_argument("--latency-only", action="store_true",
                    help="only print the board's latency statistics (UDP 5002), no tests, no clear")
    ap.add_argument("--lat-sizes", default="64,512,1024,1472",
                    help="payload sizes of the latency run (default 64,512,1024,1472; TCP is "
                         f"capped at {MAX_TCP_SEG} B, one segment)")
    ap.add_argument("--lat-count", type=int, default=1000,
                    help="request/response exchanges per size and protocol (default 1000)")
    args = ap.parse_args()
    global IP_LINE_RE
    IP_LINE_RE = re.compile(IP_LINE_RE_FMT.format(port=args.port))
    if args.mac is None:
        args.mac = port_mac(args.port)

    tests = set(args.only or ("udp", "tcp", "sock"))
    candidates = [i for i in args.ifaces.split(",") if i]

    print("zircon_echo_test: qsfp28-fmc-zircon echo server check")
    board_ip, how = resolve_board_ip(args)
    print(f"  board IP {board_ip} (from {how}), QSFP port {args.port}")

    if args.bind:
        local_ip = args.bind
        iface, net = iface_of_addr(local_ip, candidates)
        iface = args.iface or iface or "?"
    elif args.iface:
        local_ip, mask = iface_ipv4(args.iface)
        if not local_ip:
            raise SystemExit(f"{args.iface} has no IPv4 address")
        iface = args.iface
        net = ipaddress.IPv4Network(f"{local_ip}/{mask}", strict=False)
        if not iface_has_carrier(iface):
            print(f"  WARNING: {iface} reports no carrier")
    else:
        iface, local_ip, net = pick_iface(candidates, board_ip)
    mtu = int(read_sys(iface, "mtu", "1500") or 1500) if iface != "?" else 1500
    print(f"  local {local_ip} on {iface} (MTU {mtu}"
          f"{', speed ' + read_sys(iface, 'speed', '?') + ' Mb/s' if iface != '?' else ''})")
    if net is not None and ipaddress.IPv4Address(board_ip) not in net:
        print(f"  WARNING: {board_ip} is not in {net}: traffic may leave through another route")

    if args.latency_only:
        try:
            stat = lat_parse(lat_request(local_ip, board_ip, "STAT?", max(args.timeout, 1.0)))
        except (RuntimeError, ValueError) as e:
            print(f"  latency statistics: {e}\nVERDICT: FAIL")
            return 1
        lat_print_board(stat)
        ok = not (stat["flags"] & LAT_F_NO_LAT)
        print(f"\nVERDICT: {'PASS' if ok else 'FAIL'}")
        return 0 if ok else 1

    results = []
    snmp0 = snmp_counters()

    if args.ping and iface != "?":
        ok, detail = run_ping(iface, board_ip)
        print(f"  ping: {'ok' if ok else 'FAILED'} {detail}")

    if "udp" in tests:
        sizes = parse_sizes(args.udp_sizes, MAX_UDP_1500)
        if args.jumbo:
            jmax = min(8972, mtu - 28)
            if jmax <= MAX_UDP_1500:
                print(f"  jumbo sweep skipped: {iface} MTU {mtu} (needs >= 9000, "
                      "which needs root to set)")
            else:
                sizes += [s for s in (1473, 2000, 4000, 4096, 8000, 8192, 8972) if s <= jmax]
        results.append(test_udp_sweep("UDP echo (hardware, port 7) sweep", local_ip,
                                      (board_ip, UDP_ECHO_PORT), sizes, args.timeout,
                                      args.retries, args.udp_count))
        if args.burst > 0:
            results.append(test_udp_burst("UDP echo (hardware, port 7) burst", local_ip,
                                          (board_ip, UDP_ECHO_PORT), args.burst_size,
                                          args.burst, args.window, max(args.timeout, 1.0),
                                          args.max_loss))

    if "tcp" in tests:
        results.append(test_tcp("TCP echo (software, port 7)", local_ip, board_ip,
                                TCP_ECHO_PORT, parse_sizes(args.tcp_sizes, 1 << 20),
                                args.tcp_count, max(args.timeout, 3.0)))

    if "sock" in tests:
        results.append(test_udp_sweep(f"UDP socket demo (hardware socket, port {SOCK_PORT})",
                                      local_ip, (board_ip, SOCK_PORT),
                                      parse_sizes(args.sock_sizes, MAX_UDP_1500),
                                      args.timeout, args.retries, args.sock_count))

    if args.latency:
        results.append(test_latency(local_ip, board_ip,
                                    parse_sizes(args.lat_sizes, MAX_UDP_1500),
                                    args.lat_count, max(args.timeout, 1.0)))

    snmp1 = snmp_counters()
    csum = Result("Checksums (host kernel counters)")
    check_snmp(snmp0, snmp1, csum)
    results.append(csum)

    print()
    for r in results:
        print(f"[{'PASS' if r.ok else 'FAIL'}] {r.name}")
        for l in r.lines:
            print(f"       {l}")
    ok = all(r.ok for r in results)
    print(f"\nVERDICT: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\ninterrupted\nVERDICT: FAIL")
        sys.exit(1)
    except SystemExit as e:
        if isinstance(e.code, str):
            print(f"ERROR: {e.code}\nVERDICT: FAIL")
            sys.exit(1)
        raise
