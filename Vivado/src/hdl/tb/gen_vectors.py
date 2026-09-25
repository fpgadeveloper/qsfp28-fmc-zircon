#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# gen_vectors.py - test vectors and expected results for tb_zircon_nic.sv.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.
#
# This file is part of the Opsero qsfp28-fmc-zircon reference design and is
# licensed under the MIT license (see LICENSE at the repo root).
#
# Builds every frame in plain Python (no scapy), including the replies the
# hardware must produce (IPv4 header checksum, UDP checksum, socket descriptor),
# and writes a command script that tb_zircon_nic.sv interprets:
#
#   TEST <n> <name>          start of a test (the TB prints PASS/FAIL at END)
#   WR <addr> <data>         AXI-Lite write (hex)
#   RD <addr> <exp> [<mask>] AXI-Lite read and compare (hex)
#   RX <bad> <hex>           queue a frame on the MAC RX stream (bad = tuser on last beat)
#   TXRAW <hex> / TXSOCK <hex>   queue a frame on the UI0 / UI2 TX stream
#   EXP <port> <hex>         expect this frame next on MAC | UI0 | UI2 (in order)
#   HOLD <port> <0|1>        force tready low on a sink
#   RANDREADY <0|1>          random tready on all sinks
#   SUBSEQ <port> <0|1>      subsequence mode: received frames are only collected
#   CAND <port> <hex>        candidate frame for subsequence mode (in order)
#   SUBCHK <port> <addr>...  received frames must be an ordered subsequence of the
#                            candidates, and received + sum(counters) == candidates
#   RXCNT <port> <n> <addr>... received + sum(counters) == n (count only), drops > 0
#   CHKEMPTY <port>          every frame expected so far on <port> has arrived
#   RSTMACRX <0|1>           drive mac_rx_aresetn
#   RSTMACTX <0|1>           drive mac_tx_aresetn
#   PACKSTAT <hex>           pulse the mrmac_rx_packer status input for one cycle
#   WAITRX                   wait until all queued input frames have been sent
#   WAIT <ns>                wait
#   PREFIX <port> <addr>...  subsequence-mode frames == the first n candidates, regs == n
#   COLLECT <port> <0|1>     frames on <port> are only counted; CNTEQ <port> <n> checks
#   LOOPBACK <0|1>           MAC TX frames are fed back into MAC RX
#   MACSHAPE / RXSHAPE <0|1> shape MAC TX tready / the MAC RX source to 100 Gb/s line rate
#   WAITCHG <addr>           poll until the register changes (must be +1)
#   WAITREG <addr> <v> [<m>] poll until (register & m) == v
#   RDEQ <a> <b> [<min>]     registers a and b equal (and >= min)
#   TXGAPMIN <ns>            MAC TX frames of this test at least <ns> apart
#   RATEINFO <label> [<skip>] print the MAC TX throughput of this test (informational)
#   SHOWREG <label> <addr>.. print register values (informational)
#   RDSUM <n> <addr>...      the listed registers add up to n
#   RXRATEINFO <label>       print the rx_dispatch frame rate of this test (informational)
#   TSCLR                    forget the MAC TX time stamps of this test (RATEINFO)
# Latency measurement (1.3.0; the TB models the MRMAC PTP timer / timestamps):
#   TXRAWD <m> <hex>         UI0 frame behind a ZTXT descriptor (rx_ts = the PTP timer):
#                            m 0 TS_REQ 0, 1 TS_REQ 1 (bank-1 expectation), 2 TS_REQ 1
#                            with rx_ts 2 s old (implausible), 3 TS_REQ 1, no expectation
#   LATECHO <0|1>            MAC RX frames are echo requests: bank-0 expectations
#   RXDESC <0|1>             UI0 frames carry a ZRXT descriptor (checked and stripped)
#   LATCNT <frames> <ts>     PTP records used by MAC TX frames / with op 2 in this test
#   LATCHK <bank>            snapshot + exact compare with the model (all scalars, 64 bins)
#   LATCLR <bank>            LAT_CTRL clear (model cleared too); LATFLUSH: forget expectations
#   LATCOHERE <bank> <n>     n snapshots while samples arrive, each internally coherent
#   PTPTIMER <hex>           set the PTP timer; PTPDELAY <min> <max>: TX timestamp delay
#                            (mac_tx cycles); PTPREADY <0|1|2>: m_axis_tx_ptp tready
#   DRAIN                    wait until all expected frames arrived (or timeout), settle
#   END                      end of test
#   FINISH                   end of simulation
#
# Usage: gen_vectors.py <out_dir> [--gen0]   -> <out_dir>/vectors.txt
#   --gen0: the vector set for a GEN_EN = 0 build (-> vectors_gen0.txt)

import os
import random
import struct
import sys

# ---------------------------------------------------------------------------
# Addresses / configuration
# ---------------------------------------------------------------------------
LOCAL_MAC = bytes.fromhex("020a355a4901")
LOCAL_IP = bytes([192, 168, 10, 2])
HOST_MAC = bytes.fromhex("3cfdfea1b2c3")
HOST_IP = bytes([192, 168, 10, 1])
OTHER_MAC = bytes.fromhex("001122334455")
BCAST_MAC = b"\xff" * 6
ECHO_PORT = 7
SOCK_LOCAL_PORT = 5000
SOCK_REMOTE_PORT = 6000
SOCK_REMOTE_IP = HOST_IP
SOCK_REMOTE_MAC = HOST_MAC
TTL = 64

# register offsets
R_ID, R_VERSION, R_CTRL, R_STATUS = 0x000, 0x004, 0x008, 0x00C
R_MAC_LO, R_MAC_HI, R_IPV4, R_ECHO_PORT = 0x010, 0x014, 0x018, 0x01C
R_SOCK_LOCAL_PORT, R_SOCK_REMOTE_PORT, R_SOCK_REMOTE_IP = 0x020, 0x024, 0x028
R_SOCK_REMOTE_MAC_LO, R_SOCK_REMOTE_MAC_HI, R_TTL = 0x02C, 0x030, 0x034
R_RX_FRAMES, R_RX_BYTES_LO, R_RX_BYTES_HI = 0x040, 0x044, 0x048
R_RX_BAD_FRAME, R_RX_FIFO_DROP, R_RX_L3_BAD, R_RX_L4_BAD = 0x04C, 0x050, 0x054, 0x058
R_RX_RAW, R_RX_ECHO, R_RX_SOCK = 0x05C, 0x060, 0x064
R_TX_FRAMES, R_TX_BYTES_LO, R_TX_BYTES_HI = 0x068, 0x06C, 0x070
R_TX_RAW, R_TX_ECHO, R_TX_SOCK = 0x074, 0x078, 0x07C
R_RX_RAW_DROP, R_RX_SOCK_DROP, R_RX_ECHO_DROP, R_TX_OVERSIZE_DROP = 0x080, 0x084, 0x088, 0x08C
# generator / checker / rate meters (1.2.0)
R_GEN_CTRL, R_GEN_LEN, R_GEN_COUNT, R_GEN_GAP = 0x090, 0x094, 0x098, 0x09C
R_GEN_DST_MAC_LO, R_GEN_DST_MAC_HI, R_GEN_DST_IP = 0x0A0, 0x0A4, 0x0A8
R_GEN_DST_PORT, R_GEN_SRC_PORT = 0x0AC, 0x0B0
R_GEN_TX_PKTS, R_GEN_TX_BYTES_LO, R_GEN_TX_BYTES_HI = 0x0B4, 0x0B8, 0x0BC
R_CHK_CTRL, R_CHK_PORT, R_CHK_RX_PKTS = 0x0C0, 0x0C4, 0x0C8
R_CHK_RX_BYTES_LO, R_CHK_RX_BYTES_HI, R_CHK_SEQ_ERR = 0x0CC, 0x0D0, 0x0D4
R_CHK_BIT_ERR_LO, R_CHK_BIT_ERR_HI, R_CHK_LEN_ERR = 0x0D8, 0x0DC, 0x0E0
R_RATE_SEQ, R_RX_RATE_BYTES_LO, R_RX_RATE_BYTES_HI, R_RX_RATE_PKTS = 0x0E4, 0x0E8, 0x0EC, 0x0F0
R_TX_RATE_BYTES_LO, R_TX_RATE_BYTES_HI, R_TX_RATE_PKTS = 0x0F4, 0x0F8, 0x0FC

GEN_EN, GEN_CONT, GEN_CLR, GEN_BUSY = 1, 2, 4, 1 << 31
CHK_EN, CHK_CLR, CHK_SYNC = 1, 4, 1 << 31
CHK_PORT = 5001          # CHK_PORT reset value
GEN_LEN_DEFAULT = 1472
GEN_SRC_PORT = 5002

CTRL_RX_EN, CTRL_TX_EN, CTRL_ECHO_EN, CTRL_SOCK_EN = 1, 2, 4, 8
CTRL_STAT_CLR = 1 << 31
CTRL_ALL = CTRL_RX_EN | CTRL_TX_EN | CTRL_ECHO_EN | CTRL_SOCK_EN

# latency measurement (1.3.0)
R_LAT_CTRL, R_LAT_STATUS = 0x100, 0x104
R_LAT_BASE, R_LAT_WIDTH = 0x108, 0x10C
R_LAT_STALE, R_LAT_LOST, R_LAT_OVF = 0x110, 0x114, 0x118
LAT_EN, LAT_CLR0, LAT_CLR1, LAT_SNAP = 1, 2, 4, 8
LAT_RAW_RX_DESC, LAT_RAW_TX_DESC, LAT_BUSY = 1 << 8, 1 << 9, 1 << 31

COUNTERS = [R_RX_FRAMES, R_RX_BYTES_LO, R_RX_BYTES_HI, R_RX_BAD_FRAME, R_RX_FIFO_DROP,
            R_RX_L3_BAD, R_RX_L4_BAD, R_RX_RAW, R_RX_ECHO, R_RX_SOCK, R_TX_FRAMES,
            R_TX_BYTES_LO, R_TX_BYTES_HI, R_TX_RAW, R_TX_ECHO, R_TX_SOCK,
            R_RX_RAW_DROP, R_RX_SOCK_DROP, R_RX_ECHO_DROP, R_TX_OVERSIZE_DROP]

MAX_TX_BYTES = 9618   # zircon_nic MAX_TX_BYTES (UI TX transfers above it are dropped)

MIN_FRAME = 60   # without FCS

# ---------------------------------------------------------------------------
# Generator payload (docs/DESIGN_SPEC.md §10, udp_gen.sv / udp_chk.sv)
# ---------------------------------------------------------------------------
M64 = (1 << 64) - 1
PRBS_K = [((j + 1) * 0x9E3779B97F4A7C15) & M64 for j in range(8)]


def xs64(x):
    x ^= (x << 13) & M64
    x ^= x >> 7
    x ^= (x << 17) & M64
    return x


def gen_payload(seq, n):
    """Payload of generator datagram `seq` (n bytes): S little-endian in bytes 0..7,
    then per 64-byte beat b the eight lanes x_j(b+1), x_j(0) = (S ^ K_j) | 2^63."""
    x = [(seq ^ k) | (1 << 63) for k in PRBS_K]
    out = bytearray()
    while len(out) < n:
        x = [xs64(v) for v in x]
        for v in x:
            out += v.to_bytes(8, "little")
    out = out[:n]
    head = (seq & M64).to_bytes(8, "little")
    out[:min(8, n)] = head[:min(8, n)]
    return bytes(out)

# ---------------------------------------------------------------------------
# Packet construction
# ---------------------------------------------------------------------------


def csum_add(data, s=0):
    if len(data) % 2:
        data = data + b"\x00"
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return s


def inet_csum(data):
    return (~csum_add(data)) & 0xFFFF


