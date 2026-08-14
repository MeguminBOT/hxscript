/*
 * Copyright (c) 2026 MeguminBOT (hxScript)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package hxscript.heaps;

#if heaps
import haxe.io.Bytes;
import hxd.res.Any;
import hxd.res.Sound;

/**
 * Turns raw PCM a script generated into a playable sound, on heaps.
 *
 * The counterpart of `hxscript.openfl.SoundTools`, and it takes the same arguments so a script that
 * generates its own audio moves between the two targets without changing what it hands over.
 *
 * heaps takes a sound from a resource rather than from a buffer, so the samples are wrapped in a
 * WAV: a 44-byte header and the data after it, which is what a WAV is. That is deliberate rather
 * than a detour. The alternative is reaching into `hxd.snd.Data` and providing a decoder, which
 * means owning a piece of heaps' internals for the life of the library, where the header is a fixed
 * format that has not changed since 1991 and that heaps already knows how to read.
 */
@:keep
class SoundTools {
	/** Bytes one sample occupies, being sixteen bits. */
	public static inline var SAMPLE_BYTES:Int = 2;

	/** Bytes the RIFF header takes before the samples start. */
	static inline var HEADER_BYTES:Int = 44;

	/**
	 * Builds a sound from interleaved signed 16-bit PCM.
	 *
	 * @param samples Interleaved samples, each -32768 to 32767.
	 * @param count How many to take from the front, or 0 for all of them.
	 * @param sampleRate Frames per second.
	 * @param channels 1 for mono, 2 for interleaved stereo.
	 * @return The sound, or null when there was nothing to build one from.
	 */
	public static function sound(samples:Array<Int>, count:Int, sampleRate:Int, channels:Int):Sound {
		var bytes:Bytes = wav(samples, count, sampleRate, channels);

		if (bytes == null)
			return null;

		try {
			return Any.fromBytes('hxscript.wav', bytes).toSound();
		} catch (e:Dynamic) {
			return null;
		}
	}

	/**
	 * Writes one of a RIFF file's four-character tags.
	 *
	 * `Bytes` has no `setString`, and the tags are ASCII by definition, so the four codes go in one
	 * at a time rather than through an encoder that would have to decide what the characters mean.
	 *
	 * @param bytes Where to write.
	 * @param at The offset.
	 * @param value Four characters.
	 */
	static function tag(bytes:Bytes, at:Int, value:String):Void {
		for (i in 0...value.length)
			bytes.set(at + i, value.charCodeAt(i));
	}

	/**
	 * Wraps PCM in a WAV, which is the form heaps reads a sound from.
	 *
	 * @param samples Interleaved samples, each -32768 to 32767.
	 * @param count How many to take from the front, or 0 for all of them.
	 * @param sampleRate Frames per second.
	 * @param channels 1 for mono, 2 for interleaved stereo.
	 * @return The file's bytes, or null when there was nothing to build one from.
	 */
	public static function wav(samples:Array<Int>, count:Int, sampleRate:Int, channels:Int):Bytes {
		if (samples == null)
			return null;

		var total:Int = count <= 0 || count > samples.length ? samples.length : count;

		if (total <= 0 || sampleRate <= 0 || channels <= 0)
			return null;

		var audio:Int = total * SAMPLE_BYTES;
		var bytes:Bytes = Bytes.alloc(HEADER_BYTES + audio);

		tag(bytes, 0, 'RIFF');
		bytes.setInt32(4, 36 + audio);
		tag(bytes, 8, 'WAVE');

		tag(bytes, 12, 'fmt ');
		bytes.setInt32(16, 16);
		bytes.setUInt16(20, 1);
		bytes.setUInt16(22, channels);
		bytes.setInt32(24, sampleRate);
		bytes.setInt32(28, sampleRate * channels * SAMPLE_BYTES);
		bytes.setUInt16(32, channels * SAMPLE_BYTES);
		bytes.setUInt16(34, SAMPLE_BYTES * 8);

		tag(bytes, 36, 'data');
		bytes.setInt32(40, audio);

		/**
		 * Two samples per write. `Bytes` writes little-endian, which is the byte order PCM is already
		 * in, so a pair is one 32-bit store with the earlier sample in the low half. That halves the
		 * work on a buffer measured in hundreds of thousands of entries.
		 */
		var pairs:Int = total >> 1;

		for (i in 0...pairs) {
			var at:Int = i << 1;
			bytes.setInt32(HEADER_BYTES + at * SAMPLE_BYTES, (samples[at] & 0xFFFF) | (samples[at + 1] << 16));
		}

		if ((total & 1) != 0)
			bytes.setUInt16(HEADER_BYTES + (total - 1) * SAMPLE_BYTES, samples[total - 1] & 0xFFFF);

		return bytes;
	}
}
#end
