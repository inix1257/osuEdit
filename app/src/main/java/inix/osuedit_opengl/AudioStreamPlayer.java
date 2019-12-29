package inix.osuedit_opengl;

import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTimestamp;
import android.media.AudioTrack;
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.os.Handler;
import android.os.Message;
import android.util.Log;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.ArrayList;

public class AudioStreamPlayer {

    private MediaExtractor mExtractor = null;
    private MediaCodec mMediaCodec = null;
    private AudioTrack mAudioTrack = null;

    private int mInputBufIndex = 0;

    ArrayList<Long> timeSampleRate = new ArrayList<>();

    private boolean isForceStop = false;
    private volatile boolean isPause = false;

    public int currentPosition = 0;
    public int totalDuration = 0;

    private int counter = 0;

    boolean isSeek = false;
    int seekTime = 0;

    private boolean customSeek = false;

    int nativeprogress = 0;

    public static int sampleRate = 0;

    protected OnAudioStreamInterface mListener = null;

    public void setOnAudioStreamInterface(OnAudioStreamInterface listener)
    {
        this.mListener = listener;
    }

    public enum State
    {
        Stopped, Prepare, Buffering, Playing, Pause
    };

    State mState = State.Stopped;

    public State getState()
    {
        return mState;
    }

    private String mMediaPath;

    public void setUrlString(String mUrlString)
    {
        this.mMediaPath = mUrlString;
    }

    public AudioStreamPlayer()
    {
        mState = State.Stopped;
    }

    public void play() throws IOException
    {
        mState = State.Prepare;
        isForceStop = false;

        mAudioPlayerHandler.onAudioPlayerBuffering(AudioStreamPlayer.this);

        new Thread(new Runnable()
        {
            @Override
            public void run()
            {
                decodeLoop();
            }
        }).start();
    }

    private DelegateHandler mAudioPlayerHandler = new DelegateHandler();

    class DelegateHandler extends Handler
    {
        @Override
        public void handleMessage(Message msg)
        {
        }

        public void onAudioPlayerPlayerStart(AudioStreamPlayer player)
        {
            if (mListener != null)
            {
                mListener.onAudioPlayerStart(player);
            }
        }

        public void onAudioPlayerStop(AudioStreamPlayer player)
        {
            if (mListener != null)
            {
                mListener.onAudioPlayerStop(player);
            }
        }

        public void onAudioPlayerError(AudioStreamPlayer player)
        {
            if (mListener != null)
            {
                mListener.onAudioPlayerError(player);
            }
        }

        public void onAudioPlayerBuffering(AudioStreamPlayer player)
        {
            if (mListener != null)
            {
                mListener.onAudioPlayerBuffering(player);
            }
        }

        public void onAudioPlayerDuration(int ms)
        {
            if (mListener != null)
            {
                mListener.onAudioPlayerDuration(ms);
            }
        }

        public void onAudioPlayerCurrentTime(int ms)
        {
            if (mListener != null)
            {
                mListener.onAudioPlayerCurrentTime(ms);
            }
        }

        public void onAudioPlayerPause()
        {
            if(mListener != null)
            {
                mListener.onAudioPlayerPause(AudioStreamPlayer.this);
            }
        }

        public void onSeekComplete(){
            mListener.onSeekComplete(mExtractor.getSampleTime());
        }
    };

    private void decodeLoop()
    {
        ///////////////////////////////////////////////////////////////////////
        try{

                mExtractor = new MediaExtractor();
                try
                {
                    mExtractor.setDataSource(this.mMediaPath);
                }
                catch (Exception e)
                {
                    mAudioPlayerHandler.onAudioPlayerError(AudioStreamPlayer.this);
                    return;
                }

                MediaFormat format = mExtractor.getTrackFormat(0);
                String mime = format.getString(MediaFormat.KEY_MIME);
                long duration = format.getLong(MediaFormat.KEY_DURATION);
                Log.e("AudioStream", "duration : " + duration);

                mAudioPlayerHandler.onAudioPlayerDuration((int)(duration / 1000));

                mMediaCodec = MediaCodec.createDecoderByType(mime);
                mMediaCodec.configure(format, null, null, 0);
                mMediaCodec.start();

            sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE);
            mAudioTrack = new AudioTrack(AudioManager.STREAM_MUSIC, sampleRate, AudioFormat.CHANNEL_OUT_STEREO,
                    AudioFormat.ENCODING_PCM_16BIT, AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_STEREO,
                    AudioFormat.ENCODING_PCM_16BIT), AudioTrack.MODE_STREAM);


