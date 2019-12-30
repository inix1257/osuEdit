package inix.osuedit_opengl;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.Dialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.DialogInterface;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.ColorFilter;
import android.graphics.ColorMatrix;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PathMeasure;
import android.graphics.Point;
import android.graphics.PorterDuff;
import android.graphics.PorterDuffColorFilter;
import android.graphics.RectF;
import android.media.AudioManager;
import android.media.SoundPool;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.os.Handler;
import android.os.Message;
import android.os.ParcelUuid;
import android.text.Editable;
import android.text.InputType;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.util.AttributeSet;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Display;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.View;
import android.view.WindowManager;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.Spinner;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import com.chillingvan.canvasgl.CanvasGL;
import com.chillingvan.canvasgl.ICanvasGL;
import com.chillingvan.canvasgl.glcanvas.GLPaint;
import com.chillingvan.canvasgl.glview.GLContinuousView;
import com.chillingvan.canvasgl.textureFilter.BasicTextureFilter;
import com.chillingvan.canvasgl.textureFilter.ColorMatrixFilter;
import com.chillingvan.canvasgl.textureFilter.PixelationFilter;
import com.chillingvan.canvasgl.textureFilter.RGBFilter;
import com.chillingvan.canvasgl.textureFilter.TextureFilter;


import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.Array;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.text.Collator;
import java.text.DecimalFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Iterator;
import java.util.List;
import java.util.Vector;


import static inix.osuedit_opengl.AudioStreamPlayer.sampleRate;
import static inix.osuedit_opengl.EditorActivity._h;
import static inix.osuedit_opengl.EditorActivity._w;
import static inix.osuedit_opengl.LoadActivity.s;
import static inix.osuedit_opengl.Util.map;
import static inix.osuedit_opengl.Util.pDistance;
import static inix.osuedit_opengl.Util.prefLoad;

import inix.osuedit_opengl.OnAudioStreamInterface;
import inix.osuedit_opengl.player.ExtendedPlayer;
import tv.danmaku.ijk.media.player.IMediaPlayer;
import tv.danmaku.ijk.media.player.IjkMediaPlayer;
//import nl.bravobit.ffmpeg.ExecuteBinaryResponseHandler;
//import nl.bravobit.ffmpeg.FFmpeg;

public class Editor extends GLContinuousView {
    AudioStreamPlayer mAudioPlayer;
    //MediaPlayer mediaPlayer;
    SoundPool effects; //Hitsound effect
    int hsId; //ID for hitsound effects

    static public int w, h; //width, height
    static float g; //length unit of osu!res' 1 pixel
    static float left; //Left side of Mapping area
    static float top; //Top side of Mapping area
    int fontSize;

    float playbackSpeed = 1f;
    int playbackInt = 1;

    short formatVersion;

    String audioFilename = "audio.mp3";
    int audioLeadIn = 0;
    int previewTime = 0;
    int countdown = 0;
    String sampleSet = "Normal";
    int mode; //Game mode (supports standard only currently - unused)
    int letterboxInBreaks = 0;
    int epilepsyWarning = 0;
    int widescreenStoryboard = 0;

    public static int fileFormatVersion = 0;

    int[] bookmarks;
    float distanceSpacing = 1.0f;
    int[] beatDivisor = {1, 2, 3, 4, 6, 8, 12, 16};
    int beatDivIndex = 3;
    int gridSize = 16;

    static String title, artist = "", creator = "", version = "", bgfileName;
    String titleUnicode = "", artistUnicode = "";
    String source = "";
    String tags = "";
    int beatmapID, beatmapsetID;

    static float AR = -1, HP = 5, CS = 5, OD = 5, SV = 1, ST = 1; //Default mapstats, SV = Slider Velocity, ST = Slider Tick rate
    static double SR, SR_DT, SR_HT; //Star rating
    static double PP_total, PP_aim, PP_speed, PP_acc;

    String events;

    int[][] colours = new int[3][];

    double stackLeniency;
    double stackTime; //ms between stacks
    int stackpx = 4;

    int currentPosition; //song's current position in milliseconds
    int seekPosition=0;
    float percentage=0.00f; //Song play percentage
    int songDuration; //Duration of song
    int lastTimingOffset;
    long lastTime, lastMillis;

    boolean isPlaying = false;
    private boolean offsetAdjust = false;
    private long offsetAdjustMs = 0;
    boolean isSeeking = false;
    boolean isTimelineSeeking = false;
    boolean isSingleNoteSelected = false;
    boolean hasStarted = false;
    boolean removeStatus = false;
    boolean movingNoteStatus = false;
    boolean movingSliderPointStatus = false;
    boolean placingSliderStatus = false;
    boolean pinchMode = false;
    boolean isDoubletap = false;
    boolean popupStatus = false;
    boolean copyStatus = false;

    boolean scrollMode = false;

    float popupX = 0, popupY = 0;
    String[] popupStr;
    int[] popupColor;

    public Bitmap[] hitcircle;
    public Bitmap hitcircleoverlay;
    public Bitmap hitcircleselect;
    public Bitmap hitcircle_hit;
    public Bitmap[] approachcircle;
    public Bitmap[] default_img = new Bitmap[10];
    public Bitmap sliderfollowcircle;
    public Bitmap reversearrow, sliderBall;

    String header = ""; //header while parsing .osu



    double beatDuration, speed; //BPM, speed per notes
    double BPM_overall, speed_overall; //BPM, speed for current time : for display
    int volume_overall = 100;

    public float ApproachingTime; //Actual millisecond of AR
    public static float CircleSize; //Actual circle size
    public static float maxCircleSize; //Actual circle size for CS 0
    public static float CS5CircleSize; //Actual circle size for CS 5
    float scaleRatio = 0.6f;

    ArrayList<TimingPoint> TimingPoints; //Arraylist for Timing Points
    ArrayList<HitObject> HitObjects; //Arraylist for HitObjects
    ArrayList<HitObject> toBeAdded; //Temp arraylist for HitObjects that to be added
    ArrayList<HitObject> toBeMoved; //tmp
    ArrayList<HitObject> copyClipboard; //tmp
    ArrayList<int[]> breakPoints;
    HitObject selectedNote;
    int sliderPointIndex = 0;
    boolean sliderPointAdd = false;
    int sliderPointAddX = 0;
    int sliderPointAddY = 0;
    int sliderTmpOffset = 0;
    private Bitmap sliderBodyTmp;
    float noteAngle;
    Iterator<TimingPoint> TimingPoints_iter;
    Iterator<HitObject> HitObjects_iter;

    public static int[] comboColor; //should parse actual combo color from map - need to be fixed
    public static ArrayList<Integer> comboColorArray = new ArrayList<>();
    public static int comboColorCount = 0;

    boolean MP_PREPARED = false; //Is MediaPlayer prepared?
    boolean songCompleted = false;

    boolean kiai; //Kiai status
    boolean touchUP = true;
    boolean isAnySelected = false;
    int bgDim = 100; //0 ~ 255, lower is darker
    int selectCount = 0; //Counter for selected units
    int drawCount = 0; //Counter for drawing units
    long millis_draw = 0;
    long millis_tp = 0;
    long millis_UI = 0;

    float firstClick_x, firstClick_y, dragging_x, dragging_y;
    float touch_x, touch_y; //Information of touch coordinates
    long lastClick_ms = 0;
    int firstClick_offset;
    boolean preventSelection = false;

    int FPS, frameCounter;
    long lastFPStime;

    //About DEBUG / OPTIONS
    boolean DRAW_DEBUG = false; //Debuggable
    boolean showCoordinates = false;
    float timelineZoomScale = 1.20f;
    float prevZoomScale = 1.20f;
    double _diffX = 0d;
    Dialog songSetupDialog;

    boolean multiSelect = false;

    File hitsound_file;

    Bitmap bg, grid;
    Bitmap[] FONT_NUMBERS = new Bitmap[10];
    Bitmap[] FONT_ALPHABET = new Bitmap[26];
    Bitmap[] FONT_ALPHABET_UPPERCASE = new Bitmap[26];
    Bitmap[] FONT_ALPHABET_RED = new Bitmap[26];
    Bitmap[] FONT_ALPHABET_UPPERCASE_RED = new Bitmap[26];
    Bitmap FONT_COLON, FONT_PERCENT, FONT_DOT, FONT_HYPHEN, FONT_SLASH, FONT_DEGREE;
    Bitmap[] FONT_BRACKETS = new Bitmap[2];
    Bitmap BEATMAP_INFO;
    Bitmap ICON_PLAY, ICON_PAUSE, ICON_KIAI, ICON_CLIPBOARD, ICON_CLIPBOARD_R, ICON_RECYCLEBIN, ICON_SWITCH, ICON_LEFT, ICON_RIGHT, ICON_ROTATE, ICON_SCALE, ICON_SLIDERCONVERT, ICON_VFLIP, ICON_HFLIP, ICON_SLIDERSETTING;
    Bitmap ICON_playback;
    Bitmap ICON_VERSION, ICON_SONGSETUP, ICON_TIMINGSETUP;
    Bitmap ICON_SELECT, ICON_SELECTALL, ICON_DESELECTALL, ICON_NC;
    Bitmap ICON_SCROLL;
    Bitmap ICON_SIDEBLACK, ICON_SIDEWHITE, ICON_SELECTION, ICON_CIRCLE, ICON_SLIDER, ICON_SPINNER;
    Bitmap background;

    final char[] ALPHABET = "abcdefghijklmnopqrstuvwxyz".toCharArray();
    final char[] ALPHABET_UPPERCASE = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".toCharArray();
    int HITSOUND_OFFSET = -90;

    DecimalFormat dec2_2 = new DecimalFormat("00.00");
    DecimalFormat dec1_2 = new DecimalFormat("0.00");
    DecimalFormat dec1_3 = new DecimalFormat("0.000");
    DecimalFormat dec1_5 = new DecimalFormat("0.00000");
    DecimalFormat dec3 = new DecimalFormat("000");
    DecimalFormat dec2 = new DecimalFormat("00");
    DecimalFormat dec1 = new DecimalFormat("#.##");

    //CONST & STATUS
    final int TEXT_ALIGN_LEFT = 0;
    final int TEXT_ALIGN_MIDDLE = 1;
    final int TEXT_ALIGN_RIGHT = 2;

    boolean TIMELINE_MODE = false;
    final boolean OVERALL_VIEW = false;
    final boolean TIMELINE_VIEW = true;

    int editMode = 0; //SELECTION
    final int MODE_SELECTION = 0;
    final int MODE_CIRCLE = 1;
    final int MODE_SLIDER = 2;
    final int MODE_SPINNER = 3;
    final String[] MODE_STRING = {"Selection", "Circle", "Slider", "Spinner"};

    private long sliderRecycleMs = 0;

    boolean isSongsetupOpened = false;

    GLPaint paint;
    CanvasGL.BitmapMatrix matrix = new CanvasGL.BitmapMatrix();
    Canvas _canvas;
    Paint _paint;

    String appVersion = "v0.03";

    IjkMediaPlayer mp;

    public Editor(Context context) {
        super(context);

        DisplayMetrics metrics = new DisplayMetrics();
        ((Activity)context).getWindowManager().getDefaultDisplay().getRealMetrics(metrics);
        w = metrics.widthPixels;
        h = metrics.heightPixels;

        g = h*.8f/384f;
        fontSize = (int)(g * 16);

        left =  (w*.5f - h*.8f*512f/384f/2);
        top = h*.1f;

        effects = new SoundPool(64, AudioManager.STREAM_MUSIC, 5);
        hsId = effects.load(getContext(), R.raw.hitsound, 1);

        TimingPoints = new ArrayList<>();
        HitObjects = new ArrayList<>();
        toBeAdded = new ArrayList<>();
        toBeMoved = new ArrayList<>();
        copyClipboard = new ArrayList<>();
        comboColorArray = new ArrayList<>();

        breakPoints = new ArrayList<>(); //tmp



        try {
            AR = -1;

            InputStream is = new ByteArrayInputStream(s.toString().getBytes()); // read it with BufferedReader
            BufferedReader br = new BufferedReader(new InputStreamReader(is));

            Koohii.Map beatmap = new Koohii.Parser().map(br);
            Koohii.DiffCalc stars = new Koohii.DiffCalc().calc(beatmap);
            Koohii.PPv2 pp = new Koohii.PPv2(stars.aim, stars.speed, beatmap);
            SR = stars.total;
            SR_DT = stars.calc(Koohii.mods_from_str("DT")).total;
            SR_HT = stars.calc(Koohii.mods_from_str("HT")).total;
            PP_total = pp.total;
            PP_acc = pp.acc;
            PP_aim = pp.aim;
            PP_speed = pp.speed;
        }catch(Exception e){

        }

            String[] lines = s.toString().split(System.getProperty("line.separator")); //Parsing .osu
            header = "";
            int colorCounter = 0;
            for(String str : lines){
                if(str.isEmpty())continue;
                if(str.contains("osu file format")){
                    header ="";
                    fileFormatVersion = Integer.parseInt(str.split("v")[1]);
                }
                if(str.contains("[") && str.contains("]")){header=str; continue;}
                switch (header) {
                    case "[General]":
                        if (str.contains("AudioFilename:")) audioFilename = str.split(": ")[1];
                        if (str.contains("AudioLeadIn:")) audioLeadIn = Integer.parseInt(str.split(":")[1].replace(" ", ""));
                        if (str.contains("PreviewTime:")) previewTime = Integer.parseInt(str.split(":")[1].replace(" ", ""));
                        if (str.contains("Countdown:")) countdown = Integer.parseInt(str.split(":")[1].replace(" ", ""));
                        if (str.contains("SampleSet:")) sampleSet = str.split(":")[1].replace(" ", "");
                        if (str.contains("StackLeniency:")) stackLeniency = Double.parseDouble(str.split(":")[1].replace(" ", ""));
                        if (str.contains("Mode:")) mode = Integer.parseInt(str.split(":")[1].replace(" ", ""));
                        if (str.contains("LetterboxInBreaks:")) letterboxInBreaks = Integer.parseInt(str.split(":")[1].replace(" ", ""));
                        if (str.contains("EpilepsyWarning:")) epilepsyWarning = Integer.parseInt(str.split(":")[1].replace(" ", ""));
                        if (str.contains("WidescreenStoryboard:")) widescreenStoryboard = Integer.parseInt(str.split(":")[1].replace(" ", ""));
                        break;
                    case "[Editor]":
                        if (str.contains("Bookmarks:")){
                            String[] s = (str.split(": ")[1]).split(",");
                            bookmarks = new int[s.length];
                            for(int i=0; i<s.length; i++) bookmarks[i] = Integer.parseInt(s[i]);
                        }
                        if (str.contains("DistanceSpacing:")) distanceSpacing = Float.parseFloat(str.split(":")[1].replace(" ", ""));
                        //if (str.contains("BeatDivisor:")) beatDivisor = Integer.parseInt(str.split(": ")[1]);
                        if (str.contains("GridSize:")) gridSize = Integer.parseInt(str.split(":")[1].replace(" ", ""));
                        if (str.contains("TimelineZoom:")) timelineZoomScale = Float.parseFloat(str.split(":")[1].replace(" ", ""));

                    case "[Metadata]":
                        if (str.contains("Title:")) title = str.split(":")[1];
                        if (str.contains("TitleUnicode:") && str.split(":").length > 1) titleUnicode = str.split(":")[1];
                        if (str.contains("Artist:") && str.split(":").length > 1) artist = str.split(":")[1];
                        if (str.contains("ArtistUnicode:") && str.split(":").length > 1) artistUnicode = str.split(":")[1];
                        if (str.contains("Version:") && str.split(":").length > 1) version = str.split(":")[1];
                        if (str.contains("Creator:") && str.split(":").length > 1) creator = str.split(":")[1];
                        if (str.contains("Source:") && str.split(":").length > 1) source = str.split(":")[1];
                        if (str.contains("Tags:") && str.split(":").length > 1) tags = str.split(":")[1];
                        if (str.contains("BeatmapID:") && str.split(":").length > 1) beatmapID = Integer.parseInt(str.split(":")[1].replace(" ", ""));
                        if (str.contains("BeatmapSetID:") && str.split(":").length > 1) beatmapsetID = Integer.parseInt(str.split(":")[1].replace(" ", ""));
                        break;
                    case "[Difficulty]":
                        if (str.contains("HPDrainRate:")) HP = Float.parseFloat(str.split(":")[1]);
                        if (str.contains("CircleSize:")) {
                            CS = Float.parseFloat(str.split(":")[1]);
                            CircleSize = ((w*1.2f) / 16) * (1 - (0.7f * (CS - 5) / 5));
                            maxCircleSize = ((w*1.2f) / 16) * (1 - (0.7f * (0 - 5) / 5));
                            CS5CircleSize = ((w*1.2f) / 16) * (1 - (0.7f * (5 - 5) / 5));
                        }
                        if (str.contains("OverallDifficulty:")) OD = Float.parseFloat(str.split(":")[1]);
                        if (str.contains("ApproachRate:")) AR = Float.parseFloat(str.split(":")[1]);
                        if (str.contains("SliderMultiplier:")) SV = Float.parseFloat(str.split(":")[1]);
                        if (str.contains("SliderTickRate:")) ST = Float.parseFloat(str.split(":")[1]);
                        break;
                    case "[Events]":
                        if (str.contains("0,0,\"")) bgfileName = str.substring(5, str.indexOf("\"", 5));
                        if (str.startsWith("2,")){
                            int[] i = {Integer.parseInt(str.substring(2, str.indexOf(",", 2))), Integer.parseInt(str.substring(str.indexOf(",", 3)+1))};
                            breakPoints.add(i);
                        }
                        break;
                    case "[TimingPoints]":
                        TimingPoints.add(new TimingPoint(str));
                        break;
                    case "[Colours]":
                        String c = str.split(" : ")[1];
                        String[] s = c.split(",");
                        int cc = Color.rgb(Integer.parseInt(s[0]), Integer.parseInt(s[1]), Integer.parseInt(s[2]));
                        comboColorArray.add(cc);
                        break;
                    case "[HitObjects]":
                        HitObjects.add(new HitObject(str));
                        break;
                    default:
                        break;
                }
            }
        if(comboColorArray.size() == 0){
            comboColorArray.clear();
            comboColorArray.add(Color.rgb(255, 192, 0));
            comboColorArray.add(Color.rgb(0, 202, 0));
            comboColorArray.add(Color.rgb(18, 124, 255));
            comboColorArray.add(Color.rgb(242, 24, 57));
        }
            comboColor = new int[comboColorArray.size()];
            for(int i=0; i<comboColorArray.size(); i++){
                comboColor[i] = comboColorArray.get(i);
            }
            if(AR == -1) AR = OD; //if cannot found AR => for old format mapsets


            initGraphics();

            TimingPoints_iter = TimingPoints.iterator();
            HitObjects_iter = HitObjects.iterator();
        try {
            final String audioFileExtensionName = audioFilename.substring(audioFilename.lastIndexOf("."));

                // to execute "ffmpeg -version" command you just need to pass "-version"
                //String path1 = (prefLoad("location") + audioFilename).replace(" ", "_");
                //String path2 = (prefLoad("location") + audioFilename.replace(audioFileExtensionName, ".ogg")).replace(" ", "_");
                String path1 = (prefLoad("location") + audioFilename);
                String path2 = (prefLoad("location") + "audio_converted.mp3");
                String tmpcmd = "-i\n" + path1 + "\n-ar\n44100\n-b:a\n192k\n" + path2;
                File output = new File(path2);
            String cmd[] = tmpcmd.split("\n");

            audioplayerSetup();
            //mp3Convert();
            bg = base();
            grid = grid();

            try {
                Uri uri = Uri.parse("android.resource://" + context.getPackageName() + "/" + R.raw.hitsound);
                hitsound_file = new File(uri.getPath());

            } catch (IllegalArgumentException e) {
                e.printStackTrace();
            } catch (SecurityException e) {
                e.printStackTrace();
            } catch (IllegalStateException e) {
                e.printStackTrace();
            }

        }catch (Exception e){

        }

        background = BitmapFactory.decodeFile(prefLoad("location") + bgfileName);
        if(background != null) {
            float bgratio = background.getWidth() / background.getHeight();
            float Wratio = (float) w / (float) background.getWidth();
            float Hratio = (float) h / (float) background.getHeight();

            if (Wratio < Hratio) {
                background = Bitmap.createScaledBitmap(background, (int) (background.getWidth() * Hratio), (int) (background.getHeight() * Hratio), true);
            } else {
                background = Bitmap.createScaledBitmap(background, (int) (background.getWidth() * Wratio), (int) (background.getHeight() * Wratio), true);
            }
        }

        paint = new GLPaint();
        initFonts();
    }

    void audioplayerSetup(){
        try {
            mp = new IjkMediaPlayer();
            mp.setDataSource(prefLoad("location") + audioFilename);
            mp.prepareAsync();
            mp.setOnPreparedListener(new IMediaPlayer.OnPreparedListener() {
                @Override
                public void onPrepared(IMediaPlayer iMediaPlayer) {
                    //mp.start();
                    MP_PREPARED = true;
                    songDuration = (int)mp.getDuration();
                    bg = base();
                    mp.pause();
                }
            });
            mp.setOnSeekCompleteListener(new IMediaPlayer.OnSeekCompleteListener() {
                @Override
                public void onSeekComplete(IMediaPlayer iMediaPlayer) {
                    Log.e("MusicPlayer", "Seek Complete : " + iMediaPlayer.getCurrentPosition());
                    Log.e("MusicPlayer", "seekPosition : " + seekPosition);
                    lastMillis = System.currentTimeMillis();
                    lastTime = iMediaPlayer.getCurrentPosition();
                    offsetAdjust = true;
                    offsetAdjustMs = System.currentTimeMillis() + 1000;
                    isSeeking = false;
                    //currentPosition = seekPosition;
                }
            });
        }catch (Exception e){

        }

        int latency = 0;

        AudioManager am = (AudioManager)(getContext().getSystemService((Context.AUDIO_SERVICE)));
        try{
            Method m = am.getClass().getMethod("getOutputLatency", int.class);
            latency = (Integer)m.invoke(am, AudioManager.STREAM_MUSIC);
        }catch(Exception e){
        }

        //HITSOUND_OFFSET = -(latency);
        HITSOUND_OFFSET = 100;
    }

