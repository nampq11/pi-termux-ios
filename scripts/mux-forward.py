#!/usr/bin/env python3
"""Minimal iproxy replacement: forwards local TCP -> a port on a USB iPhone.

usbmuxd's plist "Connect" message turns a unix-socket connection into a raw
TCP tunnel to a port on the phone. Used to reach the iOS app's loopback
bridge (fixed port 41943) for end-to-end verification from the host — the
stock iproxy binary is not always installed.

Usage: mux-forward.py <local-port> <device-port> [udid]
Prints the matched usbmux device id, then serves until killed.
"""
import os
import select
import socket
import struct
import sys
import threading

MUX = os.environ.get('USBMUXD_SOCKET_ADDRESS', '/var/run/usbmuxd')
PLIST_HEAD = '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'


def mux_message(fields):
    payload = (PLIST_HEAD + fields + '</dict></plist>').encode()
    # usbmuxd's header is little-endian: len | version 1 | Plist | tag
    header = struct.pack('<IIII', 16 + len(payload), 1, 8, 1)
    return header + payload


def read_reply(sock):
    header = b''
    while len(header) < 16:
        chunk = sock.recv(16 - len(header))
        if not chunk:
            raise ConnectionError('usbmuxd closed during header')
        header += chunk
    length = struct.unpack('<I', header[:4])[0] - 16
    payload = b''
    while len(payload) < length:
        chunk = sock.recv(length - len(payload))
        if not chunk:
            raise ConnectionError('usbmuxd closed during payload')
        payload += chunk
    return payload.decode(errors='replace')


def first_device_id(sock, udid=None):
    """DeviceID of the attached device (optionally matching udid), via the
    one-shot ListDevices query that libusbmuxd also uses."""
    sock.sendall(mux_message(
        '<key>MessageType</key><string>ListDevices</string>'
        '<key>ClientVersionString</key><string>pi-mux-forward</string>'
        '<key>ProgName</key><string>pi-mux-forward</string>'
        '<key>kLibUSBMuxVersion</key><integer>3</integer>'))
    reply = read_reply(sock)
    # DeviceList is an array of dicts: DeviceID + Properties{SerialNumber...};
    # a device dict matches when it carries the udid (or none was given)
    devices = reply.split('<string>Attached</string>')
    for device in devices[1:]:
        if udid and udid not in device:
            continue
        for tag in device.split('<key>')[1:]:
            if tag.startswith('DeviceID</key>'):
                return int(tag.split('<integer>')[1].split('</integer>')[0])
    sys.exit(f'no matching device in usbmuxd device list: {reply[:200]}')


def tunnel_to(device_id, port):
    """Raw two-way tunnel socket to device:port; caller shuttles bytes."""
    # usbmuxd expects the port value in network byte order
    port_number = socket.htons(port)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(MUX)
    sock.sendall(mux_message(
        '<key>MessageType</key><string>Connect</string>'
        '<key>ClientVersionString</key><string>pi-mux-forward</string>'
        '<key>ProgName</key><string>pi-mux-forward</string>'
        f'<key>DeviceID</key><integer>{device_id}</integer>'
        f'<key>PortNumber</key><integer>{port_number}</integer>'))
    reply = read_reply(sock)
    # usbmuxd answers success with an empty dict; failure carries Number=errno
    if '<key>Number</key>' in reply:
        raise ConnectionError(f'usbmuxd connect refused: {reply[:200]}')
    return sock


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    listen_port, device_port = int(sys.argv[1]), int(sys.argv[2])
    udid = sys.argv[3] if len(sys.argv) > 3 else None

    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.connect(MUX)
    device_id = first_device_id(probe, udid)
    probe.close()
    print(f'device id {device_id}; forwarding 127.0.0.1:{listen_port} -> device:{device_port}', flush=True)

    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('127.0.0.1', listen_port))
    server.listen(5)

    def handle(client):
        try:
            remote = tunnel_to(device_id, device_port)
        except Exception as error:  # refused: app not running or port closed
            print(f'tunnel refused: {error}', file=sys.stderr, flush=True)
            client.close()
            return
        sockets = [client, remote]
        try:
            while True:
                readable, _, _ = select.select(sockets, [], [], 30)
                if not readable:
                    return
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return
                    (remote if source is client else client).sendall(data)
        finally:
            for sock in sockets:
                sock.close()

    while True:
        client, _ = server.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == '__main__':
    main()
