package com.example.shortplay.bvc2;

import android.content.Context;
import android.os.Handler;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.Renderer;
import androidx.media3.exoplayer.video.VideoRendererEventListener;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import java.util.ArrayList;

public final class Bvc2RenderersFactory extends DefaultRenderersFactory {
  public Bvc2RenderersFactory(Context context) { super(context); }
  @Override protected void buildVideoRenderers(Context context, int mode, MediaCodecSelector selector,
      boolean fallback, Handler handler, VideoRendererEventListener listener, long joiningTimeMs,
      ArrayList<Renderer> renderers) {
    super.buildVideoRenderers(context, mode, selector, fallback, handler, listener, joiningTimeMs, renderers);
    if (Bvc2Native.isAvailable()) renderers.add(new Bvc2VideoRenderer(handler, listener));
  }
}