def pad(frame):
    return frame + b"\x00" * max(0, MIN_FRAME - len(frame))


def eth(dst, src, ethertype, payload, vlan=None):
    hdr = dst + src
    if vlan is not None:
        hdr += struct.pack("!HH", 0x8100, vlan)
    return pad(hdr + struct.pack("!H", ethertype) + payload)


def ipv4(src, dst, proto, l4, ident=0, ttl=64, tos=0, flags_frag=0, bad_csum=False):
    total = 20 + len(l4)
    h = struct.pack("!BBHHHBBH4s4s", 0x45, tos, total, ident, flags_frag, ttl, proto, 0, src, dst)
    c = inet_csum(h)
    if bad_csum:
        c ^= 0x1234
    return h[:10] + struct.pack("!H", c) + h[12:] + l4


def udp_csum_sw(src, dst, seg):
    """Standard UDP checksum (0 is sent as 0xFFFF)."""
    ph = src + dst + struct.pack("!BBH", 0, 17, len(seg))
    c = inet_csum(ph + seg)
    return 0xFFFF if c == 0 else c


def udp_csum_hw(src, dst, seg):
    """Bit-true model of the UDP checksum on hardware-built headers:
    tx_meta_builder's payload-sum adjustment followed by zircon_ip_tx_deparse's
    single-fold ~(l4[15:0] + l4[20:16]). Equals the correct checksum (0x0000 when the
    sum folds to 0xFFFF), or 0x0000 ("no checksum") in the unreachable corner."""
    sport, dport = struct.unpack("!HH", seg[:4])
    payload = seg[8:]
    k = deparser_l4_sum(src, dst, sport, dport, payload) - fold_full(csum_add(payload))
    psum = fold_full(csum_add(payload))
    t = fold_full(psum + k)
    kl, kh = k & 0xFFFF, k >> 16
    a = kl + kh
    if t >= a:
        adj = t - a
    elif t >= kh + 1:
        adj = t + 0xFFFF - a
    elif t < kh and a <= 0x10000 + t:
        adj = 0x10000 + t - a
    elif a <= 0xFFFF:
        adj = 0xFFFF - a
    else:
        adj = 0x1FFFE - a
    l4 = adj + k
    hw = (~((l4 & 0xFFFF) + (l4 >> 16))) & 0xFFFF
    ph = src + dst + struct.pack("!BBH", 0, 17, len(seg))
    correct = inet_csum(ph + seg)
    assert hw == correct or hw == 0, "model: unexpected checksum"
    return hw


def udp(src_ip, dst_ip, sport, dport, payload, csum="sw"):
    seg = struct.pack("!HHHH", sport, dport, 8 + len(payload), 0) + payload
    if csum == "sw":
        c = udp_csum_sw(src_ip, dst_ip, seg)
    elif csum == "hw":
        c = udp_csum_hw(src_ip, dst_ip, seg)
    else:
        c = csum
    return seg[:6] + struct.pack("!H", c) + seg[8:]


def tcp(src_ip, dst_ip, sport, dport, payload, seq=1000, ack=2000, flags=0x18):
    seg = struct.pack("!HHIIBBHHH", sport, dport, seq, ack, 5 << 4, flags, 65535, 0, 0) + payload
    ph = src_ip + dst_ip + struct.pack("!BBH", 0, 6, len(seg))
    c = inet_csum(ph + seg)
    return seg[:16] + struct.pack("!H", c) + seg[18:]


def udp_frame(dst_mac, src_mac, src_ip, dst_ip, sport, dport, payload, csum="sw",
              ident=0, vlan=None, bad_ip_csum=False):
    return eth(dst_mac, src_mac, 0x0800,
               ipv4(src_ip, dst_ip, 17, udp(src_ip, dst_ip, sport, dport, payload, csum),
                    ident=ident, bad_csum=bad_ip_csum), vlan=vlan)


def arp_request(src_mac, src_ip, target_ip):
    body = struct.pack("!HHBBH6s4s6s4s", 1, 0x0800, 6, 4, 1, src_mac, src_ip, b"\x00" * 6, target_ip)
    return eth(BCAST_MAC, src_mac, 0x0806, body)


def payload_bytes(n, seed):
    r = random.Random(seed)
    return bytes(r.getrandbits(8) for _ in range(n))


def ip_to_reg(ip):
    return (ip[0] << 24) | (ip[1] << 16) | (ip[2] << 8) | ip[3]


def mac_lo(mac):
    return mac[0] | (mac[1] << 8) | (mac[2] << 16) | (mac[3] << 24)


def mac_hi(mac):
    return mac[4] | (mac[5] << 8)


# ---------------------------------------------------------------------------
# Hardware models
# ---------------------------------------------------------------------------
class Model:
    def __init__(self):
        self.ip_id = 0      # tx_meta_builder identification counter (echo + socket)

    def next_id(self):
        assert self.ip_id is not None, "IPv4 ID model out of step (continuous generator test ran)"
        v = self.ip_id
        self.ip_id = (self.ip_id + 1) & 0xFFFF
        return v

    def echo_reply(self, rx_src_mac, rx_src_ip, rx_sport, payload):
        ident = self.next_id()
        return eth(rx_src_mac, LOCAL_MAC, 0x0800,
                   ipv4(LOCAL_IP, rx_src_ip, 17,
                        udp(LOCAL_IP, rx_src_ip, ECHO_PORT, rx_sport, payload, csum="hw"),
                        ident=ident, ttl=TTL))

    def gen_tx(self, seq, n, dst_mac=HOST_MAC, dst_ip=HOST_IP, dport=9000, sport=GEN_SRC_PORT):
        """Frame built by the hardware generator (payload clamped to 8..9000)."""
        n = min(max(n, 8), 9000)
        ident = self.next_id()
        return eth(dst_mac, LOCAL_MAC, 0x0800,
                   ipv4(LOCAL_IP, dst_ip, 17,
                        udp(LOCAL_IP, dst_ip, sport, dport, gen_payload(seq, n), csum="hw"),
                        ident=ident, ttl=TTL))

    def sock_tx(self, payload, lport=SOCK_LOCAL_PORT, rport=SOCK_REMOTE_PORT):
        ident = self.next_id()
        return eth(SOCK_REMOTE_MAC, LOCAL_MAC, 0x0800,
                   ipv4(LOCAL_IP, SOCK_REMOTE_IP, 17,
                        udp(LOCAL_IP, SOCK_REMOTE_IP, lport, rport, payload, csum="hw"),
                        ident=ident, ttl=TTL))


def fold_full(v):
    while v >> 16:
        v = (v & 0xFFFF) + (v >> 16)
    return v


def deparser_l4_sum(src_ip, dst_ip, sport, dport, payload):
    """The 21-bit L4 accumulator of zircon_ip_tx_deparse for an IPv4/UDP header
    (payload sum from zircon_ip_len_cksum + UDP length + ports + folded pseudo-header)."""
    psum = fold_full(csum_add(payload))
    l4len = len(payload) + 8
    common = l4len + 17 + ((dst_ip[0] << 8) | dst_ip[1]) + ((dst_ip[2] << 8) | dst_ip[3]) + \
        ((src_ip[0] << 8) | src_ip[1]) + ((src_ip[2] << 8) | src_ip[3])
    return psum + l4len + sport + dport + (common & 0xFFFF) + (common >> 16)


def fold_corner_payloads(src_ip, dst_ip, sport, dport, n, count):
    """Payloads of n bytes (n even) for which l4[15:0] + l4[20:16] carries out of
    16 bits in the deparser. Built directly: a random prefix plus a 16-bit word
    chosen so the payload's ones'-complement sum hits a corner value."""
    k = deparser_l4_sum(src_ip, dst_ip, sport, dport, b"\x00" * n)   # payload sum 0
    targets = [ps for ps in range(1, 0x10000)
               if ((ps + k) & 0xFFFF) + ((ps + k) >> 16) > 0xFFFF]
    out = []
    for i, t in enumerate(targets[:count]):
        prefix = payload_bytes(n - 2, 7000 + i)
        ps = fold_full(csum_add(prefix))
        w = (t - ps) % 0xFFFF          # ones'-complement difference
        if w == 0:
            w = 0xFFFF
        pl = prefix + struct.pack("!H", w)
        assert fold_full(csum_add(pl)) == t
        out.append(pl)
    return out


def sock_desc(src_mac, src_ip, sport, dst_ip, dport, plen):
    flags = (1 << 3) | (1 << 9) | (1 << 31)     # IPV4 | UDP | PARSE_DONE
    d = struct.pack("<IHH", 0x5A534B54, plen, sport) + src_ip + src_mac + struct.pack("<H", dport) + dst_ip
    d += struct.pack("<I", flags)
    return d + b"\x00" * (64 - len(d))


