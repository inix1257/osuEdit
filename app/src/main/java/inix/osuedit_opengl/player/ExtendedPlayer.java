package inix.osuedit_opengl.player;

import javazoom.jl.decoder.*;
import javazoom.jl.player.AudioDevice;
import javazoom.jl.player.FactoryRegistry;

import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * @author Erik Beeson
 */
public class ExtendedPlayer {
	private enum PlayerState {
		PAUSE, PLAY, FINISHED
	}

	private static final int BLOCK_SIZE = 20;

	private PlayerState state = PlayerState.PAUSE;
	private int playSpeed = 0;
	private int blockCount = 0;
	private int skipCount = 0;

	private final Thread thread;
	boolean closed = false;

	private final Bitstream bitstream;
	private final Decoder decoder;
	private final AudioDevice audio;

	private final List<PlayerEventListener> listeners = new ArrayList<PlayerEventListener>();

	public ExtendedPlayer(InputStream in) throws JavaLayerException {
		this(in, null);
	}

	public ExtendedPlayer(InputStream in, AudioDevice audio) throws JavaLayerException {
		this.bitstream = new Bitstream(in);
		this.decoder = new Decoder();
		this.audio = (audio != null ? audio : FactoryRegistry.systemRegistry().createAudioDevice());
		this.audio.open(decoder);

		this.thread = new Thread(new Runnable() {
			public void run() {
				while(!PlayerState.FINISHED.equals(state)) {
					if(PlayerState.PLAY.equals(state)) {
						try {
							boolean playFrame = true;

							if(playSpeed > 0) { // fast forwarding
								playFrame = (skipCount >= Math.pow(playSpeed, 2) * BLOCK_SIZE);
								if(playFrame) { // haven't skipped enough frames yet
									blockCount++;
									if(blockCount == BLOCK_SIZE) {
										skipCount = 0;
										blockCount = 0;
									}
								} else {
									skipCount++;
								}
							}

							if(readFrame(playFrame) == -1) {
								close();
								for(PlayerEventListener listener : listeners) {
									listener.playbackFinished();
								}
							}
						} catch(JavaLayerException e) {
							throw new RuntimeException(e);
						}
					} else if(PlayerState.PAUSE.equals(state)) {
						try {
							synchronized(thread) {
								thread.wait();
							}
						} catch(InterruptedException ignored) {
						}
					}
				}
			}
		});
		this.thread.start();
	}

	public void addListener(PlayerEventListener listener) {
		listeners.add(listener);
	}

	public void playFaster() {
		setPlaySpeed(playSpeed + 1);
	}

	public void playSlower() {
		setPlaySpeed(Math.max(playSpeed - 1, 0));
	}

	public void playNormal() {
		setPlaySpeed(0);
	}

	protected void setPlaySpeed(int playSpeed) {
		this.playSpeed = playSpeed;
		this.skipCount = 0;
		if(!isPlaying()) {
			play();
		}
	}

	public void play() {
		state = PlayerState.PLAY;
		synchronized(thread) {
			thread.interrupt();
		}
	}

	public void pause() {
		state = PlayerState.PAUSE;
	}

	public boolean isPlaying() {
		return PlayerState.PLAY.equals(state);
	}

	public int getPlaySpeed() {
		return playSpeed;
	}

	public synchronized void close() {
		if(!closed) {
			closed = true;
			state = PlayerState.FINISHED;
			synchronized(thread) {
				try {
					thread.interrupt();
					thread.join(2000);
				} catch(InterruptedException ignored) {
				}
			}
			audio.flush();
			audio.close();
			try {
				bitstream.close();
			} catch(BitstreamException ignored) {
			}
		}
	}

	public int getPosition() {
		return audio.getPosition();
	}

	public float readFrame(boolean play) throws JavaLayerException {
		Header header = bitstream.readFrame();

		if(header == null) {
			return -1; // playback finished
		} else {
			if(play) {
				SampleBuffer output = (SampleBuffer) decoder.decodeFrame(header, bitstream);

				synchronized(this) {
					audio.write(output.getBuffer(), 0, output.getBufferLength());
				}
			}

			bitstream.closeFrame();

			return header.ms_per_frame();
		}
	}
}