            mAudioTrack.play();

            mExtractor.selectTrack(0);

             while(true){
             if(mExtractor.getSampleTime() == -1) break;
             Log.i("AudioTest", mExtractor.getSampleTime()+" / SampleTime : " +  " / Counter : " + counter);
             timeSampleRate.add(mExtractor.getSampleTime());
             mExtractor.advance();
             counter++;
             }

             Log.e("AudioTest", "counter : " + counter);
        }catch(Exception e){

        }
        //////////////////////////////////////////////////////////////////////

        ByteBuffer[] codecInputBuffers;
        ByteBuffer[] codecOutputBuffers;

        mExtractor = new MediaExtractor();
        try
        {
            mExtractor.setDataSource(this.mMediaPath);
        }
        catch (Exception e)
        {
            mAudioPlayerHandler.onAudioPlayerError(AudioStreamPlayer.this);
            return;
        }

        MediaFormat format = mExtractor.getTrackFormat(0);
        String mime = format.getString(MediaFormat.KEY_MIME);
        long duration = format.getLong(MediaFormat.KEY_DURATION);
        Log.e("AudioStream", "duration : " + duration);
        int totalSec = (int) (duration / 1000 / 1000);
        int min = totalSec / 60;
        int sec = totalSec % 60;

        totalDuration = totalSec;

        mAudioPlayerHandler.onAudioPlayerDuration((int)(duration / 1000));



        try {
            mMediaCodec = MediaCodec.createDecoderByType(mime);
            mMediaCodec.configure(format, null, null, 0);
            mMediaCodec.start();
        }catch(Exception e){

        }
        codecInputBuffers = mMediaCodec.getInputBuffers();
        codecOutputBuffers = mMediaCodec.getOutputBuffers();

        sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE);
        Log.e("AudioStream", "samplerate : " + sampleRate);
        Log.e("AudioStream", "bitrate : " + format.getInteger(MediaFormat.KEY_BIT_RATE));
        Log.e("AudioStream", "mime : " + format.getString(MediaFormat.KEY_MIME));
        Log.e("AudioStream", "channel count : " + format.getInteger(MediaFormat.KEY_CHANNEL_COUNT));
        Log.e("AudioStream", "codecName : " + mMediaCodec.getName());
        Log.e("AudioStream", "codecInfoName : " + mMediaCodec.getCodecInfo().getName());

        mAudioTrack = new AudioTrack(AudioManager.STREAM_MUSIC, sampleRate, AudioFormat.CHANNEL_OUT_STEREO,
                AudioFormat.ENCODING_PCM_16BIT, AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_STEREO,
                AudioFormat.ENCODING_PCM_16BIT), AudioTrack.MODE_STREAM);


        mAudioTrack.play();

        mExtractor.selectTrack(0);

        final long kTimeOutUs = 10000;
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();

        boolean sawInputEOS = false;
        int noOutputCounter = 0;
        int noOutputCounterLimit = 50;

        while (!sawInputEOS && noOutputCounter < noOutputCounterLimit && !isForceStop)
        {
            if (!sawInputEOS)
            {
                if(isPause)
                {
                    if(mState != State.Pause)
                    {
                        mState = State.Pause;
                        mAudioPlayerHandler.onAudioPlayerPause();
                    }
                    continue;
                }
                noOutputCounter++;
                if (isSeek)
                {

                    float scaletmp = (seekTime * 1000f) / duration;
                    int approxIndex = (int)(counter * scaletmp);
                    long approxOffset = timeSampleRate.get(approxIndex);

                    Log.e("AudioStream", "scaletmp : " + scaletmp + " / duration" + duration + " seektime : " + seekTime);
                    Log.e("AudioStream", "approxIndex : " + approxIndex + " / " + counter + " # approxOffset : " + approxOffset);

                    mExtractor.seekTo(seekTime * 1000, MediaExtractor.SEEK_TO_CLOSEST_SYNC);
                    //seekTime = seekTime * 1000;
                    //Log.e("AudioStream", mExtractor.getSampleTime() + " / " + (seekTime*1000) + " : advanced");
                    isSeek = false;
                    mAudioPlayerHandler.onSeekComplete();
                }

                mInputBufIndex = mMediaCodec.dequeueInputBuffer(kTimeOutUs);
                if (mInputBufIndex >= 0)
                {
                    ByteBuffer dstBuf = codecInputBuffers[mInputBufIndex];

                    int sampleSize = mExtractor.readSampleData(dstBuf, 0);

                    long presentationTimeUs = 0;

                    if (sampleSize < 0) //End of Stream
                    {
                        sawInputEOS = true;
                        sampleSize = 0;
                    }
                    else
                    {
                        presentationTimeUs = (long)(mExtractor.getSampleTime());

                        //Log.e("AudioStream", "presentaionTime = " + (int) (presentationTimeUs / 1000) + " / nativeprogess : " + nativeprogress);
                        //Log.e("AudioStream", "sampleTime : " + mExtractor.getSampleTime() + " / sampleRate : " + mAudioTrack.getSampleRate() + " / sampleSize" + mExtractor.getSampleSize());

                        //currentPosition = seekTime;
                        //Log.e("AudioStream", "sampleTime : " + presentationTimeUs + " / seekTime : " + seekTime);

                        mAudioPlayerHandler.onAudioPlayerCurrentTime((int)(presentationTimeUs/1000));
                    }

                    mMediaCodec.queueInputBuffer(mInputBufIndex, 0, sampleSize, presentationTimeUs,
                            sawInputEOS ? MediaCodec.BUFFER_FLAG_END_OF_STREAM : 0);

                    if (!sawInputEOS)
                    {
                        mExtractor.advance();
                    }
                }
            }

            int res = mMediaCodec.dequeueOutputBuffer(info, kTimeOutUs);

            if (res >= 0)
            {
                if (info.size > 0)
                {
                    noOutputCounter = 0;
                }

                int outputBufIndex = res;
                ByteBuffer buf = codecOutputBuffers[outputBufIndex];

                final byte[] chunk = new byte[info.size];
                //Log.e("AudioStream", "chunk size : " + chunk.length);
                buf.get(chunk);
                buf.clear();
                if (chunk.length > 0)
                {
                    mAudioTrack.write(chunk, 0, chunk.length);
                    if (this.mState != State.Playing)
                    {
                        mAudioPlayerHandler.onAudioPlayerPlayerStart(AudioStreamPlayer.this);
                    }
                    this.mState = State.Playing;
                }
                mMediaCodec.releaseOutputBuffer(outputBufIndex, false);
            }
            else if (res == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED)
            {
                codecOutputBuffers = mMediaCodec.getOutputBuffers();

            }
            else if (res == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED)
            {
                MediaFormat oformat = mMediaCodec.getOutputFormat();

            }
        }

        //End of AudioStream

        releaseResources(true);

        this.mState = State.Stopped;
        isForceStop = true;

        if (noOutputCounter >= noOutputCounterLimit)
        {
            mAudioPlayerHandler.onAudioPlayerError(AudioStreamPlayer.this);
        }
        else
        {
            //mAudioPlayerHandler.onAudioPlayerStop(AudioStreamPlayer.this);
        }
    }

    public void release()
    {
        stop();
        releaseResources(false);
    }

    private void releaseResources(Boolean release)
    {
        if (mExtractor != null)
        {
            mExtractor.release();
            mExtractor = null;
        }

        if (mMediaCodec != null)
        {
            if (release)
            {
                mMediaCodec.stop();
                mMediaCodec.release();
                mMediaCodec = null;
            }

        }
        if (mAudioTrack != null)
        {
            mAudioTrack.flush();
            mAudioTrack.release();
            mAudioTrack = null;
        }
    }

    public void pause()
    {
        isPause = true;
    }

    public void stop()
    {
        isForceStop = true;
    }



    public void seekTo(int progress)
    {
        isSeek = true;
        //customSeek = true;
        seekTime = progress;
        nativeprogress = progress;
    }

    public void pauseToPlay()
    {
        isPause = false;
    }

    public void setPlaybackSpeed(float speed){
        mAudioTrack.setPlaybackRate((int)(sampleRate * speed));
    }
}