    public Editor(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public void initFonts(){
        Paint paint = new Paint();
        paint.setTextSize(fontSize);
        paint.setColor(Color.WHITE);
        paint.setAntiAlias(true);

        for(int i=0; i<10; i++) {
            FONT_NUMBERS[i] = Bitmap.createBitmap((int)paint.measureText(i+""), fontSize, Bitmap.Config.ARGB_4444);
            Canvas canvas = new Canvas(FONT_NUMBERS[i]);
            canvas.drawText(i+"", 0, fontSize, paint);
        }
        for(int i=0; i<26; i++) {
            FONT_ALPHABET[i] = Bitmap.createBitmap((int)paint.measureText(ALPHABET[i]+""), (int)(fontSize * 1.2f), Bitmap.Config.ARGB_4444);
            Canvas canvas = new Canvas(FONT_ALPHABET[i]);
            canvas.drawText(""+ALPHABET[i], 0, fontSize, paint);
            FONT_ALPHABET_UPPERCASE[i] = Bitmap.createBitmap((int)paint.measureText(ALPHABET_UPPERCASE[i]+""), (int)(fontSize * 1.2f), Bitmap.Config.ARGB_4444);
            canvas = new Canvas(FONT_ALPHABET_UPPERCASE[i]);
            canvas.drawText(""+ALPHABET_UPPERCASE[i], 0, fontSize, paint);
        }
        paint.setColor(Color.RED);
        for(int i=0; i<26; i++) {
            FONT_ALPHABET_RED[i] = Bitmap.createBitmap((int)paint.measureText(ALPHABET[i]+""), (int)(fontSize * 1.2f), Bitmap.Config.ARGB_4444);
            Canvas canvas = new Canvas(FONT_ALPHABET_RED[i]);
            canvas.drawText(""+ALPHABET[i], 0, fontSize, paint);
            FONT_ALPHABET_UPPERCASE_RED[i] = Bitmap.createBitmap((int)paint.measureText(ALPHABET_UPPERCASE[i]+""), (int)(fontSize * 1.2f), Bitmap.Config.ARGB_4444);
            canvas = new Canvas(FONT_ALPHABET_UPPERCASE_RED[i]);
            canvas.drawText(""+ALPHABET_UPPERCASE[i], 0, fontSize, paint);
        }
        paint.setColor(Color.WHITE);
        FONT_COLON = Bitmap.createBitmap((int)paint.measureText(":"), fontSize, Bitmap.Config.ARGB_4444);
        Canvas canvas = new Canvas(FONT_COLON);
        canvas.drawText(":", 0, fontSize, paint);
        FONT_PERCENT = Bitmap.createBitmap((int)paint.measureText("%"), fontSize, Bitmap.Config.ARGB_4444);
        canvas = new Canvas(FONT_PERCENT);
        canvas.drawText("%", 0, fontSize, paint);
        FONT_DOT = Bitmap.createBitmap((int)paint.measureText("."), fontSize, Bitmap.Config.ARGB_4444);
        canvas = new Canvas(FONT_DOT);
        canvas.drawText(".", 0, 40, paint);
        FONT_HYPHEN = Bitmap.createBitmap((int)paint.measureText("-"), fontSize, Bitmap.Config.ARGB_4444);
        canvas = new Canvas(FONT_HYPHEN);
        canvas.drawText("-", 0, 40, paint);
        FONT_BRACKETS[0] = Bitmap.createBitmap((int)paint.measureText("("), fontSize, Bitmap.Config.ARGB_4444);
        canvas = new Canvas(FONT_BRACKETS[0]);
        canvas.drawText("[", 0, 40, paint);
        FONT_BRACKETS[1] = Bitmap.createBitmap((int)paint.measureText(")"), fontSize, Bitmap.Config.ARGB_4444);
        canvas = new Canvas(FONT_BRACKETS[1]);
        canvas.drawText("]", 0, 40, paint);
        FONT_SLASH = Bitmap.createBitmap((int)paint.measureText("/"), fontSize, Bitmap.Config.ARGB_4444);
        canvas = new Canvas(FONT_SLASH);
        canvas.drawText("/", 0, 40, paint);
        FONT_DEGREE = Bitmap.createBitmap((int)paint.measureText("º"), fontSize, Bitmap.Config.ARGB_4444);
        canvas = new Canvas(FONT_DEGREE);
        canvas.drawText("°", 0, 40, paint);
        BEATMAP_INFO = Bitmap.createBitmap((int)paint.measureText(artist + " - " + title + " [" + version + "] by " + creator), 50, Bitmap.Config.ARGB_4444);
        canvas = new Canvas(BEATMAP_INFO);
        //canvas.drawText(artist + " - " + title + " [" + version + "] by " + creator, 0, 40, paint);

        ICON_VERSION = Bitmap.createBitmap((int)paint.measureText(appVersion), fontSize, Bitmap.Config.ARGB_4444);
        canvas = new Canvas(ICON_VERSION);
        canvas.drawText(appVersion, 0, fontSize, paint);

        ICON_SONGSETUP = Bitmap.createBitmap((int)paint.measureText("Song Setup"), (int)(fontSize * 1.2f), Bitmap.Config.ARGB_4444);
        canvas = new Canvas(ICON_SONGSETUP);
        canvas.drawText("Song Setup", 0, fontSize, paint);

        ICON_TIMINGSETUP = Bitmap.createBitmap((int)paint.measureText("Timing"), (int)(fontSize * 1.2f), Bitmap.Config.ARGB_4444);
        canvas = new Canvas(ICON_TIMINGSETUP);
        canvas.drawText("Timing", 0, fontSize, paint);

        canvas.drawRect(0, h*0.1f, w*0.05f, h*0.15f, paint);
        ICON_KIAI = Bitmap.createBitmap((int)(w*0.08f), (int)(h*0.2f), Bitmap.Config.ARGB_4444);
        canvas = new Canvas(ICON_KIAI);
        paint.setTextSize(fontSize);
        canvas.drawText("Kiai", 0, fontSize, paint);

        ICON_playback = Bitmap.createBitmap((int)(w * .25f), (int)(g*24*10), Bitmap.Config.ARGB_4444);
        canvas = new Canvas(ICON_playback);
        paint.setColor(Color.WHITE);
        paint.setStrokeWidth(g*4);
        paint.setTextAlign(Paint.Align.LEFT);
        paint.setTextSize(g*24);
        canvas.drawLine(0, 0, 0, g*24*8, paint);
        canvas.drawText("1.5x", g*16, g*24, paint);
        canvas.drawText("1.0x", g*16, g*24*3, paint);
        canvas.drawText("0.75x", g*16, g*24*5, paint);
        canvas.drawText("0.5x", g*16, g*24*7, paint);
        //canvas.drawText("0.25x", g*16, g*24*9, paint);

        ICON_PLAY = BitmapFactory.decodeResource(getResources(), R.drawable.play);
        ICON_PAUSE = BitmapFactory.decodeResource(getResources(), R.drawable.pause);
        ICON_CLIPBOARD = BitmapFactory.decodeResource(getResources(), R.drawable.clipboard);
        ICON_CLIPBOARD_R = BitmapFactory.decodeResource(getResources(), R.drawable.clipboard_r);
        ICON_RECYCLEBIN = BitmapFactory.decodeResource(getResources(), R.drawable.recycle_bin);
        ICON_SWITCH = BitmapFactory.decodeResource(getResources(), R.drawable.shuffle);
        ICON_LEFT = BitmapFactory.decodeResource(getResources(), R.drawable.left);
        ICON_RIGHT = BitmapFactory.decodeResource(getResources(), R.drawable.right);
        ICON_VFLIP = BitmapFactory.decodeResource(getResources(), R.drawable.vflip);
        ICON_HFLIP = BitmapFactory.decodeResource(getResources(), R.drawable.hflip);
        ICON_SLIDERCONVERT = BitmapFactory.decodeResource(getResources(), R.drawable.sliderconvert);
        ICON_SLIDERSETTING = BitmapFactory.decodeResource(getResources(), R.drawable.slidersetting);
        ICON_ROTATE = BitmapFactory.decodeResource(getResources(), R.drawable.rotate);
        ICON_SCALE = BitmapFactory.decodeResource(getResources(), R.drawable.scale);
        ICON_SELECT = BitmapFactory.decodeResource(getResources(), R.drawable.select);
        ICON_SELECTALL = BitmapFactory.decodeResource(getResources(), R.drawable.selectall);
        ICON_DESELECTALL = BitmapFactory.decodeResource(getResources(), R.drawable.deselectall);
        ICON_SCROLL = BitmapFactory.decodeResource(getResources(), R.drawable.scroll);
        ICON_NC = BitmapFactory.decodeResource(getResources(), R.drawable.nc);
        ICON_SIDEBLACK = BitmapFactory.decodeResource(getResources(), R.drawable.siderect_black);
        ICON_SIDEWHITE = BitmapFactory.decodeResource(getResources(), R.drawable.siderect_white);
        ICON_SELECTION = BitmapFactory.decodeResource(getResources(), R.drawable.btnimg_selection);
        ICON_CIRCLE = BitmapFactory.decodeResource(getResources(), R.drawable.btnimg_circle);
        ICON_SLIDER = BitmapFactory.decodeResource(getResources(), R.drawable.btnimg_slider);
        ICON_SPINNER = BitmapFactory.decodeResource(getResources(), R.drawable.btnimg_spinner);
        ICON_PLAY = Bitmap.createScaledBitmap(ICON_PLAY, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_PAUSE = Bitmap.createScaledBitmap(ICON_PAUSE, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_CLIPBOARD = Bitmap.createScaledBitmap(ICON_CLIPBOARD, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_CLIPBOARD_R = Bitmap.createScaledBitmap(ICON_CLIPBOARD_R, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_RECYCLEBIN = Bitmap.createScaledBitmap(ICON_RECYCLEBIN, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_SWITCH = Bitmap.createScaledBitmap(ICON_SWITCH, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_LEFT = Bitmap.createScaledBitmap(ICON_LEFT, (int)(w*0.04f), (int)(w*0.04f), true);
        ICON_RIGHT = Bitmap.createScaledBitmap(ICON_RIGHT, (int)(w*0.04f), (int)(w*0.04f), true);
        ICON_VFLIP = Bitmap.createScaledBitmap(ICON_VFLIP, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_HFLIP = Bitmap.createScaledBitmap(ICON_HFLIP, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_ROTATE = Bitmap.createScaledBitmap(ICON_ROTATE, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_SCALE = Bitmap.createScaledBitmap(ICON_SCALE, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_SLIDERCONVERT = Bitmap.createScaledBitmap(ICON_SLIDERCONVERT, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_SLIDERSETTING = Bitmap.createScaledBitmap(ICON_SLIDERSETTING, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_SELECT = Bitmap.createScaledBitmap(ICON_SELECT, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_SELECTALL = Bitmap.createScaledBitmap(ICON_SELECTALL, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_DESELECTALL = Bitmap.createScaledBitmap(ICON_DESELECTALL, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_SCROLL = Bitmap.createScaledBitmap(ICON_SCROLL, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_NC = Bitmap.createScaledBitmap(ICON_NC, (int)(w*0.06f), (int)(w*0.06f), true);
        ICON_SELECTION = Bitmap.createScaledBitmap(ICON_SELECTION, (int)(w*0.1f), (int)(w*0.087f), true);
        ICON_CIRCLE = Bitmap.createScaledBitmap(ICON_CIRCLE, (int)(w*0.1f), (int)(w*0.087f), true);
        ICON_SLIDER = Bitmap.createScaledBitmap(ICON_SLIDER, (int)(w*0.1f), (int)(w*0.087f), true);
        ICON_SPINNER = Bitmap.createScaledBitmap(ICON_SPINNER, (int)(w*0.1f), (int)(w*0.087f), true);
        ICON_SIDEBLACK = Bitmap.createScaledBitmap(ICON_SIDEBLACK, (int)(w*0.1f), (int)(w*0.087f), true);
        ICON_SIDEWHITE = Bitmap.createScaledBitmap(ICON_SIDEWHITE, (int)(w*0.1f), (int)(w*0.087f), true);
    }

    public void initGraphics(){
        ApproachingTime = 1950 - AR * 150;
        CircleSize = ((w*1.2f) / 16) * (1 - (0.7f * (CS - 5) / 5));
        stackTime = ApproachingTime * stackLeniency;
        stackpx = (int)(5 - CS/2);

        Bitmap _hitcircle = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.hitcircle);
        _hitcircle = Bitmap.createScaledBitmap(_hitcircle, (int) (CircleSize), (int) (CircleSize), true);
        Bitmap _approachcircle = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.approachcircle);
        _approachcircle = Bitmap.createScaledBitmap(_approachcircle, (int) (CircleSize), (int) (CircleSize), true);
        sliderfollowcircle = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.sliderfollowcircle);
        sliderfollowcircle = Bitmap.createScaledBitmap(sliderfollowcircle, (int) (2 * CircleSize), (int) (2 * CircleSize), true);
        reversearrow = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.reversearrow);
        reversearrow = Bitmap.createScaledBitmap(reversearrow, (int) (CircleSize), (int) (CircleSize), true);
        sliderBall = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.sliderb);
        sliderBall = Bitmap.createScaledBitmap(sliderBall, (int) (CircleSize*1.2), (int) (CircleSize*1.2), true);
        hitcircleselect = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.hitcircleselect);
        hitcircleselect = Bitmap.createScaledBitmap(hitcircleselect, (int) (CircleSize*2), (int) (CircleSize*2), true);

        default_img[0] = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.default_0);
        default_img[1] = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.default_1);
        default_img[2] = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.default_2);
        default_img[3] = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.default_3);
        default_img[4] = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.default_4);
        default_img[5] = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.default_5);
        default_img[6] = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.default_6);
        default_img[7] = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.default_7);
        default_img[8] = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.default_8);
        default_img[9] = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.default_9);

        _paint = new Paint();
        _paint.setAntiAlias(true);

        for(int i=0; i<10; i++){
            default_img[i] = Bitmap.createScaledBitmap(default_img[i], (int) (default_img[i].getWidth()*0.4f), (int) (default_img[i].getHeight()*0.4f), true);
        }

        hitcircle = new Bitmap[comboColor.length + 1];
        approachcircle = new Bitmap[comboColor.length];

        for (int i = 0; i < comboColor.length + 1; i++) {
            Paint paint = new Paint();
            ColorFilter filter;
            if(i != comboColor.length) filter = new PorterDuffColorFilter((comboColor[i]), PorterDuff.Mode.SRC_ATOP);
            else filter = new PorterDuffColorFilter((Color.rgb(255, 255, 255)), PorterDuff.Mode.SRC_ATOP);
            paint.setColorFilter(filter);
            hitcircle[i] = Bitmap.createBitmap((int) CircleSize, (int) CircleSize, Bitmap.Config.ARGB_4444);
            Canvas cv = new Canvas(hitcircle[i]);
            cv.drawBitmap(_hitcircle, 0, 0, paint);

            if(i == comboColor.length ) break;

            approachcircle[i] = Bitmap.createBitmap((int) CircleSize, (int) CircleSize, Bitmap.Config.ARGB_8888);
            cv = new Canvas(approachcircle[i]);
            cv.drawBitmap(_approachcircle, 0, 0, paint);
        }

        hitcircleoverlay = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.hitcircleoverlay);
        hitcircleoverlay = Bitmap.createScaledBitmap(hitcircleoverlay, (int) (CircleSize), (int) (CircleSize), true);
        hitcircle_hit = BitmapFactory.decodeResource(getContext().getResources(), R.drawable.hitcircle);
        hitcircle_hit = Bitmap.createScaledBitmap(hitcircle_hit, (int) (CircleSize), (int) (CircleSize), true);


    }

    @Override
    protected void onGLDraw(ICanvasGL canvas) {
        try {
            frameCounter++;
            if (isPlaying)
                currentPosition = (int) (lastTime + (float) ((int) (System.currentTimeMillis() - lastMillis)) * playbackSpeed) + (int) (HITSOUND_OFFSET * playbackSpeed);
            //if(isPlaying) currentPosition = (int)(mp.getCurrentPosition() * playbackSpeed + HITSOUND_OFFSET);
            percentage = ((float) currentPosition / (float) songDuration) * 100f;
            if (percentage >= 100 && MP_PREPARED) {
                lastMillis = System.currentTimeMillis();
                lastTime = currentPosition;
                isPlaying = false;
                //mAudioPlayer.pause();
                mp.pause();
                //mediaPlayer.pause();
            }

            drawBG(canvas);
            canvas.drawBitmap(bg, 0, 0);

            //drawText(canvas, artist + " - " + title , 0,h*0.025f, 1.5f, TEXT_ALIGN_LEFT);

            if (!MP_PREPARED) {
                drawText(canvas, "Loading files. Please wait...", w / 2, h / 2, 1f, TEXT_ALIGN_MIDDLE, Color.WHITE);
                return;
            }

            canvas.drawBitmap(grid, 0, 0);
            if (TIMELINE_MODE) drawTimeline(canvas);
            setTimingPointsOverall();
            if(placingSliderStatus){
                paint.setColor(Color.argb(150, 60, 60, 60));
                canvas.drawRect(0, 0, w, h, paint);
            }
            _playHitObjects(canvas);
            SelectObject(canvas);
            editUI(canvas);


            if (removeStatus) removeHitObject();

            draw_UI(canvas);

            if(popupStatus && !isPlaying) drawPopup(canvas);

            if (System.currentTimeMillis() >= lastFPStime + 1000) {
                lastFPStime = System.currentTimeMillis();
                FPS = frameCounter;
                frameCounter = 0;
            }

            if (System.currentTimeMillis() <= offsetAdjustMs) {
                offsetAdjust = false;

                lastTime = mp.getCurrentPosition();
                lastMillis = System.currentTimeMillis();
            }
        }catch(Exception e){
            //Log.e("ERROR", e.getMessage()+"");
        }

    }

    void saveFile(){
        try {
            String filename =  "/" + artist + " - " + title + " (" + creator + ") [" + version + "].osu";
            BufferedWriter bfw = new BufferedWriter(new FileWriter(prefLoad("location") + filename));
            bfw.write("osu file format v14\n\n");
            bfw.write("[General]\n");
            bfw.write("AudioFilename: " + audioFilename + "\n");
            bfw.write("AudioLeadIn: " + audioLeadIn + "\n");
            bfw.write("PreviewTime: " + previewTime + "\n");
            bfw.write("Countdown: " + countdown + "\n");
            bfw.write("Sampleset: " + sampleSet + "\n");
            bfw.write("StackLeniency: " + stackLeniency + "\n");
            bfw.write("Mode: 0\n");
            bfw.write("LetterboxInBreaks: " + letterboxInBreaks + "\n");
            bfw.write("WidescreenStoryboard: " + widescreenStoryboard + "\n\n");
            bfw.write("[Editor]\n");
            String bookmarkStr = "";
            if(bookmarks != null){
                for(int i=0; i<bookmarks.length; i++){
                    bookmarkStr += bookmarks[i]+"";
                    if(i<bookmarks.length-1) bookmarkStr += ",";
                }
            }
            if(!bookmarkStr.equals(""))bfw.write("Bookmarks: " + bookmarkStr + "\n");
            bfw.write("DistanceSpacing: " + distanceSpacing + "\n");
            bfw.write("BeatDivisor: " + beatDivisor[beatDivIndex] + "\n");
            bfw.write("GridSize: " + gridSize + "\n");
            bfw.write("TimelineZoom: " + timelineZoomScale + "\n\n");
            bfw.write("[Metadata]\n");
            bfw.write("Title:" + title + "\n");
            bfw.write("TitleUnicode:" + titleUnicode + "\n");
            bfw.write("Artist:" + artist + "\n");
            bfw.write("ArtistUnicode:" + artistUnicode + "\n");
            bfw.write("Creator:" + creator + "\n");
            bfw.write("Version:" + version + "\n");
            bfw.write("Source:" + source + "\n");
            bfw.write("Tags:" + tags + "\n");
            bfw.write("BeatmapID:" + beatmapID + "\n");
            bfw.write("BeatmapSetID:" + beatmapsetID + "\n");
            bfw.write("\n");
            bfw.write("[Difficulty]\n");
            bfw.write("HPDrainRate:" + dec1.format(HP) + "\n");
            bfw.write("CircleSize:" + dec1.format(CS) + "\n");
            bfw.write("OverallDifficulty:" + dec1.format(OD) + "\n");
            bfw.write("ApproachRate:" + dec1.format(AR) + "\n");
            bfw.write("SliderMultiplier:" + SV + "\n");
            bfw.write("SliderTickRate:" + dec1.format(ST) + "\n\n");
            bfw.write("[Events]\n");
            bfw.write("0,0,\"" + bgfileName + "\",0,0\n");
            if(breakPoints.size() > 0){
                for(int[] i : breakPoints){
                    bfw.write("2," + i[0] + "," + i[1] + "\n");
                }
            }
            bfw.write("\n");
            bfw.write("[TimingPoints]\n");
            for(TimingPoint tp : TimingPoints){
                if(tp.speed%1 == 0) bfw.write(tp.offset + "," + dec1.format(tp.speed) + "," + tp.metro + "," + tp.sampleset + "," + tp.customnum + "," + tp.volume + "," + ((tp.status) ? 1 : 0) + "," + ((tp.kiai) ? 1 : 0) + "\n");
                else bfw.write(tp.offset + "," + tp.speed + "," + tp.metro + "," + tp.sampleset + "," + tp.customnum + "," + tp.volume + "," + ((tp.status) ? 1 : 0) + "," + ((tp.kiai) ? 1 : 0) + "\n");
            }
            bfw.write("\n");
            if(comboColorArray.size() > 0){
                bfw.write("[Colours]\n");
                for(int i=0; i<comboColor.length; i++){
                    int color = comboColor[i];
                    int red = (color >> 16) & 0xFF;
                    int green = (color >> 8) & 0xFF;
                    int blue = color & 0xFF;
                    bfw.write("Combo" + i + " : " + red + "," + green + "," + blue + "\n");
                }
                bfw.write("\n");
            }
            bfw.write("[HitObjects]\n");
            for(HitObject ho : HitObjects){
                String s = "";
                ho.type = 0;
                if(ho.notetype.equals("circle")) ho.type += 1;
                if(ho.notetype.equals("slider")) ho.type += 2;
                if(ho.notetype.equals("spinner")) ho.type += 8;
                if(ho.skip > 0){
                    for(int i=2; i>=0; i--){
                        if(ho.skip >= Math.pow(2, i)){
                            ho.skip -= Math.pow(2, i);
                            ho.type += Math.pow(2, i+4);
                        }
                    }
                }
                if(ho.NC) ho.type += 4;
                s = dec1.format(ho.x) + "," + dec1.format(ho.y) + "," + ho.offset + "," + ho.type + "," + ho.hitsound;
                if(ho.notetype.equals("circle")){
                    s += "," + ho.extra;
                }else if(ho.notetype.equals("slider")){
                    s += "," + ho.sliderType;
                    for(int i=1; i<ho.sliderPoints.size() - 1; i++){
                        s += "|" + dec1.format(ho.sliderPoints.get(i).x) + ":" + dec1.format(ho.sliderPoints.get(i).y);
                    }
                    if(ho.extra.contains(",")) s += "," + ho.sliderRepeat + "," + dec1.format(ho.sliderLength) + ho.extra;
                    else s += "," + ho.sliderRepeat + "," + dec1.format(ho.sliderLength) + "," + ho.extra;
                }else{
                    s += "," + ho.spinnerEndOffset + "," + ho.extra;
                }
                bfw.write(s + "\n");
            }
            bfw.flush();
            bfw.close();

        } catch (Exception e) {
            Log.e("ERROR", e.getMessage());
        }
    }

    void editUI(ICanvasGL canvas){
        switch(editMode) {
            case MODE_SELECTION:
                if(dragging_x != -1 && !movingNoteStatus) drawDragArea(canvas);
                break;
            case MODE_CIRCLE:
                paint.setColor(Color.GRAY);
                //canvas.drawRect(50,150,50,150, paint);
                break;
        }
    }

