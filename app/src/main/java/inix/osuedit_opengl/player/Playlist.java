package inix.osuedit_opengl.player;

import javazoom.jl.decoder.JavaLayerException;
import javazoom.jl.player.AudioDevice;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.util.ArrayList;
import java.util.List;
import java.util.ListIterator;

/**
 * @author Erik Beeson
 */
public class Playlist {
	private final AudioDevice audioDevice;
	private final File[] files;
	private final ListIterator<File> playlist;

	private File currentFile = null;
	private ExtendedPlayer player = null;

	public Playlist(File... files) {
		this(null, files);
	}

	public Playlist(AudioDevice audioDevice, File... files) {
		this.audioDevice = audioDevice;
		this.files = files;
		List<File> list = new ArrayList<File>(files.length);
		for(File file : files) {
			if(file.exists()) {
				if(file.isDirectory()) {
					for(File f : file.listFiles()) {
						if(f.getName().toLowerCase().endsWith(".mp3")) {
							list.add(f);
						}
					}
				} else {
					list.add(file);
				}
			}
		}
		this.playlist = list.listIterator();
	}

	public synchronized boolean next() throws FileNotFoundException, JavaLayerException {
		if(playlist.hasNext()) {
			gotoFile(playlist.next());
			return true;
		} else {
			return false;
		}
	}

	public synchronized boolean previous() throws JavaLayerException, FileNotFoundException {
		if(playlist.hasPrevious()) {
			gotoFile(playlist.previous());
			return true;
		} else {
			return false;
		}
	}

	protected void gotoFile(File file) throws FileNotFoundException, JavaLayerException {
		currentFile = file;
		player = new ExtendedPlayer(new FileInputStream(currentFile), audioDevice);
		player.addListener(new PlayerEventListener() {
			public void playbackFinished() {
				try {
					next();
				} catch(FileNotFoundException e) {
					e.printStackTrace();
				} catch(JavaLayerException e) {
					e.printStackTrace();
				}
			}
		});
		player.play();
	}

	public void play() throws JavaLayerException, FileNotFoundException {
		if(player != null) {
			player.play();
		} else {
			next();
		}
	}

	public void pause() {
		if(player != null) {
			player.pause();
		}
	}

	public boolean isPlaying() {
		return player != null && player.isPlaying();
	}

	public int getPosition() {
		return player != null ? player.getPosition() : -1;
	}

	public void close() {
		if(player != null) {
			player.close();
		}
	}

	public File[] getFiles() {
		return files;
	}

	public File getCurrentFile() {
		return currentFile;
	}
}
