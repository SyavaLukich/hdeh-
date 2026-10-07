import struct, zlib, sys
src, dst = sys.argv[1], sys.argv[2]
d=open(src,'rb').read()
off=struct.unpack_from('<I',d,10)[0]
w=struct.unpack_from('<i',d,18)[0]; h=struct.unpack_from('<i',d,22)[0]
rowsize=((w*3+3)//4)*4
rows=[]
for y in range(h-1,-1,-1):
    s=off+y*rowsize
    row=bytearray(b'\x00')
    for x in range(w):
        b,g,r=d[s+x*3],d[s+x*3+1],d[s+x*3+2]
        row+=bytes((r,g,b))
    rows.append(bytes(row))
raw=b''.join(rows)
def chunk(t,data):
    return struct.pack('>I',len(data))+t+data+struct.pack('>I',zlib.crc32(t+data)&0xffffffff)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw,6))+chunk(b'IEND',b'')
open(dst,'wb').write(png)
print('ok',w,h)