    void draw_UI(ICanvasGL canvas){
        paint.setColor(Color.argb(120, 0,0,0));
        //canvas.drawRect(w*0.9f, h*0.75f, w*0.96f, h*0.75f+w*0.06f, paint);
        if(!isPlaying) canvas.drawBitmap(ICON_PLAY, (int)(w*0.92f), (int)(h*0.75f));
        else canvas.drawBitmap(ICON_PAUSE, (int)(w*0.92f), (int)(h*0.75f));

        //canvas.drawRect(w*0.9f, h*0.6f, w*0.96f, h*0.6f+w*0.06f, paint);
        canvas.drawBitmap(ICON_SWITCH, (int)(w*0.92f - h*0.15f), (int)(h*0.75f));

        //canvas.drawRect(w*0.9f, h*0.45f, w*0.96f, h*0.45f+w*0.06f, paint);
        if(!copyStatus) canvas.drawBitmap(ICON_CLIPBOARD, (int)(w*0.92f), (int)(h*0.6f));
        else canvas.drawBitmap(ICON_CLIPBOARD_R, (int)(w*0.92f), (int)(h*0.6f));

        //canvas.drawRect(w*0.9f, h*0.3f, w*0.96f, h*0.3f+w*0.06f, paint);

        if(selectCount > 0){
            canvas.drawBitmap(ICON_RECYCLEBIN, (int)(w*0.92f), (int)(h*0.45f));
            canvas.drawBitmap(ICON_VFLIP, (int)(w*0.92f - h*0.15f), (int)(h*0.45f));
            canvas.drawBitmap(ICON_HFLIP, (int)(w*0.92f - h*0.15f), (int)(h*0.6f));
            canvas.drawBitmap(ICON_ROTATE, (int)(w*0.92f - h*0.15f), (int)(h*0.3f));
            canvas.drawBitmap(ICON_SCALE, (int)(w*0.92f), (int)(h*0.3f));
        }


        if(selectCount == 1 && selectedNote.notetype.equals("slider")){
            canvas.drawBitmap(ICON_SLIDERCONVERT, (int)(w*0.92f - h*0.15f), (int)(h*0.15f));
            canvas.drawBitmap(ICON_SLIDERSETTING, (int)(w*0.92f), (int)(h*0.15f));
        }

        if(multiSelect){
            canvas.drawBitmap(ICON_SELECT, (int)(w*0.12f), (int)(h*0.75f));
        }else{
            canvas.setAlpha(100);
            canvas.drawBitmap(ICON_SELECT, (int)(w*0.12f), (int)(h*0.75f));
        }
         canvas.setAlpha(255);

        if(selectCount > 0){
            canvas.drawBitmap(ICON_DESELECTALL, (int)(w*0.12f), (int)(h*0.6f));
            canvas.drawBitmap(ICON_NC, (int)(w*0.12f), (int)(h*0.3f));
        }
        if(multiSelect) canvas.drawBitmap(ICON_SELECTALL, (int)(w*0.12f), (int)(h*0.45f));


        canvas.drawBitmap(ICON_VERSION, ICON_VERSION.getWidth()/2,ICON_VERSION.getHeight()/2);

        canvas.drawBitmap(ICON_SONGSETUP, w - ICON_SONGSETUP.getWidth(),ICON_SONGSETUP.getHeight()/2);

        canvas.drawBitmap(ICON_TIMINGSETUP, (int)(w - ICON_SONGSETUP.getWidth() - ICON_TIMINGSETUP.getWidth() - w*0.03f ), ICON_TIMINGSETUP.getHeight()/2);



        if(kiai){
            if(!TIMELINE_MODE){
                paint.setColor(Color.rgb(80,163,206));
                canvas.drawRect(0, h*0.15f, w*0.08f, h*0.22f, paint);
                paint.setColor(Color.rgb(40, 83, 106));
                int alpha = (int)((currentPosition%BPM_overall)/BPM_overall * 255f);
                canvas.setAlpha(alpha);
                canvas.drawRect(0, h*0.15f, w*0.075f, h*0.22f, paint);
                canvas.setAlpha(255);
                canvas.drawBitmap(ICON_KIAI, (int)(w*0.01f), (int)(h*0.15f));
            }else{
                paint.setColor(Color.rgb(80,163,206));
                canvas.drawRect(ICON_SIDEBLACK.getWidth(), h*0.15f, ICON_SIDEBLACK.getWidth() + w*0.08f, h*0.22f, paint);
                paint.setColor(Color.rgb(40, 83, 106));
                int alpha = (int)((currentPosition%BPM_overall)/BPM_overall * 255f);
                canvas.setAlpha(alpha);
                canvas.drawRect(ICON_SIDEBLACK.getWidth(), h*0.15f, ICON_SIDEBLACK.getWidth() + w*0.075f, h*0.22f, paint);
                canvas.setAlpha(255);
                canvas.drawBitmap(ICON_KIAI, (int)(ICON_SIDEBLACK.getWidth() + w*0.01f), (int)(h*0.15f));
            }
        }

        if(TIMELINE_MODE == TIMELINE_VIEW) {
            for(int i=0; i<4; i++){

                canvas.drawBitmap(ICON_SIDEBLACK, 0, (int)(h * 0.1f + h*0.2f*i));

                canvas.drawBitmap(ICON_SELECTION, 0, (int)(h * 0.1f));
                canvas.drawBitmap(ICON_CIRCLE, 0, (int)(h * 0.1f + h*0.2f*1));
                canvas.drawBitmap(ICON_SLIDER, 0, (int)(h * 0.1f + h*0.2f*2));
                canvas.drawBitmap(ICON_SPINNER, 0, (int)(h * 0.1f + h*0.2f*3));

                if(i == editMode) canvas.drawBitmap(ICON_SIDEWHITE, 0, (int)(h * 0.1f + h*0.2f*i));
            }
            canvas.drawBitmap(ICON_LEFT, (int)(w*0.45f - ICON_LEFT.getWidth()/2), (int)(h*0.04f - ICON_LEFT.getHeight()/2));
            canvas.drawBitmap(ICON_RIGHT, (int)(w*0.55f - ICON_LEFT.getWidth()/2), (int)(h*0.04f - ICON_LEFT.getHeight()/2));
            drawText(canvas,"1/"+beatDivisor[beatDivIndex], w*0.5f, h*0.01f, 1.25f, TEXT_ALIGN_MIDDLE, Color.WHITE);
        }


        drawText(canvas, dec2.format(currentPosition/60000) + ":" + dec2.format(currentPosition/1000%60) + ":" + dec3.format(currentPosition%1000), (int)(w*0.02f), h*0.9f, 1.0f, TEXT_ALIGN_LEFT, Color.WHITE);
        drawText(canvas, dec2_2.format(percentage)+"%", w*0.03f, h*0.95f, 1.0f, TEXT_ALIGN_LEFT, Color.WHITE);
        drawText(canvas, "FPS : " + FPS, ICON_VERSION.getWidth() * 2, ICON_VERSION.getHeight()/2, 1, TEXT_ALIGN_LEFT, Color.WHITE);

        if(selectCount == 1){
            drawText(canvas, "x:" + (selectedNote.x - (stackpx * selectedNote.stackCount)) + " y:" + (selectedNote.y - (stackpx * selectedNote.stackCount)), (w*0.56f + ICON_LEFT.getWidth()/2), (h*0.04f - ICON_LEFT.getHeight()/2), 1, TEXT_ALIGN_LEFT, Color.WHITE);
        }else if(selectCount == 3){
            Point[] p = new Point[3];
            int counter = 0;
            for(HitObject ho : HitObjects){
                if(ho.isSelected){
                    p[counter] = new Point();
                    Log.e("angle", counter+"");
                    p[counter].x = ho.x;
                    p[counter].y = ho.y;
                    counter++;
                }
            }
            double angle = Math.toDegrees(Math.atan2(p[0].x - p[1].x,p[0].y - p[1].y)-
                    Math.atan2(p[2].x- p[1].x,p[2].y- p[1].y));
            drawText(canvas, dec1_2.format(Math.abs(angle)%180)+"°", (w*0.40f), (h*0.04f - ICON_LEFT.getHeight()/2), 1, TEXT_ALIGN_RIGHT, Color.WHITE);
        }
/*
        switch (dec1_2.format(playbackSpeed)){
            case "1.00":
                drawText(canvas, "SR : " + dec1_5.format(SR), w, h * 0.15f, 1, TEXT_ALIGN_RIGHT);
                break;
            case "1.50":
                drawText(canvas, "[DT] SR : " + dec1_5.format(SR_DT), w, h * 0.15f, 1, TEXT_ALIGN_RIGHT);
                break;
            case "0.75":
                drawText(canvas, "[HT] SR : " + dec1_5.format(SR_HT), w, h * 0.15f, 1, TEXT_ALIGN_RIGHT);
                break;
        }
        */
        if(DRAW_DEBUG) {
            drawText(canvas, currentPosition + "", w, h * 0.1f, 1, TEXT_ALIGN_RIGHT, Color.WHITE);

            drawText(canvas, "MillisTP : " + millis_tp, 0, h * 0.15f, 1, TEXT_ALIGN_LEFT, Color.WHITE);
            drawText(canvas, "MillisDraw : " + millis_draw, 0, h * 0.2f, 1, TEXT_ALIGN_LEFT, Color.WHITE);

            drawText(canvas, "BPM : " + dec2_2.format(60000f / BPM_overall), w, h * 0.15f, 1, TEXT_ALIGN_RIGHT, Color.WHITE);
            drawText(canvas, "Speed : " + speed_overall, w, h * 0.2f, 1, TEXT_ALIGN_RIGHT, Color.WHITE);

            drawText(canvas, selectCount + " selected", w, h * 0.3f, 1, TEXT_ALIGN_RIGHT, Color.WHITE);
            drawText(canvas, "Drawing " + drawCount + " objects", w, h * 0.35f, 1, TEXT_ALIGN_RIGHT, Color.WHITE);

            int sliderbodyCount = 0;
            for(HitObject ho : HitObjects){
                if(ho.sliderBody != null) sliderbodyCount++;
            }
            drawText(canvas, "Drawing " + sliderbodyCount + " sliderbodies", w, h * 0.4f, 1, TEXT_ALIGN_RIGHT, Color.WHITE);
        }

        if(!TIMELINE_MODE) {
            paint.setColor(Color.WHITE);
            float l = w * .15f + (w * .8f * percentage / 100f);
            canvas.drawRect(l - w * 0.002f, h * 0.92f, l + w * 0.002f, h * 0.98f, paint);

            paint.setColor(Color.RED);
            paint.setLineWidth(g*4);

            canvas.drawBitmap(ICON_playback, (int)(g*4), (int)(h*0.25f));
            canvas.drawLine(g*5, h*0.25f + g*48*playbackInt , g*5, h*0.25f+g*36+g*48*playbackInt, paint);
        }else{
            drawText(canvas, "Zoomscale : " + timelineZoomScale,w*0.02f, h*0.85f, 0.8f, TEXT_ALIGN_LEFT, Color.WHITE);
        }

        //canvas.drawBitmap(BEATMAP_INFO, (int)(w*0.02f), (int)(h*0.02f));

        if(isSongsetupOpened){

        }


    }

    void drawBG(ICanvasGL canvas){
        canvas.setAlpha(bgDim);
        if(background!=null) canvas.drawBitmap(background, w/2-background.getWidth()/2, h/2-background.getHeight()/2);
        canvas.setAlpha(255);
    }

    public void drawText(ICanvasGL canvas, String text, float width, float height, float scale, int alignType, int color){
        _paint.setTextSize(scale*fontSize);
        if(alignType == TEXT_ALIGN_MIDDLE) width = width - _paint.measureText(text)/2;
        else if(alignType == TEXT_ALIGN_RIGHT) width -= _paint.measureText(text);
        for(int i=0; i<text.length(); i++){
            char chr = text.charAt(i);
            matrix.reset();
            matrix.translate(width, height);
            matrix.scale(scale, scale);
            if(Character.isLetter(chr)){
                if(Character.isLowerCase(chr)){ //LOWERCASE
                    if(color == Color.WHITE) canvas.drawBitmap(FONT_ALPHABET[chr-97], matrix);
                    else if(color == Color.RED) canvas.drawBitmap(FONT_ALPHABET_RED[chr-97], matrix);
                }else{ //UPPERCASE
                    if(color == Color.WHITE) canvas.drawBitmap(FONT_ALPHABET_UPPERCASE[chr-65], matrix);
                    else if(color == Color.RED) canvas.drawBitmap(FONT_ALPHABET_UPPERCASE_RED[chr-65], matrix);
                }
            }else if(Character.isDigit(chr)){ //DIGITS
                canvas.drawBitmap(FONT_NUMBERS[chr-48], matrix);
            }else if(chr=='.') canvas.drawBitmap(FONT_DOT, matrix);
            else if(chr==':') canvas.drawBitmap(FONT_COLON, matrix);
            else if(chr=='%') canvas.drawBitmap(FONT_PERCENT, matrix);
            else if(chr=='-') canvas.drawBitmap(FONT_HYPHEN, matrix);
            else if(chr=='/') canvas.drawBitmap(FONT_SLASH, matrix);
            else if(chr=='°') canvas.drawBitmap(FONT_DEGREE, matrix);
            else if(chr=='[') canvas.drawBitmap(FONT_BRACKETS[0], matrix);
            else if(chr==']') canvas.drawBitmap(FONT_BRACKETS[1], matrix);

            width += _paint.measureText(chr+"");
        }
    }

    public void drawPopup(ICanvasGL canvas){
        float x = popupX;
        float y = popupY;
        String[] str = popupStr;
        int[] color = popupColor;
        float width, height;
        float padding = 2;
        _paint.setTextSize(50);
        float widestWidth = 0;
        for(String s : str){
            if(_paint.measureText(s) > widestWidth){
                widestWidth = _paint.measureText(s);
            }
        }
        width = (padding * 2) + (widestWidth);
        height = (padding * 2) + (str.length * 65);

        paint.setColor(Color.DKGRAY);
        canvas.drawRect(x, y - height, x + width, y , paint);
        paint.setColor(Color.LTGRAY);
        paint.setLineWidth(2);

        for(int i=0; i<str.length; i++){
            if(i!=0) canvas.drawLine(x + 5, padding + (y - height) + i * 65, x + width - 5, padding + (y - height) + i * 65, paint);
            drawText(canvas, popupStr[i], x + 5, padding + (y - height) + i * 65, 1.25f, TEXT_ALIGN_LEFT, popupColor[i]);
        }
    }

    public int getPopupClickPos(){
        float width = 0, height = 0;
        float padding = 2;
        _paint.setTextSize(50);
        float widestWidth = 0;
        for(String s : popupStr){
            if(_paint.measureText(s) > widestWidth){
                widestWidth = _paint.measureText(s);
            }
        }

        width = (padding * 2) + (widestWidth);
        height = (padding * 2) + (popupStr.length * 65);

        int pos = -1;
        for(int i=0; i<popupStr.length; i++){
            if(firstClick_x >= popupX + 5 && firstClick_x <= popupX + width - 5 && firstClick_y >= padding + (popupY - height) + i * 65 && firstClick_y <= padding + (popupY - height) + (i+1) * 65){
                pos = i;
            }
        }
        return pos;
    }


    public void drawDragArea(ICanvasGL canvas){
        if(scrollMode || movingSliderPointStatus || movingNoteStatus || preventSelection) return;
        paint.setColor(Color.argb(150, 104, 140, 220));
        canvas.drawRect(firstClick_x, firstClick_y, dragging_x, dragging_y, paint);
    }

    public void drawObjects(ICanvasGL canvas, HitObject ho){
        if(ho == null) return;
        if(ho.isRendering) return;
        setTimingPoints(ho.offset);

        ///DRAWING HITCIRCLES AFTER HIT                         ///////////////////////////////////

        if(ho.offset <= currentPosition){
            if(ho.notetype.equals("spinner")){
                if(!ho.isPlayed && ho.spinnerEndOffset <= currentPosition){
                    playHitsound(ho);
                    ho.isPlayed = true;
                    ho.dead = true;
                }
            }else if(!ho.isPlayed) {
                playHitsound(ho);
                ho.isPlayed = true;
            }
            matrix.reset();
            matrix.translate(left + g * (ho.x - (stackpx * ho.stackCount)) - CircleSize / 2, top + g * (ho.y - (stackpx * ho.stackCount)) - CircleSize / 2);
            int alpha = 255 - (currentPosition - ho.offset)/2;
            canvas.setAlpha(alpha);
            canvas.drawBitmap(hitcircle_hit, matrix); // 히트서클 그려줌
            canvas.drawBitmap(hitcircleoverlay, matrix);
            canvas.setAlpha(255);
            if(!ho.dead && !isSeeking && ho.offset+500 <= currentPosition){
                if(ho.notetype.equals("circle")) {

                    ho.dead = true;
                }else if(ho.notetype.equals("slider")){
                    int sliderTime = (int)(ho.sliderLength / (speed * SV * 100.0d) * beatDuration);
                    if(ho.offset + sliderTime * ho.sliderRepeat+500 <= currentPosition) {
                        ho.dead = true;
                        if(ho.sliderBody != null) {
                            ho.sliderBody.recycle();
                            ho.sliderBody = null;
                        }
                    }
                }else if(ho.notetype.equals("spinner") && ho.spinnerEndOffset <= currentPosition){
                }
            }
            if(ho.notetype.equals("spinner")){

            }
        }

        ///////////////////////////////////////////////////////////////////////////////////////////

        // DRAWING HITCIRCLES BEFORE HIT

        ///////////////////////////////////////////////////////////////////////////////////////////


        if(ho.dead) return;
            if(ho.notetype.equals("circle") && ho.offset>currentPosition) {
                int alpha = (int)ApproachingTime - (ho.offset - currentPosition);
                alpha = Math.min(255, alpha);
                canvas.setAlpha(alpha);
                canvas.drawBitmap(hitcircle[ho.mColorCount], (int)(left + g * (ho.x - (stackpx * ho.stackCount)) - CircleSize / 2), (int)(top + g * (ho.y - (stackpx * ho.stackCount)) - CircleSize / 2)); // 히트서클 그려줌
                canvas.drawBitmap(hitcircleoverlay, (int)(left + g * (ho.x - (stackpx * ho.stackCount)) - CircleSize / 2), (int)(top + g * (ho.y - (stackpx * ho.stackCount)) - CircleSize / 2));
                canvas.setAlpha(255);
            }

            else if(ho.notetype.equals("slider")){
                if(ho.sliderCoordinates.size() == 0) return;

                if(ho.sliderBody == null) {
                    ho.sliderBody = Bitmap.createBitmap((int) (g*Math.abs(ho.Xmax - ho.Xmin) + maxCircleSize), (int) (g*Math.abs(ho.Ymax - ho.Ymin) + maxCircleSize), Bitmap.Config.ARGB_4444);
                    _canvas = new Canvas(ho.sliderBody);
                    _paint = new Paint();
                    _paint.setColor(Color.WHITE);
                    _paint.setAntiAlias(true);
                    _paint.setAlpha(200);
                    _paint.setStyle(Paint.Style.STROKE);
                    _paint.setStrokeJoin(Paint.Join.ROUND);
                    _paint.setStrokeCap(Paint.Cap.ROUND);
                    _paint.setStrokeWidth(CircleSize*0.9f);
                    _canvas.drawPath(ho.sliderPath, _paint);
                    _paint.setColor(comboColor[ho.mColorCount]);
                    _paint.setStrokeWidth(CircleSize*0.8f);
                    _canvas.drawPath(ho.sliderPath, _paint);
                }

                //Define slider timing variable
                double sliderTime = (ho.sliderLength / (speed * SV * 100) * beatDuration); //슬라이더 한번 리버스까지 걸리는 시간
                double sliderFPS = sliderTime * (double)(ho.sliderRepeat + 1) / (double)ho.sliderCoordinates.size();
                int repeatCount = (int)((currentPosition - ho.offset)/sliderTime);
                repeatCount = Math.max(0, repeatCount);
                int sliderbTime = (int)((currentPosition - ho.offset)*(ho.sliderRepeat+1) / sliderFPS);
                sliderbTime = sliderbTime % (ho.sliderCoordinates.size() * 2);
                if(sliderbTime >= ho.sliderCoordinates.size()) sliderbTime = ho.sliderCoordinates.size()*2 - sliderbTime - 1;

                int _repeatCount = (int)((currentPosition - ho.offset)/sliderTime);
                if((_repeatCount+1)%2 == ho.prevRepeatCount%2 && _repeatCount > 0 && _repeatCount < ho.sliderRepeat){
                    ho.prevRepeatCount = _repeatCount;
                    playHitsound(ho);
                }

                int _w = (int)(left + g*(ho.Xmin - (stackpx * ho.stackCount)) - maxCircleSize/2);
                int _h = (int)(top + g*(ho.Ymin - (stackpx * ho.stackCount)) - maxCircleSize/2);
                if(sliderTime*(ho.sliderRepeat)+ho.offset >= currentPosition){
                    int alpha = (int)ApproachingTime - (ho.offset - currentPosition);
                    alpha = Math.min(alpha, 255);
                    canvas.setAlpha(alpha);
                    if(movingSliderPointStatus && sliderBodyTmp != null && !sliderBodyTmp.isRecycled() && ho.offset == sliderTmpOffset) canvas.drawBitmap(sliderBodyTmp, _w, _h);
                    else if(ho.sliderBody != null) canvas.drawBitmap(ho.sliderBody, _w, _h);
                    canvas.setAlpha(255);
                }
                else {
                    int alpha = 255 - (int)(currentPosition - ho.offset - sliderTime*ho.sliderRepeat)/2;

                    canvas.setAlpha(alpha);
                    if(movingSliderPointStatus && sliderBodyTmp != null && !sliderBodyTmp.isRecycled() && ho.offset == sliderTmpOffset) canvas.drawBitmap(sliderBodyTmp, _w, _h);
                    else if(ho.sliderBody != null) canvas.drawBitmap(ho.sliderBody, _w, _h);
                    canvas.setAlpha(255);
                }

                matrix.reset();
                matrix.translate(left + g * (ho.x - (stackpx * ho.stackCount)) - CircleSize / 2, top + g * (ho.y - (stackpx * ho.stackCount)) - CircleSize / 2);
                int alpha = (int)ApproachingTime - (ho.offset - currentPosition);
                alpha = Math.min(255, alpha);
                if(ho.offset > currentPosition){
                    canvas.setAlpha(alpha);
                    canvas.drawBitmap(hitcircle[ho.mColorCount], matrix);
                    canvas.drawBitmap(hitcircleoverlay, matrix);
                    matrix.reset();
                    matrix.translate(left + g * (ho.endx - (stackpx * ho.stackCount)) - CircleSize / 2, top + g * (ho.endy - (stackpx * ho.stackCount)) - CircleSize / 2);
                    canvas.drawBitmap(hitcircle[ho.mColorCount], matrix);
                    canvas.drawBitmap(hitcircleoverlay, matrix);
                    canvas.setAlpha(255);
                }else{
                    alpha = 255 - (currentPosition - ho.offset)/2;
                    canvas.setAlpha(alpha);
                    canvas.drawBitmap(hitcircle_hit, matrix);
                    canvas.drawBitmap(hitcircleoverlay, matrix);
                    canvas.setAlpha(255);
                    if(repeatCount == 0){
                        matrix.reset();
                        matrix.translate(left + g * (ho.endx - (stackpx * ho.stackCount)) - CircleSize / 2, top + g * (ho.endy - (stackpx * ho.stackCount)) - CircleSize / 2);
                        canvas.drawBitmap(hitcircle[ho.mColorCount], matrix);
                        canvas.drawBitmap(hitcircleoverlay, matrix);
                    }else{
                        if(currentPosition >= ho.offset + sliderTime*ho.sliderRepeat && !ho.isPlayed_end){
                            playHitsound(ho);
                            ho.isPlayed_end = true;
                        }
                        alpha = 255 - (int)(currentPosition - (ho.offset + sliderTime))/2;
                        alpha = Math.min(255, alpha);
                        canvas.setAlpha(alpha);
                        matrix.reset();
                        matrix.translate(left + g * (ho.endx - (stackpx * ho.stackCount)) - CircleSize / 2, top + g * (ho.endy - (stackpx * ho.stackCount)) - CircleSize / 2);
                        canvas.drawBitmap(hitcircle_hit, matrix);
                        canvas.drawBitmap(hitcircleoverlay, matrix);
                        canvas.setAlpha(255);
                    }
                }

                if(sliderTime*(ho.sliderRepeat)+ho.offset >= currentPosition) {
                    if (ho.offset <= currentPosition){
                        if(ho.sliderRepeat%2==0 && repeatCount < ho.sliderRepeat - 2){
                            matrix.reset();
                            matrix.translate(left + g * (ho.endx - (stackpx * ho.stackCount))- CircleSize / 2, top + g * (ho.endy - (stackpx * ho.stackCount)) - CircleSize / 2);
                            canvas.drawBitmap(hitcircle[ho.mColorCount], matrix);
                            canvas.drawBitmap(hitcircleoverlay, matrix);
                            matrix.reset();
                            matrix.translate((left + g * (ho.x - (stackpx * ho.stackCount))) - reversearrow.getWidth() / 2, (top + g * (ho.y - (stackpx * ho.stackCount))) - reversearrow.getHeight() / 2);
                            matrix.rotateZ((float) ho.reverseAngle);
                            canvas.drawBitmap(reversearrow, matrix);
                        }else if(ho.sliderRepeat%2==1 && repeatCount < ho.sliderRepeat - 1){
                            matrix.reset();
                            matrix.translate(left + g * (ho.endx - (stackpx * ho.stackCount)) - CircleSize / 2, top + g * (ho.endy - (stackpx * ho.stackCount)) - CircleSize / 2);
                            canvas.drawBitmap(hitcircle[ho.mColorCount], matrix);
                            canvas.drawBitmap(hitcircleoverlay, matrix);
                            matrix.reset();
                            matrix.translate((left + g * (ho.x - (stackpx * ho.stackCount))) - reversearrow.getWidth() / 2, (top + g * (ho.y - (stackpx * ho.stackCount))) - reversearrow.getHeight() / 2);
                            matrix.rotateZ((float) ho.reverseAngle);
                            canvas.drawBitmap(reversearrow, matrix);
                        }
                    }

                    if (ho.sliderRepeat >= 2 && repeatCount < ho.sliderRepeat - 1) {
                        if(ho.sliderRepeat%2==0 && repeatCount < ho.sliderRepeat - 1){
                            matrix.reset();
                            matrix.translate(left + g * (ho.endx - (stackpx * ho.stackCount)) - CircleSize / 2, top + g * (ho.endy - (stackpx * ho.stackCount)) - CircleSize / 2);
                            canvas.drawBitmap(hitcircle[ho.mColorCount], matrix);
                            canvas.drawBitmap(hitcircleoverlay, matrix);
                            matrix.reset();
                            matrix.translate((left + g * (ho.endx - (stackpx * ho.stackCount))) - reversearrow.getWidth() / 2, (top + g * (ho.endy - (stackpx * ho.stackCount))) - reversearrow.getHeight() / 2);
                            matrix.rotateZ((float) ho.reverseAngle2 + 180);
                            canvas.drawBitmap(reversearrow, matrix);
                        }else if(ho.sliderRepeat%2==1 && repeatCount < ho.sliderRepeat - 2){
                            matrix.reset();
                            matrix.translate(left + g * (ho.endx - (stackpx * ho.stackCount)) - CircleSize / 2, top + g * (ho.endy - (stackpx * ho.stackCount)) - CircleSize / 2);
                            canvas.drawBitmap(hitcircle[ho.mColorCount], matrix);
                            canvas.drawBitmap(hitcircleoverlay, matrix);
                            matrix.reset();
                            matrix.translate((left + g * (ho.endx - (stackpx * ho.stackCount))) - reversearrow.getWidth() / 2, (top + g * (ho.endy - (stackpx * ho.stackCount))) - reversearrow.getHeight() / 2);
                            matrix.rotateZ((float) ho.reverseAngle2 + 180);
                            canvas.drawBitmap(reversearrow, matrix);
                        }
                    }
                    if (ho.offset <= currentPosition && sliderbTime >= 0 && sliderbTime < ho.sliderCoordinates.size()) {
                        canvas.drawBitmap(sliderBall, (int) ((ho.sliderCoordinates.get(sliderbTime).x - (stackpx * ho.stackCount)) - sliderBall.getWidth() / 2), (int) ((ho.sliderCoordinates.get(sliderbTime).y - (stackpx * ho.stackCount)) - sliderBall.getHeight() / 2));
                        canvas.drawBitmap(sliderfollowcircle, (int) ((ho.sliderCoordinates.get(sliderbTime).x - (stackpx * ho.stackCount)) - sliderfollowcircle.getWidth() / 2), (int) ((ho.sliderCoordinates.get(sliderbTime).y - (stackpx * ho.stackCount)) - sliderfollowcircle.getHeight() / 2));
                    }
                }

            }else if(ho.notetype.equals("spinner")){
                canvas.drawBitmap(hitcircle[comboColor.length-1], (int)(left + g * 256 - CircleSize / 2), (int)(top + g * 192 - CircleSize / 2)); // 히트서클 그려줌
                canvas.drawBitmap(hitcircleoverlay, (int)(left + g * 256 - CircleSize / 2), (int)(top + g * 192 - CircleSize / 2));
            }

            float scale = (float)(ho.offset - currentPosition) * (400f / ApproachingTime) / (CircleSize) + 1f;
            matrix.reset();
            matrix.scale(scale, scale);
            matrix.translate(left + g * (ho.x - (stackpx * ho.stackCount)) - (CircleSize/2 * scale), top + g * (ho.y - (stackpx * ho.stackCount)) - (CircleSize/2 * scale));

            int alpha = (int)ApproachingTime - (ho.offset - currentPosition);
            if(ho.notetype.equals("spinner")){
                scale = (float)(ho.spinnerEndOffset - currentPosition)/(float)(ho.spinnerEndOffset - ho.offset)*4 + 1f;
                if(scale < 1f){
                    ho.dead = true;
                    return;
                }
                scale = Math.max(scale, 1);
                matrix.reset();
                matrix.scale(scale, scale);
                matrix.translate(left + g * (ho.x - (stackpx * ho.stackCount)) - (CircleSize/2 * scale), top + g * (ho.y - (stackpx * ho.stackCount)) - (CircleSize/2 * scale));
                alpha = Math.min(255, alpha);
                canvas.setAlpha(alpha);
                canvas.drawBitmap(approachcircle[ho.mColorCount], matrix);
                canvas.setAlpha(255);
                return;
            }

            if(scale>=1f) {
                alpha = (int)ApproachingTime - (ho.offset - currentPosition);
                alpha = Math.min(255, alpha);
                canvas.setAlpha(alpha);
                canvas.drawBitmap(approachcircle[ho.mColorCount], matrix);
                canvas.setAlpha(255);
            }else{
                alpha = 255 - (currentPosition - ho.offset)/2;
                canvas.setAlpha(alpha);
                scale = -scale + 1.9f;
                scale = Math.min(1.1f, scale);
                matrix.reset();
                matrix.scale(scale, scale);
                matrix.translate(left + g * (ho.x - (stackpx * ho.stackCount)) - (CircleSize/2 * scale), top + g * (ho.y - (stackpx * ho.stackCount)) - (CircleSize/2 * scale));
                canvas.drawBitmap(approachcircle[ho.mColorCount], matrix);
            }
            canvas.setAlpha(255);
    }

