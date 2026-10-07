# Сравнение двух кадров BMP: насколько программный растеризатор
# расходится с настоящим OpenGL.
import struct, sys, zlib

def load(path):
    d = open(path, 'rb').read()
    off = struct.unpack_from('<I', d, 10)[0]
    w = struct.unpack_from('<i', d, 18)[0]
    h = struct.unpack_from('<i', d, 22)[0]
    rs = ((w * 3 + 3) // 4) * 4
    px = bytearray(w * h * 3)
    for y in range(h):
        s = off + y * rs
        o = (h - 1 - y) * w * 3
        px[o:o + w * 3] = d[s:s + w * 3]
    return w, h, px

wa, ha, a = load(sys.argv[1])
wb, hb, b = load(sys.argv[2])
assert (wa, ha) == (wb, hb), "размеры кадров не совпадают"
n = wa * ha * 3
tot = 0
hist = [0] * 5
diff = bytearray(n)
for i in range(n):
    d = abs(a[i] - b[i])
    tot += d
    diff[i] = min(255, d * 6)
    if d <= 2: hist[0] += 1
    elif d <= 8: hist[1] += 1
    elif d <= 24: hist[2] += 1
    elif d <= 64: hist[3] += 1
    else: hist[4] += 1

print(f"кадр {wa}x{ha}, каналов {n}")
print(f"средняя разница: {tot / n:.2f} из 255 ({tot / n / 2.55:.2f}%)")
labels = ["<=2", "3..8", "9..24", "25..64", ">64"]
for l, c in zip(labels, hist):
    print(f"  отличие {l:>7}: {c * 100 / n:6.2f}%")

if len(sys.argv) > 3:
    rows = []
    for y in range(ha):
        rows.append(b'\x00' + bytes(diff[y * wa * 3:(y + 1) * wa * 3]))
    raw = b''.join(rows)
    def chunk(t, data):
        return struct.pack('>I', len(data)) + t + data + struct.pack('>I', zlib.crc32(t + data) & 0xffffffff)
    png = (b'\x89PNG\r\n\x1a\n' +
           chunk(b'IHDR', struct.pack('>IIBBBBB', wa, ha, 8, 2, 0, 0, 0)) +
           chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))
    open(sys.argv[3], 'wb').write(png)
    print("карта расхождений (x6):", sys.argv[3])