# ---------------------------------------------------------------------------
# Script writer
# ---------------------------------------------------------------------------
class Script:
    def __init__(self):
        self.lines = []

    def c(self, *args):
        self.lines.append(" ".join(str(a) for a in args))

    def wr(self, addr, data):
        self.c("WR", "%03x" % addr, "%08x" % (data & 0xFFFFFFFF))

    def rd(self, addr, exp, mask=0xFFFFFFFF):
        self.c("RD", "%03x" % addr, "%08x" % (exp & 0xFFFFFFFF), "%08x" % mask)

    def rx(self, frame, bad=0):
        self.c("RX", bad, frame.hex())

    def txraw(self, frame):
        self.c("TXRAW", frame.hex())

    def txsock(self, frame):
        self.c("TXSOCK", frame.hex())

    def exp(self, port, frame):
        self.c("EXP", port, frame.hex())

    def counters(self, **kw):
        """Read every counter; unspecified ones must be 0."""
        vals = {a: 0 for a in COUNTERS}
        names = {"rx_frames": R_RX_FRAMES, "rx_bad": R_RX_BAD_FRAME, "rx_drop": R_RX_FIFO_DROP,
                 "rx_l3": R_RX_L3_BAD, "rx_l4": R_RX_L4_BAD, "rx_raw": R_RX_RAW, "rx_echo": R_RX_ECHO,
                 "rx_sock": R_RX_SOCK, "tx_frames": R_TX_FRAMES, "tx_raw": R_TX_RAW,
                 "tx_echo": R_TX_ECHO, "tx_sock": R_TX_SOCK, "rx_raw_drop": R_RX_RAW_DROP,
                 "rx_sock_drop": R_RX_SOCK_DROP, "rx_echo_drop": R_RX_ECHO_DROP,
                 "tx_oversize": R_TX_OVERSIZE_DROP}
        for k, v in kw.items():
            if k == "rx_bytes":
                vals[R_RX_BYTES_LO] = v & 0xFFFFFFFF
                vals[R_RX_BYTES_HI] = v >> 32
            elif k == "tx_bytes":
                vals[R_TX_BYTES_LO] = v & 0xFFFFFFFF
                vals[R_TX_BYTES_HI] = v >> 32
            else:
                vals[names[k]] = v
        for a in COUNTERS:     # LO before HI (HI is latched on the LO read)
            self.rd(a, vals[a])

    def configure(self, ctrl=CTRL_ALL):
        self.wr(R_MAC_LO, mac_lo(LOCAL_MAC))
        self.wr(R_MAC_HI, mac_hi(LOCAL_MAC))
        self.wr(R_IPV4, ip_to_reg(LOCAL_IP))
        self.wr(R_ECHO_PORT, ECHO_PORT)
        self.wr(R_SOCK_LOCAL_PORT, SOCK_LOCAL_PORT)
        self.wr(R_SOCK_REMOTE_PORT, SOCK_REMOTE_PORT)
        self.wr(R_SOCK_REMOTE_IP, ip_to_reg(SOCK_REMOTE_IP))
        self.wr(R_SOCK_REMOTE_MAC_LO, mac_lo(SOCK_REMOTE_MAC))
        self.wr(R_SOCK_REMOTE_MAC_HI, mac_hi(SOCK_REMOTE_MAC))
        self.wr(R_TTL, TTL)
        self.start(ctrl)

    def gen_counters(self, gen_pkts=0, gen_bytes=0, chk_pkts=0, chk_bytes=0, seq_err=0, bit_err=0,
                     len_err=0):
        """Read the generator / checker counters (LO before HI)."""
        self.rd(R_GEN_TX_PKTS, gen_pkts)
        self.rd(R_GEN_TX_BYTES_LO, gen_bytes & 0xFFFFFFFF)
        self.rd(R_GEN_TX_BYTES_HI, gen_bytes >> 32)
        self.rd(R_CHK_RX_PKTS, chk_pkts)
        self.rd(R_CHK_RX_BYTES_LO, chk_bytes & 0xFFFFFFFF)
        self.rd(R_CHK_RX_BYTES_HI, chk_bytes >> 32)
        self.rd(R_CHK_SEQ_ERR, seq_err)
        self.rd(R_CHK_BIT_ERR_LO, bit_err & 0xFFFFFFFF)
        self.rd(R_CHK_BIT_ERR_HI, bit_err >> 32)
        self.rd(R_CHK_LEN_ERR, len_err)

    def gen_config(self, dst_mac=HOST_MAC, dst_ip=HOST_IP, dport=9000, sport=GEN_SRC_PORT,
                   length=GEN_LEN_DEFAULT, count=0, gap=0):
        self.wr(R_GEN_CTRL, 0)
        self.wr(R_GEN_DST_MAC_LO, mac_lo(dst_mac))
        self.wr(R_GEN_DST_MAC_HI, mac_hi(dst_mac))
        self.wr(R_GEN_DST_IP, ip_to_reg(dst_ip))
        self.wr(R_GEN_DST_PORT, dport)
        self.wr(R_GEN_SRC_PORT, sport)
        self.wr(R_GEN_LEN, length)
        self.wr(R_GEN_COUNT, count)
        self.wr(R_GEN_GAP, gap)

    def start(self, ctrl=CTRL_ALL):
        """Set CTRL, clear the statistics and let the configuration cross over."""
        self.wr(R_CTRL, ctrl | CTRL_STAT_CLR)
        self.c("WAIT", 1000)
        self.wr(R_STATUS, 0x3F)  # clear sticky flags


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    gen0 = "--gen0" in sys.argv[1:]
    out_dir = args[0] if args else "."
    # ZIRCON_TESTS="17,18" generates only those tests (plus test 1, which
    # programs the addresses). Tests are skipped at generation time so the
    # model's IPv4 ID counter stays in step with the hardware.
    only = os.environ.get("ZIRCON_TESTS", "").strip()
    wanted = {int(t) for t in only.split(",") if t.strip()} | {1} if only else None
    if gen0:
        # GEN_EN = 0 build: registers, the base datapaths, and the CHK port going RAW
        wanted = {9, 1, 3, 5, 44, 60}

    def sel(n):
        return wanted is None or n in wanted

    os.makedirs(out_dir, exist_ok=True)
    s = Script()
    m = Model()

    # ------------------------------------------------------------------
    # Test 9 first (register defaults must be read before anything is written)
    # ------------------------------------------------------------------
    if sel(9):
        s.c("TEST", 9, "registers_id_version_defaults_rw")
        s.rd(R_ID, 0x5A495243)
        s.rd(R_VERSION, 0x00010300)
        s.rd(R_CTRL, 0)
        s.rd(R_STATUS, 0)
        for a in (R_MAC_LO, R_MAC_HI, R_IPV4, R_SOCK_LOCAL_PORT, R_SOCK_REMOTE_PORT,
                  R_SOCK_REMOTE_IP, R_SOCK_REMOTE_MAC_LO, R_SOCK_REMOTE_MAC_HI):
            s.rd(a, 0)
        s.rd(R_ECHO_PORT, 7)
        s.rd(R_TTL, 64)
        s.counters()
        rw = [(R_MAC_LO, 0xA5A55A5A, 0xFFFFFFFF), (R_MAC_HI, 0xFFFFFFFF, 0x0000FFFF),
              (R_IPV4, 0x12345678, 0xFFFFFFFF), (R_ECHO_PORT, 0xDEADBEEF, 0x0000FFFF),
              (R_SOCK_LOCAL_PORT, 0xCAFE1388, 0x0000FFFF), (R_SOCK_REMOTE_PORT, 0x55AA1770, 0x0000FFFF),
              (R_SOCK_REMOTE_IP, 0xC0A80A01, 0xFFFFFFFF), (R_SOCK_REMOTE_MAC_LO, 0x01234567, 0xFFFFFFFF),
              (R_SOCK_REMOTE_MAC_HI, 0x89ABCDEF, 0x0000FFFF), (R_TTL, 0x1FF, 0xFF)]
        for a, v, msk in rw:
            s.wr(a, v)
        for a, v, msk in rw:
            s.rd(a, v & msk)
        s.wr(R_CTRL, 0x8000001F)            # STAT_CLR self-clears
        s.rd(R_CTRL, 0x1F)
        s.wr(R_CTRL, 0)
        s.rd(R_CTRL, 0)
        s.wr(R_ID, 0x11111111)              # read-only: ignored
        s.rd(R_ID, 0x5A495243)
        s.wr(0x128, 0x12345678)             # undefined offsets
        s.rd(0x128, 0)
        # latency registers (1.3.0): defaults, read/write, a snapshot of the empty banks
        for a, v in ((R_LAT_CTRL, 0), (R_LAT_STATUS, 0), (R_LAT_BASE, 0), (R_LAT_WIDTH, 64),
                     (R_LAT_STALE, 0), (R_LAT_LOST, 0), (R_LAT_OVF, 0), (0x11C, 0),
                     (0x200, 0), (0x400, 0), (0x7FC, 0)):
            s.rd(a, v)
        s.wr(R_LAT_BASE, 0x12345678)
        s.wr(R_LAT_WIDTH, 1000)             # rounded down to a power of two
        s.rd(R_LAT_BASE, 0x12345678)
        s.rd(R_LAT_WIDTH, 512)
        s.wr(R_LAT_WIDTH, 0)
        s.rd(R_LAT_WIDTH, 1)
        s.wr(R_LAT_WIDTH, 8)
        s.wr(R_LAT_CTRL, 0xFFFFFFF1)        # EN, RAW_RX_DESC, RAW_TX_DESC (+ reserved bits)
        s.rd(R_LAT_CTRL, LAT_EN | LAT_RAW_RX_DESC | LAT_RAW_TX_DESC)
        s.wr(R_LAT_CTRL, LAT_SNAP)          # commands self-clear; the snapshot runs
        s.c("WAITREG", "%03x" % R_LAT_CTRL, "00000000", "%08x" % LAT_BUSY)
        for a, v in ((0x200, 0), (0x204, 0), (0x218, 0xFFFFFFFF), (0x21C, 0), (0x228, 0x12345678), (0x22C, 8),
                     (0x240, 0), (0x258, 0xFFFFFFFF), (0x268, 0x12345678), (0x26C, 8), (0x230, 0),
                     (0x280, 0), (0x400, 0), (0x5FC, 0), (0x7F8, 0), (0x7FC, 0), (0x800, 0)):
            s.rd(a, v)
        s.wr(R_LAT_BASE, 0)
        s.wr(R_LAT_WIDTH, 64)
        s.rd(0x038, 0)
        s.rd(0xFFC, 0)
        s.rd(R_STATUS, 0)
        # generator / checker registers (1.2.0); with GEN_EN = 0 they all read 0
        g = 0 if gen0 else 1
        s.rd(R_GEN_CTRL, 0)
        s.rd(R_GEN_LEN, GEN_LEN_DEFAULT * g)
        for a in (R_GEN_COUNT, R_GEN_GAP, R_GEN_DST_MAC_LO, R_GEN_DST_MAC_HI, R_GEN_DST_IP,
                  R_GEN_DST_PORT, R_GEN_SRC_PORT, R_GEN_TX_PKTS, R_GEN_TX_BYTES_LO, R_GEN_TX_BYTES_HI,
                  R_CHK_CTRL, R_CHK_RX_PKTS, R_CHK_RX_BYTES_LO, R_CHK_RX_BYTES_HI, R_CHK_SEQ_ERR,
                  R_CHK_BIT_ERR_LO, R_CHK_BIT_ERR_HI, R_CHK_LEN_ERR):
            s.rd(a, 0)
        s.rd(R_CHK_PORT, CHK_PORT * g)
        # rate registers hold 0 until RATE_SEQ is read; no traffic yet, so 0 after too
        for a in (R_RX_RATE_BYTES_LO, R_RX_RATE_BYTES_HI, R_RX_RATE_PKTS, R_TX_RATE_BYTES_LO,
                  R_TX_RATE_BYTES_HI, R_TX_RATE_PKTS):
            s.rd(a, 0)
        s.c("WAITCHG", "%03x" % R_RATE_SEQ)      # the window counter runs (+1 per window)
        for a in (R_RX_RATE_BYTES_LO, R_RX_RATE_BYTES_HI, R_RX_RATE_PKTS, R_TX_RATE_BYTES_LO,
                  R_TX_RATE_BYTES_HI, R_TX_RATE_PKTS):
            s.rd(a, 0)
        rw = [(R_GEN_LEN, 0xFFFF1234, 0x0000FFFF), (R_GEN_COUNT, 0xDEADBEEF, 0xFFFFFFFF),
              (R_GEN_GAP, 0x12345678, 0xFFFFFFFF), (R_GEN_DST_MAC_LO, 0xA1B2C3D4, 0xFFFFFFFF),
              (R_GEN_DST_MAC_HI, 0x9876E5F6, 0x0000FFFF), (R_GEN_DST_IP, 0x0A000001, 0xFFFFFFFF),
              (R_GEN_DST_PORT, 0xFFFF1389, 0x0000FFFF), (R_GEN_SRC_PORT, 0x1234138A, 0x0000FFFF),
              (R_CHK_PORT, 0xABCD2710, 0x0000FFFF)]
        for a, v, msk in rw:
            s.wr(a, v)
        for a, v, msk in rw:
            s.rd(a, (v & msk) * g)
        s.wr(R_GEN_CTRL, GEN_CONT | GEN_CLR)     # CLR self-clears; EN stays 0 (no run)
        s.rd(R_GEN_CTRL, GEN_CONT * g)
        s.wr(R_GEN_CTRL, 0)
        s.wr(R_CHK_CTRL, CHK_EN | CHK_CLR)
        s.rd(R_CHK_CTRL, CHK_EN * g)
        s.wr(R_CHK_CTRL, 0)
        s.rd(R_CHK_CTRL, 0)
        s.wr(R_GEN_LEN, GEN_LEN_DEFAULT)
        s.wr(R_CHK_PORT, CHK_PORT)
        s.wr(R_GEN_COUNT, 0)
        s.wr(R_GEN_GAP, 0)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 1: raw RX
    # ------------------------------------------------------------------
    if sel(1):
        s.c("TEST", 1, "raw_rx_arp_tcp_udp_other_port")
        s.configure()
        frames = [arp_request(HOST_MAC, HOST_IP, LOCAL_IP),
                  eth(LOCAL_MAC, HOST_MAC, 0x0800,
                      ipv4(HOST_IP, LOCAL_IP, 6, tcp(HOST_IP, LOCAL_IP, 40000, 22, payload_bytes(1460, 1)))),
                  udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 1234, 9999, payload_bytes(33, 2)),
                  udp_frame(OTHER_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 1234, ECHO_PORT, payload_bytes(40, 3))]
        assert len(frames[1]) == 1514
        for f in frames:
            s.rx(f)
            s.exp("UI0", f)
        s.c("DRAIN")
        nb = sum(len(f) for f in frames)
        s.counters(rx_frames=4, rx_bytes=nb, rx_raw=4)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 2: raw TX
    # ------------------------------------------------------------------
    if sel(2):
        s.c("TEST", 2, "raw_tx_normal_short_jumbo")
        s.start()
        frames = [udp_frame(HOST_MAC, LOCAL_MAC, LOCAL_IP, HOST_IP, 7777, 8888, payload_bytes(58, 4)),
                  arp_request(LOCAL_MAC, LOCAL_IP, HOST_IP)[:42],     # unpadded 42-byte ARP from software
                  eth(HOST_MAC, LOCAL_MAC, 0x0800,
                      ipv4(LOCAL_IP, HOST_IP, 17, udp(LOCAL_IP, HOST_IP, 1, 2, payload_bytes(8958, 5))))]
        assert len(frames[2]) == 9000
        for f in frames:
            s.txraw(f)
            s.exp("MAC", pad(f))
        s.c("DRAIN")
        s.counters(tx_frames=3, tx_bytes=sum(len(pad(f)) for f in frames), tx_raw=3)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 3: hardware echo
    # ------------------------------------------------------------------
    if sel(3):
        s.c("TEST", 3, "hw_echo_sizes_badcsum_zerocsum")
        s.start()
        rxb = txb = 0
        n_echo = 0
        for i, n in enumerate([1, 18, 100, 1472, 8000]):
            p = payload_bytes(n, 100 + i)
            f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 33000 + i, ECHO_PORT, p, ident=0x100 + i)
            r = m.echo_reply(HOST_MAC, HOST_IP, 33000 + i, p)
            s.rx(f)
            s.exp("MAC", pad(r))
            rxb += len(f)
            txb += len(pad(r))
            n_echo += 1
        # wrong UDP checksum -> raw
        p = payload_bytes(100, 200)
        f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 33100, ECHO_PORT, p)
        f = bytearray(f)
        f[40] ^= 0x5A
        f = bytes(f)
        s.rx(f)
        s.exp("UI0", f)
        rxb += len(f)
        # wrong IPv4 header checksum -> raw, counted as L3 bad
        f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 33101, ECHO_PORT, payload_bytes(64, 201),
                      bad_ip_csum=True)
        s.rx(f)
        s.exp("UI0", f)
        rxb += len(f)
        # UDP checksum 0 (not computed by the sender) -> echoed
        p = payload_bytes(64, 202)
        f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 33102, ECHO_PORT, p, csum=0)
        r = m.echo_reply(HOST_MAC, HOST_IP, 33102, p)
        s.rx(f)
        s.exp("MAC", pad(r))
        rxb += len(f)
        txb += len(pad(r))
        n_echo += 1
        s.c("DRAIN")
        s.counters(rx_frames=8, rx_bytes=rxb, rx_raw=2, rx_echo=n_echo, rx_l3=1, rx_l4=1,
                   tx_frames=n_echo, tx_bytes=txb, tx_echo=n_echo)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 4: socket RX
    # ------------------------------------------------------------------
    if sel(4):
        s.c("TEST", 4, "hw_socket_rx_descriptor")
        s.start()
        rxb = 0
        for i, n in enumerate([200, 5, 1472, 64]):
            p = payload_bytes(n, 300 + i)
            f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, SOCK_REMOTE_PORT + i, SOCK_LOCAL_PORT, p)
            s.rx(f)
            s.exp("UI2", sock_desc(HOST_MAC, HOST_IP, SOCK_REMOTE_PORT + i, LOCAL_IP, SOCK_LOCAL_PORT, n) + p)
            rxb += len(f)
        s.c("DRAIN")
        s.counters(rx_frames=4, rx_bytes=rxb, rx_sock=4)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 5: socket TX
    # ------------------------------------------------------------------
    if sel(5):
        s.c("TEST", 5, "hw_socket_tx_headers_from_regs")
        s.start()
        txb = 0
        for i, n in enumerate([300, 10, 1472, 64, 3000]):
            p = payload_bytes(n, 400 + i)
            r = pad(m.sock_tx(p))
            s.txsock(p)
            s.exp("MAC", r)
            txb += len(r)
        s.c("DRAIN")
        s.counters(tx_frames=5, tx_bytes=txb, tx_sock=5)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 6: MAC error frame dropped
    # ------------------------------------------------------------------
    if sel(6):
        s.c("TEST", 6, "mac_bad_frame_dropped")
        s.start()
        bad = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 1111, ECHO_PORT, payload_bytes(300, 500))
        bad1 = arp_request(HOST_MAC, HOST_IP, LOCAL_IP)
        good = arp_request(HOST_MAC, HOST_IP, bytes([192, 168, 10, 99]))
        s.rx(bad, bad=1)
        s.rx(bad1, bad=1)
        s.rx(good)
        s.exp("UI0", good)
        s.c("DRAIN")
        s.counters(rx_frames=1, rx_bytes=len(good), rx_bad=2, rx_raw=1)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 7: back-to-back minimum-size frames with UI0 back-pressure
    # ------------------------------------------------------------------
    def min_frame(seq):
        return eth(LOCAL_MAC, HOST_MAC, 0x88B5, struct.pack("!I", seq) + payload_bytes(46, seq))

    if sel(7):
        s.c("TEST", 7, "back_to_back_64B_x200_backpressure")
        s.start()
        s.c("HOLD", "UI0", 1)
        frames = [min_frame(i) for i in range(200)]
        for f in frames:
            assert len(f) == 64
            s.rx(f)
            s.exp("UI0", f)
        s.c("WAITRX")
        s.c("WAIT", 20000)
        s.rd(R_RX_FIFO_DROP, 0)
        s.rd(R_STATUS, 0)
        s.c("HOLD", "UI0", 0)
        s.c("DRAIN")
        s.counters(rx_frames=200, rx_bytes=200 * 64, rx_raw=200)
        s.c("END")

    if sel(71):
        s.c("TEST", 71, "back_to_back_64B_x1500_overrun")
        s.start()
        s.c("HOLD", "UI0", 1)
        s.c("SUBSEQ", "UI0", 1)
        for i in range(1500):
            f = min_frame(10000 + i)
            s.rx(f)
            s.c("CAND", "UI0", f.hex())
        s.c("WAITRX")
        s.c("WAIT", 20000)
        s.rd(R_STATUS, 1, 1)                # RX_FIFO_OVF sticky
        s.c("HOLD", "UI0", 0)
        s.c("DRAIN")
        # frames are lost at the MAC-side FIFO (parser-bound) and at the raw-path FIFO
        s.c("SUBCHK", "UI0", "%03x" % R_RX_FIFO_DROP, "%03x" % R_RX_RAW_DROP)
        s.c("SUBSEQ", "UI0", 0)
        s.wr(R_STATUS, 1)                   # W1C
        s.rd(R_STATUS, 0)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 8: VLAN-tagged UDP to the echo port -> raw
    # ------------------------------------------------------------------
    if sel(8):
        s.c("TEST", 8, "vlan_udp_to_echo_port_is_raw")
        s.start()
        f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 2222, ECHO_PORT, payload_bytes(80, 800), vlan=10)
        s.rx(f)
        s.exp("UI0", f)
        s.c("DRAIN")
        s.counters(rx_frames=1, rx_bytes=len(f), rx_raw=1)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 10: CTRL.RX_EN = 0 drops at dispatch, CTRL.TX_EN = 0 discards at the MAC side
    # ------------------------------------------------------------------
    if sel(10):
        s.c("TEST", 10, "rx_en_tx_en_gating")
        s.start(CTRL_TX_EN | CTRL_ECHO_EN | CTRL_SOCK_EN)
        f1 = arp_request(HOST_MAC, HOST_IP, LOCAL_IP)
        f2 = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 3333, ECHO_PORT, payload_bytes(20, 900))
        s.rx(f1)
        s.rx(f2)
        s.c("DRAIN")
        s.counters(rx_frames=2, rx_bytes=len(f1) + len(f2), rx_drop=2)
        s.start(CTRL_RX_EN | CTRL_ECHO_EN | CTRL_SOCK_EN)
        t1 = udp_frame(HOST_MAC, LOCAL_MAC, LOCAL_IP, HOST_IP, 1, 2, payload_bytes(100, 901))
        s.txraw(t1)
        s.c("DRAIN")
        s.counters(tx_raw=1)
        s.start(CTRL_ALL)
        t2 = udp_frame(HOST_MAC, LOCAL_MAC, LOCAL_IP, HOST_IP, 3, 4, payload_bytes(200, 902))
        s.txraw(t2)
        s.exp("MAC", t2)
        s.rx(f1)
        s.exp("UI0", f1)
        s.c("DRAIN")
        s.counters(rx_frames=1, rx_bytes=len(f1), rx_raw=1, tx_frames=1, tx_bytes=len(t2), tx_raw=1)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 11: mixed traffic, random back-pressure on every sink
    # ------------------------------------------------------------------
    if sel(11):
        s.c("TEST", 11, "mixed_traffic_random_backpressure")
        s.start()
        s.c("RANDREADY", 1)
        rnd = random.Random(1234)
        cnt = dict(rx_frames=0, rx_bytes=0, rx_raw=0, rx_echo=0, rx_sock=0, tx_frames=0, tx_bytes=0,
                   tx_raw=0, tx_echo=0, tx_sock=0)
        for i in range(60):
            kind = rnd.choice(["raw", "echo", "sock", "txraw", "txsock"])
            n = rnd.choice([1, 7, 22, 23, 64, 86, 100, 500, 1400, rnd.randint(1, 3000)])
            p = payload_bytes(n, 1000 + i)
            if kind == "raw":
                f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 4000 + i, 4444, p)
                s.rx(f)
                s.exp("UI0", f)
                cnt["rx_frames"] += 1
                cnt["rx_bytes"] += len(f)
                cnt["rx_raw"] += 1
            elif kind == "echo":
                f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 4000 + i, ECHO_PORT, p)
                s.rx(f)
                cnt["rx_frames"] += 1
                cnt["rx_bytes"] += len(f)
                cnt["rx_echo"] += 1
                r = pad(m.echo_reply(HOST_MAC, HOST_IP, 4000 + i, p))
                s.exp("MAC", r)
                cnt["tx_frames"] += 1
                cnt["tx_bytes"] += len(r)
                cnt["tx_echo"] += 1
                # wait for the echo so the MAC TX order (echo vs. UI TX) is deterministic
                s.c("DRAIN")
            elif kind == "sock":
                f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 4000 + i, SOCK_LOCAL_PORT, p)
                s.rx(f)
                s.exp("UI2", sock_desc(HOST_MAC, HOST_IP, 4000 + i, LOCAL_IP, SOCK_LOCAL_PORT, n) + p)
                cnt["rx_frames"] += 1
                cnt["rx_bytes"] += len(f)
                cnt["rx_sock"] += 1
            elif kind == "txraw":
                f = udp_frame(HOST_MAC, LOCAL_MAC, LOCAL_IP, HOST_IP, 5, 6, p)
                s.txraw(f)
                s.exp("MAC", pad(f))
                cnt["tx_frames"] += 1
                cnt["tx_bytes"] += len(pad(f))
                cnt["tx_raw"] += 1
                s.c("DRAIN")
            else:
                r = pad(m.sock_tx(p))
                s.txsock(p)
                s.exp("MAC", r)
                cnt["tx_frames"] += 1
                cnt["tx_bytes"] += len(r)
                cnt["tx_sock"] += 1
                s.c("DRAIN")
        s.c("DRAIN")
        s.c("RANDREADY", 0)
        s.counters(**cnt)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 12: UDP checksum corner cases of the hardware-built headers
    # (payloads chosen so the deparser's 21-bit L4 sum needs a second
    # end-around-carry fold; see tx_meta_builder.sv)
    # ------------------------------------------------------------------
    if sel(12):
        s.c("TEST", 12, "udp_csum_fold_corner_cases")
        s.start()
        txb = rxb = 0
        n_echo = n_sock = 0
        for sport in (34567, 50000, 60001, 65000):
            for p in fold_corner_payloads(LOCAL_IP, HOST_IP, ECHO_PORT, sport, 18, 3):
                f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, sport, ECHO_PORT, p)
                r = pad(m.echo_reply(HOST_MAC, HOST_IP, sport, p))
                s.rx(f)
                s.exp("MAC", r)
                s.c("DRAIN")
                rxb += len(f)
                txb += len(r)
                n_echo += 1
        for lport, rport in ((50000, 65000), (65535, 65535)):
            s.wr(R_SOCK_LOCAL_PORT, lport)
            s.wr(R_SOCK_REMOTE_PORT, rport)
            s.c("WAIT", 1000)
            for p in fold_corner_payloads(LOCAL_IP, SOCK_REMOTE_IP, lport, rport, 40, 3):
                r = pad(m.sock_tx(p, lport, rport))
                s.txsock(p)
                s.exp("MAC", r)
                s.c("DRAIN")
                txb += len(r)
                n_sock += 1
        assert n_echo > 0 and n_sock > 0
        s.wr(R_SOCK_LOCAL_PORT, SOCK_LOCAL_PORT)
        s.wr(R_SOCK_REMOTE_PORT, SOCK_REMOTE_PORT)
        s.counters(rx_frames=n_echo, rx_bytes=rxb, rx_echo=n_echo, tx_frames=n_echo + n_sock, tx_bytes=txb,
                   tx_echo=n_echo, tx_sock=n_sock)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 15: head-of-line blocking (review #2): UI0 and UI2 stalled, the
    # hardware echo must keep working; RAW / SOCK frames beyond their drop
    # FIFOs are dropped and counted; the paths resume with intact frames.
    # ------------------------------------------------------------------
    if sel(15):
        s.c("TEST", 15, "hol_raw_sock_stalled_echo_flows")
        s.start()
        s.c("RXGAP", 24)                    # stay below the parser rate: no MAC-side drops
        s.c("HOLD", "UI0", 1)
        s.c("HOLD", "UI2", 1)
        s.c("SUBSEQ", "UI0", 1)
        s.c("SUBSEQ", "UI2", 1)
        n_grp = 40
        for i in range(n_grp):
            f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 20000 + i, 9999, payload_bytes(1472, 1500 + i))
            s.rx(f)
            s.c("CAND", "UI0", f.hex())
            p = payload_bytes(100 + i, 1600 + i)
            f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 21000 + i, ECHO_PORT, p)
            s.rx(f)
            s.exp("MAC", pad(m.echo_reply(HOST_MAC, HOST_IP, 21000 + i, p)))
            p = payload_bytes(1000, 1700 + i)
            f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 22000 + i, SOCK_LOCAL_PORT, p)
            s.rx(f)
            s.c("CAND", "UI2", (sock_desc(HOST_MAC, HOST_IP, 22000 + i, LOCAL_IP, SOCK_LOCAL_PORT, 1000) + p).hex())
        s.c("WAITRX")
        s.c("WAIT", 30000)
        s.c("CHKEMPTY", "MAC")              # every echo left while UI0/UI2 were stalled
        s.rd(R_RX_FIFO_DROP, 0)
        s.rd(R_RX_ECHO, n_grp)
        s.rd(R_RX_ECHO_DROP, 0)
        s.c("HOLD", "UI0", 0)
        s.c("HOLD", "UI2", 0)
        s.c("DRAIN")
        s.c("SUBCHK", "UI0", "%03x" % R_RX_RAW_DROP)
        s.c("SUBCHK", "UI2", "%03x" % R_RX_SOCK_DROP)
        s.c("SUBSEQ", "UI0", 0)
        s.c("SUBSEQ", "UI2", 0)
        # nothing wedged: both paths deliver intact frames again
        for i in range(4):
            f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 23000 + i, 9999, payload_bytes(1472 - 300 * i, 1800 + i))
            s.rx(f)
            s.exp("UI0", f)
            p = payload_bytes(64 + 500 * i, 1900 + i)
            f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 24000 + i, SOCK_LOCAL_PORT, p)
            s.rx(f)
            s.exp("UI2", sock_desc(HOST_MAC, HOST_IP, 24000 + i, LOCAL_IP, SOCK_LOCAL_PORT, len(p)) + p)
        s.c("DRAIN")
        s.rd(R_RX_RAW, n_grp + 4)
        s.rd(R_RX_SOCK, n_grp + 4)
        s.rd(R_TX_ECHO, n_grp)
        s.rd(R_RX_FIFO_DROP, 0)
        s.c("RXGAP", 0)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 17: MAC-side reset while the MAC-side FIFO is reading a frame out
    # (review #5): the FIFO terminates the frame with tuser = bad; the core
    # must drop it (RX_BAD_FRAME) instead of delivering a truncated frame.
    # ------------------------------------------------------------------
    if sel(17):
        s.c("TEST", 17, "mac_rx_reset_mid_frame_dropped")
        s.start()
        f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 25000, 9999, payload_bytes(8958, 2000))
        assert len(f) == 9000
        s.rx(f)
        s.c("WAITRX")
        s.c("WAIT", 100)                    # read-out of the 141-beat frame has started
        s.c("RSTMACRX", 0)
        s.c("WAIT", 200)
        s.c("RSTMACRX", 1)
        s.c("WAIT", 3000)
        good = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 25001, 9999, payload_bytes(500, 2001))
        s.rx(good)
        s.exp("UI0", good)
        s.c("DRAIN")
        s.counters(rx_frames=1, rx_bytes=len(good), rx_raw=1, rx_bad=1)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 18: non-zero Ethernet padding (review #6): short UDP echo requests
    # padded with 0xFF / 0xA5 must be echoed; a wrong checksum still fails.
    # ------------------------------------------------------------------
    def repad(frame, n, fill):
        body = frame[:42 + n]
        return body + bytes([fill]) * (MIN_FRAME - len(body))

    if sel(18):
        s.c("TEST", 18, "echo_short_udp_nonzero_padding")
        s.start()
        rxb = txb = 0
        n_echo = 0
        for i, (n, fill) in enumerate([(1, 0xFF), (17, 0xFF), (2, 0xA5), (9, 0xFF), (16, 0x5A), (1, 0x01)]):
            p = payload_bytes(n, 2100 + i)
            f = repad(udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 26000 + i, ECHO_PORT, p), n, fill)
            assert len(f) == 60
            s.rx(f)
            r = pad(m.echo_reply(HOST_MAC, HOST_IP, 26000 + i, p))
            s.exp("MAC", r)
            s.c("DRAIN")
            rxb += len(f)
            txb += len(r)
            n_echo += 1
        # padded socket datagram
        p = payload_bytes(3, 2150)
        f = repad(udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 26100, SOCK_LOCAL_PORT, p), 3, 0xFF)
        s.rx(f)
        s.exp("UI2", sock_desc(HOST_MAC, HOST_IP, 26100, LOCAL_IP, SOCK_LOCAL_PORT, 3) + p)
        rxb += len(f)
        # wrong UDP checksum with 0xFF padding -> RAW, counted as L4 bad
        p = payload_bytes(5, 2160)
        f = bytearray(repad(udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 26200, ECHO_PORT, p), 5, 0xFF))
        f[41] ^= 0x01
        f = bytes(f)
        s.rx(f)
        s.exp("UI0", f)
        rxb += len(f)
        s.c("DRAIN")
        s.counters(rx_frames=n_echo + 2, rx_bytes=rxb, rx_echo=n_echo, rx_sock=1, rx_raw=1, rx_l4=1,
                   tx_frames=n_echo, tx_bytes=txb, tx_echo=n_echo)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 19: oversize UI TX transfers (review #7) are dropped and counted
    # instead of wedging zircon_ip_tx_buffer; normal traffic continues.
    # ------------------------------------------------------------------
    if sel(19):
        s.c("TEST", 19, "tx_oversize_dropped")
        s.start()
        big = eth(HOST_MAC, LOCAL_MAC, 0x88B5, payload_bytes(40000 - 14, 2200))
        over = eth(HOST_MAC, LOCAL_MAC, 0x88B5, payload_bytes(MAX_TX_BYTES + 1 - 14, 2201))
        limit = eth(HOST_MAC, LOCAL_MAC, 0x88B5, payload_bytes(MAX_TX_BYTES - 14, 2202))
        normal = udp_frame(HOST_MAC, LOCAL_MAC, LOCAL_IP, HOST_IP, 7, 8, payload_bytes(1472, 2203))
        assert len(big) == 40000 and len(over) == MAX_TX_BYTES + 1 and len(limit) == MAX_TX_BYTES
        assert len(normal) == 1514
        s.txraw(big)
        s.txraw(over)
        s.txraw(limit)
        s.exp("MAC", limit)
        s.txraw(normal)
        s.exp("MAC", normal)
        s.c("DRAIN")                    # UI0 and UI2 run in parallel: keep the MAC order fixed
        s.txsock(payload_bytes(12000, 2204))
        sp = payload_bytes(100, 2205)
        s.txsock(sp)
        r = pad(m.sock_tx(sp))
        s.exp("MAC", r)
        s.c("DRAIN")
        s.counters(tx_frames=3, tx_bytes=len(limit) + len(normal) + len(r), tx_raw=2, tx_sock=1, tx_oversize=3)
        s.c("END")


    # ==================================================================
    # Hardware UDP generator / checker (1.2.0). The generator tests build
    # headers, so they run while the model's IPv4 ID counter is in step.
    # ==================================================================
    gen_seq = [0]      # next generator sequence number (model)

    def gen_expect(count, n, **kw):
        tot = 0
        for _ in range(count):
            f = pad(m.gen_tx(gen_seq[0], n, **kw))
            gen_seq[0] += 1
            s.exp("MAC", f)
            tot += len(f)
        return tot

    # ------------------------------------------------------------------
    # Latency measurement (1.3.0, DESIGN_SPEC §11). The TB models the MRMAC PTP
    # timer and timestamps; every tagged frame's latency is checked against the
    # SOF time difference and all statistics / bins exactly against the model.
    # ------------------------------------------------------------------
    def lat_echo(i, n, sport_base):
        p = payload_bytes(n, 3000 + sport_base % 1000 + i)
        f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, sport_base + i, ECHO_PORT, p)
        return f, p

    # Test 80: hardware echo -> bank 0 (default bins, then BASE / SHIFT moved so
    # samples land below BASE, in the linear bins and the doubling tail); the PTP
    # timer wraps (2^55) during the test
    if sel(80) and not gen0:
        s.c("TEST", 80, "lat_hw_echo_bank0")
        s.start()
        s.c("PTPTIMER", "%x" % ((1 << 55) - 1024 * 1250))    # wraps 5 us from now
        s.wr(R_LAT_CTRL, LAT_EN)
        s.c("WAIT", 500)
        s.c("LATECHO", 1)
        s.c("RXGAP", 40)
        sizes = [1, 18, 46, 64, 100, 200, 333, 500, 700, 1000, 1472, 2000, 3000, 4500, 8000, 64, 1, 1472,
                 128, 256, 512, 1024, 9000 - 28, 700]
        k = 0
        for phase in range(2):
            if phase == 1:
                s.c("LATCLR", 0)
                s.wr(R_LAT_BASE, 450)
                s.wr(R_LAT_WIDTH, 8)              # 8 ns bins: below 450 -> bin 0, linear to 834 ns, doubling
                s.c("WAIT", 500)
            for n in sizes:
                f, p = lat_echo(k, n, 33200)
                s.rx(f)
                s.exp("MAC", pad(m.echo_reply(HOST_MAC, HOST_IP, 33200 + k, p)))
                k += 1
            s.c("DRAIN")
            s.c("LATCNT", len(sizes) * (phase + 1), len(sizes) * (phase + 1))
            s.c("LATCHK", 0)
            s.c("LATCHK", 1)                      # bank 1 untouched
        s.rd(R_LAT_STATUS, 0)
        s.c("RXGAP", 0)
        s.c("LATECHO", 0)
        s.wr(R_LAT_BASE, 0)
        s.wr(R_LAT_WIDTH, 64)
        s.wr(R_LAT_CTRL, 0)
        s.c("LATCLR", 0)
        s.c("END")

    # Test 81: software path: UI0 frames behind a ZTXT descriptor -> bank 1;
    # descriptors stripped, frames without one (or too short) untouched and untagged
    def raw_out(i, n):
        return udp_frame(HOST_MAC, LOCAL_MAC, LOCAL_IP, HOST_IP, 7777, 41000 + i, payload_bytes(n, 4100 + i))

    if sel(81) and not gen0:
        s.c("TEST", 81, "lat_sw_raw_tx_descriptor_bank1")
        s.start()
        s.wr(R_LAT_CTRL, LAT_EN | LAT_RAW_TX_DESC)
        s.c("WAIT", 500)
        tagged = 0
        for i, n in enumerate([1, 18, 60, 100, 500, 1000, 1472, 3000, 8000, 22]):
            f = raw_out(i, n)
            s.c("TXRAWD", 1, f.hex())
            s.exp("MAC", pad(f))
            tagged += 1
        f = raw_out(10, 200)                      # descriptor with TS_REQ = 0: stripped, not tagged
        s.c("TXRAWD", 0, f.hex())
        s.exp("MAC", pad(f))
        f = raw_out(11, 300)                      # no descriptor: untouched, not tagged
        s.txraw(f)
        s.exp("MAC", pad(f))
        f = raw_out(12, 64)                       # rx_ts 2 s old: implausible (counted, not accumulated)
        s.c("TXRAWD", 2, f.hex())
        s.exp("MAC", pad(f))
        tagged += 1
        f = bytes.fromhex("5458545a") + raw_out(13, 1)[4:]   # magic in a short single-beat frame
        s.txraw(f)
        s.exp("MAC", pad(f))
        s.c("DRAIN")
        s.c("LATCNT", 14, tagged)
        s.c("LATCHK", 1)
        s.c("LATCHK", 0)
        # LAT_CTRL.EN = 0: the descriptor is still stripped, nothing is timestamped
        s.wr(R_LAT_CTRL, LAT_RAW_TX_DESC)
        s.c("WAIT", 500)
        f = raw_out(14, 100)
        s.c("TXRAWD", 3, f.hex())
        s.exp("MAC", pad(f))
        s.c("DRAIN")
        # RAW_TX_DESC = 0: a descriptor is not recognised - the frame goes out as sent
        s.wr(R_LAT_CTRL, LAT_EN)
        s.c("WAIT", 500)
        d = struct.pack("<IHBBQ", 0x5A545854, 0, 1, 0, 0x123456789) + b"\x00" * 48
        f = d + raw_out(15, 100)
        s.txraw(f)
        s.exp("MAC", pad(f))
        s.c("DRAIN")
        s.c("LATCNT", 16, tagged)
        s.c("LATCHK", 1)
        s.rd(R_TX_RAW, 16)
        s.wr(R_LAT_CTRL, 0)
        s.c("LATCLR", 1)
        s.c("END")

    # Test 82: RAW RX descriptor (LAT_CTRL.RAW_RX_DESC): a ZRXT beat with the frame
    # length and its RX timestamp in front of every UI0 frame
    if sel(82) and not gen0:
        s.c("TEST", 82, "lat_raw_rx_descriptor")
        s.start()
        s.wr(R_LAT_CTRL, LAT_RAW_RX_DESC)
        s.c("WAIT", 500)
        s.c("RXDESC", 1)
        frames = [arp_request(HOST_MAC, HOST_IP, LOCAL_IP),
                  eth(LOCAL_MAC, HOST_MAC, 0x0800,
                      ipv4(HOST_IP, LOCAL_IP, 6, tcp(HOST_IP, LOCAL_IP, 40000, 22, payload_bytes(1460, 11)))),
                  udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 1234, 9999, payload_bytes(33, 12)),
                  udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 1234, 9999, payload_bytes(8958, 13)),
                  udp_frame(OTHER_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 1234, ECHO_PORT, payload_bytes(18, 14))]
        for f in frames:
            s.rx(f)
            s.exp("UI0", f)
        s.c("DRAIN")
        s.c("RXDESC", 0)
        s.wr(R_LAT_CTRL, 0)
        s.c("WAIT", 500)
        s.rx(frames[2])
        s.exp("UI0", frames[2])
        s.c("DRAIN")
        s.counters(rx_frames=6, rx_bytes=sum(len(f) for f in frames) + len(frames[2]), rx_raw=6)
        s.c("END")

    # Test 83: mixed traffic (echo, raw with / without descriptor, socket, generator)
    # with random MAC TX and m_axis_tx_ptp back-pressure: one record per frame, in
    # order, op 2 exactly for the timestamped frames; both banks exact
    if sel(83) and not gen0:
        s.c("TEST", 83, "lat_mixed_traffic_ptp_stream")
        s.start()
        s.wr(R_LAT_CTRL, LAT_EN | LAT_RAW_TX_DESC)
        s.gen_config(count=10, length=100)
        s.c("WAIT", 500)
        s.c("LATECHO", 1)
        s.c("RXGAP", 20)
        s.c("COLLECT", "MAC", 1)
        s.c("RANDREADY", 1)
        s.c("PTPREADY", 2)
        s.wr(R_GEN_CTRL, GEN_EN)
        for i in range(30):
            f, p = lat_echo(i, 50 + 37 * i, 36000)
            s.rx(f)
            if i < 20:
                s.c("TXRAWD", 1, raw_out(100 + i, 40 + 61 * i).hex())
            if i < 10:
                s.c("TXRAWD", 0, raw_out(200 + i, 80 + i).hex())
                s.txraw(raw_out(300 + i, 90 + i))
                s.txsock(payload_bytes(20 + 30 * i, 4400 + i))
        s.c("WAITRX")
        s.c("WAIT", 30000)
        s.c("CNTEQ", "MAC", 90)
        s.c("LATCNT", 90, 50)
        s.c("RANDREADY", 0)
        s.c("PTPREADY", 1)
        s.c("COLLECT", "MAC", 0)
        s.c("LATECHO", 0)
        s.c("RXGAP", 0)
        s.rd(R_RX_ECHO_DROP, 0)
        s.c("LATCHK", 0)
        s.c("LATCHK", 1)
        s.wr(R_GEN_CTRL, 0)
        s.wr(R_LAT_CTRL, 0)
        s.c("LATCLR", 0)
        s.c("LATCLR", 1)
        m.ip_id = (m.ip_id + 30 + 10 + 10) & 0xFFFF      # echo + socket + generator headers built
        s.c("END")

    # Test 84: MAC TX reset while timestamps are outstanding: no wedge, the late
    # timestamps are flagged STALE, and measurement is exact again afterwards
    if sel(84) and not gen0:
        s.c("TEST", 84, "lat_mac_tx_reset_stale")
        s.start()
        s.wr(R_LAT_CTRL, LAT_EN)
        s.c("WAIT", 500)
        s.c("LATECHO", 1)
        s.c("PTPDELAY", 300, 400)
        s.c("COLLECT", "MAC", 1)
        s.c("RXGAP", 60)
        for i in range(20):
            f, p = lat_echo(i, 1000, 37000)
            s.rx(f)
        s.c("WAIT", 1500)
        s.c("RSTMACTX", 0)
        s.c("WAIT", 300)
        s.c("RSTMACTX", 1)
        s.c("WAITRX")
        s.c("WAIT", 20000)
        s.c("WAITREG", "%03x" % R_LAT_STATUS, "00000001", "00000001")
        s.c("SHOWREG", "after_mac_tx_reset", "%03x" % R_LAT_STALE, "%03x" % R_LAT_LOST, "%03x" % R_LAT_OVF)
        s.rd(R_LAT_LOST, 0)
        s.rd(R_LAT_OVF, 0)
        s.rd(R_RX_ECHO_DROP, 0)
        m.ip_id = (m.ip_id + 20) & 0xFFFF
        s.c("COLLECT", "MAC", 0)
        s.c("PTPDELAY", 4, 24)
        s.c("LATFLUSH")
        s.c("LATCLR", 0)
        s.wr(R_LAT_STATUS, 7)
        s.rd(R_LAT_STATUS, 0)
        for i in range(10):
            f, p = lat_echo(i, 100 + 100 * i, 37100)
            s.rx(f)
            s.exp("MAC", pad(m.echo_reply(HOST_MAC, HOST_IP, 37100 + i, p)))
        s.c("DRAIN")
        s.c("LATCHK", 0)
        s.rd(R_LAT_STATUS, 0)
        s.c("RXGAP", 0)
        s.c("LATECHO", 0)
        s.wr(R_LAT_CTRL, 0)
        s.c("LATCLR", 0)
        s.c("END")

    # Test 85: snapshots taken while samples arrive are coherent (histogram sum ==
    # count, count monotonic); CLEAR of one bank leaves the other intact
    if sel(85) and not gen0:
        s.c("TEST", 85, "lat_snapshot_coherence_clear")
        s.start()
        s.wr(R_LAT_CTRL, LAT_EN | LAT_RAW_TX_DESC)
        s.c("WAIT", 500)
        for i in range(5):
            f = raw_out(500 + i, 100 * (i + 1))
            s.c("TXRAWD", 1, f.hex())
            s.exp("MAC", pad(f))
        s.c("DRAIN")
        s.c("LATCHK", 1)
        s.c("LATECHO", 1)
        s.c("RXGAP", 30)
        s.c("COLLECT", "MAC", 1)
        for i in range(400):
            f, p = lat_echo(i, 18, 38000)
            s.rx(f)
        s.c("LATCOHERE", 0, 3)
        s.c("WAITRX")
        s.c("WAIT", 10000)
        s.c("CNTEQ", "MAC", 400)
        s.rd(R_RX_ECHO_DROP, 0)
        s.rd(R_RX_FIFO_DROP, 0)
        m.ip_id = (m.ip_id + 400) & 0xFFFF
        s.c("COLLECT", "MAC", 0)
        s.c("LATCHK", 0)
        s.c("LATCLR", 0)
        s.c("LATCHK", 0)                        # empty: count 0, MIN 0xFFFFFFFF, bins 0
        s.c("LATCHK", 1)                        # bank 1 intact
        s.c("LATCLR", 1)
        s.c("LATCHK", 1)
        s.c("RXGAP", 0)
        s.c("LATECHO", 0)
        s.wr(R_LAT_CTRL, 0)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 30: count mode, 5 x 1472-byte datagrams: headers, checksums,
    # sequence numbers 0..4 and the exact PRBS payload
    # ------------------------------------------------------------------
    if sel(30):
        s.c("TEST", 30, "gen_count5_len1472_exact")
        s.start()
        s.gen_config(length=1472, count=5)
        s.wr(R_GEN_CTRL, GEN_CLR)               # sequence number -> 0
        gen_seq[0] = 0
        s.c("WAIT", 500)
        txb = gen_expect(5, 1472)
        s.wr(R_GEN_CTRL, GEN_EN)
        s.c("DRAIN")
        s.rd(R_GEN_CTRL, GEN_EN)                # run over: BUSY = 0, EN still set
        s.gen_counters(gen_pkts=5, gen_bytes=5 * 1472)
        s.counters(tx_frames=5, tx_bytes=txb)
        s.wr(R_GEN_CTRL, 0)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 31: GEN_LEN 8 and 9000, and out-of-range values clamped; the
    # sequence number continues across runs
    # ------------------------------------------------------------------
    if sel(31):
        s.c("TEST", 31, "gen_len_8_9000_clamp")
        s.start()
        if not sel(30):
            s.wr(R_GEN_CTRL, GEN_CLR)
            gen_seq[0] = 0
        s.gen_config(dport=7777, sport=65000)
        txb = gb = n_pk = 0
        for length, cnt, eff in ((8, 2, 8), (9000, 2, 9000), (3, 1, 8), (20000, 1, 9000), (9, 1, 9)):
            s.wr(R_GEN_LEN, length)
            s.wr(R_GEN_COUNT, cnt)
            txb += gen_expect(cnt, eff, dport=7777, sport=65000)
            gb += cnt * eff
            n_pk += cnt
            s.wr(R_GEN_CTRL, GEN_EN)
            s.c("DRAIN")
            s.wr(R_GEN_CTRL, 0)
        s.gen_counters(gen_pkts=n_pk, gen_bytes=gb)
        s.counters(tx_frames=n_pk, tx_bytes=txb)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 32: GEN_GAP (3000 idle core cycles = 10 us between packets)
    # ------------------------------------------------------------------
    if sel(32):
        s.c("TEST", 32, "gen_gap_honoured")
        s.start()
        s.gen_config(length=64, count=4, gap=3000)
        txb = gen_expect(4, 64)
        s.wr(R_GEN_CTRL, GEN_EN)
        s.c("WAIT", 20000)
        s.rd(R_GEN_CTRL, GEN_EN | GEN_BUSY)     # still running (gaps)
        s.c("DRAIN")
        s.c("WAIT", 30000)
        s.c("TXGAPMIN", 9990)
        s.rd(R_GEN_CTRL, GEN_EN)
        s.gen_counters(gen_pkts=4, gen_bytes=4 * 64)
        s.counters(tx_frames=4, tx_bytes=txb)
        s.wr(R_GEN_CTRL, 0)
        s.wr(R_GEN_GAP, 0)
        s.c("END")

    # ------------------------------------------------------------------
    # Checker (RX): datagrams built by the Python model of the generator
    # ------------------------------------------------------------------
    def chk_frame(seq, n, sport=40000, dport=CHK_PORT, flip=(), csum="sw"):
        p = bytearray(gen_payload(seq, n))
        for byte, bit in flip:
            p[byte] ^= 1 << bit
        return udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, sport, dport, bytes(p), csum=csum)

    # Test 40: clean datagrams of many sizes -> counters exact, no errors
    if sel(40):
        s.c("TEST", 40, "chk_clean_counts")
        s.start()
        s.wr(R_CHK_CTRL, CHK_EN | CHK_CLR)
        s.c("WAIT", 500)
        s.rd(R_CHK_CTRL, CHK_EN)                # not synchronised yet
        sizes = [8, 9, 63, 64, 65, 100, 1472, 3000, 8972, 1000, 22, 23, 86]
        rxb = pb = 0
        for i, n in enumerate(sizes):
            f = chk_frame(100 + i, n)
            s.rx(f)
            rxb += len(f)
            pb += n
        s.c("DRAIN")
        s.rd(R_CHK_CTRL, CHK_EN | CHK_SYNC)
        s.gen_counters(chk_pkts=len(sizes), chk_bytes=pb)
        s.counters(rx_frames=len(sizes), rx_bytes=rxb)
        s.c("END")

    # Test 41: flipped payload bits (valid UDP checksum) -> CHK_BIT_ERR exact
    if sel(41):
        s.c("TEST", 41, "chk_bit_errors")
        s.start()
        s.wr(R_CHK_CTRL, CHK_EN | CHK_CLR)
        s.c("WAIT", 500)
        s.rx(chk_frame(500, 1472))
        s.rx(chk_frame(501, 1472, flip=((700, 3),)))
        s.c("DRAIN")
        s.gen_counters(chk_pkts=2, chk_bytes=2 * 1472, bit_err=1)
        s.rx(chk_frame(502, 1000, flip=((8, 0), (999, 7), (64, 5), (63, 1))))
        s.rx(chk_frame(503, 9, flip=((8, 6),)))
        s.rx(chk_frame(504, 200))
        s.c("DRAIN")
        s.gen_counters(chk_pkts=5, chk_bytes=2 * 1472 + 1000 + 9 + 200, bit_err=6)
        s.c("END")

    # Test 42: one datagram lost -> one CHK_SEQ_ERR, the following ones clean
    if sel(42):
        s.c("TEST", 42, "chk_seq_gap")
        s.start()
        s.wr(R_CHK_CTRL, CHK_EN | CHK_CLR)
        s.c("WAIT", 500)
        seqs = [200, 201, 203, 204, 205, 206]
        for q in seqs:
            s.rx(chk_frame(q, 300))
        s.c("DRAIN")
        s.gen_counters(chk_pkts=len(seqs), chk_bytes=300 * len(seqs), seq_err=1)
        # re-enable: resynchronises without an error (new run of a generator)
        s.wr(R_CHK_CTRL, 0)
        s.wr(R_CHK_CTRL, CHK_EN)
        s.c("WAIT", 500)
        s.rx(chk_frame(0, 300))
        s.rx(chk_frame(1, 300))
        s.c("DRAIN")
        s.gen_counters(chk_pkts=len(seqs) + 2, chk_bytes=300 * (len(seqs) + 2), seq_err=1)
        s.c("END")

    # Test 43: rule corners - bad UDP checksum / checker disabled / other port
    # -> RAW; payload < 8 bytes -> CHK_LEN_ERR; UDP checksum 0 -> checked
    if sel(43):
        s.c("TEST", 43, "chk_rule_badcsum_short_disabled")
        s.start()
        s.wr(R_CHK_CTRL, CHK_EN | CHK_CLR)
        s.c("WAIT", 500)
        rxb = 0
        f = bytearray(chk_frame(10, 500))
        f[41] ^= 0x01                              # UDP checksum wrong -> RAW, L4 bad
        f = bytes(f)
        s.rx(f)
        s.exp("UI0", f)
        rxb += len(f)
        f = chk_frame(11, 5)                       # 5-byte payload: length error
        s.rx(f)
        rxb += len(f)
        f = chk_frame(12, 400, csum=0)             # checksum not computed: accepted
        s.rx(f)
        rxb += len(f)
        f = chk_frame(13, 400)
        s.rx(f)
        rxb += len(f)
        s.c("DRAIN")
        s.gen_counters(chk_pkts=2, chk_bytes=800, len_err=1)
        s.counters(rx_frames=4, rx_bytes=rxb, rx_raw=1, rx_l4=1)
        # CHK_PORT moved: datagrams to the old port go RAW, the new port is checked
        s.wr(R_CHK_PORT, 6001)
        s.c("WAIT", 500)
        f = chk_frame(14, 100)
        s.rx(f)
        s.exp("UI0", f)
        s.rx(chk_frame(14, 100, dport=6001))
        s.c("DRAIN")
        s.rd(R_CHK_RX_PKTS, 3)
        s.rd(R_CHK_SEQ_ERR, 0)
        # checker disabled -> RAW
        s.wr(R_CHK_CTRL, 0)
        s.c("WAIT", 500)
        f = chk_frame(15, 100, dport=6001)
        s.rx(f)
        s.exp("UI0", f)
        s.c("DRAIN")
        s.rd(R_CHK_RX_PKTS, 3)
        s.rd(R_RX_RAW, 3)
        s.wr(R_CHK_PORT, CHK_PORT)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 34: continuous mode stops cleanly (the packet in progress is
    # finished; every frame sent is complete and exact). Last test that
    # knows the IPv4 ID: afterwards the model is out of step.
    # ------------------------------------------------------------------
    if sel(34):
        s.c("TEST", 34, "gen_continuous_clean_stop")
        s.start()
        s.gen_config(length=1472)
        s.wr(R_GEN_CTRL, GEN_CLR)
        s.c("WAIT", 500)
        s.c("SUBSEQ", "MAC", 1)
        for q in range(400):
            s.c("CAND", "MAC", pad(m.gen_tx(q, 1472)).hex())
        m.ip_id = None
        s.wr(R_GEN_CTRL, GEN_CONT | GEN_EN)
        s.c("WAIT", 3000)
        s.rd(R_GEN_CTRL, GEN_BUSY | GEN_CONT | GEN_EN)
        s.wr(R_GEN_CTRL, GEN_CONT)             # disable: finish the current packet, stop
        s.c("DRAIN")
        s.rd(R_GEN_CTRL, GEN_CONT)
        s.c("PREFIX", "MAC", "%03x" % R_GEN_TX_PKTS, "%03x" % R_TX_FRAMES)
        s.c("SUBSEQ", "MAC", 0)
        s.rd(R_STATUS, 0)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 16 (last: the number of echo replies built is not predictable, so
    # the model's IPv4 ID counter is out of step afterwards): MAC TX stalled,
    # the raw path must keep flowing and echo requests beyond the echo buffering
    # are dropped and counted (review #2, the other direction).
    # ------------------------------------------------------------------
    if sel(16):
        s.c("TEST", 16, "hol_tx_stalled_raw_flows_echo_dropped")
        s.start()
        s.c("RXGAP", 24)
        s.c("HOLD", "MAC", 1)
        s.c("SUBSEQ", "MAC", 1)
        n_echo = 120
        for i in range(n_echo):
            p = payload_bytes(1472, 2300 + i)
            s.rx(udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 27000 + i, ECHO_PORT, p))
            f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 28000 + i, 9999, payload_bytes(200, 2500 + i))
            s.rx(f)
            s.exp("UI0", f)
        s.c("WAITRX")
        s.c("WAIT", 30000)
        s.c("CHKEMPTY", "UI0")              # every raw frame arrived while MAC TX was stalled
        s.rd(R_RX_FIFO_DROP, 0)
        s.rd(R_RX_RAW_DROP, 0)
        s.c("HOLD", "MAC", 0)
        s.c("DRAIN")
        s.c("RXCNT", "MAC", n_echo, "%03x" % R_RX_ECHO_DROP)
        s.c("SUBSEQ", "MAC", 0)
        s.rd(R_RX_RAW, n_echo)
        s.c("RXGAP", 0)
        # nothing wedged: raw TX and raw RX still work
        t = udp_frame(HOST_MAC, LOCAL_MAC, LOCAL_IP, HOST_IP, 9, 10, payload_bytes(700, 2700))
        s.txraw(t)
        s.exp("MAC", t)
        f = arp_request(HOST_MAC, HOST_IP, LOCAL_IP)
        s.rx(f)
        s.exp("UI0", f)
        s.c("DRAIN")
        s.c("END")

    # ------------------------------------------------------------------
    # Test 21: mrmac_rx_packer status -> STATUS b4 RX_PACK_STALL / b5 RX_PACK_OVF
    # ------------------------------------------------------------------
    if sel(21):
        s.c("TEST", 21, "rx_packer_status_bits")
        s.start()
        s.rd(R_STATUS, 0, 0x30)
        s.c("PACKSTAT", 1)
        s.c("WAIT", 2000)
        s.rd(R_STATUS, 0x10, 0x30)
        s.c("PACKSTAT", 2)
        s.c("WAIT", 2000)
        s.rd(R_STATUS, 0x30, 0x30)
        s.wr(R_STATUS, 0x10)            # W1C one bit
        s.rd(R_STATUS, 0x20, 0x30)
        s.wr(R_STATUS, 0x20)
        s.rd(R_STATUS, 0x00, 0x30)
        s.c("END")


    # ------------------------------------------------------------------
    # Test 44 (GEN_EN = 0 build): no checker - CHK_CTRL writes are ignored
    # and a datagram to 5001 goes RAW
    # ------------------------------------------------------------------
    if sel(44) and gen0:
        s.c("TEST", 44, "gen0_chk_port_is_raw")
        s.start()
        s.wr(R_CHK_CTRL, CHK_EN)
        s.wr(R_GEN_CTRL, GEN_EN | GEN_CONT)
        s.c("WAIT", 1000)
        s.rd(R_CHK_CTRL, 0)
        s.rd(R_GEN_CTRL, 0)
        f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 40000, 5001, gen_payload(0, 300))
        s.rx(f)
        s.exp("UI0", f)
        s.c("DRAIN")
        s.counters(rx_frames=1, rx_bytes=len(f), rx_raw=1)
        s.wr(R_CHK_CTRL, 0)
        s.wr(R_GEN_CTRL, 0)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 50: the customer scenario in simulation - MAC TX looped back to
    # MAC RX, generator -> own local MAC / IP / CHK_PORT, MAC TX shaped to
    # 100 Gb/s: GEN_TX_PKTS == CHK_RX_PKTS, no errors, no drops
    # ------------------------------------------------------------------
    if sel(50) and not gen0:
        s.c("TEST", 50, "loopback_gen_to_chk_100g")
        s.start()
        s.gen_config(dst_mac=LOCAL_MAC, dst_ip=LOCAL_IP, dport=CHK_PORT, sport=GEN_SRC_PORT,
                     length=1472, count=200)
        s.wr(R_GEN_CTRL, GEN_CLR)
        s.wr(R_CHK_CTRL, CHK_EN | CHK_CLR)
        s.c("WAIT", 500)
        s.c("LOOPBACK", 1)
        s.c("MACSHAPE", 1)
        s.wr(R_GEN_CTRL, GEN_EN)
        s.c("WAITREG", "%03x" % R_GEN_CTRL, "%08x" % GEN_EN, "%08x" % (GEN_EN | GEN_BUSY))
        s.c("WAITREG", "%03x" % R_CHK_RX_PKTS, "%08x" % 200)
        s.c("WAIT", 3000)
        s.gen_counters(gen_pkts=200, gen_bytes=200 * 1472, chk_pkts=200, chk_bytes=200 * 1472)
        s.counters(rx_frames=200, rx_bytes=200 * 1514, tx_frames=200, tx_bytes=200 * 1514)
        s.rd(R_CHK_CTRL, CHK_EN | CHK_SYNC)
        s.c("RATEINFO", "loopback_count200_1472B_shaped")
        # continuous run over several rate-meter windows (66.7 us each here)
        s.wr(R_GEN_CTRL, 0)
        s.wr(R_GEN_CTRL, GEN_CONT | GEN_EN)
        s.c("WAIT", 160000)
        s.c("WAITCHG", "%03x" % R_RATE_SEQ)
        s.c("SHOWREG", "rate_window_loopback_1472B", "%03x" % R_RX_RATE_PKTS, "%03x" % R_RX_RATE_BYTES_LO,
            "%03x" % R_TX_RATE_PKTS, "%03x" % R_TX_RATE_BYTES_LO)
        s.wr(R_GEN_CTRL, GEN_CONT)
        s.c("WAITREG", "%03x" % R_GEN_CTRL, "%08x" % GEN_CONT, "%08x" % (GEN_EN | GEN_BUSY))
        s.c("WAIT", 20000)       # tx_buffer + MAC TX FIFO (64 KB) drain at 100G
        s.c("RDEQ", "%03x" % R_GEN_TX_PKTS, "%03x" % R_CHK_RX_PKTS, 1000)
        s.c("RDEQ", "%03x" % R_GEN_TX_BYTES_LO, "%03x" % R_CHK_RX_BYTES_LO)
        s.c("RDEQ", "%03x" % R_TX_FRAMES, "%03x" % R_RX_FRAMES)
        s.rd(R_CHK_SEQ_ERR, 0)
        s.rd(R_CHK_BIT_ERR_LO, 0)
        s.rd(R_CHK_BIT_ERR_HI, 0)
        s.rd(R_CHK_LEN_ERR, 0)
        s.rd(R_RX_FIFO_DROP, 0)
        s.rd(R_RX_RAW, 0)
        s.rd(R_STATUS, 0)
        s.c("LOOPBACK", 0)
        s.c("MACSHAPE", 0)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 60: rate meters (TB window 20000 core cycles): a known burst in one
    # window is latched exactly, the next window reads 0, RATE_SEQ +1 each
    # ------------------------------------------------------------------
    if sel(60):
        s.c("TEST", 60, "rate_meters_window")
        s.start()
        s.c("COLLECT", "MAC", 1)
        if not gen0:
            s.gen_config(length=1000, count=10)
        s.c("WAITCHG", "%03x" % R_RATE_SEQ)
        rxb = 0
        for i in range(10):
            f = udp_frame(LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP, 41000 + i, 9999, payload_bytes(400 + 50 * i, 6000 + i))
            s.rx(f)
            s.exp("UI0", f)
            rxb += len(f)
        if gen0:
            txb = 0
            for i in range(10):
                t = udp_frame(HOST_MAC, LOCAL_MAC, LOCAL_IP, HOST_IP, 1, 2, payload_bytes(958, 6100 + i))
                s.txraw(t)
                txb += len(t)
        else:
            s.wr(R_GEN_CTRL, GEN_EN)
            txb = 10 * 1042
        s.c("WAITRX")
        s.c("WAIT", 5000)
        s.c("WAITCHG", "%03x" % R_RATE_SEQ)     # latches the window with the burst
        s.rd(R_RX_RATE_BYTES_LO, rxb)
        s.rd(R_RX_RATE_BYTES_HI, 0)
        s.rd(R_RX_RATE_PKTS, 10)
        s.rd(R_TX_RATE_BYTES_LO, txb)
        s.rd(R_TX_RATE_BYTES_HI, 0)
        s.rd(R_TX_RATE_PKTS, 10)
        s.c("WAITCHG", "%03x" % R_RATE_SEQ)     # an idle window
        for a in (R_RX_RATE_BYTES_LO, R_RX_RATE_BYTES_HI, R_RX_RATE_PKTS, R_TX_RATE_BYTES_LO,
                  R_TX_RATE_BYTES_HI, R_TX_RATE_PKTS):
            s.rd(a, 0)
        s.c("CNTEQ", "MAC", 10)
        s.c("COLLECT", "MAC", 0)
        s.c("DRAIN")
        s.counters(rx_frames=10, rx_bytes=rxb, rx_raw=10, tx_frames=10, tx_bytes=txb,
                   **({"tx_raw": 10} if gen0 else {}))
        # a MAC TX side reset (link flap) inside a window: the TX sample reports the
        # frames since the reset, not a wrapped difference
        s.c("COLLECT", "MAC", 1)
        s.c("WAITCHG", "%03x" % R_RATE_SEQ)
        for i in range(5 + 3):
            if i == 5:
                s.c("WAITRX")
                s.c("WAIT", 5000)
                s.c("RSTMACTX", 0)
                s.c("WAIT", 200)
                s.c("RSTMACTX", 1)
                s.c("WAIT", 2000)
            t = udp_frame(HOST_MAC, LOCAL_MAC, LOCAL_IP, HOST_IP, 1, 2, payload_bytes(458, 6200 + i))
            s.txraw(t)
        s.c("WAITRX")
        s.c("WAIT", 5000)
        s.c("WAITCHG", "%03x" % R_RATE_SEQ)
        s.rd(R_TX_RATE_PKTS, 3)
        s.rd(R_TX_RATE_BYTES_LO, 3 * 500)
        s.rd(R_TX_RATE_BYTES_HI, 0)
        s.c("CNTEQ", "MAC", 8)
        s.c("COLLECT", "MAC", 0)
        if not gen0:
            s.wr(R_GEN_CTRL, 0)
        s.c("END")

    # ------------------------------------------------------------------
    # Test 70: throughput sweep (informational RATE / SHOWREG lines; fails
    # only on functional errors). TX: generator capacity with an unshaped MAC,
    # then at 100G. RX: checker datagrams at 100G line rate, drops reported.
    # ------------------------------------------------------------------
    if sel(70) and not gen0:
        s.c("TEST", 70, "throughput_sweep_info")
        s.start()
        s.c("COLLECT", "MAC", 1)
        s.gen_config()
        for shaped, lens in ((0, (8, 64, 256, 512, 1024, 1184, 1472, 9000)), (1, (1024, 1184, 1472, 9000))):
            s.c("MACSHAPE", shaped)
            for n in lens:
                s.c("TSCLR")                    # restart the MAC TX time stamps
                s.wr(R_GEN_LEN, n)
                s.wr(R_GEN_CTRL, GEN_CONT | GEN_EN)
                s.c("WAIT", 20000 if n < 9000 else 40000)
                s.wr(R_GEN_CTRL, GEN_CONT)
                s.c("WAITREG", "%03x" % R_GEN_CTRL, "%08x" % GEN_CONT, "%08x" % (GEN_EN | GEN_BUSY))
                s.c("WAIT", 20000)       # tx_buffer + MAC TX FIFO drain
                s.c("RATEINFO", "tx_%s_payload_%d" % ("100G" if shaped else "unshaped", n), 8)
        s.c("MACSHAPE", 0)
        s.c("COLLECT", "MAC", 0)
        s.wr(R_GEN_CTRL, 0)
        s.c("RXSHAPE", 1)
        s.wr(R_CHK_CTRL, CHK_EN | CHK_CLR)
        q = 0
        # enough frames to be far beyond the 32 KB MAC-side FIFO (sustained rate)
        for n, cnt in ((46, 1500), (256, 1200), (512, 800), (640, 600), (725, 400), (1024, 300), (1472, 300)):
            s.start()
            s.wr(R_CHK_CTRL, CHK_EN | CHK_CLR)
            s.c("WAIT", 500)
            s.c("TSCLR")
            for _ in range(cnt):
                s.rx(chk_frame(q, n))
                q += 1
            s.c("WAITRX")
            s.c("WAIT", 30000)      # the MAC-side FIFO (32 KB) drains
            s.c("SHOWREG", "rx_100G_%dx_payload_%d" % (cnt, n), "%03x" % R_CHK_RX_PKTS, "%03x" % R_RX_FIFO_DROP,
                "%03x" % R_CHK_SEQ_ERR, "%03x" % R_CHK_BIT_ERR_LO)
            s.c("RXRATEINFO", "rx_100G_payload_%d" % n)
            s.c("RDSUM", cnt, "%03x" % R_CHK_RX_PKTS, "%03x" % R_RX_FIFO_DROP)
            if n >= 725:
                s.rd(R_RX_FIFO_DROP, 0)
                s.rd(R_CHK_RX_PKTS, cnt)
                s.rd(R_CHK_SEQ_ERR, 0)
            s.rd(R_CHK_BIT_ERR_LO, 0)
        s.c("RXSHAPE", 0)
        s.wr(R_CHK_CTRL, 0)
        s.c("END")

    s.c("FINISH")
    name = "vectors_gen0.txt" if gen0 else "vectors.txt"
    with open(os.path.join(out_dir, name), "w") as fh:
        fh.write("\n".join(s.lines) + "\n")
    print("wrote %d commands to %s" % (len(s.lines), os.path.join(out_dir, name)))


if __name__ == "__main__":
    main()