    public void drawTimeline(ICanvasGL canvas){
        //w*0.55 = CENTER OF TIMELINE
        //Timeline starts at w*.1 ~ ends at w
        try{
            double opb = BPM_overall; //offset per beat (1/1)
            double sliderTime = 0;
            float ratio = CS5CircleSize / CircleSize;
            float _w;

            for (TimingPoint tp : TimingPoints){
                _w = (w*0.55f) + (float)(tp.offset - currentPosition)*timelineZoomScale;
                if(_w > w || _w < 0) continue;
                paint.setColor(Color.GREEN);
                canvas.drawRect(_w, h*0.9f, _w + 2, h, paint);
            }

            for (HitObject ho : HitObjects) {
                if(ho == null) break;
                _w = (w*0.55f) + (float)(ho.offset - currentPosition)*timelineZoomScale;
                if(_w>w || (ho.notetype.equals("circle") && _w<0)) continue;

                if(ho.notetype.equals("slider")){
                    setTimingPoints(ho.offset);
                    sliderTime = (ho.sliderLength / (speed * SV * 100) * beatDuration);
                    double _ww = (w*0.55f) + ((ho.offset + sliderTime * ho.sliderRepeat) - currentPosition) * timelineZoomScale;
                    if(_ww <= 0) continue;
                    paint.setLineWidth(CS5CircleSize*0.4f);
                    paint.setColor(comboColorArray.get(ho.mColorCount));
                    //float tmpy = h - CircleSize*0.75f*ratio/2;
                    float tmpy = h - CS5CircleSize*scaleRatio/2;
                    canvas.setAlpha(255);
                    canvas.drawLine(_w, tmpy, (float)_ww, tmpy, paint);
                    canvas.drawRect(_w, tmpy - CS5CircleSize*0.25f, (float)_ww, tmpy + CS5CircleSize*0.25f, paint);
                    for(int i=1; i<=ho.sliderRepeat; i++){
                        //if((_w + sliderTime*timelineZoomScale*i - hitcircle[0].getWidth()/2*0.6f) < w*.15f) continue;
                        int alpha = 255;
                        float _wws = (float)(w*0.55f + (ho.offset + sliderTime*i - currentPosition) * timelineZoomScale);
                        alpha = 255 + (int)(_wws - w*0.15f);
                        alpha = Math.max(0, alpha);
                        alpha = Math.min(255, alpha);
                        canvas.setAlpha(alpha);
                        matrix.reset();
                        matrix.scale(scaleRatio*ratio, scaleRatio*ratio);
                        matrix.translate((float)(_w + sliderTime*timelineZoomScale*i - CircleSize/2*scaleRatio*ratio), h - CircleSize*scaleRatio*ratio);
                        canvas.drawBitmap(hitcircle[ho.mColorCount], matrix);
                        matrix.reset();
                        matrix.scale(scaleRatio*ratio, scaleRatio*ratio);
                        matrix.translate((float)(_w + sliderTime*timelineZoomScale*i - CircleSize/2*scaleRatio*ratio),  h - CircleSize*scaleRatio*ratio);
                        canvas.drawBitmap(hitcircleoverlay, matrix);
                        if(i<ho.sliderRepeat){
                            matrix.reset();
                            matrix.scale(scaleRatio*ratio, scaleRatio*ratio);
                            matrix.translate((float)(_w + sliderTime*timelineZoomScale*i - CircleSize/2*scaleRatio*ratio),  h - CircleSize*scaleRatio*ratio);
                            canvas.drawBitmap(reversearrow, matrix);
                        }
                    }
                }else if(ho.notetype.equals("spinner")){
                    double _ww = (w*0.55f) + (ho.spinnerEndOffset - currentPosition) * timelineZoomScale;
                    if(_ww <= 0) continue;
                    paint.setLineWidth(CS5CircleSize*scaleRatio/2f);
                    paint.setColor(Color.LTGRAY);
                    int spinnerTime = ho.spinnerEndOffset - ho.offset;

                    float tmpy = h - CS5CircleSize*0.75f/2;
                    canvas.setAlpha(255);
                    canvas.drawLine(_w, tmpy, (float)_ww, tmpy, paint);

                    matrix.reset();
                    matrix.scale(0.5f*ratio, 0.5f*ratio);
                    matrix.translate((float)(_w + (spinnerTime)*timelineZoomScale - CircleSize/2*0.75f*ratio), h - CircleSize*0.75f*ratio);
                    canvas.drawBitmap(hitcircle[ho.mColorCount], matrix);
                    matrix.reset();
                    matrix.scale(0.5f*ratio, 0.5f*ratio);
                    matrix.translate((float)(_w + spinnerTime*timelineZoomScale - CircleSize/2*0.75f*ratio),  h - CircleSize*0.75f*ratio);
                    canvas.drawBitmap(hitcircleoverlay, matrix);
                }
                int alpha = 255;
                if(_w <= w*0.15f) alpha = 255 + (int)((_w - w*.15f));
                alpha = Math.max(0, alpha);
                alpha = Math.min(255, alpha);
                canvas.setAlpha(alpha);
                matrix.reset();
                matrix.scale(ratio * scaleRatio, ratio * scaleRatio);
                matrix.translate(_w - CS5CircleSize*scaleRatio/2f, h - CS5CircleSize*scaleRatio);
                canvas.drawBitmap(hitcircle[ho.mColorCount], matrix);
                matrix.reset();
                matrix.scale(ratio * scaleRatio, ratio * scaleRatio);
                matrix.translate(_w - CS5CircleSize*scaleRatio/2f, h - CS5CircleSize*scaleRatio);
                canvas.drawBitmap(hitcircleoverlay, matrix);
                if(ho.isSelected){
                    matrix.reset();
                    matrix.scale(ratio * scaleRatio, scaleRatio * ratio);
                    matrix.translate(_w - CS5CircleSize*scaleRatio, h - CS5CircleSize*scaleRatio*1.5f);
                    canvas.drawBitmap(hitcircleselect, matrix);
                }
            }
            paint.setColor(Color.WHITE);
            canvas.setAlpha(255);
//for(float i=0; i<(8f*beatDivisor[beatDivIndex]/timelineZoomScale); i++){
            for(float i=0; i<(8f*beatDivisor[beatDivIndex]); i++){
                //- ((currentPosition - lastTimingOffset)%opb)/opb)*(opb/4d)*timelineZoomScale)
                _w = (float)((w*0.55f - ((4f*beatDivisor[beatDivIndex])-i)*(opb/beatDivisor[beatDivIndex])*timelineZoomScale) - (((currentPosition - lastTimingOffset)%opb)*timelineZoomScale));
                if(_w < w*0.15f || _w > w) continue;

                setColorByBeatDivisor(paint, i);

                if(paint.getColor() == Color.WHITE) canvas.drawRect(_w, h*0.96f, _w + 2, h, paint);
                else canvas.drawRect(_w, h*0.98f, _w + 2, h, paint);
            }

            paint.setColor(Color.WHITE);
            canvas.drawRect(w*0.55f - w*0.002f, h*0.9f, w*0.55f + w*0.002f, h, paint);

            if(scrollMode){
                canvas.setAlpha(255);
            }else{
                canvas.setAlpha(150);
            }
            canvas.drawBitmap(ICON_SCROLL, w - ICON_SCROLL.getWidth(), h - ICON_SCROLL.getHeight());
            canvas.setAlpha(255);
        }catch(Exception e){
            Log.e("log", e.toString());
        }
    }

    public void setColorByBeatDivisor(GLPaint paint, float i){
        if(i%beatDivisor[beatDivIndex]==0){ paint.setColor(Color.WHITE); return;}
        if(beatDivisor[beatDivIndex]%3==0){
            if(i%beatDivisor[beatDivIndex]==3 && beatDivisor[beatDivIndex]==6){ paint.setColor(Color.RED); return;}
            paint.setColor(Color.rgb(180, 4, 180));
            return;
        }else{
            if(i%beatDivisor[beatDivIndex]==2 && beatDivisor[beatDivIndex] == 4){
                paint.setColor(Color.RED);
                return;
            }
            else paint.setColor(Color.rgb(61, 112, 226));
        }
    }

    public void drawSliderpoint(ICanvasGL canvas, HitObject ho){
        float _x=0, _y=0;
        boolean isFirst = true;
        for (int index = 0; index < ho.sliderPoints.size(); index++) {
            float x = (float)ho.sliderPoints.get(index).x;
            float y = (float)ho.sliderPoints.get(index).y;
            if(!isFirst){
                paint.setLineWidth(g*2);
                paint.setColor(Color.rgb(255,255,255));
                canvas.drawLine(left + g*_x,top + g*_y, left + g*x,top + g*y, paint);
            }
            if(index == sliderPointIndex){
                paint.setColor(Color.YELLOW);
                canvas.drawCircle(left + g*x,top + g*y, 10*g, paint);
            }

            paint.setColor(Color.rgb(255,255,255));
            canvas.drawRect(left + g*x - g*5,top + g*y - g*5, left + g*x + g*5,top + g*y + g*5, paint);
            paint.setColor(Color.rgb(180,180,180));
            canvas.drawRect(left + g*x - g*4,top + g*y - g*4, left + g*x + g*4,top + g*y + g*4, paint);
            if(_x == x && _y == y){
                paint.setColor(Color.rgb(255,0,0));
                canvas.drawRect(left + g*x - g*4,top + g*y - g*4, left + g*x + g*4,top + g*y + g*4, paint);
            }
            _x = x;
            _y = y;
            isFirst = false;

        }

    }

    void _playHitObjects(ICanvasGL canvas){
        ArrayList<HitObject> tmp = new ArrayList<>();
        int defaultCount = 0;
        int NCcounter = 0;

        for (HitObject ho : HitObjects) {
            ho.stackCount = 0;
        }

        for (int i = 0; i < HitObjects.size() - 1; i++){ //Stacking
            HitObject curr = HitObjects.get(i);
            if(curr.stackCount != 0) continue;
            if(curr.offset > currentPosition + ApproachingTime) continue;
            if(curr.offset + 10000 <= currentPosition) continue;
            ArrayList<HitObject> stackObj = new ArrayList<>();
            stackObj.add(curr);
            double currOffset = curr.offset;

            if(curr.notetype.equals("circle")){
                for(int j = i+1; j < HitObjects.size(); j++){
                    HitObject next = HitObjects.get(j);
                    if(currOffset + stackTime <= next.offset) break;
                    if((Math.abs(curr.x - next.x) <= 2 && Math.abs(curr.y - next.y) <= 2)){
                        currOffset = next.offset;
                        stackObj.add(next);
                        for(HitObject ho : stackObj){
                            ho.stackCount++;
                        }
                    }
                }
                for(int m=1; m < stackObj.size(); m++){
                    stackObj.get(m).stackCount--;
                }
            }else if(curr.notetype.equals("slider")){
                setTimingPoints(curr.offset);
                boolean isStacked = false;
                for(int j = i+1; j < HitObjects.size(); j++) {
                    HitObject next = HitObjects.get(j);

                    if((Math.abs(curr.x - next.x) <= 2 && Math.abs(curr.y - next.y) <= 2)){
                        if(currOffset + stackTime <= next.offset) break;
                        currOffset = next.offset;
                        stackObj.add(next);
                        isStacked = true;
                        for(HitObject ho : stackObj){
                            ho.stackCount++;
                        }
                    }else if((Math.abs(curr.endx - next.x) <= 2 && Math.abs(curr.endy - next.y) <= 2)){
                        int sliderTime = (int)(curr.sliderLength / (speed * SV * 100.0d) * beatDuration);
                        currOffset = next.offset + sliderTime;
                        if(currOffset + stackTime <= next.offset) break;
                        stackObj.add(next);
                        isStacked = true;
                        for(HitObject ho : stackObj){
                            ho.stackCount--;
                        }
                    }
                }
                if(isStacked){
                    for(int m=1; m < stackObj.size(); m++){
                        stackObj.get(m).stackCount++;
                    }
                    for(HitObject ho : stackObj){
                        ho.stackCount = -ho.stackCount;
                    }
                    for(HitObject ho : stackObj){
                        ho.stackCount -= stackObj.size() - 1;
                    }
                }
            }
        }

        for (int currentObjNum = 0; currentObjNum < HitObjects.size(); currentObjNum++){
            if(HitObjects.get(currentObjNum).NC || currentObjNum == 0){
                defaultCount = 0;
                NCcounter += HitObjects.get(currentObjNum).skip + 1;
            }
            defaultCount++;
            float _w = (w*0.55f) + (float)(HitObjects.get(currentObjNum).offset - currentPosition)*timelineZoomScale;
            HitObjects.get(currentObjNum).combo = defaultCount;
            HitObjects.get(currentObjNum).mColorCount = NCcounter % comboColor.length;
            //if((HitObjects.get(currentObjNum).offset < currentPosition + ApproachingTime && !HitObjects.get(currentObjNum).dead) || (_w > 0 && _w < w)) {
            if((HitObjects.get(currentObjNum).offset < currentPosition + ApproachingTime && !HitObjects.get(currentObjNum).dead) || (_w > 0 && _w < w)) {

                tmp.add(HitObjects.get(currentObjNum));
                //drawObjects(canvas, HitObjects.get(currentObjNum));
                //drawDefault(canvas, HitObjects.get(currentObjNum), defaultCount);
            }
        }

        for(int i=tmp.size()-1; i>=0; i--){
            if (tmp.get(i).offset <= currentPosition + ApproachingTime) drawObjects(canvas, tmp.get(i));
            drawDefault(canvas, tmp.get(i), tmp.get(i).combo);
        }
        drawCount = tmp.size();
    }

    public void removeHitObject(){
        removeStatus = false;
        HitObjects_iter = HitObjects.iterator();
        while (HitObjects_iter.hasNext()) {
            HitObject ho = HitObjects_iter.next();
            if(ho.isSelected){
                HitObjects_iter.remove();
            }
        }
        if(toBeAdded.size() != 0){
            HitObjects.addAll(toBeAdded);
            toBeAdded.clear();
            final Comparator mComparator = new Comparator<HitObject>() {
                private final Collator collator = Collator.getInstance();
                public int compare(HitObject object1,HitObject object2) {
                    return collator.compare(object1.toString(), object2.toString());
                }
            };
            Collections.sort(HitObjects, mComparator);
        }
    }

    public void addCircle(int x, int y, int offset){
        for(HitObject ho : HitObjects){
            ho.isSelected = false;
        }
        String s = x + "," + y + "," + offset + ",1,0,0:0:0:0:";
        toBeAdded.add(new HitObject(s));
    }

    public void addSlider(int x, int y, int offset){
        String s = x + "," + y + "," + offset + ",1,0,0:0:0:0:";
        HitObject ho = new HitObject(s);
        ho.isSelected = true;
        ho.sliderRepeat = 1;
        ho.sliderType = "B";
        ho.type = 2;
        ho.notetype = "slider";
        PathPoint p = new PathPoint();
        p.x = ho.x;
        p.y = ho.y;
        ho.sliderCoordinates.add(p);
        ho.sliderPoints.add(p);
        toBeAdded.add(ho);
    }

    public void copyToClipboard(){
        int startOffset=currentPosition;
        boolean offsetFound = false;
        int defaultCount = 0;
        String comboStr = "";
        for (int currentObjNum = 0; currentObjNum < HitObjects.size(); currentObjNum++){
            if(HitObjects.get(currentObjNum).NC){
                defaultCount=0;
            }
            defaultCount++;
            if(HitObjects.get(currentObjNum).isSelected){
                copyClipboard.add(HitObjects.get(currentObjNum));
                if(!offsetFound) {
                    startOffset = HitObjects.get(currentObjNum).offset;
                    offsetFound = true;
                }
                comboStr += defaultCount + ",";
            }
        }
        String str = dec2.format(startOffset/60000) + ":" + dec2.format(startOffset/1000%60) + ":" + dec3.format(startOffset%1000);
        if(comboStr.length()>0) comboStr = "("+comboStr.substring(0, comboStr.length()-1)+") ";
        ClipboardManager clipboard = (ClipboardManager) getContext().getSystemService(Context.CLIPBOARD_SERVICE);
        ClipData clip = ClipData.newPlainText("osuEdit Timingpoint", str + " " + comboStr +"- ");
        clipboard.setPrimaryClip(clip);

        Toast.makeText(getContext(), str + " " + comboStr +"- ", Toast.LENGTH_SHORT).show();
    }

    public void setTimingPoints(int offset){
        boolean gotSpeed = false;
        boolean gotBPM = false;
        for(int i=TimingPoints.size()-1; i>=0; i--) {
            TimingPoint tp = TimingPoints.get(i);
            if(tp.offset <= offset || i==0){
                if (tp.status && !gotBPM) {
                    beatDuration = tp.speed;
                    gotBPM = true;
                    if(!gotSpeed){
                        speed = 1.00f;
                        gotSpeed = true;
                    }
                }
                else if(!tp.status && !gotSpeed){
                    speed = -100d / tp.speed;
                    gotSpeed = true;
                }
            }
        }
        if(TimingPoints.size() == 0) return;
        if (!gotBPM) {
            beatDuration = TimingPoints.get(0).speed;
        }
        if(!gotSpeed){
            speed = 1f;
        }
    }

    public void setTimingPointsOverall(){
        int BPMoffset=0, SpeedOffset=0;
        boolean kiai_BPM=false, kiai_speed=false;
        int BPMoffsetGap = songDuration, speedOffsetGap = songDuration;
        for(int i=TimingPoints.size()-1; i>=0; i--) { //끝에서부터 역순으로 탐색
            TimingPoint tp = TimingPoints.get(i);
            if(tp.offset <= currentPosition){  //오프셋을 기준으로 앞 범위에서 가장 가까운 포인트
                if (tp.status && BPMoffsetGap > (currentPosition - tp.offset)) { //BPM
                    BPMoffsetGap = currentPosition - tp.offset;
                    BPM_overall = tp.speed;
                    lastTimingOffset = tp.offset;
                    BPMoffset = tp.offset;
                    kiai_BPM = tp.kiai;
                }
                if(!tp.status && speedOffsetGap > (currentPosition - tp.offset)){ //Speed
                    speedOffsetGap = currentPosition - tp.offset;
                    speed_overall = (float) (-100 / tp.speed);
                    speed_overall = Math.round(speed_overall*100)/100d;
                    speed_overall = Math.max(speed_overall, 0.1f);
                    SpeedOffset = tp.offset;
                    kiai_speed = tp.kiai;
                }
                volume_overall = tp.volume;
            }
            if(BPMoffset > SpeedOffset) kiai = kiai_BPM;
            else kiai = kiai_speed;

        }
    }

    public void SelectObject(ICanvasGL canvas){
        selectCount = 0;
        for (HitObject ho : HitObjects) {
            if(ho.isSelected){
                selectedNote = ho;
                selectCount++;
                matrix.reset();
                matrix.translate(left + g * (ho.x - (stackpx * ho.stackCount)) - CircleSize, top + g * (ho.y - (stackpx * ho.stackCount)) - CircleSize);
                canvas.drawBitmap(hitcircleselect, matrix);
                if(ho.notetype.equals("slider")){
                    matrix.reset();
                    matrix.translate(left + g * (ho.endx - (stackpx * ho.stackCount)) - CircleSize, top + g * (ho.endy - (stackpx * ho.stackCount)) - CircleSize);
                    canvas.drawBitmap(hitcircleselect, matrix);
                    drawSliderpoint(canvas, ho);
                }
                paint.setColor(Color.RED);
                //if(showCoordinates) drawText(canvas, (ho.x - (4 * ho.stackCount))+","+(ho.y - (4 * ho.stackCount)), left+g*(ho.x - (4 * ho.stackCount)), top+g*(ho.y - (4 * ho.stackCount)) - 30, 0.8f, TEXT_ALIGN_MIDDLE);
            }
        }
        paint.setColor(Color.argb(180, 255, 0, 0));
        if(touch_x!=0 && touch_y!=0){
            canvas.drawCircle(touch_x, touch_y, 16, paint);
        }
    }

