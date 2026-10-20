#!/usr/bin/env python3
"""Tiny MQTT 3.1.1 test broker for Mesh Pulse development: accepts clients, acks CONNECT/SUBSCRIBE/PINGREQ,
and publishes canned meshcore-packet-capture messages to every subscriber.

    python3 tools/fake_broker.py [--port 1883] [--count 5] [--interval 1.0]

It does not route messages between clients; it only replays the sample packets below.
"""
import argparse
import json
import socket
import struct
import threading
import time

SAMPLES = [
    # Real ADVERT (FLOOD, 2 hops) captured by CoreScope.
    "11023AFA3811EF9726FBC987F4CDD0065B971A51DB1FE578E9570F2C6C888C89C6EF10AF51E84466CCF597A7F9648C0CC541AA581D3BF8DAF606EA6CB08B9C639409A96D307EF1A502D58ED09F63416CC7314E11A270DEDE4F3DC988C7A7FA60F7B951874755FB0B9294EA3302DEBADCF86D657368636F726540656573636F6261722E636F6D",
    # GRP_TXT flood, 3 one-byte hops.
    "15033AFA4011223344556677",
]
OBSERVER = "BB34780231E5BE9657CB994BA05CDF1BD9635FF126F7681ADD4A4977034A15FB"


def encode_len(n):
    out = bytearray()
    while True:
        d = n % 128
        n //= 128
        if n:
            d |= 0x80
        out.append(d)
        if not n:
            return bytes(out)


def mqtt_str(s):
    b = s.encode()
    return struct.pack("!H", len(b)) + b


def publish(topic, payload, qos=0, pid=1):
    body = mqtt_str(topic) + (struct.pack("!H", pid) if qos else b"") + payload
    return bytes([0x30 | (qos << 1)]) + encode_len(len(body)) + body


def read_packet(sock):
    first = sock.recv(1)
    if not first:
        return None, None
    mult, length = 1, 0
    while True:
        b = sock.recv(1)[0]
        length += (b & 0x7F) * mult
        mult *= 128
        if not b & 0x80:
            break
    body = b""
    while len(body) < length:
        chunk = sock.recv(length - len(body))
        if not chunk:
            return None, None
        body += chunk
    return first[0], body


def serve(conn, addr, args):
    print(f"client {addr} connected", flush=True)
    subscribed = threading.Event()

    def pump():
        subscribed.wait()
        for i in range(args.count):
            raw = SAMPLES[i % len(SAMPLES)]
            msg = {"origin": "Fake Observer", "origin_id": OBSERVER, "type": "PACKET", "direction": "rx",
                   "raw": raw, "SNR": "5.5", "RSSI": "-90", "hash": f"{i:016x}"}
            qos = 1 if i % 2 else 0  # exercise PUBACK handling too
            conn.sendall(publish(f"meshcore/TST/{OBSERVER}/packets", json.dumps(msg).encode(), qos, i + 1))
            time.sleep(args.interval)

    threading.Thread(target=pump, daemon=True).start()
    try:
        while True:
            ptype, body = read_packet(conn)
            if ptype is None:
                break
            kind = ptype >> 4
            if kind == 1:
                client_id = body[12:12 + struct.unpack("!H", body[10:12])[0]].decode()
                print(f"CONNECT client_id={client_id} flags=0x{body[7]:02x}", flush=True)
                conn.sendall(bytes([0x20, 2, 0, 0]))
            elif kind == 8:
                pid = body[:2]
                topic_len = struct.unpack("!H", body[2:4])[0]
                print(f"SUBSCRIBE {body[4:4 + topic_len].decode()}", flush=True)
                conn.sendall(bytes([0x90, 3]) + pid + b"\x00")
                subscribed.set()
            elif kind == 4:
                print(f"PUBACK {struct.unpack('!H', body)[0]}", flush=True)
            elif kind == 12:
                conn.sendall(bytes([0xD0, 0]))
            elif kind == 14:
                print("DISCONNECT", flush=True)
                break
    finally:
        conn.close()
        print(f"client {addr} closed", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=1883)
    ap.add_argument("--count", type=int, default=5)
    ap.add_argument("--interval", type=float, default=1.0)
    args = ap.parse_args()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", args.port))
    srv.listen()
    print(f"fake broker on 127.0.0.1:{args.port}", flush=True)
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=serve, args=(conn, addr, args), daemon=True).start()


if __name__ == "__main__":
    main()
