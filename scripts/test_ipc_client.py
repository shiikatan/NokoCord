#!/usr/bin/env python3
"""
Test script for NokoCord Game Rich Presence IPC.
Connects to /tmp/discord-ipc-0, performs the Discord RPC handshake,
dispatches a game activity (Minecraft), verifies the protocol framing,
and then clears the activity.
"""

import os
import sys
import time
import socket
import struct
import json
import subprocess

SOCKET_PATHS = [
    "/tmp/discord-ipc-0",
    os.path.join(os.environ.get("TMPDIR", "/tmp"), "discord-ipc-0")
]

def find_socket():
    for p in SOCKET_PATHS:
        if os.path.exists(p):
            return p
    return None

def send_packet(sock, opcode, payload_dict):
    payload_bytes = json.dumps(payload_dict).encode("utf-8")
    header = struct.pack("<II", opcode, len(payload_bytes))
    sock.sendall(header + payload_bytes)

def read_packet(sock):
    header = sock.recv(8)
    if len(header) < 8:
        raise ValueError(f"Incomplete header: {len(header)} bytes")
    opcode, length = struct.unpack("<II", header)
    payload_bytes = b""
    while len(payload_bytes) < length:
        chunk = sock.recv(length - len(payload_bytes))
        if not chunk:
            break
        payload_bytes += chunk
    data = json.loads(payload_bytes.decode("utf-8"))
    return opcode, data

def run_test():
    print("==> [1/4] Checking for NokoCord IPC socket...")
    sock_path = find_socket()
    proc = None

    if not sock_path:
        print("    No active socket found. Launching NokoCord.app binary in background...")
        app_bin = "build/NokoCord.app/Contents/MacOS/NokoCord"
        if not os.path.exists(app_bin):
            print(f"Error: {app_bin} not found. Please run scripts/build.sh first.")
            sys.exit(1)
        proc = subprocess.Popen([app_bin])
        for _ in range(30):
            time.sleep(0.2)
            sock_path = find_socket()
            if sock_path:
                break

    if not sock_path:
        print("Error: Could not locate /tmp/discord-ipc-0")
        if proc:
            proc.terminate()
        sys.exit(1)

    print(f"    Found active Discord IPC socket at: {sock_path}")

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
        print("==> [2/4] Sending Discord RPC Handshake (Opcode 0)...")
        handshake = {
            "v": 1,
            "client_id": "123456789012345678"
        }
        send_packet(s, 0, handshake)

        op, resp = read_packet(s)
        print(f"    Received response Opcode {op}: cmd={resp.get('cmd')}, evt={resp.get('evt')}")
        assert op == 1, f"Expected Opcode 1, got {op}"
        assert resp.get("cmd") == "DISPATCH" and resp.get("evt") == "READY", "Expected READY dispatch"
        print("    Handshake successful! Client connected.")

        print("==> [3/4] Broadcasting Game Activity (SET_ACTIVITY: Minecraft)...")
        activity_payload = {
            "cmd": "SET_ACTIVITY",
            "args": {
                "pid": os.getpid(),
                "activity": {
                    "name": "Minecraft",
                    "details": "Mining Netherite",
                    "state": "Survival (Hardcore)",
                    "timestamps": {
                        "start": int(time.time())
                    },
                    "assets": {
                        "large_image": "nether_portal",
                        "large_text": "The Nether",
                        "small_image": "diamond_pickaxe",
                        "small_text": "Diamond Pickaxe"
                    }
                }
            },
            "nonce": "test-nonce-1"
        }
        send_packet(s, 1, activity_payload)
        op, resp = read_packet(s)
        print(f"    Received SET_ACTIVITY response: cmd={resp.get('cmd')}, nonce={resp.get('nonce')}")
        assert resp.get("cmd") == "SET_ACTIVITY", "Expected SET_ACTIVITY response"
        print("    Game Presence successfully received and active!")

        print("==> [4/4] Clearing Game Activity...")
        clear_payload = {
            "cmd": "SET_ACTIVITY",
            "args": {
                "pid": os.getpid(),
                "activity": None
            },
            "nonce": "test-nonce-2"
        }
        send_packet(s, 1, clear_payload)
        op, resp = read_packet(s)
        print(f"    Received clear response: cmd={resp.get('cmd')}")
        assert resp.get("cmd") == "SET_ACTIVITY", "Expected SET_ACTIVITY response"

        s.close()
        print("\n🎉 ALL GAME RICH PRESENCE IPC TESTS PASSED!")

    finally:
        if proc:
            print("    Terminating test NokoCord process...")
            proc.terminate()
            proc.wait()

if __name__ == "__main__":
    run_test()
