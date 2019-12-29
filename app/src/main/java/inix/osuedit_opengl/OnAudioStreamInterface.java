package inix.osuedit_opengl;

public interface OnAudioStreamInterface {
    public void onAudioPlayerStart(AudioStreamPlayer player);

    public void onAudioPlayerPause(AudioStreamPlayer player);

    public void onAudioPlayerStop(AudioStreamPlayer player);

    public void onAudioPlayerError(AudioStreamPlayer player);

    public void onAudioPlayerBuffering(AudioStreamPlayer player);

    public void onAudioPlayerDuration(int totalSec);

    public void onAudioPlayerCurrentTime(int sec);

    public void onSeekComplete(long ms);
}
