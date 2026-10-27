"""Validate colored, unletterboxed testsrc PNG output using only the standard library."""
import struct
import zlib


def inspect_testsrc_png(data):
    """Require colored testsrc pixels; a valid PNG can still be a VS dummy frame.

    Sample the first 32 rows, where this suite's unletterboxed color bars live.
    Decode RGB/RGBA 8/16-bit PNG with stdlib only, ignoring alpha for the check.
    """
    try:
        if data[:8] != b'\x89PNG\r\n\x1a\n':
            raise ValueError('not PNG')
        offset, compressed, header, ended = 8, [], None, False
        while offset < len(data):
            size = struct.unpack_from('>I', data, offset)[0]
            kind = data[offset + 4:offset + 8]
            payload = data[offset + 8:offset + 8 + size]
            crc = struct.unpack_from('>I', data, offset + 8 + size)[0]
            if zlib.crc32(kind + payload) != crc:
                raise ValueError('PNG CRC mismatch')
            if kind == b'IHDR':
                header = struct.unpack('>IIBBBBB', payload)
            elif kind == b'IDAT':
                compressed.append(payload)
            elif kind == b'IEND':
                ended = True
                break
            offset += size + 12
        if not header or not ended:
            raise ValueError('incomplete PNG')
        width, height, depth, color, compression, filtering, interlace = header
        if (not 0 < width <= 8192 or not 0 < height <= 8192 or depth not in (8, 16) or
                color not in (2, 6) or compression or filtering or interlace):
            raise ValueError('unsupported PNG layout')
        channels, sample_bytes = (3 if color == 2 else 4), depth // 8
        pixel_bytes = channels * sample_bytes
        stride, rows = width * pixel_bytes, min(height, 32)
        raw = zlib.decompressobj().decompress(b''.join(compressed), (stride + 1) * rows)
        if len(raw) != (stride + 1) * rows:
            raise ValueError('truncated PNG pixels')
        previous, colorful = bytearray(stride), 0
        for row in range(rows):
            start = row * (stride + 1)
            mode, decoded = raw[start], bytearray(raw[start + 1:start + 1 + stride])
            if mode not in range(5):
                raise ValueError('invalid PNG row filter')
            if mode:
                for i in range(stride):
                    left = decoded[i - pixel_bytes] if i >= pixel_bytes else 0
                    up = previous[i]
                    upper_left = previous[i - pixel_bytes] if i >= pixel_bytes else 0
                    if mode == 1:
                        prediction = left
                    elif mode == 2:
                        prediction = up
                    elif mode == 3:
                        prediction = (left + up) // 2
                    else:
                        p = left + up - upper_left
                        distances = (abs(p - left), abs(p - up), abs(p - upper_left))
                        prediction = (left, up, upper_left)[distances.index(min(distances))]
                    decoded[i] = (decoded[i] + prediction) & 255
            for i in range(0, stride, pixel_bytes):
                rgb = decoded[i:i + 3 * sample_bytes:sample_bytes]
                colorful += max(rgb) - min(rgb) > 32
            previous = decoded
        fraction = colorful / (width * rows)
        return dict(valid=fraction > 0.05, width=width, height=height,
                    colorful_fraction=round(fraction, 4))
    except (ValueError, struct.error, zlib.error, IndexError) as exc:
        return dict(valid=False, reason=str(exc))
