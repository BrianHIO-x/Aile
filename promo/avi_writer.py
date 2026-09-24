"""Minimal MJPEG AVI writer (RIFF AVI 1.0) using Pillow for JPEG encoding."""
import io
import struct


class MjpegAviWriter:
    def __init__(self, path, width, height, fps, quality=92):
        self.path = path
        self.width = width
        self.height = height
        self.fps = fps
        self.quality = quality
        self.index = []
        self.max_size = 0
        self.f = open(path, 'wb')
        self._write_headers(0)
        self.f.write(b'LIST')
        self.movi_size_pos = self.f.tell()
        self.f.write(struct.pack('<I', 0))
        self.movi_start = self.f.tell()
        self.f.write(b'movi')

    def _write_headers(self, frames):
        self.f.seek(0)
        avih = struct.pack('<IIIIIIIIII16x',
                           int(1_000_000 / self.fps), 0, 0, 0x10, frames, 0, 1,
                           self.max_size, self.width, self.height)
        strh = struct.pack('<4s4sIHHIIIIIIIIhhhh',
                           b'vids', b'MJPG', 0, 0, 0, 0, 1, self.fps, 0, frames,
                           self.max_size, 10000, 0, 0, 0, self.width, self.height)
        strf = struct.pack('<IiiHH4sIiiII', 40, self.width, self.height, 1, 24, b'MJPG',
                           self.width * self.height * 3, 0, 0, 0, 0)
        strl = b'strl' + b'strh' + struct.pack('<I', len(strh)) + strh + b'strf' + struct.pack('<I', len(strf)) + strf
        hdrl = b'hdrl' + b'avih' + struct.pack('<I', len(avih)) + avih + b'LIST' + struct.pack('<I', len(strl)) + strl
        self.f.write(b'RIFF')
        self.f.write(struct.pack('<I', 0))
        self.f.write(b'AVI ')
        self.f.write(b'LIST' + struct.pack('<I', len(hdrl)) + hdrl)

    def add(self, image):
        buf = io.BytesIO()
        # 4:2:0 chroma: the Windows MJPEG decoder mis-decodes 4:4:4 frames into color blocks
        image.convert('RGB').save(buf, 'JPEG', quality=self.quality, subsampling=2)
        data = buf.getvalue()
        offset = self.f.tell() - self.movi_start
        self.f.write(b'00dc' + struct.pack('<I', len(data)) + data)
        if len(data) % 2:
            self.f.write(b'\0')
        self.index.append((offset, len(data)))
        self.max_size = max(self.max_size, len(data))

    def close(self):
        end_movi = self.f.tell()
        self.f.seek(self.movi_size_pos)
        self.f.write(struct.pack('<I', end_movi - self.movi_start))
        self.f.seek(end_movi)
        self.f.write(b'idx1' + struct.pack('<I', 16 * len(self.index)))
        for offset, size in self.index:
            self.f.write(b'00dc' + struct.pack('<III', 0x10, offset, size))
        end = self.f.tell()
        self._write_headers(len(self.index))
        self.f.seek(4)
        self.f.write(struct.pack('<I', end - 8))
        self.f.close()
