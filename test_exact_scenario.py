import struct
import socket
import ssl
import time

# Recreate the exact h2spec test scenario
# The test likely:
# 1. Sets initial window to 0
# 2. Sends HEADERS to create a stream (but server can't send data)
# 3. Sends SETTINGS with multiple INITIAL_WINDOW_SIZE values
# 4. Expects server to send some data to prove window was updated

preface = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

# Step 1: SETTINGS to set initial window to 0
settings1_payload = struct.pack("!HI", 4, 0)  # INITIAL_WINDOW_SIZE = 0
settings1 = struct.pack("!HBBL", len(settings1_payload), 0x04, 0x00, 0) + settings1_payload

# Step 2: HEADERS frame
headers_payload = bytes([
    0x88,  # :method GET
    0x86,  # :scheme https
    0x84,  # :path /
    0x41, 0x00  # :authority empty
])
headers = struct.pack("!HBBL", len(headers_payload), 0x01, 0x05, 1) + headers_payload

# Step 3: SETTINGS with multiple values
# First: INITIAL_WINDOW_SIZE = 100
# Second: INITIAL_WINDOW_SIZE = 1
settings2_payload = struct.pack("!HI", 4, 100) + struct.pack("!HI", 4, 1)
settings2 = struct.pack("!HBBL", len(settings2_payload), 0x04, 0x00, 0) + settings2_payload

# Connect
context = ssl.create_default_context()
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE

sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
ssl_sock = context.wrap_socket(sock)

try:
    ssl_sock.connect(('::1', 8443))
    ssl_sock.settimeout(5.0)
    
    # Send preface
    ssl_sock.send(preface)
    
    # Send first SETTINGS (window = 0)
    ssl_sock.send(settings1)
    time.sleep(0.1)
    
    # Send HEADERS
    ssl_sock.send(headers)
    time.sleep(0.1)
    
    # Send second SETTINGS (multiple values)
    ssl_sock.send(settings2)
    
    # Wait for response
    print("Waiting for response...")
    total_data = b""
    start_time = time.time()
    
    while time.time() - start_time < 2.0:
        try:
            data = ssl_sock.recv(4096)
            if data:
                total_data += data
                print(f"Received {len(data)} bytes")
        except socket.timeout:
            break
        except ssl.SSLError:
            break
    
    print(f"Total received: {len(total_data)} bytes")
    
    # Parse and show frames
    pos = 0
    while pos < len(total_data):
        if pos + 9 > len(total_data):
            break
        length = (total_data[pos] << 16) | (total_data[pos+1] << 8) | total_data[pos+2]
        frame_type = total_data[pos+3]
        flags = total_data[pos+4]
        stream_id = struct.unpack("!I", total_data[pos+5:pos+9])[0] & 0x7FFFFFFF
        
        type_names = {0: "DATA", 1: "HEADERS", 3: "RST_STREAM", 4: "SETTINGS", 7: "GOAWAY", 8: "WINDOW_UPDATE"}
        type_name = type_names.get(frame_type, f"TYPE_{frame_type}")
        
        print(f"Frame: {type_name} length={length}, flags={flags:#x}, stream_id={stream_id}")
        
        if frame_type == 0:  # DATA
            data_content = total_data[pos+9:pos+9+length]
            print(f"  DATA content length: {len(data_content)}")
            if len(data_content) <= 10:
                print(f"  DATA content: {data_content}")
        
        pos += 9 + length
        
except Exception as e:
    print(f"Error: {e}")
    import traceback
    traceback.print_exc()
finally:
    ssl_sock.close()
