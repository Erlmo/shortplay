package com.shortplay.playback

import androidx.media3.common.C
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy

/** The local IO layer already exhausted its retry/route budget for terminal
 * network failures. Do not let the ordinary-MP4 outer loader repeat that chain.
 * All unrelated Media3 errors keep the host's existing policy. */
class MediaNetworkLoadErrorPolicy : DefaultLoadErrorHandlingPolicy() {
    override fun getRetryDelayMsFor(info: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
        if (generateSequence<Throwable>(info.exception) { it.cause }
                .any { it is MediaNetworkFailure && it.terminal }) return C.TIME_UNSET
        return super.getRetryDelayMsFor(info)
    }
}