    public void drawDefault(ICanvasGL canvas, HitObject ho, int defaultCount){
        int alpha;
        if(ho.offset > currentPosition) alpha = (int)ApproachingTime - (ho.offset - currentPosition);
        else alpha = 255 - (currentPosition - ho.offset)/2;
        alpha = Math.min(255, alpha);
        alpha = Math.max(0, alpha);
        canvas.setAlpha(alpha);
        matrix.reset();
        float ratio = CircleSize / CS5CircleSize;
        matrix.scale(ratio, ratio);
        if(defaultCount<10){
            matrix.translate((int)(left + g*(ho.x - (stackpx * ho.stackCount)) - (default_img[defaultCount%10].getWidth()*ratio/2)), (int)(top+g*(ho.y - (4 * ho.stackCount)) - (default_img[defaultCount%10].getHeight()*ratio/2)));
            canvas.drawBitmap(default_img[defaultCount%10], matrix);
        }
        else if(defaultCount < 100){
            matrix.translate((int)(left + g*(ho.x - (stackpx * ho.stackCount)) - (default_img[defaultCount/10].getWidth()*ratio/2) - default_img[defaultCount/10].getWidth()*ratio/3), (int)(top+g*(ho.y - (stackpx * ho.stackCount)) - (default_img[defaultCount/10].getHeight()*ratio/2)));
            canvas.drawBitmap(default_img[defaultCount/10], matrix);
            matrix.reset();
            matrix.scale(ratio, ratio);
            matrix.translate((int)(left + g*(ho.x - (stackpx * ho.stackCount)) - (default_img[defaultCount/10].getWidth()*ratio/2) + default_img[defaultCount/10].getWidth()*ratio/3), (int)(top+g*(ho.y - (stackpx * ho.stackCount)) - (default_img[defaultCount/10].getHeight()*ratio/2)));
            canvas.drawBitmap(default_img[defaultCount%10], matrix);
        }else if(defaultCount< 1000){
            matrix.translate((int)(left + g*(ho.x - (stackpx * ho.stackCount)) - (default_img[defaultCount/10].getWidth()*ratio/2) - default_img[defaultCount/10].getWidth()*ratio), (int)(top+g*(ho.y - (stackpx * ho.stackCount)) - (default_img[defaultCount/10].getHeight()*ratio/2)));
            canvas.drawBitmap(default_img[defaultCount/100], matrix);
            matrix.reset();
            matrix.scale(ratio, ratio);
            matrix.translate((int)(left + g*(ho.x - (stackpx * ho.stackCount)) - (default_img[defaultCount/10].getWidth()*ratio/2)), (int)(top+g*(ho.y - (stackpx * ho.stackCount)) - (default_img[defaultCount/10].getHeight()*ratio/2)));
            canvas.drawBitmap(default_img[(defaultCount%100)/10], matrix);
            matrix.reset();
            matrix.scale(ratio, ratio);
            matrix.translate((int)(left + g*(ho.x - (stackpx * ho.stackCount)) - (default_img[defaultCount/10].getWidth()*ratio/2) + default_img[defaultCount/10].getWidth()*ratio), (int)(top+g*(ho.y - (stackpx * ho.stackCount)) - (default_img[defaultCount/10].getHeight()*ratio/2)));
            canvas.drawBitmap(default_img[defaultCount%10], matrix);
        }
        canvas.setAlpha(255);
        matrix.reset();
        alpha = 255;
        if(!TIMELINE_MODE) return;
        float _w = w*0.55f + (ho.offset - currentPosition)*timelineZoomScale;
        if(_w < 0 || _w>w) return;
        if(_w <= w*0.15f) alpha = 255 + (int)((_w - w*.15f));
        alpha = Math.max(0, alpha);
        alpha = Math.min(255, alpha);
        canvas.setAlpha(alpha);
        if(defaultCount<10){
            matrix.scale(0.75f, 0.75f);
            matrix.translate(_w - (default_img[defaultCount%10].getWidth()*0.75f/2), h - (CS5CircleSize*scaleRatio)/2 - default_img[defaultCount%10].getHeight()*0.75f/2);
            canvas.drawBitmap(default_img[defaultCount%10], matrix);
        }else{
            float widsum = (default_img[defaultCount/10].getWidth()*0.75f) + (default_img[defaultCount%10].getWidth()*0.75f);
            matrix.scale(0.75f, 0.75f);
            matrix.translate(_w - widsum/2, h - (CS5CircleSize*scaleRatio)/2 - default_img[defaultCount/10].getHeight()*0.75f/2);
            canvas.drawBitmap(default_img[defaultCount/10], matrix);
            matrix.reset();
            matrix.scale(0.75f, 0.75f);
            matrix.translate(_w , h - (CS5CircleSize*scaleRatio)/2 - default_img[defaultCount%10].getHeight()*0.75f/2);
            canvas.drawBitmap(default_img[defaultCount%10], matrix);
        }
        canvas.setAlpha(255);
    }

    int snapPosition(boolean isForward, int position){ //t
        int calcPosition = position;
        float opb = (float)(BPM_overall/beatDivisor[beatDivIndex]);
        boolean isSnapped = false;
        if(!isForward){ //backward
            if(BPM_overall%1==0) calcPosition--;
            while(!isSnapped){
                calcPosition -= 1;
                //Log.e("log", "calcPosition : " + calcPosition);
                //Log.e("log", "x : " + (calcPosition-lastTimingOffset)%opb);
                if((int)((calcPosition-lastTimingOffset)%opb) >= Math.floor(opb-1) && (calcPosition-lastTimingOffset)%opb < Math.floor(opb)){
                    if(BPM_overall%1==0 && calcPosition+1 == currentPosition) calcPosition -= 2;
                    else break;
                }
                if(calcPosition<=0 || calcPosition>=songDuration) break;
            }
            if(BPM_overall%1==0) calcPosition++;
        }else{
            while(!isSnapped){
                calcPosition += 1;
                //Log.e("log", "calcPosition : " + calcPosition);
                //Log.e("log", "x : " + (calcPosition-lastTimingOffset)%opb);

                if((int)((calcPosition-lastTimingOffset)%opb) >= Math.floor(opb-1) && (calcPosition-lastTimingOffset)%opb < Math.floor(opb)){
                    isSnapped = true;
                    //Log.e("log", "snap");
                    break;
                }
                if(calcPosition<=0 || calcPosition>=songDuration) break;
            }
            if(BPM_overall%1==0) calcPosition++;
        }
        return calcPosition;
    }

    void sortObjects(){
        final Comparator mComparator = new Comparator<HitObject>() {
            private final Collator collator = Collator.getInstance();
            public int compare(HitObject object1,HitObject object2) {
                return collator.compare(object1.toString(), object2.toString());
            }
        };
        Collections.sort(HitObjects, mComparator);
    }

