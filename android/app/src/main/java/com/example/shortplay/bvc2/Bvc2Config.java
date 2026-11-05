package com.example.shortplay.bvc2;

import androidx.media3.common.ParserException;
import java.io.ByteArrayOutputStream;

/** bv2C 转 Annex B，按红果 libttmplayer.so 的 0xd103c 解析路径实现。 */
public final class Bvc2Config {
  public final int nalLengthSize;
  public final byte[] annexB;
  private Bvc2Config(int size, byte[] data) { nalLengthSize = size; annexB = data; }
  public static Bvc2Config parse(byte[] bytes) throws ParserException {
    try {
      Cursor c = new Cursor(bytes);
      if (c.u8() != 1) throw new IllegalArgumentException("unsupported bv2C version");
      int flags = c.u8();
      int lengthSize = ((flags >> 1) & 7) + 1;
      if (lengthSize > 4) throw new IllegalArgumentException("invalid NAL length size");
      if ((flags & 1) != 0) {
        c.skip(2);
        int sublayers = c.u8() - 1;
        c.skip(3);
        if (sublayers < 0 || sublayers > 7) throw new IllegalArgumentException("invalid sublayers");
        c.skip(sublayers);
        int present = c.u8();
        for (int mask = 128; mask != 0; mask >>= 1) if ((present & mask) != 0) c.skip(1);
        c.skip(c.u8() * 4);
        c.skip(8); // bit depth/chroma flags, width, height, frame rate
      }
      int arrays = c.u8();
      ByteArrayOutputStream output = new ByteArrayOutputStream();
      for (int i = 0; i < arrays; i++) {
        c.skip(1);
        int count = c.u16();
        for (int j = 0; j < count; j++) {
          int length = c.u16();
          if (length == 0) throw new IllegalArgumentException("empty parameter NAL");
          c.require(length);
          output.write(0); output.write(0); output.write(0); output.write(1);
          output.write(bytes, c.at, length); c.skip(length);
        }
      }
      if (c.at != bytes.length) throw new IllegalArgumentException("trailing bv2C data");
      return new Bvc2Config(lengthSize, output.toByteArray());
    } catch (IllegalArgumentException error) {
      throw ParserException.createForMalformedContainer("Invalid BVC2 configuration", error);
    }
  }
  private static final class Cursor {
    final byte[] bytes; int at;
    Cursor(byte[] bytes) { this.bytes = bytes; }
    void require(int count) {
      if (count < 0 || count > bytes.length - at) throw new IllegalArgumentException("truncated bv2C");
    }
    void skip(int count) { require(count); at += count; }
    int u8() { require(1); return bytes[at++] & 255; }
    int u16() { return (u8() << 8) | u8(); }
  }
}
