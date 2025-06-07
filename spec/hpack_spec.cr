require "./spec_helper"

describe HT2::HPACK::Huffman do
  it "encodes and decodes strings correctly" do
    test_strings = [
      "",
      "www.example.com",
      "no-cache",
      "/sample/path",
      "custom-header-value",
      "Mon, 21 Oct 2013 20:13:21 GMT",
      "https://www.example.com",
    ]

    test_strings.each do |str|
      encoded : Bytes = HT2::HPACK::Huffman.encode(str)
      decoded : String = HT2::HPACK::Huffman.decode(encoded)

      decoded.should eq(str)
    end
  end

  it "encodes with proper padding" do
    # Test string that doesn't align to byte boundary
    str : String = "a"
    encoded : Bytes = HT2::HPACK::Huffman.encode(str)

    # 'a' is 5 bits in Huffman, should be padded to 8 bits
    encoded.size.should eq(1)
  end

  it "rejects invalid Huffman sequences" do
    # Invalid sequence (all 1s is EOS pattern repeated)
    invalid : Bytes = Bytes[0xFF, 0xFF, 0xFF, 0xFF]

    expect_raises(HT2::HPACK::DecompressionError) do
      HT2::HPACK::Huffman.decode(invalid)
    end
  end
end

describe HT2::HPACK::Encoder do
  it "encodes headers with indexing" do
    encoder = HT2::HPACK::Encoder.new
    headers : Array(Tuple(String, String)) = [
      {":method", "GET"},
      {":path", "/"},
      {":scheme", "https"},
      {"custom-header", "value"},
    ]

    encoded : Bytes = encoder.encode(headers)
    encoded.size.should be > 0

    # First three should be indexed from static table
    # Fourth should be literal with incremental indexing
    encoder.dynamic_table.size.should eq(1)
    encoder.dynamic_table[0].should eq({"custom-header", "value"})
  end

  it "uses dynamic table for repeated headers" do
    encoder = HT2::HPACK::Encoder.new
    headers1 : Array(Tuple(String, String)) = [
      {"x-custom", "value1"},
    ]
    headers2 : Array(Tuple(String, String)) = [
      {"x-custom", "value1"},
    ]

    encoded1 : Bytes = encoder.encode(headers1)
    encoded2 : Bytes = encoder.encode(headers2)

    # Second encoding should be smaller (indexed)
    encoded2.size.should be < encoded1.size
  end

  it "evicts entries when table is full" do
    # Small table size to force eviction
    encoder = HT2::HPACK::Encoder.new(100_u32)

    # Add headers that will fill the table
    headers : Array(Tuple(String, String)) = [
      {"header1", "a" * 30}, # ~62 bytes with overhead
      {"header2", "b" * 30}, # ~62 bytes with overhead
    ]

    encoder.encode(headers)

    # First header should be evicted
    encoder.dynamic_table.size.should eq(1)
    encoder.dynamic_table[0][0].should eq("header2")
  end

  it "handles table size updates" do
    encoder = HT2::HPACK::Encoder.new(4096_u32)

    # Add some entries
    headers : Array(Tuple(String, String)) = [
      {"test", "value"},
    ]
    encoder.encode(headers)
    encoder.dynamic_table.size.should eq(1)

    # Reduce table size to force eviction
    encoder.set_max_table_size(0_u32)
    encoder.dynamic_table.size.should eq(0)
  end
end

describe HT2::HPACK::Decoder do
  it "decodes indexed headers from static table" do
    decoder = HT2::HPACK::Decoder.new

    # Encode index 2 (":method" "GET")
    data : Bytes = Bytes[0x82] # 10000010 = indexed 2

    headers : Array(Tuple(String, String)) = decoder.decode(data)
    headers.size.should eq(1)
    headers[0].should eq({":method", "GET"})
  end

  it "decodes literal headers with incremental indexing" do
    decoder = HT2::HPACK::Decoder.new
    encoder = HT2::HPACK::Encoder.new

    original : Array(Tuple(String, String)) = [
      {"custom-header", "custom-value"},
    ]

    encoded : Bytes = encoder.encode(original)
    decoded : Array(Tuple(String, String)) = decoder.decode(encoded)

    decoded.should eq(original)

    # Should be added to dynamic table
    decoder.dynamic_table.size.should eq(1)
    decoder.dynamic_table[0].should eq({"custom-header", "custom-value"})
  end

  it "handles dynamic table size updates" do
    decoder = HT2::HPACK::Decoder.new

    # Size update to 100
    data : Bytes = Bytes[0x3F, 0x45] # 0x3F = 00111111, 0x45 = 69, total = 31 + 69 = 100

    headers : Array(Tuple(String, String)) = decoder.decode(data)
    headers.empty?.should be_true
    decoder.max_dynamic_table_size.should eq(100)
  end

  it "decodes Huffman encoded strings" do
    decoder = HT2::HPACK::Decoder.new

    # Manual construction of literal header with Huffman encoded value
    # Format: 01000000 (literal with incremental indexing, new name)
    #         10000011 (Huffman bit set, length 3)
    #         Huffman encoded "GET" (3 bytes)
    #         10000100 (Huffman bit set, length 4)
    #         Huffman encoded "test" (4 bytes)

    io = IO::Memory.new
    io.write_byte(0x40_u8) # Literal with incremental indexing

    # Name: "GET" Huffman encoded
    name_encoded : Bytes = HT2::HPACK::Huffman.encode("GET")
    io.write_byte((0x80 | name_encoded.size).to_u8)
    io.write(name_encoded)

    # Value: "test" Huffman encoded
    value_encoded : Bytes = HT2::HPACK::Huffman.encode("test")
    io.write_byte((0x80 | value_encoded.size).to_u8)
    io.write(value_encoded)

    headers : Array(Tuple(String, String)) = decoder.decode(io.to_slice)
    headers.size.should eq(1)
    headers[0].should eq({"GET", "test"})
  end
end

describe "HPACK round-trip" do
  it "encodes and decodes complex header sets" do
    encoder = HT2::HPACK::Encoder.new
    decoder = HT2::HPACK::Decoder.new

    test_headers : Array(Array(Tuple(String, String))) = [
      [
        {":method", "GET"},
        {":scheme", "https"},
        {":path", "/"},
        {":authority", "www.example.com"},
        {"accept", "*/*"},
        {"user-agent", "test/1.0"},
      ],
      [
        {":method", "POST"},
        {":scheme", "https"},
        {":path", "/api/data"},
        {":authority", "www.example.com"},
        {"content-type", "application/json"},
        {"content-length", "42"},
        {"authorization", "Bearer token123"},
      ],
      [
        {":status", "200"},
        {"content-type", "text/html; charset=utf-8"},
        {"content-length", "1234"},
        {"cache-control", "no-cache"},
        {"date", "Mon, 21 Oct 2013 20:13:21 GMT"},
      ],
    ]

    test_headers.each do |headers|
      encoded : Bytes = encoder.encode(headers)
      decoded : Array(Tuple(String, String)) = decoder.decode(encoded)

      decoded.should eq(headers)
    end

    # Both should have same dynamic table state
    encoder.dynamic_table.size.should eq(decoder.dynamic_table.size)
  end
end