    @Override
    public boolean onTouchEvent(MotionEvent event){
        float x = event.getX();
        float y = event.getY();
        touch_x = x;
        touch_y = y;
        float minX, minY, maxX, maxY;
        boolean buttonClick = false;
        boolean seekEvent = false;
        int seekUnit = 0;

        if(event.getAction() == MotionEvent.ACTION_DOWN){
            firstClick_x = x;
            firstClick_y = y;
        }

        if(event.getAction() == MotionEvent.ACTION_DOWN && popupStatus){
            if(getPopupClickPos() == -1){ //Disable popup
                popupStatus = false;
                return true;
            }
            if(selectCount == 1 && selectedNote.notetype.equals("slider")){ //removing slider
                if(getPopupClickPos() == 1 && sliderPointIndex > -1){
                    if(selectedNote.sliderPoints.size() > 2) selectedNote.sliderPoints.remove(sliderPointIndex);
                    else{
                        HitObjects.remove(selectedNote);
                    }

                    setTimingPoints(selectedNote.offset);
                    double beatLength = beatDuration / beatDivisor[beatDivIndex];
                    int beatCount = (int)((selectedNote.getBezierLength() * beatDuration) / (speed * SV * 100 * beatLength));
                    beatCount = Math.max(1, beatCount);
                    selectedNote.sliderLength = (beatCount * beatLength * speed * SV * 100) / beatDuration;
                    selectedNote.bezier();

                    if(selectedNote.sliderBody != null){
                        selectedNote.sliderBody.recycle();
                        selectedNote.sliderBody = null;
                    }
                    toBeMoved.clear();

                    sliderPointIndex = -1;
                    popupStatus = false;
                }else if(getPopupClickPos() == 0){ //Adding
                    PathPoint p = new PathPoint();
                    p.x = sliderPointAddX;
                    p.y = sliderPointAddY;

                    selectedNote.sliderPoints.add(sliderPointIndex + 1, p);
                    if(selectedNote.sliderPoints.size() > 4) selectedNote.sliderType = "B";

                    setTimingPoints(selectedNote.offset);
                    double beatLength = beatDuration / beatDivisor[beatDivIndex];
                    int beatCount = (int)((selectedNote.getBezierLength() * beatDuration) / (speed * SV * 100 * beatLength));
                    beatCount = Math.max(1, beatCount);
                    selectedNote.sliderLength = (beatCount * beatLength * speed * SV * 100) / beatDuration;
                    selectedNote.bezier();

                    if(selectedNote.sliderBody != null){
                        selectedNote.sliderBody.recycle();
                        selectedNote.sliderBody = null;
                    }

                    popupStatus = false;
                    toBeMoved.clear();
                }
            }
            return true;
        }

        if(event.getAction() == MotionEvent.ACTION_DOWN && touchUP){
            float touchMinH = h - CS5CircleSize * .75f;
            if(System.currentTimeMillis() - lastClick_ms < 250 && TIMELINE_MODE && y > touchMinH){
                isDoubletap = true;
                //isTimelineSeeking = true;
                Log.e("onTouch", "doubletap");
            }else{
                isDoubletap = false;
            }
            lastClick_ms = System.currentTimeMillis();
        }

        if(event.getPointerCount() == 2 && TIMELINE_MODE){ //Pinch mode
            double diffX = Math.abs(event.getX(0) - event.getX(1));
            float ratio = CS5CircleSize / CircleSize;
            float touchMinH = h - CS5CircleSize * .75f;
            if(touch_y < touchMinH) return true; //ignore

            if(!pinchMode){
                _diffX = diffX;
                prevZoomScale = timelineZoomScale;
                pinchMode = true;
            }

            timelineZoomScale = (float)(prevZoomScale * ((1 + (diffX - _diffX) / _diffX)));
            //Log.e("log", "diffX : " + diffX + ", _diffX : " + _diffX + " / scale : " + timelineZoomScale);
            timelineZoomScale = Math.max(timelineZoomScale, 0.5f);
            timelineZoomScale = Math.min(timelineZoomScale, 3.0f);

            return true;
        }

        if(event.getAction() == MotionEvent.ACTION_DOWN && touchUP){
            Log.i("onTouch", "ACTION_DOWN");
            isAnySelected=false;
            for(HitObject ho : HitObjects){
                if(ho.isSelected) isAnySelected = true;
            }

            preventSelection = false;

            minX = Math.min(firstClick_x, dragging_x);
            maxX = Math.max(firstClick_x, dragging_x);
            minY = Math.min(firstClick_y, dragging_y);
            maxY = Math.max(firstClick_y, dragging_y);
            if(x>w*0.92f && x<w*0.98f && y>h*0.75f && y<h*0.75f+w*0.06f) // Play / Pause
            {
                if(songCompleted) return true;
                buttonClick = true;
                isPlaying = !isPlaying;

                try {
                    if (isPlaying) {
                        lastMillis = System.currentTimeMillis();
                        lastTime = mp.getCurrentPosition();
                        //lastTime = mediaPlayer.getCurrentPosition();
                        //mAudioPlayer.play();
                        //HXMusic.music().play(getContext());
                        //mAudioPlayer.pauseToPlay();
                        mp.start();
                        offsetAdjust = true;
                        offsetAdjustMs = System.currentTimeMillis() + 250;
                    }else{
                        mp.pause();
                        lastMillis = System.currentTimeMillis();
                        lastTime = currentPosition;
                    }
                }catch(Exception e){

                }
                touchUP = false;
            }
            else if(x>w*.15f && x<w*.95f && y>h*.9f && !TIMELINE_MODE) //TL seek
            {
                isSeeking = true;
                seekEvent = true;
                buttonClick = true;
            }
            else if(x > w - ICON_SCROLL.getWidth() && y > h - ICON_SCROLL.getHeight() && TIMELINE_MODE) //TL seek
            {
                buttonClick = true;
                scrollMode = !scrollMode;
                isTimelineSeeking = scrollMode;
                return true;
            }
            else if(x>w*0.92f - h*0.15f && x<w*0.98f - h*0.15f && y>h*0.75f && y<h*0.75f+w*0.06f) //TL toggle
            {
                TIMELINE_MODE = !TIMELINE_MODE;
                editMode = MODE_SELECTION;
                scrollMode = false;
                buttonClick = true;
                bg = base();
            }
            else if(x<w*0.1 && y>h*0.25 && y<h*.25+g*24*10 && !TIMELINE_MODE) // playbackspeed
            {
                if(y < h*0.25 + g*24 * 2){ //1.5x
                    playbackSpeed = 1.5f;
                    playbackInt = 0;
                }else if(y < h*0.25 + g*24*4){ //1.0x
                    playbackSpeed = 1.0f;
                    playbackInt = 1;
                }else if(y < h*0.25 + g*24*6){ //0.75x
                    playbackSpeed = 0.75f;
                    playbackInt = 2;
                }else if(y < h*0.25 + g*24*8){ //0.5x
                    playbackSpeed = 0.5f;
                    playbackInt = 3;
                }else{ //0.25x . unused
                    return true;
                    //playbackSpeed = 0.25f;
                    //playbackInt = 4;
                }
                offsetAdjustMs = System.currentTimeMillis() + 1000;
                //lastTime = mediaPlayer.getCurrentPosition();
                //mAudioPlayer.setPlaybackSpeed(playbackSpeed);
                mp.setSpeed(playbackSpeed);

                //mediaPlayer.setPlaybackSpeed(playbackSpeed);
            }
            else if(x >= w*0.45f - ICON_LEFT.getWidth()/2f && x <= w*0.45f + ICON_LEFT.getWidth()/2f && y >= h*0.04f - ICON_LEFT.getHeight()/2f && y <= h*0.04f + ICON_LEFT.getHeight()/2f) //BEAT DIV LEFT
            {
                beatDivIndex--;
                beatDivIndex = Math.max(beatDivIndex, 0);
            }
            else if(x >= w*0.55f - ICON_LEFT.getWidth()/2f && x <= w*0.55f + ICON_LEFT.getWidth()/2f && y >= h*0.04f - ICON_LEFT.getHeight()/2f && y <= h*0.04f + ICON_LEFT.getHeight()/2f) //BEAT DIV RIGHT
            {
                beatDivIndex++;
                beatDivIndex = Math.min(beatDivIndex, 7);
            }
            else if(x>w*0.92f && x<w*0.98f && y>h*0.6f && y<h*0.6f+w*0.06f) //empty -> copy
            {
                buttonClick = true;
                touchUP = false;

                if(!copyStatus){
                    copyToClipboard();
                }else if(copyClipboard.size() > 0){
                    for(HitObject ho : HitObjects) ho.isSelected = false;
                    int firstOffset = 0;
                    int offsetdiff = 0;
                    for(HitObject ho : copyClipboard){
                        if(firstOffset == 0){
                            firstOffset = ho.offset;
                            offsetdiff = currentPosition - firstOffset;
                        }
                        String s = "";
                        ho.type = 0;
                        if(ho.notetype.equals("circle")) ho.type += 1;
                        if(ho.notetype.equals("slider")) ho.type += 2;
                        if(ho.notetype.equals("spinner")) ho.type += 8;
                        if(ho.skip > 0){
                            for(int i=2; i>=0; i--){
                                if(ho.skip >= Math.pow(2, i)){
                                    ho.skip -= Math.pow(2, i);
                                    ho.type += Math.pow(2, i+4);
                                }
                            }
                        }
                        if(ho.NC) ho.type += 4;
                        s = ho.x + "," + ho.y + "," + ho.offset + "," + ho.type + "," + ho.hitsound;
                        if(ho.notetype.equals("circle")){
                            s += "," + ho.extra;
                        }else if(ho.notetype.equals("slider")){
                            s += "," + ho.sliderType;
                            for(int i=1; i<ho.sliderPoints.size() - 1; i++){
                                s += "|" + ho.sliderPoints.get(i).x + ":" + ho.sliderPoints.get(i).y;
                            }
                            s += "," + ho.sliderRepeat + "," + ho.sliderLength + "," + ho.extra;
                        }else{
                            s += "," + ho.spinnerEndOffset + "," + ho.extra;
                        }

                        HitObject tmp = new HitObject(s);
                        tmp.offset = ho.offset + offsetdiff;
                        toBeAdded.add(tmp);
                    }
                    removeHitObject();
                    copyClipboard.clear();
                }

                copyStatus = !copyStatus;
            }
            else if(x>w*0.92f && x<w*0.98f && y>h*0.45f && y<h*0.45f+w*0.06f) //remove notes
            {
                buttonClick = true;
                touchUP = false;
                removeStatus = true;
            }
            else if(x>w*0.92f && x<w*0.98f && y>h*0.3f && y<h*0.3f+w*0.06f) //scale
            {
                buttonClick = true;
                touchUP = false;
                handler_scale.sendEmptyMessage(0);
                return true;
            }
            else if(x>w*0.92f - h*0.15f && x<w*0.98f - h*0.15f && y>h*0.3f && y<h*0.3f+w*0.06f) //rotate
            {
                buttonClick = true;
                touchUP = false;
                handler_rotate.sendEmptyMessage(0);
                return true;
            }
            else if(x>w*0.92f - h*0.15f && x<w*0.98f - h*0.15f && y>h*0.45f && y<h*0.45f+w*0.06f) //vflip
            {
                buttonClick = true;
                touchUP = false;
                for(HitObject ho : HitObjects){
                    if(ho.isSelected){
                        ho.y = 384 - ho.y;
                        if(ho.notetype.equals("slider")){
                            for (int index = 0; index < ho.sliderPoints.size(); index++) {
                                PathPoint p = ho.sliderPoints.get(index);
                                Log.e("onTouch", "moving " + index + " : " + p.x + " / " + p.y);
                                p.y = 384 - p.y;
                                if(index == ho.sliderPoints.size() - 1) p.y = 384 - p.y;
                            }
                            if(ho.sliderType.equals("P")){
                                ho.slider_P();
                            }else{
                                ho.bezier();
                            }
                            if(ho.sliderBody != null){
                                ho.sliderBody.recycle();
                                ho.sliderBody = null;
                            }
                        }


                    }
                }
                return true;
            }
            else if(x>w*0.92f - h*0.15f && x<w*0.98f - h*0.15f && y>h*0.6f && y<h*0.6f+w*0.06f) //hflip
            {
                buttonClick = true;
                touchUP = false;
                for(HitObject ho : HitObjects){
                    if(ho.isSelected){
                        ho.x = 512 - ho.x;
                        if(ho.notetype.equals("slider")){
                            for (int index = 0; index < ho.sliderPoints.size(); index++) {
                                PathPoint p = ho.sliderPoints.get(index);
                                Log.e("onTouch", "moving " + index);
                                p.x = 512 - p.x;
                                if(index == ho.sliderPoints.size() - 1) p.x = 512 - p.x;
                            }
                            if(ho.sliderType.equals("P")){
                                ho.slider_P();
                            }else{
                                ho.bezier();
                            }
                            if(ho.sliderBody != null){
                                ho.sliderBody.recycle();
                                ho.sliderBody = null;
                            }

                        }
                    }
                }
                return true;
            }
            else if(x>w*0.12f && x<w*0.18f && y>h*0.75f && y<h*0.75f+w*0.06f) //multi select
            {
                touchUP = false;
                multiSelect = !multiSelect;
                if(multiSelect){
                    preventSelection = true;
                }
            }
            else if(x>w*0.12f && x<w*0.18f && y>h*0.6f && y<h*0.6f+w*0.06f && selectCount > 0) //deselect all
            {
                touchUP = false;
                for(HitObject ho : HitObjects){
                    ho.isSelected = false;
                }
            }
            else if(x>w*0.12f && x<w*0.18f && y>h*0.45f && y<h*0.45f+w*0.06f && multiSelect) //select all
            {
                touchUP = false;
                for(HitObject ho : HitObjects){
                    ho.isSelected = true;
                }
            }
            else if(x>w*0.12f && x<w*0.18f && y>h*0.3f && y<h*0.3f+w*0.06f) //NC
            {
                touchUP = false;
                int ncCount = 0;
                for(HitObject ho : HitObjects) if(ho.isSelected && ho.NC) ncCount++;
                if(selectCount > 1){
                    if(ncCount == 0){
                        for(HitObject ho : HitObjects){
                            if(ho.isSelected) ho.NC = true;
                        }
                    }else{
                        for(HitObject ho : HitObjects){
                            if(ho.isSelected) ho.NC = false;
                        }
                    }
                }else if(selectCount == 1){
                    selectedNote.NC = !selectedNote.NC;
                }
            }
            else if(x>w*0.92f - h*0.15f && x<w*0.98f - h*0.15f && y>h*0.15f && y<h*0.15f+w*0.06f && selectCount == 1 && selectedNote.notetype.equals("slider")) //sliderconvert
            {
                touchUP = false;
                handler_sliderconvert.sendEmptyMessage(0);
            }
            else if(x>w*0.92f && x<w*0.98f && y>h*0.15f && y<h*0.15f+w*0.06f && selectCount == 1 && selectedNote.notetype.equals("slider")) //slidersetting
            {
                Message msg = new Message();
                msg.obj = selectedNote;
                handler_slidersetting.sendMessage(msg);
            }
            else if(x>w - ICON_SONGSETUP.getWidth() && y<ICON_SONGSETUP.getHeight()  * 2) //Song Setup Box Toggle
            {
                isSongsetupOpened = !isSongsetupOpened;
                handler_songSetup.sendEmptyMessage(0);
            }
            else if(x > w - ICON_SONGSETUP.getWidth() - ICON_TIMINGSETUP.getWidth() - w*0.03f && x < w - ICON_SONGSETUP.getWidth() - w*0.03f && y < ICON_TIMINGSETUP.getHeight() * 2) //Timing Setup?
            {
                handler_timingSetup.sendEmptyMessage(0);
            }
            else if(x>w*.15f && x<w*.95f && y>h*.9f && TIMELINE_MODE) // Timeline Click
            {

                float distance;
                float minDistance = w;
                int selectOffset = -65535;
                boolean isClickable = false;
                float ratio = CS5CircleSize / CircleSize;
                preventSelection = false;

                if(multiSelect){
                    for (HitObject ho : HitObjects) {
                        float _w = (w*0.55f) + (float)(ho.offset - currentPosition)*timelineZoomScale;
                        distance = (float)Math.sqrt(Math.pow(_w - x, 2) + Math.pow((h - CS5CircleSize * 0.75f) - y, 2));
                        if(minDistance > distance){
                            minDistance = distance;

                            if(distance <= CS5CircleSize * 0.75f){
                                selectOffset = ho.offset;
                            }
                        }
                    }

                    for (HitObject ho : HitObjects) {
                        if(selectOffset == ho.offset){
                            ho.isSelected = !ho.isSelected;
                            break;
                        }
                    }
                    return true;
                }

                for (HitObject ho : HitObjects) {
                    float _w = w*0.55f + (ho.offset - currentPosition)*timelineZoomScale;
                    //if(_w < w*0.15f || _w>w) return;
                    distance = Math.abs(_w - x);

                    if(distance < ratio * CircleSize){
                        isClickable = true;
                        preventSelection = true;
                    }
                }
                if(isClickable && toBeMoved.size() > 0){
                    movingNoteStatus = true;
                }else{
                    Log.e("onTouch", "movingNoteStatus Off");
                    movingNoteStatus = false;
                }

                if(!movingNoteStatus){
                    toBeMoved.clear();
                    isSingleNoteSelected = false;
                }

            }
            else if(y>top && y<top+g*384 && x>left && x<left+g*512 && editMode==MODE_CIRCLE) //Mapping area, placing circle
            {
                addCircle((Math.round((touch_x-left)/g)), (Math.round((touch_y-top)/g)), currentPosition);
                removeStatus = true;
                return true;
            }
            else if(y>top && y<top+g*384 && x>left && x<left+g*512 && editMode==MODE_SLIDER) //Mapping area, placing slider
            {
                if(!placingSliderStatus){
                    placingSliderStatus = true;
                    for(HitObject ho : HitObjects){
                        ho.isSelected = false;
                    }
                    addSlider((Math.round((touch_x-left)/g)), (Math.round((touch_y-top)/g)), currentPosition);
                    removeStatus = true;
                    return true;
                }

                for(HitObject ho : HitObjects){
                    if(ho.isSelected){
                        selectedNote = ho;
                    }
                }

                int placeX = (Math.round((touch_x-left)/g));
                int placeY = (Math.round((touch_y-top)/g));

                PathPoint p = new PathPoint();
                p.x = placeX;
                p.y = placeY;
                selectedNote.sliderPoints.add(p);
                if(selectedNote.sliderType.equals("P")){
                    setTimingPoints(selectedNote.offset);
                    double beatLength = beatDuration / beatDivisor[beatDivIndex];
                    int beatCount = (int)((selectedNote.getPerfectLength() * beatDuration) / (speed * SV * 100 * beatLength));
                    beatCount = Math.max(1, beatCount);
                    selectedNote.sliderLength = (beatCount * beatLength * speed * SV * 100) / beatDuration;
                    selectedNote.slider_P();
                }else{
                    setTimingPoints(selectedNote.offset);
                    double beatLength = beatDuration / beatDivisor[beatDivIndex];
                    int beatCount = (int)((selectedNote.getBezierLength() * beatDuration) / (speed * SV * 100 * beatLength));
                    beatCount = Math.max(1, beatCount);
                    //beatLength * beatCount = ((ho.sliderLength * beatDuration) / (speed * SV * 100));
                    //ho.sliderLength = beatCount * (beatDuration / beatDivisor[beatDivIndex]) * speed * SV * 100 * beatDuration;
                    selectedNote.sliderLength = (beatCount * beatLength * speed * SV * 100) / beatDuration;
                    selectedNote.bezier();
                }
                if(selectedNote.sliderBody != null) {
                    selectedNote.sliderBody.recycle();
                    selectedNote.sliderBody = null;
                }
            }
            else if(y>top && y<top+g*384 && x>left && x<left+g*512 && editMode==MODE_SELECTION) // Selection, mapping area
            {
                Log.e("onTouch", "selection, mapping area");
                boolean isClickable = false;
                if(multiSelect){ // MULTI SELECTION
                    float distance;
                    float minDistance = w;
                    int selectOffset = -65536;
                    for (HitObject ho : HitObjects) {
                        boolean statusChanged = false; // in case if TIMELINE_MODE changes isSelected twice
                        distance = (float)Math.sqrt(Math.pow(left+g*ho.x - x, 2) + Math.pow(top+g*ho.y - y, 2));

                        if(ho.offset < currentPosition + ApproachingTime && ho.offset + 500 > currentPosition && minDistance > distance){
                            minDistance = distance;
                            selectOffset = ho.offset;
                        }
                    }

                    for (HitObject ho : HitObjects) {
                        if(selectOffset == ho.offset){
                            ho.isSelected = !ho.isSelected;
                            break;
                        }
                    }


                    return true;
                }

                if(selectCount == 1 && toBeMoved.size() != 0){
                    HitObject ho = toBeMoved.get(0);
                    float minDistance = g * 16;
                    //sliderPointIndex = -1;
                    int tmpIndex = -2;
                    PathPoint _p = new PathPoint();
                    boolean sliderpointClick = false;
                    sliderPointAdd = false;
                    for(int i=0; i<ho.sliderPoints.size(); i++){
                        PathPoint p = ho.sliderPoints.get(i);
                        float distance = (float)Math.sqrt(Math.pow(left+g*p.x - x, 2) + Math.pow(top+g*p.y - y, 2));
                        Log.e("onTouch", "distance : " + distance);
                        if(minDistance > distance){
                            Log.e("onTouch", "got minDistance at " + i);
                            minDistance = distance;
                            tmpIndex = i;
                            _p = p;
                            sliderpointClick = true;
                        }
                    }
                    if(!sliderpointClick){
                        minDistance = g * 16;
                        for(int i=0; i<ho.sliderPoints.size() - 1; i++){
                            PathPoint p = ho.sliderPoints.get(i);
                            PathPoint nextp = ho.sliderPoints.get(i+1);
                            Log.e("onTouch", "mindistance " + minDistance + " " + i);
                            Log.e("onTouch", "pDistance" + pDistance(x, y, (float)(left + g*p.x), (float)(top + g*p.y), (float)(left + g*nextp.x), (float)(top + g*nextp.y)));
                            if(minDistance > pDistance(x, y, (float)(left + g*p.x), (float)(top + g*p.y), (float)(left + g*nextp.x), (float)(top + g*nextp.y))){
                                minDistance = (float)(pDistance(x, y, (float)(left + g*p.x), (float)(top + g*p.y), (float)(left + g*nextp.x), (float)(top + g*nextp.y)));
                                sliderPointAdd = true;
                                sliderPointIndex = i;

                            }
                        }
                        if(minDistance != g * 16){
                            Log.e("onTouch", "clicked " + sliderPointIndex);
                            popupStatus = true;
                            popupX = x;
                            popupY = y;
                            sliderPointAddX = (int)((x - left) / g);
                            sliderPointAddY = (int)((y - top) / g);
                            popupStr = new String[]{"Add a new slider anchor"};
                            popupColor = new int[]{Color.WHITE};

                            return true;
                        }
                    }
                    if(tmpIndex == sliderPointIndex && sliderPointIndex > 0){
                        popupStatus = true;
                        popupX = (float)(left + g*selectedNote.sliderPoints.get(sliderPointIndex).x);
                        popupY = (float)(top + g*selectedNote.sliderPoints.get(sliderPointIndex).y);
                        sliderPointAddX = (int)selectedNote.sliderPoints.get(sliderPointIndex).x;
                        sliderPointAddY = (int)selectedNote.sliderPoints.get(sliderPointIndex).y;
                        popupStr = new String[]{"Add a new slider anchor", "Delete slider anchor"};
                        popupColor = new int[]{Color.WHITE, Color.RED};
                    }else{
                        Log.e("onTouch", "no");
                        popupStatus = false;
                    }
                    sliderPointIndex = tmpIndex;
                    if(minDistance <= g*20 && sliderPointIndex > -1){
                        Log.e("onTouch", "moving sliderpoint : " + sliderPointIndex);
                        movingSliderPointStatus = true;
                        movingNoteStatus = false;
                        sliderTmpOffset = ho.offset;
                        return true;
                    }
                };

                for (HitObject ho : HitObjects) {
                    float _w = w*0.55f + (ho.offset - currentPosition)*timelineZoomScale;
                    //if(_w < w*0.15f || _w>w) return;
                    float distance = (float)Math.sqrt(Math.pow(left+g*ho.x - x, 2) + Math.pow(top+g*ho.y - y, 2));

                        if(ho.offset < currentPosition + ApproachingTime && ho.offset + 500 > currentPosition && distance <= CircleSize){
                            Log.e("onTouch", "this note is clickable : " + ho.offset);
                            isClickable = true;
                        }


                    if(_w >= minX && _w <= maxX && maxY >= h*0.95f){
                        isClickable = true;
                    }
                }
                if(isClickable && toBeMoved.size() > 0){
                    movingNoteStatus = true;
                }else{
                    Log.e("onTouch", "movingNoteStatus Off");
                    movingNoteStatus = false;
                }

                    boolean action = false;

                    if(!movingNoteStatus){
                        toBeMoved.clear();
                        isSingleNoteSelected = false;
                    }
                int noteSelectionCounter = 0;
                    for(HitObject _ho : HitObjects){
                        if (_ho.isSelected) noteSelectionCounter++;
                    }
            }
            else if(y>top && y<top+g*384 && x>left && x<left+g*512 && editMode==MODE_SPINNER) // Selection, mapping area
            {
                Toast.makeText(getContext(), "Spinner isn't supported yet", Toast.LENGTH_SHORT).show();
            }
            else if(y > top+g*384 && TIMELINE_MODE){ //TIMELINE MODE, select a note
                boolean isClickable = false;
                float minDistance = w;
                float ratio = CS5CircleSize / CircleSize;
                for (HitObject ho : HitObjects) {
                    float _w = w*0.55f + (ho.offset - currentPosition)*timelineZoomScale;
                    //if(_w < w*0.15f || _w>w) return;
                    float distance = Math.abs(_w - x);

                    if(distance < ratio * CircleSize){
                        isClickable = true;
                    }
                }
                if(isClickable){
                    movingNoteStatus = true;
                }else{
                    Log.e("onTouch", "movingNoteStatus Off");
                    movingNoteStatus = false;
                }

                if(!movingNoteStatus){
                    toBeMoved.clear();
                    isSingleNoteSelected = false;
                }
            }


            for(int i=0; i<4; i++){
                if(x<w*0.1f && h*0.1f+h*0.2f*i<y && h*0.25f+h*0.2f*i>y){
                    editMode = i;
                    if(placingSliderStatus){
                        placingSliderStatus = false;
                        PathPoint p = new PathPoint();
                        p.x = selectedNote.sliderPoints.get(selectedNote.sliderPoints.size() - 1).x;
                        p.y = selectedNote.sliderPoints.get(selectedNote.sliderPoints.size() - 1).y;
                        selectedNote.sliderPoints.add(p);
                    }
                    break;
                }
            }

            if(!buttonClick && isTimelineSeeking && editMode==MODE_SELECTION) {
                firstClick_offset = currentPosition;
                int offsetGap = songDuration;
                int selectedOffset = 0;
                for (HitObject ho : HitObjects) {
                    ho.isSelected = false;
                }
                for (HitObject ho : HitObjects) {
                    float distance = (float)Math.sqrt(Math.pow(left+g*ho.x - x, 2) + Math.pow(top+g*ho.y - y, 2));
                    if (distance < CircleSize/2 && ho.offset < currentPosition + ApproachingTime && ho.offset + 500 > currentPosition) {
                        if(offsetGap > currentPosition - ho.offset) {
                            offsetGap = currentPosition - ho.offset;
                            selectedOffset = ho.offset;
                        }
                    }
                }
                for (HitObject ho : HitObjects) {
                    if(ho.offset == selectedOffset){
                        ho.isSelected = true;
                    }
                }
            }

        }
        if(event.getAction() == MotionEvent.ACTION_MOVE & touchUP){
            Log.i("onTouch", "ACTION_MOVE");
            if(x>w*.15f && x<w*.95f && y>h*.9f && !TIMELINE_MODE && dragging_x == -1) { //곡 탐색
                seekEvent = true;
            }

            dragging_x = x;
            dragging_y = y;

            if(Math.sqrt(Math.pow(firstClick_x - dragging_x, 2) + Math.pow(firstClick_y - dragging_y, 2)) <= g*3){
                Log.e("onTouch", "distance low, passing");
                //return true;
            }

            if(multiSelect){
                Log.e("onTouch_MOVE", "multiSelect");
                return true;
            }

            if(placingSliderStatus){
                Log.e("onTouch_MOVE", "placingSlider");
                return true;
            }

                if(movingNoteStatus && y < top + g*384){
                    float movedX = dragging_x - firstClick_x;
                    float movedY = dragging_y - firstClick_y;
                    int diff_x = 0, diff_y = 0;

                    for(HitObject ho : HitObjects) {
                        int snapLeniency = 4;
                        for (HitObject tbm : toBeMoved) { //check if snappable
                            int tmpx, tmpy;
                            tmpx = map(tbm.x + (int) ((movedX) / g), 0, 512);
                            tmpy = map(tbm.y + (int) ((movedY) / g), 0, 384);

                            if(ho.offset < currentPosition + ApproachingTime && !ho.dead && Math.abs(tmpx - ho.x) <= snapLeniency && Math.abs(tmpy - ho.y) <= snapLeniency && tmpy + snapLeniency >= ho.y && tmpy - snapLeniency <= ho.y && tbm.offset != ho.offset){
                                Log.e("snap", "snapping with : " + ho.offset + " / " + tbm.offset);
                                diff_x = ho.x - tbm.x;
                                diff_y = ho.y - tbm.y;
                            }
                        }
                    }

                    if(diff_x != 0 || diff_y != 0){
                        movedX = g * (diff_x);
                        movedY = g * diff_y;
                    }

                    for(HitObject ho : HitObjects){
                        if(ho.isSelected){
                            for(HitObject tbm : toBeMoved){
                                if(ho.offset == tbm.offset) {
                                    if(ho.notetype.equals("circle")){
                                        ho.x = map(tbm.x + (int) ((movedX) / g), 0, 512);
                                        ho.y = map(tbm.y + (int) ((movedY) / g), 0, 384);
                                    }

                                    if(ho.notetype.equals("slider") && tbm.notetype.equals("slider")) {
                                        boolean sliderstuck = false;
                                        if (tbm.x + (int) ((movedX) / g) > 512
                                                || tbm.x + (int) ((movedX) / g) < 0
                                                || tbm.y + (int) ((movedY) / g) > 384
                                                || tbm.y + (int) ((movedY) / g) < 0
                                                || tbm.endx + (int) ((movedX) / g) > 512
                                                || tbm.endx + (int) ((movedX) / g) < 0
                                                || tbm.endy + (int) ((movedY) / g) > 384
                                                || tbm.endy + (int) ((movedY) / g) < 0
                                        ) {
                                            sliderstuck = true;
                                        }
                                        if (!sliderstuck) {
                                            ho.x = tbm.x + (int) ((movedX) / g);
                                            ho.y = tbm.y + (int) ((movedY) / g);
                                            ho.Xmin = tbm.Xmin + (int) ((movedX) / g);
                                            ho.Xmax = tbm.Xmax + (int) ((movedX) / g);
                                            ho.Ymin = tbm.Ymin + (int) ((movedY) / g);
                                            ho.Ymax = tbm.Ymax + (int) ((movedY) / g);
                                            ho.endx = tbm.endx + (int) ((movedX) / g);
                                            ho.endy = tbm.endy + (int) ((movedY) / g);
                                            for (int i = 0; i < ho.sliderPoints.size(); i++) {
                                                ho.sliderPoints.get(i).x = tbm.sliderPoints.get(i).x + (int) (movedX / g);
                                                ho.sliderPoints.get(i).y = tbm.sliderPoints.get(i).y + (int) (movedY / g);
                                            }
                                            for (int i = 0; i < ho.sliderCoordinates.size(); i++) {
                                                try {
                                                    ho.sliderCoordinates.get(i).x = tbm.sliderCoordinates.get(i).x + (int) ((movedX));
                                                    ho.sliderCoordinates.get(i).y = tbm.sliderCoordinates.get(i).y + (int) ((movedY));
                                                } catch (Exception e) {

                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    return true;
                }

                if(movingSliderPointStatus){
                    if(selectCount != 1) return true;
                    float movedX = dragging_x - firstClick_x;
                    float movedY = dragging_y - firstClick_y;
                    for(HitObject ho : HitObjects){
                        if(ho.isSelected) {
                            if(!ho.notetype.equals("slider")) return true;
                            HitObject tbm = toBeMoved.get(0);
                            PathPoint p = ho.sliderPoints.get(sliderPointIndex);
                            PathPoint tbm_p = tbm.sliderPoints.get(sliderPointIndex);
                            PathPoint p2 = p;
                            PathPoint tbm_p2 = tbm_p;
                            if(sliderPointIndex < ho.sliderPoints.size() - 1){
                                p2 = ho.sliderPoints.get(sliderPointIndex+1);
                                tbm_p2 = tbm.sliderPoints.get(sliderPointIndex+1);
                            }
                            //PathPoint p2 = ho.sliderPoints.get(sliderPointIndex+1);

                            //PathPoint tbm_p2 = tbm.sliderPoints.get(sliderPointIndex+1);
                            p.x = tbm_p.x + (int)((movedX) / g);
                            p.y = tbm_p.y + (int)((movedY) / g);
                            if(sliderPointIndex < ho.sliderPoints.size() - 1 && tbm_p.x == tbm_p2.x && tbm_p.y == tbm_p2.y){ //in case if the point is red
                                p2.x = tbm_p2.x + (int)((movedX) / g);
                                p2.y = tbm_p2.y + (int)((movedY) / g);
                            }
                            if(sliderPointIndex == 0){
                                ho.x = tbm.x + (int) ((movedX) / g);
                                ho.y = tbm.y + (int) ((movedY) / g);
                            }
                            if(ho.sliderBody != null && !ho.sliderBody.isRecycled()) sliderBodyTmp = ho.sliderBody;
                            if(ho.sliderType.equals("P")){
                                setTimingPoints(ho.offset);
                                double beatLength = beatDuration / beatDivisor[beatDivIndex];
                                int beatCount = (int)((ho.getPerfectLength() * beatDuration) / (speed * SV * 100 * beatLength));
                                beatCount = Math.max(1, beatCount);
                                ho.sliderLength = (beatCount * beatLength * speed * SV * 100) / beatDuration;
                                ho.slider_P();
                            }else{
                                setTimingPoints(ho.offset);
                                double beatLength = beatDuration / beatDivisor[beatDivIndex];
                                int beatCount = (int)((ho.getBezierLength() * beatDuration) / (speed * SV * 100 * beatLength));
                                beatCount = Math.max(1, beatCount);
                                //beatLength * beatCount = ((ho.sliderLength * beatDuration) / (speed * SV * 100));
                                //ho.sliderLength = beatCount * (beatDuration / beatDivisor[beatDivIndex]) * speed * SV * 100 * beatDuration;
                                ho.sliderLength = (beatCount * beatLength * speed * SV * 100) / beatDuration;
                                ho.bezier();


                            }
                            if(ho.sliderBody != null && sliderRecycleMs + 50 < System.currentTimeMillis()) {
                                sliderRecycleMs = System.currentTimeMillis();
                                ho.sliderBody.recycle();
                                ho.sliderBody = null;
                            }
                        }
                    }
                    return true;
                }


            minX = Math.min(firstClick_x, dragging_x);
            maxX = Math.max(firstClick_x, dragging_x);
            minY = Math.min(firstClick_y, dragging_y);
            maxY = Math.max(firstClick_y, dragging_y);

            if(isTimelineSeeking){
                buttonClick = true;
                if(Math.abs(firstClick_x-dragging_x) > BPM_overall*timelineZoomScale/beatDivisor[beatDivIndex]){
                    isSeeking = true;
                    int calcPostion = currentPosition;

                    boolean isSnapped = false;
                    if(firstClick_x < dragging_x) currentPosition = snapPosition(false, currentPosition);
                    else currentPosition = snapPosition(true, currentPosition);

                    seekEvent = true;
                    seekUnit = 1;
                    firstClick_x = dragging_x;
                }
            }

            if(!preventSelection){
                for (HitObject ho : HitObjects) {
                    float _w = w*0.55f + (ho.offset - currentPosition)*timelineZoomScale;
                    //if(_w < w*0.15f || _w>w) return;
                    float distance = (float)Math.sqrt(Math.pow(left+g*ho.x - x, 2) + Math.pow(top+g*ho.y - y, 2));

                    if (left + g * ho.x > minX && left + g * ho.x < maxX && top + g * ho.y > minY && top + g * ho.y < maxY) {
                        if(ho.offset < currentPosition + ApproachingTime && ho.offset + 500 > currentPosition){
                            ho.isSelected = true;
                        }

                    }else if(distance > CircleSize/2){
                        ho.isSelected = false;
                    }
                    if(_w >= minX && _w <= maxX && maxY >= h*0.95f){
                        ho.isSelected = true;
                    }
                }
            }else{
                double opb = BPM_overall;
                float _w = (float)((w*0.55f - ((4f*beatDivisor[beatDivIndex]))*(opb/beatDivisor[beatDivIndex])*timelineZoomScale) - (((currentPosition - lastTimingOffset)%opb)*timelineZoomScale));
                float _w2 = (float)((w*0.55f - ((4f*beatDivisor[beatDivIndex])+1)*(opb/beatDivisor[beatDivIndex])*timelineZoomScale) - (((currentPosition - lastTimingOffset)%opb)*timelineZoomScale));
                float diff = Math.abs(_w - _w2);
                boolean isMoved = false;
                if(Math.abs(firstClick_x - dragging_x ) >= diff){
                    boolean isForward = false;
                    if(firstClick_x < dragging_x) isForward = true;
                    else isForward = false;

                    for(HitObject ho : HitObjects){
                        if(ho.isSelected){
                            ho.offset = snapPosition(isForward, ho.offset);
                            isMoved = true;
                        }
                    }
                    firstClick_x = dragging_x;
                }
            }
        }
        if(event.getAction() == MotionEvent.ACTION_UP){
            pinchMode = false;
            movingNoteStatus = false;

            if(placingSliderStatus){
                Log.e("onTouch_UP", "placingSlider");
                if(selectedNote != null && selectedNote.sliderBody != null){
                    selectedNote.sliderBody.recycle();
                    selectedNote.sliderBody = null;
                }
                return true;
            }

            for (HitObject ho : HitObjects) {
                boolean selecionStatus = false; //F = note, T = sliderPoint
                float distance = (float)Math.sqrt(Math.pow(left+g*ho.x - x, 2) + Math.pow(top+g*ho.y - y, 2));
                float minDistance = w;
                if(distance < minDistance) minDistance = distance;
                if(!ho.dead && distance <= CircleSize/2 && selectCount <= 1 && ho.offset <= currentPosition + ApproachingTime && !movingNoteStatus){
                    for(HitObject _ho : HitObjects){
                        _ho.isSelected = false;
                    }
                    isSingleNoteSelected = true;
                    ho.isSelected = true;
                    movingNoteStatus = true;
                }

                if(ho.isSelected){
                    HitObject _t = new HitObject();
                    _t.x = ho.x;
                    _t.y = ho.y;
                    _t.Xmin = ho.Xmin;
                    _t.Ymin = ho.Ymin;
                    _t.endx = ho.endx;
                    _t.endy = ho.endy;
                    _t.offset = ho.offset;
                    _t.notetype = ho.notetype;
                    if(ho.notetype.equals("slider")){
                        for(int i=0; i<ho.sliderPoints.size(); i++){
                            PathPoint p = ho.sliderPoints.get(i);
                            _t.sliderPoints.add(new PathPoint(p));
                        }
                        for(PathPoint p : ho.sliderCoordinates){
                            _t.sliderCoordinates.add(new PathPoint(p));
                        }
                        //_t.sliderPath = ho.sliderPath;
                    }
                    toBeMoved.add(_t);

                    if(minDistance <= CircleSize/2) movingNoteStatus = true;
                }
            }

            if(movingSliderPointStatus){
                for(HitObject ho : HitObjects){
                    if(ho.isSelected) {

                    }

                }
            }
            movingSliderPointStatus = false;
            if(x>w*.15f && x<w*.95f && y>h*.9f && !TIMELINE_MODE && dragging_x == -1) { //곡 탐색
                seekEvent = true;
            }
            if(dragging_x != -1){
            }
            if(!buttonClick) {
                dragging_x = -1;
                dragging_y = -1;
            }
            touchUP = true;

            sortObjects();
        }

        if((seekEvent && dragging_x == -1) || (seekEvent && seekUnit != 0)){
            isSeeking = true;
            lastMillis = System.currentTimeMillis();
            //currentPosition = (int)(mp.getDuration() * (x-w*.15f)/(w*.8f));
            if(seekUnit == 0) currentPosition = (int)(songDuration * (x-w*.15f)/(w*.8f));

            seekPosition = currentPosition;
            //mAudioPlayer.seekTo(currentPosition);
            mp.seekTo(currentPosition);
            currentPosition = (int)mp.getCurrentPosition();
            //mediaPlayer.seekTo(currentPosition);

            for(HitObject ho : HitObjects){
                ho.dead = false;
                if(ho.sliderBody != null){
                    ho.sliderBody.recycle();
                    ho.sliderBody = null;
                }
            }

            for (HitObject ho : HitObjects) {
                ho.prevRepeatCount = 0;
                if(ho.notetype.equals("circle")){
                    if(ho.offset+500 <= currentPosition) ho.dead = true;
                }else if(ho.notetype.equals("slider")){
                    setTimingPoints(ho.offset);
                    int sliderTime = (int)(ho.sliderLength / (speed * SV * 100.0d) * beatDuration);
                    if(ho.offset + sliderTime * ho.sliderRepeat+500 <= currentPosition) {
                        ho.dead = true;
                    }
                }else if(ho.notetype.equals("spinner")){
                    if(ho.spinnerEndOffset <= currentPosition) ho.dead = true;
                    else ho.dead = false;
                }
                if(ho.offset > currentPosition){
                    ho.isPlayed = false;
                    ho.isPlayed_end = false;
                }
                else {
                    ho.isPlayed = true;
                    ho.isPlayed_end = true;
                }
            }
            isSeeking = false;
        }
        if(isPlaying && dragging_x == -1 && x>w*0.9f && x<w*0.96f && y>h*0.75f && y<h*0.75f+w*0.06f){
            //mp.seekTo(currentPosition);

            //mAudioPlayer.seekTo(currentPosition);
            hasStarted = true;
        }

        return true;
    }



    void snapNotes(ArrayList<HitObject> Notes){
        for(HitObject ho : Notes){
            int originOffset = ho.offset;
            if(Math.abs(originOffset - snapPosition(true, ho.offset)) < Math.abs(originOffset - snapPosition(false, ho.offset))){
                ho.offset = snapPosition(true, ho.offset);
            }else if(Math.abs(originOffset - snapPosition(true, ho.offset)) > Math.abs(originOffset - snapPosition(false, ho.offset))){
                ho.offset = snapPosition(false, ho.offset);
            }else{

            }
        }
    }

    boolean sliderToStream(boolean type, int value, int beatDiv){
        //true -> obj
        if(selectCount != 1 || !selectedNote.notetype.equals("slider")) return false;

        ArrayList<HitObject> tmp = new ArrayList<>();

        setTimingPoints(selectedNote.offset);

        double beatgap = beatDuration / (double)beatDiv;

        if(type){
            for(int i=0; i<value; i++){
                PathPoint p = selectedNote.sliderCoordinates.get(i*selectedNote.sliderCoordinates.size()/value);
                p.x = (p.x - left) / g;
                p.y = (p.y - top) / g;
                String s = (int)p.x + "," + (int)p.y + "," + (int)(selectedNote.offset + beatgap * i) + ",1,0,0:0:0:0:";
                toBeAdded.add(new HitObject(s));
            }
        }else{

        }
        //snapNotes(toBeAdded);
        removeHitObject();
        return true;
    }

    void scaleBy(float scale, boolean isPlayfieldCentre, boolean Xaxis, boolean Yaxis){
        int center_x = 256, center_y = 192;
        if(!isPlayfieldCentre){ //Selection Centre
            Polygon polygon = new Polygon();
            for(HitObject ho : HitObjects){
                if(ho.isSelected){
                    polygon.addPoint((float)ho.x, (float)ho.y);
                }
            }
            center_x = polygon.centroidOfPolygon().x;
            center_y = polygon.centroidOfPolygon().y;
        }
        for(HitObject ho : HitObjects){
            if(ho.isSelected){
                int diff_x = ho.x - center_x;
                int diff_y = ho.y - center_y;

                if(Xaxis) ho.x = (int)(center_x + diff_x * scale);
                if(Yaxis) ho.y = (int)(center_y + diff_y * scale);

                if(ho.notetype.equals("slider")){
                    for (int index = 0; index < ho.sliderPoints.size(); index++) {
                        PathPoint p = ho.sliderPoints.get(index);
                        p.x = (int)(center_x + (p.x - center_x) * scale);
                        p.y = (int)(center_y + (p.y - center_y) * scale);
                        if(index == ho.sliderPoints.size() - 1){
                            p.x = (int)(center_x + (p.x - center_x) / scale);
                            p.y = (int)(center_y + (p.y - center_y) / scale);
                        }
                    }
                    if(ho.sliderType.equals("P")){
                        setTimingPoints(ho.offset);
                        double beatLength = beatDuration / beatDivisor[beatDivIndex];
                        int beatCount = (int)((ho.getPerfectLength() * beatDuration) / (speed * SV * 100 * beatLength));
                        beatCount = Math.max(1, beatCount);
                        ho.sliderLength = (beatCount * beatLength * speed * SV * 100) / beatDuration;
                        ho.slider_P();
                    }else{
                        setTimingPoints(ho.offset);
                        double beatLength = beatDuration / beatDivisor[beatDivIndex];
                        int beatCount = (int)((ho.getBezierLength() * beatDuration) / (speed * SV * 100 * beatLength));
                        beatCount = Math.max(1, beatCount);
                        //beatLength * beatCount = ((ho.sliderLength * beatDuration) / (speed * SV * 100));
                        //ho.sliderLength = beatCount * (beatDuration / beatDivisor[beatDivIndex]) * speed * SV * 100 * beatDuration;
                        ho.sliderLength = (beatCount * beatLength * speed * SV * 100) / beatDuration;
                        ho.bezier();
                    }
                    if(ho.sliderBody != null){
                        ho.sliderBody.recycle();
                        ho.sliderBody = null;
                    }
                }
            }
        }
        toBeMoved.clear();
        for (HitObject ho : HitObjects) {
            if(ho.isSelected){
                HitObject _t = new HitObject();
                _t.x = ho.x;
                _t.y = ho.y;
                _t.Xmin = ho.Xmin;
                _t.Ymin = ho.Ymin;
                _t.endx = ho.endx;
                _t.endy = ho.endy;
                _t.offset = ho.offset;
                _t.notetype = ho.notetype;
                if(ho.notetype.equals("slider")){
                    for(int i=0; i<ho.sliderPoints.size(); i++){
                        PathPoint p = ho.sliderPoints.get(i);
                        _t.sliderPoints.add(new PathPoint(p));
                    }
                    for(PathPoint p : ho.sliderCoordinates){
                        _t.sliderCoordinates.add(new PathPoint(p));
                    }
                    //_t.sliderPath = ho.sliderPath;
                }
                toBeMoved.add(_t);
            }
        }
        movingNoteStatus = true;
    }

    void rotateBy(boolean isClockwise, int degree, boolean isPlayfieldCentre){
        int center_x = 256, center_y = 192;
        if(!isPlayfieldCentre){ //Selection Centre
            Polygon polygon = new Polygon();
            for(HitObject ho : HitObjects){
                if(ho.isSelected){
                    polygon.addPoint((float)ho.x, (float)ho.y);
                }
            }
            center_x = polygon.centroidOfPolygon().x;
            center_y = polygon.centroidOfPolygon().y;
        }
        if(selectCount == 1 || (center_x == 0 && center_y == 0)){
            center_x = selectedNote.x;
            center_y = selectedNote.y;
        }
        Log.e("degree", degree +" ; "+center_x + " / " + center_y);
        for(HitObject ho : HitObjects){
            if(ho.isSelected){
                double dSetDegree = Math.toRadians(degree);
                double cosq = Math.cos(dSetDegree);
                double sinq = Math.sin(dSetDegree);
                double sx = ho.x - center_x;
                double sy = ho.y - center_y;
                double rx = (sx * cosq - sy * sinq) + center_x; //결과 좌표 x
                double ry = (sx * sinq + sy * cosq) + center_y; //결과 좌표 y
                ho.x = (int)rx;
                ho.y = (int)ry;
                if(ho.notetype.equals("slider")){
                    for (int index = 0; index < ho.sliderPoints.size(); index++) {
                        PathPoint p = ho.sliderPoints.get(index);
                        sx = p.x - center_x;
                        sy = p.y - center_y;
                        rx = (sx * cosq - sy * sinq) + center_x; //결과 좌표 x
                        ry = (sx * sinq + sy * cosq) + center_y; //결과 좌표 y
                        p.x = (int)rx;
                        p.y = (int)ry;
                        if(index == ho.sliderPoints.size() - 1){
                            dSetDegree = Math.toRadians(-degree);
                            cosq = Math.cos(dSetDegree);
                            sinq = Math.sin(dSetDegree);
                            sx = p.x - center_x;
                            sy = p.y - center_y;
                            rx = (sx * cosq - sy * sinq) + center_x;
                            ry = (sx * sinq + sy * cosq) + center_y;
                            p.x = (int)rx;
                            p.y = (int)ry;
                        }
                    }
                    if(ho.sliderType.equals("P")){
                        ho.slider_P();
                    }else{
                        ho.bezier();
                    }
                    if(ho.sliderBody != null){
                        ho.sliderBody.recycle();
                        ho.sliderBody = null;
                    }
                }
            }
        }
        toBeMoved.clear();
        for (HitObject ho : HitObjects) {
            if(ho.isSelected){
                HitObject _t = new HitObject();
                _t.x = ho.x;
                _t.y = ho.y;
                _t.Xmin = ho.Xmin;
                _t.Ymin = ho.Ymin;
                _t.endx = ho.endx;
                _t.endy = ho.endy;
                _t.offset = ho.offset;
                _t.notetype = ho.notetype;
                if(ho.notetype.equals("slider")){
                    for(int i=0; i<ho.sliderPoints.size(); i++){
                        PathPoint p = ho.sliderPoints.get(i);
                        _t.sliderPoints.add(new PathPoint(p));
                    }
                    for(PathPoint p : ho.sliderCoordinates){
                        _t.sliderCoordinates.add(new PathPoint(p));
                    }
                    //_t.sliderPath = ho.sliderPath;
                }
                toBeMoved.add(_t);
            }
        }
        movingNoteStatus = true;
    }

    public Bitmap base(){
        Bitmap myBitmap = Bitmap.createBitmap((int)w, (int)h, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(myBitmap);
        Paint paint = new Paint();
        paint.setColor(Color.argb(180, 0, 0, 0));
        canvas.drawRect(0, h*.9f, w, h, paint);
        paint.setColor(Color.argb(20, 40,40,40));
        canvas.drawRect(w*.5f - h*.8f*512f/384f/2, h*0.1f,w*.5f + h*.8f*512f/384f/2, h*.9f, paint);
        paint.setColor(Color.WHITE);
        paint.setTextAlign(Paint.Align.RIGHT);
        paint.setTextSize(h*.05f);

        if(!TIMELINE_MODE) {
            paint.setColor(Color.WHITE);
            paint.setStrokeWidth(1);
            paint.setTextSize(h * .04f);
            canvas.drawLine(w * .15f, h * .95f, w * .95f, h * .95f, paint);
        }

        if(MP_PREPARED && !TIMELINE_MODE){
            int prevOffset = 0;
            boolean prevKiai = false;
            paint.setAlpha(180);
            for(TimingPoint tp : TimingPoints){
                if(prevKiai){
                    paint.setColor(Color.argb(180, 218, 122, 29));
                    float prev = w*.15f + (w*.8f*((float)prevOffset/(float)songDuration));
                    float current = w*.15f + (w*.8f*((float)tp.offset/(float)songDuration));
                    canvas.drawRect(prev, h*.935f, current, h*.965f, paint);
                }
                float l = w*.15f + (w*.8f*((float)tp.offset/(float)songDuration));
                if(!tp.status){
                    paint.setColor(Color.GREEN);
                }else{
                    paint.setColor(Color.RED);
                }

                canvas.drawRect(l-1, h*0.915f, l, h*0.95f, paint);
                prevOffset = tp.offset;
                prevKiai = tp.kiai;
            }
            paint.setColor(Color.argb(255, 56, 105, 162));
            if(bookmarks != null){
                for(int offset : bookmarks){
                    float l = w*.15f + (w*.8f*((float)offset/(float)songDuration));
                    canvas.drawRect(l-1, h*0.95f, l, h*0.995f, paint);
                }
            }
        }

        return myBitmap;
    }

    public Bitmap grid(){
        Bitmap myBitmap = Bitmap.createBitmap((int)w, (int)h, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(myBitmap);
        Paint paint = new Paint();
        paint.setColor(Color.LTGRAY);
        paint.setStrokeWidth(1);
        for(int i=0; i<=32; i++) canvas.drawLine((w*.5f - h*.8f*512f/384f/2)+g*16*i, h*.1f, (w*.5f - h*.8f*512f/384f/2)+g*16*i, h*.9f, paint);
        for(int i=0; i<=24; i++) canvas.drawLine((w*.5f - h*.8f*512f/384f/2), h*.1f+g*16*i,(w*.5f + h*.8f*512f/384f/2), h*.1f+g*16*i,paint);
        paint.setStrokeWidth(4);
        canvas.drawLine((w*.5f - h*.8f*512f/384f/2)+g*16*16, h*.1f, (w*.5f - h*.8f*512f/384f/2)+g*16*16, h*.9f, paint);
        canvas.drawLine((w*.5f - h*.8f*512f/384f/2), h*.1f+g*16*12,(w*.5f + h*.8f*512f/384f/2), h*.1f+g*16*12,paint);

        return myBitmap;
    }

    void playHitsound(HitObject ho){
        if(!isPlaying || isSeeking || !mp.isPlaying()) return;

        effects.play(hsId, volume_overall / 100f, volume_overall / 100f, 1, 0, 1f);
    }

    public Handler handler_slidersetting = new Handler(){
        public void handleMessage(Message msg){
            HitObject ho = (HitObject)msg.obj;
            if(!ho.notetype.equals("slider")) return;
            List<String> spinnerArray =  new ArrayList<String>();

            if(ho.sliderPoints.size() == 3){
                spinnerArray.add("Linear");
            }else if(ho.sliderPoints.size() == 4){
                spinnerArray.add("Bezier");
                spinnerArray.add("Perfect");
            }else{
                spinnerArray.add("Bezier");
            }

            ArrayAdapter<String> adapter = new ArrayAdapter<String>(
                    getContext(), android.R.layout.simple_spinner_item, spinnerArray);

            adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
            Spinner sItems = new Spinner(getContext());
            sItems.setAdapter(adapter);
            sItems.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
                @Override
                public void onItemSelected(AdapterView<?> adapterView, View view, int num, long l) {
                    if(ho.sliderPoints.size() == 4){
                        if(num == 0){
                            ho.sliderType = "B";
                        }else{
                            ho.sliderType = "P";
                        }
                        if(ho.sliderType.equals("P")){
                            setTimingPoints(ho.offset);
                            double beatLength = beatDuration / beatDivisor[beatDivIndex];
                            int beatCount = (int)((ho.getPerfectLength() * beatDuration) / (speed * SV * 100 * beatLength));
                            beatCount = Math.max(1, beatCount);
                            ho.sliderLength = (beatCount * beatLength * speed * SV * 100) / beatDuration;
                            ho.slider_P();
                        }else{
                            setTimingPoints(ho.offset);
                            double beatLength = beatDuration / beatDivisor[beatDivIndex];
                            int beatCount = (int)((ho.getBezierLength() * beatDuration) / (speed * SV * 100 * beatLength));
                            beatCount = Math.max(1, beatCount);
                            //beatLength * beatCount = ((ho.sliderLength * beatDuration) / (speed * SV * 100));
                            //ho.sliderLength = beatCount * (beatDuration / beatDivisor[beatDivIndex]) * speed * SV * 100 * beatDuration;
                            ho.sliderLength = (beatCount * beatLength * speed * SV * 100) / beatDuration;
                            ho.bezier();
                        }
                        if(ho.sliderBody != null){
                            ho.sliderBody.recycle();
                            ho.sliderBody = null;
                        }
                        toBeMoved.clear();
                        for (HitObject ho : HitObjects) {
                            if(ho.isSelected){
                                HitObject _t = new HitObject();
                                _t.x = ho.x;
                                _t.y = ho.y;
                                _t.Xmin = ho.Xmin;
                                _t.Ymin = ho.Ymin;
                                _t.endx = ho.endx;
                                _t.endy = ho.endy;
                                _t.offset = ho.offset;
                                _t.notetype = ho.notetype;
                                if(ho.notetype.equals("slider")){
                                    for(int i=0; i<ho.sliderPoints.size(); i++){
                                        PathPoint p = ho.sliderPoints.get(i);
                                        _t.sliderPoints.add(new PathPoint(p));
                                    }
                                    for(PathPoint p : ho.sliderCoordinates){
                                        _t.sliderCoordinates.add(new PathPoint(p));
                                    }
                                    //_t.sliderPath = ho.sliderPath;
                                }
                                toBeMoved.add(_t);
                            }
                        }
                        movingNoteStatus = true;
                    }
                }

                @Override
                public void onNothingSelected(AdapterView<?> adapterView) {

                }
            });

            final EditText et_sliderrepeat = new EditText(getContext());
            et_sliderrepeat.setInputType(InputType.TYPE_CLASS_NUMBER);
            et_sliderrepeat.setText(ho.sliderRepeat+"");

            final SeekBar seekBar_sliderrepeat = new SeekBar(getContext());
            seekBar_sliderrepeat.setMax(8);
            seekBar_sliderrepeat.setProgress(ho.sliderRepeat);
            seekBar_sliderrepeat.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override
                public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                    et_sliderrepeat.setText((progress)+"");
                    seekBar.setProgress(Math.max(1, progress));
                    ho.sliderRepeat = Math.max(1, progress);
                }

                @Override
                public void onStartTrackingTouch(SeekBar seekBar) {
                }

                @Override
                public void onStopTrackingTouch(SeekBar seekBar) {

                }
            });

            final LinearLayout linearLayout_sliderrepeat = new LinearLayout(getContext());
            linearLayout_sliderrepeat.setOrientation(LinearLayout.HORIZONTAL);
            LinearLayout.LayoutParams layoutParams = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.MATCH_PARENT);
            layoutParams.weight = 3;
            linearLayout_sliderrepeat.addView(seekBar_sliderrepeat, layoutParams);
            layoutParams.weight = 1;
            linearLayout_sliderrepeat.addView(et_sliderrepeat, layoutParams);
            linearLayout_sliderrepeat.setWeightSum(4);

            final LinearLayout linearLayout = new LinearLayout(getContext());
            linearLayout.setOrientation(LinearLayout.VERTICAL);
            linearLayout.addView(sItems);
            linearLayout.addView(linearLayout_sliderrepeat);
            new AlertDialog.Builder(getContext())
                    .setTitle("Slider settings")
                    .setView(linearLayout)
                    .setNegativeButton("Close", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface dialog, int which) {
                            dialog.dismiss();
                        }
                    })
                    .setPositiveButton("OK", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface dialog, int which) {
                        }
                    })
                    .show();
        }
    };

