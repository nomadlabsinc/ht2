import struct
import socket
import ssl
import time

# This test sends multiple SETTINGS_INITIAL_WINDOW_SIZE values in one frame
# The server should process them in order

preface = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

# Initial SETTINGS frame (empty)
settings1 = b"\x00\x00\x00\x04\x00\x00\x00\x00\x00"

# SETTINGS frame with multiple INITIAL_WINDOW_SIZE values
# First: Set to 0
# Second: Set to 65536
settings_payload = struct.pack("!HI", 4, 0) + struct.pack("!HI", 4, 65536)
settings2 = struct.pack("!HBBL", len(settings_payload), 0x04, 0x00, 0) + settings_payload

# HEADERS frame to create stream
headers_payload = bytes([
    0x88,  # :method GET
    0x86,  # :scheme https
    0x84,  # :path /
    0x41, 0x00  # :authority empty
])
headers_frame = struct.pack("!HBBL", len(headers_payload), 0x01, 0x05, 1) + headers_payload

# Create connection
context = ssl.create_default_context()
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE

sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
ssl_sock = context.wrap_socket(sock)

try:
    ssl_sock.connect(('::1', 8443))
    
    # Send preface and frames
    ssl_sock.send(preface)
    ssl_sock.send(settings1)
    
    # Wait for SETTINGS ACK
    time.sleep(0.1)
    
    # Send SETTINGS with multiple values
    ssl_sock.send(settings2)
    
    # Send HEADERS
    ssl_sock.send(headers_frame)
    
    # Wait for response
    time.sleep(0.5)
    
    # Read response
    response = ssl_sock.recv(4096)
    print(f"Response: {len(response)} bytes")
    
    # Parse frames
    pos = 0
    while pos < len(response):
        if pos + 9 > len(response):
            break
        length = (response[pos] << 16) | (response[pos+1] << 8) | response[pos+2]
        frame_type = response[pos+3]
        flags = response[pos+4]
        stream_id = struct.unpack("!I", response[pos+5:pos+9])[0] & 0x7FFFFFFF
        
        type_names = {0: "DATA", 1: "HEADERS", 3: "RST_STREAM", 4: "SETTINGS", 7: "GOAWAY", 8: "WINDOW_UPDATE"}
        type_name = type_names.get(frame_type, f"TYPE_{frame_type}")
        
        print(f"Frame: {type_name} length={length}, flags={flags}, stream_id={stream_id}")
        
        if frame_type == 0:  # DATA
            data = response[pos+9:pos+9+length]
            print(f"  DATA: {data}")
        
        pos += 9 + length
        
except Exception as e:
    print(f"Error: {e}")
finally:
    ssl_sock.close()
