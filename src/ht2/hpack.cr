require "./hpack/*"

module HT2
  module HPACK
    # HPACK static table as defined in RFC 7541 Appendix A
    STATIC_TABLE = [
      {":authority", ""},
      {":method", "GET"},
      {":method", "POST"},
      {":path", "/"},
      {":path", "/index.html"},
      {":scheme", "http"},
      {":scheme", "https"},
      {":status", "200"},
      {":status", "204"},
      {":status", "206"},
      {":status", "304"},
      {":status", "400"},
      {":status", "404"},
      {":status", "500"},
      {"accept-charset", ""},
      {"accept-encoding", "gzip, deflate"},
      {"accept-language", ""},
      {"accept-ranges", ""},
      {"accept", ""},
      {"access-control-allow-origin", ""},
      {"age", ""},
      {"allow", ""},
      {"authorization", ""},
      {"cache-control", ""},
      {"content-disposition", ""},
      {"content-encoding", ""},
      {"content-language", ""},
      {"content-length", ""},
      {"content-location", ""},
      {"content-range", ""},
      {"content-type", ""},
      {"cookie", ""},
      {"date", ""},
      {"etag", ""},
      {"expect", ""},
      {"expires", ""},
      {"from", ""},
      {"host", ""},
      {"if-match", ""},
      {"if-modified-since", ""},
      {"if-none-match", ""},
      {"if-range", ""},
      {"if-unmodified-since", ""},
      {"last-modified", ""},
      {"link", ""},
      {"location", ""},
      {"max-forwards", ""},
      {"proxy-authenticate", ""},
      {"proxy-authorization", ""},
      {"range", ""},
      {"referer", ""},
      {"refresh", ""},
      {"retry-after", ""},
      {"server", ""},
      {"set-cookie", ""},
      {"strict-transport-security", ""},
      {"transfer-encoding", ""},
      {"user-agent", ""},
      {"vary", ""},
      {"via", ""},
      {"www-authenticate", ""},
    ]

    STATIC_TABLE_SIZE = STATIC_TABLE.size

    # Huffman encoding table from RFC 7541 Appendix B
    HUFFMAN_TABLE = {
        0 => {0x1ff8, 13},
        1 => {0x7fffd8, 23},
        2 => {0xfffffe2, 28},
        3 => {0xfffffe3, 28},
        4 => {0xfffffe4, 28},
        5 => {0xfffffe5, 28},
        6 => {0xfffffe6, 28},
        7 => {0xfffffe7, 28},
        8 => {0xfffffe8, 28},
        9 => {0xffffea, 24},
       10 => {0x3ffffffc, 30},
       11 => {0xfffffe9, 28},
       12 => {0xfffffea, 28},
       13 => {0x3ffffffd, 30},
       14 => {0xfffffeb, 28},
       15 => {0xfffffec, 28},
       16 => {0xfffffed, 28},
       17 => {0xfffffee, 28},
       18 => {0xfffffef, 28},
       19 => {0xffffff0, 28},
       20 => {0xffffff1, 28},
       21 => {0xffffff2, 28},
       22 => {0x3ffffffe, 30},
       23 => {0xffffff3, 28},
       24 => {0xffffff4, 28},
       25 => {0xffffff5, 28},
       26 => {0xffffff6, 28},
       27 => {0xffffff7, 28},
       28 => {0xffffff8, 28},
       29 => {0xffffff9, 28},
       30 => {0xffffffa, 28},
       31 => {0xffffffb, 28},
       32 => {0x14, 6},        # ' '
       33 => {0x3f8, 10},      # '!'
       34 => {0x3f9, 10},      # '"'
       35 => {0xffa, 12},      # '#'
       36 => {0x1ff9, 13},     # '$'
       37 => {0x15, 6},        # '%'
       38 => {0xf8, 8},        # '&'
       39 => {0x7fa, 11},      # '\''
       40 => {0x3fa, 10},      # '('
       41 => {0x3fb, 10},      # ')'
       42 => {0xf9, 8},        # '*'
       43 => {0x7fb, 11},      # '+'
       44 => {0xfa, 8},        # ','
       45 => {0x16, 6},        # '-'
       46 => {0x17, 6},        # '.'
       47 => {0x18, 6},        # '/'
       48 => {0x0, 5},         # '0'
       49 => {0x1, 5},         # '1'
       50 => {0x2, 5},         # '2'
       51 => {0x19, 6},        # '3'
       52 => {0x1a, 6},        # '4'
       53 => {0x1b, 6},        # '5'
       54 => {0x1c, 6},        # '6'
       55 => {0x1d, 6},        # '7'
       56 => {0x1e, 6},        # '8'
       57 => {0x1f, 6},        # '9'
       58 => {0x5c, 7},        # ':'
       59 => {0xfb, 8},        # ';'
       60 => {0x7ffc, 15},     # '<'
       61 => {0x20, 6},        # '='
       62 => {0xffb, 12},      # '>'
       63 => {0x3fc, 10},      # '?'
       64 => {0x1ffa, 13},     # '@'
       65 => {0x21, 6},        # 'A'
       66 => {0x5d, 7},        # 'B'
       67 => {0x5e, 7},        # 'C'
       68 => {0x5f, 7},        # 'D'
       69 => {0x60, 7},        # 'E'
       70 => {0x61, 7},        # 'F'
       71 => {0x62, 7},        # 'G'
       72 => {0x63, 7},        # 'H'
       73 => {0x64, 7},        # 'I'
       74 => {0x65, 7},        # 'J'
       75 => {0x66, 7},        # 'K'
       76 => {0x67, 7},        # 'L'
       77 => {0x68, 7},        # 'M'
       78 => {0x69, 7},        # 'N'
       79 => {0x6a, 7},        # 'O'
       80 => {0x6b, 7},        # 'P'
       81 => {0x6c, 7},        # 'Q'
       82 => {0x6d, 7},        # 'R'
       83 => {0x6e, 7},        # 'S'
       84 => {0x6f, 7},        # 'T'
       85 => {0x70, 7},        # 'U'
       86 => {0x71, 7},        # 'V'
       87 => {0x72, 7},        # 'W'
       88 => {0xfc, 8},        # 'X'
       89 => {0x73, 7},        # 'Y'
       90 => {0xfd, 8},        # 'Z'
       91 => {0x1ffb, 13},     # '['
       92 => {0x7fff0, 19},    # '\\'
       93 => {0x1ffc, 13},     # ']'
       94 => {0x3ffc, 14},     # '^'
       95 => {0x22, 6},        # '_'
       96 => {0x7ffd, 15},     # '`'
       97 => {0x3, 5},         # 'a'
       98 => {0x23, 6},        # 'b'
       99 => {0x4, 5},         # 'c'
      100 => {0x24, 6},        # 'd'
      101 => {0x5, 5},         # 'e'
      102 => {0x25, 6},        # 'f'
      103 => {0x26, 6},        # 'g'
      104 => {0x27, 6},        # 'h'
      105 => {0x6, 5},         # 'i'
      106 => {0x74, 7},        # 'j'
      107 => {0x75, 7},        # 'k'
      108 => {0x28, 6},        # 'l'
      109 => {0x29, 6},        # 'm'
      110 => {0x2a, 6},        # 'n'
      111 => {0x7, 5},         # 'o'
      112 => {0x2b, 6},        # 'p'
      113 => {0x76, 7},        # 'q'
      114 => {0x2c, 6},        # 'r'
      115 => {0x8, 5},         # 's'
      116 => {0x9, 5},         # 't'
      117 => {0x2d, 6},        # 'u'
      118 => {0x77, 7},        # 'v'
      119 => {0x78, 7},        # 'w'
      120 => {0x79, 7},        # 'x'
      121 => {0x7a, 7},        # 'y'
      122 => {0x7b, 7},        # 'z'
      123 => {0x7ffe, 15},     # '{'
      124 => {0x7fc, 11},      # '|'
      125 => {0x3ffd, 14},     # '}'
      126 => {0x1ffd, 13},     # '~'
      256 => {0x3fffffff, 30}, # EOS
    }

    # Extend table for remaining byte values
    (127..255).each do |i|
      HUFFMAN_TABLE[i] = {0xffffffc + (i - 127), 28}
    end

    class Error < HT2::Error
    end

    class CompressionError < Error
    end

    class DecompressionError < Error
    end
  end
end
