# Pass the macOS test executable inside a fixture app bundle with sing-box beside it.
# Only the fixture bundle needs an ATS HTTP exception for aauv-test.invalid.
import json
import socket
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor


def exact(connection, count):
    data = b""
    while len(data) < count:
        part = connection.recv(count - len(data))
        if not part:
            raise AssertionError("unexpected EOF")
        data += part
    return data


def serve(listener):
    for _ in range(2):
        with listener.accept()[0] as connection:
            connection.settimeout(5)
            version, count = exact(connection, 2)
            assert version == 5 and 2 in exact(connection, count)
            connection.sendall(b"\x05\x02")
            version, count = exact(connection, 2)
            assert version == 1 and exact(connection, count) == b"synthetic"
            count = exact(connection, 1)[0]
            assert exact(connection, count) == b"mock-password"
            connection.sendall(b"\x01\x00")
            version, operation, reserved, kind = exact(connection, 4)
            assert (version, operation, reserved, kind) == (5, 1, 0, 3)
            size = exact(connection, 1)[0]
            assert exact(connection, size) == b"aauv-test.invalid"
            assert exact(connection, 2) == b"\x00\x50"
            connection.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
            raw = b""
            while not raw.endswith(b"\r\n\r\n"):
                raw += exact(connection, 1)
            headers = raw.decode("utf-8").split("\r\n")
            assert headers[0] == "POST /v1/responses HTTP/1.1"
            size = next(int(line.split(":", 1)[1]) for line in headers if line.lower().startswith("content-length:"))
            assert json.loads(exact(connection, size)) == {"model": "mock"}
            connection.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 8\r\n\r\nproxy ok")


with socket.socket() as listener, ThreadPoolExecutor(max_workers=1) as pool:
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    listener.settimeout(10)
    received = pool.submit(serve, listener)
    subprocess.run([sys.argv[1], str(listener.getsockname()[1])], check=True, timeout=20)
    received.result()
