package hxscript.openfl;

#if (lime && openfl)
import haxe.io.Bytes;
import lime.media.AudioBuffer;
import lime.utils.UInt8Array;
import openfl.media.Sound;

/**
 * Turns raw PCM a script generated into a playable sound.
 */
@:keep
class SoundTools {
	/** Bytes one sample occupies, being sixteen bits. */
	public static inline var SAMPLE_BYTES:Int = 2;

	/**
	 * Builds a sound from interleaved signed 16-bit PCM.
	 *
	 * Two samples are packed per write rather than one. `Bytes` writes little-endian, which is the
	 * byte order PCM is already in, so a stereo frame is exactly one 32-bit store with the left
	 * channel in the low half. That halves the work on a buffer measured in millions of entries.
	 *
	 * @param samples Interleaved samples, each -32768 to 32767.
	 * @param count How many to take from the front, or 0 for all of them.
	 * @param sampleRate Frames per second.
	 * @param channels 1 for mono, 2 for interleaved stereo.
	 * @return The sound, or null when there was nothing to build one from.
	 */
	public static function sound(samples:Array<Int>, count:Int, sampleRate:Int, channels:Int):Sound {
		if (samples == null)
			return null;

		var total:Int = count <= 0 || count > samples.length ? samples.length : count;
		if (total <= 0 || sampleRate <= 0 || channels <= 0)
			return null;

		var bytes:Bytes = Bytes.alloc(total * SAMPLE_BYTES);

		var pairs:Int = total >> 1;
		for (i in 0...pairs) {
			var at:Int = i << 1;
			bytes.setInt32(at * SAMPLE_BYTES, (samples[at] & 0xFFFF) | (samples[at + 1] << 16));
		}

		if ((total & 1) != 0)
			bytes.setUInt16((total - 1) * SAMPLE_BYTES, samples[total - 1] & 0xFFFF);

		var buffer:AudioBuffer = new AudioBuffer();
		buffer.bitsPerSample = SAMPLE_BYTES * 8;
		buffer.channels = channels;
		buffer.sampleRate = sampleRate;
		buffer.data = UInt8Array.fromBytes(bytes);

		return Sound.fromAudioBuffer(buffer);
	}
}
#end
