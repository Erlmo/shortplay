package com.example.shortplay.bvc2;

import androidx.media3.common.C;
import androidx.media3.decoder.Decoder;
import androidx.media3.decoder.DecoderException;
import androidx.media3.decoder.DecoderInputBuffer;
import androidx.media3.decoder.VideoDecoderOutputBuffer;
import java.nio.ByteBuffer;
import java.util.ArrayDeque;

/** 每个播放器独占解码上下文；用有界队列把解码与 ExoPlayer 的音频时钟分开。 */
final class Bvc2Decoder implements Decoder<DecoderInputBuffer, VideoDecoderOutputBuffer, DecoderException> {
  private final Object lock = new Object();
  private final ArrayDeque<DecoderInputBuffer> freeInputs = new ArrayDeque<>();
  private final ArrayDeque<DecoderInputBuffer> inputs = new ArrayDeque<>();
  private final ArrayDeque<VideoDecoderOutputBuffer> freeOutputs = new ArrayDeque<>();
  private final ArrayDeque<VideoDecoderOutputBuffer> outputs = new ArrayDeque<>();
  private final byte[] config;
  private final Thread worker;
  private DecoderException failure;
  private DecoderInputBuffer dequeued;
  private boolean released;
  private int generation;
  private long outputStartTimeUs = C.TIME_UNSET;

  Bvc2Decoder(byte[] config) {
    this.config = config.clone();
    for (int i = 0; i < 4; i++) freeInputs.add(new DecoderInputBuffer(DecoderInputBuffer.BUFFER_REPLACEMENT_MODE_DIRECT));
    for (int i = 0; i < 8; i++) freeOutputs.add(new VideoDecoderOutputBuffer(this::releaseOutput));
    worker = new Thread(this::run, "ShortPlay:BVC2");
    worker.start();
  }
  @Override public String getName() { return "ShortPlay BVC2 CPU"; }
  private void check() throws DecoderException { if (failure != null) throw failure; }
  @Override public DecoderInputBuffer dequeueInputBuffer() throws DecoderException {
    synchronized (lock) {
      check(); if (released || dequeued != null || freeInputs.isEmpty()) return null;
      dequeued = freeInputs.removeFirst(); return dequeued;
    }
  }
  @Override public void queueInputBuffer(DecoderInputBuffer input) throws DecoderException {
    synchronized (lock) {
      check();
      if (input != dequeued || released) throw new IllegalStateException("Invalid BVC2 input ownership");
      inputs.addLast(input); dequeued = null; lock.notifyAll();
    }
  }
  @Override public VideoDecoderOutputBuffer dequeueOutputBuffer() throws DecoderException {
    synchronized (lock) { check(); return outputs.pollFirst(); }
  }
  private void releaseOutput(VideoDecoderOutputBuffer output) {
    synchronized (lock) { output.clear(); freeOutputs.addLast(output); lock.notifyAll(); }
  }
  @Override public void setOutputStartTimeUs(long timeUs) {
    synchronized (lock) { outputStartTimeUs = timeUs; }
  }
  @Override public void flush() {
    synchronized (lock) {
      generation++; android.util.Log.d("ShortPlayBvc2", "flush generation=" + generation); outputStartTimeUs = C.TIME_UNSET;
      if (dequeued != null) { dequeued.clear(); freeInputs.addLast(dequeued); dequeued = null; }
      while (!inputs.isEmpty()) { DecoderInputBuffer in = inputs.removeFirst(); in.clear(); freeInputs.addLast(in); }
      while (!outputs.isEmpty()) releaseOutput(outputs.removeFirst());
      lock.notifyAll();
    }
  }
  @Override public void release() {
    synchronized (lock) { released = true; lock.notifyAll(); }
    boolean interrupted = false;
    for (;;) {
      try { worker.join(); break; } catch (InterruptedException error) { interrupted = true; }
    }
    if (interrupted) Thread.currentThread().interrupt();
  }
  private void run() {
    long nativeHandle = 0;
    int nativeGeneration = -1;
    DecoderInputBuffer input = null;
    int jobGeneration = -1;
    int drainCount = 0;
    try {
      for (;;) {
        VideoDecoderOutputBuffer output;
        synchronized (lock) {
          if (input != null && jobGeneration != generation) {
            input.clear(); freeInputs.addLast(input); input = null;
          }
          while (!released && (freeOutputs.isEmpty() || (input == null && inputs.isEmpty()))) lock.wait();
          if (released) break;
          if (input == null) { input = inputs.removeFirst(); jobGeneration = generation; drainCount = 0; }
          output = freeOutputs.removeFirst();
        }
        if (nativeGeneration != jobGeneration) {
          if (nativeHandle != 0) Bvc2Native.destroy(nativeHandle);
          nativeHandle = 0;
          nativeHandle = Bvc2Native.create(config);
          nativeGeneration = jobGeneration;
          android.util.Log.d("ShortPlayBvc2", "created generation=" + nativeGeneration);
        }
        boolean end = input.isEndOfStream();
        if (end) android.util.Log.d("ShortPlayBvc2", "drain=" + drainCount);
        ByteBuffer data = end ? null : input.data;
        output.init(input.timeUs, C.VIDEO_OUTPUT_MODE_SURFACE_YUV, null);
        boolean gotFrame = Bvc2Native.decode(nativeHandle, data,
            data == null ? 0 : data.position(), data == null ? 0 : data.remaining(), input.timeUs, output);
        if (end && !gotFrame) output.addFlag(C.BUFFER_FLAG_END_OF_STREAM);
        if (end && ++drainCount > 64) throw new IllegalStateException("BVC2 drain did not finish");
        synchronized (lock) {
          if (jobGeneration == generation && (gotFrame || end)) {
            output.shouldBeSkipped = gotFrame && outputStartTimeUs != C.TIME_UNSET && output.timeUs < outputStartTimeUs;
            outputs.addLast(output);
          } else releaseOutput(output);
          if (!end || !gotFrame) { input.clear(); freeInputs.addLast(input); input = null; }
        }
      }
    } catch (Exception | LinkageError error) {
      synchronized (lock) { failure = new DecoderException("BVC2 decode failed", error); lock.notifyAll(); }
    } finally {
      if (nativeHandle != 0) Bvc2Native.destroy(nativeHandle);
    }
  }
}
