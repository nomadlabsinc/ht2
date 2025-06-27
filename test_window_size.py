import struct
import socket
import ssl

# This test checks if server handles SETTINGS_INITIAL_WINDOW_SIZE changes correctly
# The test:
# 1. Sends HEADERS frame to create a stream
# 2. Then sends SETTINGS to change initial window size
# 3. Expects the server to adjust the window size for existing streams

preface = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

# Initial SETTINGS frame (empty)
settings1 = b"\x00\x00\x00\x04\x00\x00\x00\x00\x00"

# HEADERS frame to create stream 1
headers_payload = bytes([
    0x88,  # :method GET
    0x86,  # :scheme https
    0x84,  # :path /
    0x41, 0x00  # :authority empty
])
headers_frame = struct.pack("!HBBL", len(headers_payload), 0x01, 0x05, 1) + headers_payload

# SETTINGS frame to change INITIAL_WINDOW_SIZE to 100
# Parameter ID 4 = SETTINGS_INITIAL_WINDOW_SIZE
settings2_payload = struct.pack("!HI", 4, 100)
settings2_frame = struct.pack("!HBBL", len(settings2_payload), 0x04, 0x00, 0) + settings2_payload

# Create connection
context = ssl.create_default_context()
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE

sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
ssl_sock = context.wrap_socket(sock)
ssl_sock.connect(('::1', 8443))

# Send frames
ssl_sock.send(preface)
ssl_sock.send(settings1)
ssl_sock.send(headers_frame)
ssl_sock.send(settings2_frame)

# Read response
response = ssl_sock.recv(4096)
print(f"Response: {len(response)} bytes")

ssl_sock.close()