    public Handler handler_sliderconvert = new Handler(){
        public void handleMessage(Message msg){
            RadioButton rb1 = new RadioButton(getContext());
            RadioButton rb2 = new RadioButton(getContext());
            rb1.setText("By object count");
            rb1.setId(10);
            rb2.setText("By distance snap");
            rb2.setId(11);
            RadioGroup rg = new RadioGroup(getContext());

            final SeekBar seekBar_objcount = new SeekBar(getContext());
            seekBar_objcount.setMax(17);
            seekBar_objcount.setProgress(5);

            final SeekBar seekBar_distancesnap = new SeekBar(getContext());
            seekBar_distancesnap.setMax(500);
            seekBar_distancesnap.setProgress(100);

            final EditText et_objcount = new EditText(getContext());
            et_objcount.setInputType(InputType.TYPE_CLASS_NUMBER);
            et_objcount.setText("5");

            final EditText et_distancesnap = new EditText(getContext());
            et_distancesnap.setInputType(InputType.TYPE_CLASS_NUMBER);
            et_distancesnap.setText("1.00");

            rb1.setChecked(true);
            seekBar_objcount.setEnabled(false);
            et_objcount.setEnabled(false);
            seekBar_distancesnap.setEnabled(true);
            et_distancesnap.setEnabled(true);

            seekBar_objcount.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override
                public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                    et_objcount.setText((progress)+"");
                    seekBar.setProgress(Math.max(1, progress));
                }

                @Override
                public void onStartTrackingTouch(SeekBar seekBar) {
                }

                @Override
                public void onStopTrackingTouch(SeekBar seekBar) {

                }
            });

            seekBar_distancesnap.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override
                public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                    et_distancesnap.setText((progress/100f)+"");
                    seekBar.setProgress(Math.max(1, progress));
                }

                @Override
                public void onStartTrackingTouch(SeekBar seekBar) {
                }

                @Override
                public void onStopTrackingTouch(SeekBar seekBar) {

                }
            });

            rg.setOnCheckedChangeListener(new RadioGroup.OnCheckedChangeListener() {
                @Override
                public void onCheckedChanged(RadioGroup radioGroup, int i) {
                    if(i == 10){
                        seekBar_objcount.setEnabled(true);
                        et_objcount.setEnabled(true);
                        seekBar_distancesnap.setEnabled(false);
                        et_distancesnap.setEnabled(false);
                    }else{
                        /*
                        seekBar_objcount.setEnabled(false);
                        et_objcount.setEnabled(false);
                        seekBar_distancesnap.setEnabled(true);
                        et_distancesnap.setEnabled(true);
                        */
                        Toast.makeText(getContext(), "This feature is not supported yet", Toast.LENGTH_SHORT).show();
                    }
                }
            });


            LinearLayout.LayoutParams layoutParams = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.MATCH_PARENT);
            layoutParams.weight = 1;
            final LinearLayout linearLayout_obj = new LinearLayout(getContext());
            linearLayout_obj.setOrientation(LinearLayout.HORIZONTAL);
            layoutParams.weight = 2;
            linearLayout_obj.addView(seekBar_objcount, layoutParams);
            layoutParams.weight = 1;
            linearLayout_obj.addView(et_objcount, layoutParams);
            linearLayout_obj.setWeightSum(3);

            final LinearLayout linearLayout_distance = new LinearLayout(getContext());
            linearLayout_distance.setOrientation(LinearLayout.HORIZONTAL);
            layoutParams.weight = 2;
            linearLayout_distance.addView(seekBar_distancesnap, layoutParams);
            layoutParams.weight = 1;
            linearLayout_distance.addView(et_distancesnap, layoutParams);
            linearLayout_distance.setWeightSum(3);

            final SeekBar seekBar_beatdiv = new SeekBar(getContext());
            seekBar_beatdiv.setMax(7);
            seekBar_beatdiv.setProgress(3);

            final TextView textView_beatdiv = new TextView(getContext());
            textView_beatdiv.setText("1/4");

            seekBar_beatdiv.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override
                public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                    textView_beatdiv.setText("1/"+beatDivisor[progress]);
                }

                @Override
                public void onStartTrackingTouch(SeekBar seekBar) {
                }

                @Override
                public void onStopTrackingTouch(SeekBar seekBar) {

                }
            });

            final LinearLayout linearLayout_beatdiv = new LinearLayout(getContext());
            linearLayout_distance.setOrientation(LinearLayout.HORIZONTAL);
            layoutParams.weight = 3;
            linearLayout_beatdiv.addView(seekBar_beatdiv, layoutParams);
            layoutParams.weight = 1;
            linearLayout_beatdiv.addView(textView_beatdiv, layoutParams);
            linearLayout_beatdiv.setWeightSum(4);

            rg.setOrientation(LinearLayout.VERTICAL);
            rg.addView(rb1, layoutParams);
            rg.addView(linearLayout_obj, layoutParams);
            rg.addView(rb2, layoutParams);
            rg.addView(linearLayout_distance, layoutParams);
            rg.addView(linearLayout_beatdiv, layoutParams);

            final LinearLayout linearLayout = new LinearLayout(getContext());
            linearLayout.setOrientation(LinearLayout.VERTICAL);
            //linearLayout.addView(rg, layoutParams);
            //linearLayout.addView(linearLayout_obj, layoutParams);
            //linearLayout.addView(linearLayout_distance, layoutParams);
            new AlertDialog.Builder(getContext())
                    .setTitle("Convert slider to stream")
                    .setView(rg)
                    .setNegativeButton("Close", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface dialog, int which) {
                            dialog.dismiss();
                        }
                    })
                    .setPositiveButton("OK", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface dialog, int which) {
                            if(rb1.isChecked()){
                                if(!sliderToStream(true, seekBar_objcount.getProgress(), beatDivisor[seekBar_beatdiv.getProgress()])) Toast.makeText(getContext(), "Failed to convert stream", Toast.LENGTH_SHORT).show();
                            }else{
                                if(!sliderToStream(false, seekBar_distancesnap.getProgress(), beatDivisor[seekBar_beatdiv.getProgress()])) Toast.makeText(getContext(), "Failed to convert stream", Toast.LENGTH_SHORT).show();
                            }

                        }
                    })
                    .show();
        }
    };

    public Handler handler_scale = new Handler(){
        public void handleMessage(Message msg){
            final SeekBar seekBar_scale = new SeekBar(getContext());
            seekBar_scale.setMax(5000);
            seekBar_scale.setProgress(1000);
            final EditText et_scale = new EditText(getContext());
            et_scale.setInputType(InputType.TYPE_CLASS_NUMBER);
            final TextView textView_txt = new TextView(getContext());
            textView_txt.setText(" Scale the selected objects' spacing by : ");
            seekBar_scale.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override
                public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                    et_scale.setText((progress/1000f)+"");
                }

                @Override
                public void onStartTrackingTouch(SeekBar seekBar) {
                }

                @Override
                public void onStopTrackingTouch(SeekBar seekBar) {

                }
            });

            final LinearLayout linearLayout_degree = new LinearLayout(getContext());
            linearLayout_degree.setOrientation(LinearLayout.HORIZONTAL);
            linearLayout_degree.setWeightSum(8);
            LinearLayout.LayoutParams layoutParams = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.MATCH_PARENT);
            //layoutParams.width = 0;
            layoutParams.weight = 6;
            linearLayout_degree.addView(seekBar_scale, layoutParams);
            layoutParams.weight = 1;
            linearLayout_degree.addView(et_scale, layoutParams);
            final TextView textView_x = new TextView(getContext());
            textView_x.setText(" x");
            linearLayout_degree.addView(textView_x, layoutParams);
            final CheckBox cb_centre = new CheckBox(getContext());
            cb_centre.setText("Playfield Centre");
            final LinearLayout linearLayout_axis = new LinearLayout(getContext());
            linearLayout_axis.setOrientation(LinearLayout.VERTICAL);
            final CheckBox cb_Xaxis = new CheckBox(getContext());
            cb_Xaxis.setText("X-axis");
            cb_Xaxis.setChecked(true);
            final CheckBox cb_Yaxis = new CheckBox(getContext());
            cb_Yaxis.setText("Y-axis");
            cb_Yaxis.setChecked(true);
            linearLayout_axis.addView(cb_Xaxis);
            linearLayout_axis.addView(cb_Yaxis);
            final LinearLayout linearLayout_bottom = new LinearLayout(getContext());
            linearLayout_bottom.setOrientation(LinearLayout.HORIZONTAL);
            linearLayout_bottom.setWeightSum(2);
            layoutParams.weight = 1;
            linearLayout_bottom.addView(cb_centre, layoutParams);
            linearLayout_bottom.addView(linearLayout_axis, layoutParams);
            final LinearLayout linearLayout = new LinearLayout(getContext());
            linearLayout.setOrientation(LinearLayout.VERTICAL);
            linearLayout.addView(textView_txt);
            linearLayout.addView(linearLayout_degree);
            linearLayout.addView(linearLayout_bottom);
            new AlertDialog.Builder(getContext())
                    .setTitle("Scale by")
                    .setView(linearLayout)
                    .setNegativeButton("Close", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface dialog, int which) {
                            dialog.dismiss();
                        }
                    })
                    .setPositiveButton("OK", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface dialog, int which) {
                            if(!et_scale.getText().toString().equals("")) scaleBy(Float.parseFloat(et_scale.getText().toString()), cb_centre.isChecked(), cb_Xaxis.isChecked(), cb_Yaxis.isChecked());
                            else Toast.makeText(getContext(), "invalid value", Toast.LENGTH_SHORT).show();
                        }
                    })
                    .show();
        }
    };

    public Handler handler_rotate = new Handler(){
        public void handleMessage(Message msg){
            final SeekBar seekBar_degree = new SeekBar(getContext());
            seekBar_degree.setMax(360);
            seekBar_degree.setProgress(180);
            final EditText et_degree = new EditText(getContext());
            et_degree.setInputType(InputType.TYPE_CLASS_NUMBER);
            final TextView textView_txt = new TextView(getContext());
            textView_txt.setText(" Enter an angle rotate by : ");
            boolean ignore = false;
            seekBar_degree.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override
                public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                    et_degree.setText(progress-180+"");
                }

                @Override
                public void onStartTrackingTouch(SeekBar seekBar) {
                }

                @Override
                public void onStopTrackingTouch(SeekBar seekBar) {

                }
            });
            et_degree.addTextChangedListener(new TextWatcher() {
                @Override
                public void beforeTextChanged(CharSequence charSequence, int i, int i1, int i2) {

                }

                @Override
                public void onTextChanged(CharSequence charSequence, int i, int i1, int i2) {
                }

                @Override
                public void afterTextChanged(Editable editable) {
                    //seekBar_degree.setProgress(Integer.parseInt(et_degree.getText().toString()));
                }
            });

            final LinearLayout linearLayout_degree = new LinearLayout(getContext());
            linearLayout_degree.setOrientation(LinearLayout.HORIZONTAL);
            linearLayout_degree.setWeightSum(4);
            LinearLayout.LayoutParams layoutParams = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.MATCH_PARENT);
            //layoutParams.width = 0;
            layoutParams.weight = 3;
            linearLayout_degree.addView(seekBar_degree, layoutParams);
            layoutParams.weight = 1;
            linearLayout_degree.addView(et_degree, layoutParams);
            final CheckBox cb_centre = new CheckBox(getContext());
            cb_centre.setText("Playfield Centre");
            final LinearLayout linearLayout = new LinearLayout(getContext());
            linearLayout.setOrientation(LinearLayout.VERTICAL);
            linearLayout.addView(textView_txt);
            linearLayout.addView(linearLayout_degree);
            linearLayout.addView(cb_centre);
            new AlertDialog.Builder(getContext())
                    .setTitle("Rotate by")
                    .setView(linearLayout)
                    .setNegativeButton("Close", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface dialog, int which) {
                            dialog.dismiss();
                        }
                    })
                    .setPositiveButton("OK", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface dialog, int which) {
                            if(!et_degree.getText().toString().equals("")) rotateBy(true, Integer.parseInt(et_degree.getText().toString()), cb_centre.isChecked());
                            else Toast.makeText(getContext(), "invalid angle", Toast.LENGTH_SHORT).show();
                        }
                    })
                    .show();
        }
    };

    public Handler handler_songSetup = new Handler(){
        public  void handleMessage(Message msg){
            final LinearLayout linearLayout = new LinearLayout(getContext());
            linearLayout.setOrientation(LinearLayout.VERTICAL);
            final Button btn_metadata = new Button(getContext());
            btn_metadata.setText("metadata");
            btn_metadata.setOnClickListener(new OnClickListener() {
                @Override
                public void onClick(View v) {
                    handler_metadata.sendEmptyMessage(0);
                }
            });
            final Button btn_mapstat = new Button(getContext());
            btn_mapstat.setOnClickListener(new OnClickListener() {
                @Override
                public void onClick(View v) {
                    handler_mapstat.sendEmptyMessage(0);
                }
            });
            btn_mapstat.setText("mapstat");
            final Button btn_debug = new Button(getContext());
            btn_debug.setOnClickListener(new OnClickListener() {
                @Override
                public void onClick(View v) {
                    DRAW_DEBUG = !DRAW_DEBUG;
                }
            });
            btn_debug.setText("debug");
            final Button btn_save = new Button(getContext());
            btn_save.setOnClickListener(new OnClickListener() {
                @Override
                public void onClick(View v) {
                    saveFile();
                }
            });
            btn_save.setText("save");
            linearLayout.addView(btn_metadata);
            linearLayout.addView(btn_mapstat);
            linearLayout.addView(btn_debug);
            linearLayout.addView(btn_save);
            final ScrollView sv = new ScrollView(getContext());
            sv.addView(linearLayout);
            new AlertDialog.Builder(getContext())
                    .setTitle("Song Setup")
                    .setView(sv)
                    .setNegativeButton("Close", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface dialog, int which) {
                            dialog.dismiss();
                        }
                    })
                    .show();
        }
    };

    public Handler handler_timingSetup = new Handler(){
        public  void handleMessage(Message msg){
            final ScrollView scrollView = new ScrollView(getContext());
            final ListView listView = new ListView(getContext());
            TimingPointAdapter adapter;
            adapter = new TimingPointAdapter(TimingPoints, getContext());
            listView.setAdapter(adapter);
            listView.setChoiceMode(ListView.CHOICE_MODE_SINGLE);
            listView.setId(-1);
            final LinearLayout linearLayout = new LinearLayout(getContext());
            linearLayout.setOrientation(LinearLayout.VERTICAL);

            final LinearLayout linearLayout_bottom = new LinearLayout(getContext());
            linearLayout_bottom.setOrientation(LinearLayout.HORIZONTAL);
            final EditText et_offset = new EditText(getContext());
            et_offset.setText("");
            et_offset.setInputType(InputType.TYPE_CLASS_NUMBER);
            final TextView tv_offset = new TextView(getContext());
            tv_offset.setText("Offset ");
            tv_offset.setGravity(Gravity.CENTER);
            final EditText et_value = new EditText(getContext());
            et_value.setText("");
            et_value.setInputType(InputType.TYPE_NUMBER_FLAG_DECIMAL);
            final TextView tv_value = new TextView(getContext());
            tv_value.setText("Value ");
            tv_value.setGravity(Gravity.CENTER);
            final CheckBox cb_kiai = new CheckBox(getContext());
            cb_kiai.setText("Kiai");
            final Button btn_useCurrentOffset = new Button(getContext());
            btn_useCurrentOffset.setText("Use Current Time");
            btn_useCurrentOffset.setEllipsize(TextUtils.TruncateAt.END);
            btn_useCurrentOffset.setSingleLine(true);
            btn_useCurrentOffset.setOnClickListener(new OnClickListener() {
                @Override
                public void onClick(View view) {
                    et_offset.setText(currentPosition+"");
                }
            });

            LinearLayout.LayoutParams layoutParams = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT);
            LinearLayout.LayoutParams layoutParams2 = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT);
            LinearLayout.LayoutParams layoutParams3 = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT);
            layoutParams3.weight = 1f;
            layoutParams3.gravity = Gravity.CENTER;
            layoutParams2.weight = 0.5f;
            layoutParams2.gravity = Gravity.CENTER;
            layoutParams.gravity = Gravity.CENTER;

            layoutParams.weight = 0.7f;
            linearLayout_bottom.addView(tv_offset, layoutParams2);
            linearLayout_bottom.addView(et_offset, layoutParams);
            linearLayout_bottom.addView(tv_value, layoutParams2);
            linearLayout_bottom.addView(et_value, layoutParams);
            linearLayout_bottom.addView(cb_kiai, layoutParams2);
            linearLayout_bottom.addView(btn_useCurrentOffset, layoutParams3);


            linearLayout.addView(linearLayout_bottom);
            linearLayout.addView(listView);

            et_value.addTextChangedListener(new TextWatcher() {
                @Override
                public void beforeTextChanged(CharSequence charSequence, int i, int i1, int i2) {

                }

                @Override
                public void onTextChanged(CharSequence charSequence, int i, int i1, int i2) {

                }

                @Override
                public void afterTextChanged(Editable editable) {

                }
            });

            listView.setOnItemClickListener(new AdapterView.OnItemClickListener() {
                @Override
                public void onItemClick(AdapterView<?> adapterView, View view, int i, long l) {
                    TimingPoint p = (TimingPoint)(listView.getItemAtPosition(i));
                    et_offset.setText(p.offset+"");
                    if(p.status){
                        et_value.setText(dec1_3.format(60000f / p.speed));
                    }else{
                        et_value.setText(dec1_2.format(-100f / p.speed));
                    }
                    cb_kiai.setChecked(p.kiai);

                    listView.setItemChecked(i, true);
                    listView.setId(i);
                    adapter.selectedPos = i;
                    adapter.notifyDataSetChanged();
                }
            });

            final AlertDialog alertDialog = new AlertDialog.Builder(getContext())
                    .setTitle("Timing Setup")
                    .setView(linearLayout)
                    .setPositiveButton("Add", null)
                    .setNegativeButton("Delete", null)
                    .setNeutralButton("Edit", null)
                    .create();
            alertDialog.setOnShowListener(new DialogInterface.OnShowListener() {
                @Override
                public void onShow(DialogInterface dialogInterface) {
                    Button btn_pos = ((AlertDialog) alertDialog).getButton(AlertDialog.BUTTON_POSITIVE);
                    Button btn_neu = ((AlertDialog) alertDialog).getButton(AlertDialog.BUTTON_NEUTRAL);
                    Button btn_neg = ((AlertDialog) alertDialog).getButton(AlertDialog.BUTTON_NEGATIVE);
                    btn_pos.setOnClickListener(new View.OnClickListener() {
                        @Override
                        public void onClick(View view) {
                            //Add TimingPoint
                            TimingPoint selectP = new TimingPoint();
                            boolean validId = false;
                            if(listView.getId() != -1){
                                selectP = (TimingPoint)(listView.getItemAtPosition(listView.getId()));
                                validId = true;
                            }
                            int count = adapter.getCount();
                            TimingPoint p = new TimingPoint();
                            p.offset = currentPosition;
                            if(validId) p.speed = selectP.speed;
                            else p.speed = -100;
                            p.metro = 4;
                            p.customnum = 0;
                            p.sampleset = 0;
                            p.volume = 50;
                            p.status = false;
                            p.kiai = false;
                            final AlertDialog alertDialog = new AlertDialog.Builder(getContext())
                                    .setTitle("Select Type")
                                    .setPositiveButton("Timing Points", new DialogInterface.OnClickListener() {
                                        @Override
                                        public void onClick(DialogInterface dialogInterface, int i) {
                                            p.status = true;
                                            p.speed = 600;
                                            adapter.notifyDataSetChanged();
                                        }
                                    })
                                    .setNegativeButton("Inherited Points", new DialogInterface.OnClickListener() {
                                        @Override
                                        public void onClick(DialogInterface dialogInterface, int i) {
                                            p.status = false;
                                            adapter.notifyDataSetChanged();
                                        }
                                    })
                                    .show();
                            TimingPoints.add(p);

                            final Comparator mComparator = new Comparator<TimingPoint>() {
                                private final Collator collator = Collator.getInstance();
                                public int compare(TimingPoint object1,TimingPoint object2) {
                                    return collator.compare(object1.getOffset(), object2.getOffset());
                                }
                            };
                            Collections.sort(TimingPoints, mComparator);
                            for(int ii=0; ii<TimingPoints.size(); ii++){
                                TimingPoint tp = TimingPoints.get(ii);
                                if(tp.offset == p.offset){
                                    listView.setSelection(ii);
                                    listView.setItemChecked(ii, true);
                                    listView.setId(ii);
                                    adapter.selectedPos = ii;
                                }
                            }
                            adapter.notifyDataSetChanged();

                            et_offset.setText(p.offset+"");
                            if(p.status){
                                et_value.setText((60000f / p.speed)+"");
                            }else{
                                et_value.setText((-100f / p.speed)+"");
                            }

                            bg = base();
                            grid = grid();
                        }
                    });
                    btn_neu.setOnClickListener(new View.OnClickListener() {
                        @Override
                        public void onClick(View view) {
                            // Edit TimingPoint
                            int checked = listView.getId();
                            int count = adapter.getCount();

                            if (checked > -1 && checked < count) {
                                TimingPoint p = TimingPoints.get(checked);
                                if(p.status) p.speed = 60000f / Float.parseFloat(et_value.getText().toString());
                                else p.speed = -100f / Float.parseFloat(et_value.getText().toString());
                                p.offset = Integer.parseInt(et_offset.getText().toString());
                                p.kiai = cb_kiai.isChecked();

                                adapter.notifyDataSetChanged();
                            }

                            bg = base();
                            grid = grid();
                        }
                    });
                    btn_neg.setOnClickListener(new View.OnClickListener() {
                        @Override
                        public void onClick(View view) {
                            // Delete TimingPoint
                            TimingPoint _p = (TimingPoint)listView.getSelectedItem();
                            int checked = listView.getId();
                            int count = adapter.getCount();

                            if (checked > -1 && checked < count) {
                                TimingPoints.remove(checked);
                                listView.clearChoices();
                                adapter.notifyDataSetChanged();
                            }

                            bg = base();
                            grid = grid();
                        }
                    });
                }
            });
            alertDialog.show();
        }
    };

    public Handler handler_metadata = new Handler() {
        public void handleMessage (Message msg){
            final TextView tv_title = new TextView(getContext());
            tv_title.setText(" Title");
            final EditText et_title = new EditText(getContext());
            et_title.setText(title);
            final TextView tv_titleunicode = new TextView(getContext());
            tv_titleunicode.setText(" Title (Romanised)");
            final EditText et_titleunicode = new EditText(getContext());
            et_titleunicode.setText(titleUnicode);
            final TextView tv_artist = new TextView(getContext());
            tv_artist.setText(" Artist");
            final EditText et_artist = new EditText(getContext());
            et_artist.setText(artist);
            final TextView tv_artistunicode = new TextView(getContext());
            tv_artistunicode.setText(" Artist (Romanised)");
            final EditText et_artistunicode = new EditText(getContext());
            et_artistunicode.setText(artistUnicode);
            final TextView tv_creator = new TextView(getContext());
            tv_creator.setText(" Mapper");
            final EditText et_creator = new EditText(getContext());
            et_creator.setText(creator);
            final TextView tv_version = new TextView(getContext());
            tv_version.setText(" Diffname");
            final EditText et_version = new EditText(getContext());
            et_version.setText(version);
            final TextView tv_source = new TextView(getContext());
            tv_source.setText(" Source");
            final EditText et_source = new EditText(getContext());
            et_source.setText(source);
            final TextView tv_tags = new TextView(getContext());
            tv_tags.setText(" Tags");
            final EditText et_tags = new EditText(getContext());
            et_tags.setText(tags);


            final LinearLayout linearLayout = new LinearLayout(getContext());
            linearLayout.setOrientation(LinearLayout.VERTICAL);
            linearLayout.addView(tv_artist);
            linearLayout.addView(et_artist);
            linearLayout.addView(tv_artistunicode);
            linearLayout.addView(et_artistunicode);
            linearLayout.addView(tv_title);
            linearLayout.addView(et_title);
            linearLayout.addView(tv_titleunicode);
            linearLayout.addView(et_titleunicode);
            linearLayout.addView(tv_version);
            linearLayout.addView(et_version);
            linearLayout.addView(tv_source);
            linearLayout.addView(et_source);
            linearLayout.addView(tv_tags);
            linearLayout.addView(et_tags);
            final ScrollView sv = new ScrollView(getContext());
            sv.addView(linearLayout);
            new AlertDialog.Builder(getContext())
                    .setTitle("Song Setup")
                    .setView(sv)
                    .setNegativeButton("Close", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface dialog, int which) {
                            dialog.dismiss();
                        }
                    })
                    .setPositiveButton("Save", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface dialog, int which) {
                            title = et_title.getText().toString();
                            titleUnicode = et_titleunicode.getText().toString();
                            artist = et_artist.getText().toString();
                            artistUnicode = et_artistunicode.getText().toString();
                            version = et_version.getText().toString();
                            creator = et_creator.getText().toString();
                            source = et_source.getText().toString();
                            tags = et_tags.getText().toString();
                            initFonts();
                        }
                    })
                    .show();
        }
    };

    public Handler handler_mapstat = new Handler() {
        public void handleMessage (Message msg){
            final SeekBar seekBar_CS = new SeekBar(getContext());
            seekBar_CS.setMax(100);
            seekBar_CS.setProgress((int)(CS*10));
            final SeekBar seekBar_AR = new SeekBar(getContext());
            seekBar_AR.setMax(100);
            seekBar_AR.setProgress((int)(AR*10));
            final SeekBar seekBar_OD = new SeekBar(getContext());
            seekBar_OD.setMax(100);
            seekBar_OD.setProgress((int)(OD*10));
            final SeekBar seekBar_HP = new SeekBar(getContext());
            seekBar_HP.setMax(100);
            seekBar_HP.setProgress((int)(HP*10));
            final SeekBar seekBar_offset = new SeekBar(getContext());
            seekBar_offset.setMax(1000);
            seekBar_offset.setProgress(HITSOUND_OFFSET+500);
            final SeekBar seekBar_stackleniency = new SeekBar(getContext());
            seekBar_stackleniency.setMax(10);
            seekBar_stackleniency.setProgress((int)(stackLeniency*10));
            final TextView textView_CS = new TextView(getContext());
            textView_CS.setText(" CS : " + CS);
            final TextView textView_AR = new TextView(getContext());
            textView_AR.setText(" AR : " + AR);
            final TextView textView_OD = new TextView(getContext());
            textView_OD.setText(" OD : " + OD);
            final TextView textView_HP = new TextView(getContext());
            textView_HP.setText(" HP : " + HP);
            final TextView textView_offset = new TextView(getContext());
            textView_offset.setText(" Offset : " + HITSOUND_OFFSET + " (only use this if you have audio offset issue");
            final TextView textView_stackleniency = new TextView(getContext());
            textView_stackleniency.setText(" Stack Leniency : " + (int)(stackLeniency*10));
            seekBar_CS.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override
                public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                    textView_CS.setText(" CS : " + progress/10f);
                }

                @Override
                public void onStartTrackingTouch(SeekBar seekBar) {

                }

                @Override
                public void onStopTrackingTouch(SeekBar seekBar) {

                }
            });
            seekBar_AR.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override
                public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                    textView_AR.setText(" AR : " + progress/10f);
                }

                @Override
                public void onStartTrackingTouch(SeekBar seekBar) {

                }

                @Override
                public void onStopTrackingTouch(SeekBar seekBar) {

                }
            });
            seekBar_OD.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override
                public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                    textView_OD.setText(" OD : " + progress/10f);
                }

                @Override
                public void onStartTrackingTouch(SeekBar seekBar) {

                }

                @Override
                public void onStopTrackingTouch(SeekBar seekBar) {

                }
            });
            seekBar_HP.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override
                public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                    textView_HP.setText(" HP : " + progress/10f);
                }

                @Override
                public void onStartTrackingTouch(SeekBar seekBar) {

                }

                @Override
                public void onStopTrackingTouch(SeekBar seekBar) {

                }
            });
            seekBar_offset.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override
                public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                    textView_offset.setText(" Offset : " + (progress-500));
                }

                @Override
                public void onStartTrackingTouch(SeekBar seekBar) {

                }

                @Override
                public void onStopTrackingTouch(SeekBar seekBar) {

                }
            });
            seekBar_stackleniency.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override
                public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                    textView_stackleniency.setText(" Stack Leniency : " + seekBar_stackleniency.getProgress());
                }

                @Override
                public void onStartTrackingTouch(SeekBar seekBar) {

                }

                @Override
                public void onStopTrackingTouch(SeekBar seekBar) {

                }
            });
            final LinearLayout linearLayout = new LinearLayout(getContext());
            linearLayout.setOrientation(LinearLayout.VERTICAL);
            linearLayout.addView(textView_CS);
            linearLayout.addView(seekBar_CS);
            linearLayout.addView(textView_AR);
            linearLayout.addView(seekBar_AR);
            linearLayout.addView(textView_OD);
            linearLayout.addView(seekBar_OD);
            linearLayout.addView(textView_HP);
            linearLayout.addView(seekBar_HP);
            linearLayout.addView(textView_offset);
            linearLayout.addView(seekBar_offset);
            linearLayout.addView(textView_stackleniency);
            linearLayout.addView(seekBar_stackleniency);
            final ScrollView sv = new ScrollView(getContext());
            sv.addView(linearLayout);
            new AlertDialog.Builder(getContext())
                    .setTitle("Song Setup")
                    .setView(sv)
                    .setNegativeButton("Close", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface dialog, int which) {
                            dialog.dismiss();
                        }
                    })
                    .setPositiveButton("Save", new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface dialog, int which) {
                            CS = seekBar_CS.getProgress()/10f;
                            AR = seekBar_AR.getProgress()/10f;
                            OD = seekBar_OD.getProgress()/10f;
                            HP = seekBar_HP.getProgress()/10f;
                            HITSOUND_OFFSET = seekBar_offset.getProgress()-500;
                            stackLeniency = seekBar_stackleniency.getProgress()/10f;
                            initGraphics();
                        }
                    })
                    .show();
        }
    };
}


