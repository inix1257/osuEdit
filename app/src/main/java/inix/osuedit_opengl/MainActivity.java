package inix.osuedit_opengl;

import android.Manifest;
import android.annotation.TargetApi;
import android.app.ActivityManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.AudioManager;
import android.opengl.GLSurfaceView;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.text.util.Linkify;
import android.util.Log;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.widget.RelativeLayout;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;


import com.github.javiersantos.appupdater.AppUpdater;
import com.github.javiersantos.appupdater.enums.UpdateFrom;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;


import nl.bravobit.ffmpeg.FFmpeg;

public class MainActivity extends AppCompatActivity {

    private static Context context;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        context = getApplicationContext();
        setContentView(R.layout.activity_main);

        TextView tv_osu = (TextView) findViewById(R.id.tv_osu);
        TextView tv_github = (TextView) findViewById(R.id.tv_github);
        TextView tv_paypal = (TextView) findViewById(R.id.tv_paypal);
        TextView tv_credit = (TextView) findViewById(R.id.tv_credit);

        String str_osu = "osu! Profile";
        String str_github = "GitHub";
        String str_paypal = "Donation (Paypal)";
        String str_credit = "Code by Luscent (@luscentos) / Design by aly (@sagwayaya)";

        tv_osu.setText(str_osu);
        tv_github.setText(str_github);
        tv_paypal.setText(str_paypal);
        tv_credit.setText(str_credit);

        Linkify.TransformFilter mTransform = new Linkify.TransformFilter() { @Override public String transformUrl(Matcher match, String url) { return ""; } };

        Linkify.addLinks(tv_osu, Pattern.compile(str_osu), "https://osu.ppy.sh/users/2688581",null,mTransform);
        Linkify.addLinks(tv_github, Pattern.compile(str_github), "https://github.com/inix1257",null,mTransform);
        Linkify.addLinks(tv_paypal, Pattern.compile("Donation"), "https://paypal.me/inix1257",null,mTransform);
        Linkify.addLinks(tv_credit, Pattern.compile("(@luscentos)"), "https://twitter.com/luscentos",null,mTransform);
        Linkify.addLinks(tv_credit, Pattern.compile("(@sagwayaya)"), "https://twitter.com/sagwayaya",null,mTransform);


        new AppUpdater(this)
                .setUpdateFrom(UpdateFrom.GITHUB)
                .setGitHubUserAndRepo("javiersantos", "AppUpdater")
                .start();

        if (FFmpeg.getInstance(this).isSupported()) {
            // ffmpeg is supported
        } else {
            // ffmpeg is not supported
        }

        if(android.os.Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) checkPermission();
        //requestAudioFocus(MainActivity.this);

        File f = new File(Environment.getExternalStorageDirectory().getPath()+"/osuEdit");
        if(!f.exists()){
            f.mkdirs();
        }
        File[] files = f.listFiles();
        if(files.length > 0){
            for(File ff : files){
                if(ff.getName().contains(".osz")){
                    try {
                        //unpackZip(ff.getPath(), Environment.getExternalStorageDirectory().getPath() + "/osuEdit/");
                        unpackZip(Environment.getExternalStorageDirectory().getPath() + "/osuEdit/", ff.getName());
                        Log.e("unzip", ff.getPath());
                    }catch(Exception e){};
                }
            }
            Toast.makeText(context, "Found " + files.length + " mapsets", Toast.LENGTH_SHORT).show();
        }else{
            Toast.makeText(context, "Song folder is empty", Toast.LENGTH_SHORT).show();
        }



    }

    public static void unzip(String zipFile, String location, String fileName) throws IOException {
        try {
            String safeName = fileName.replace(".osz", "");
            File f = new File(location + "/" + safeName);
            f.mkdirs();

            //if (!f.isDirectory())f.mkdirs();

            ZipInputStream zin = new ZipInputStream(new FileInputStream(zipFile));
            try {
                ZipEntry ze = null;
                while ((ze = zin.getNextEntry()) != null) {
                    String path = location + File.separator + ze.getName();
                    Log.v("Decompress", "Unzipping " + ze.getName());


                    if (ze.isDirectory()) {
                        File unzipFile = new File(path);
                        if (!unzipFile.isDirectory()) {
                            unzipFile.mkdirs();
                        }
                    } else {
                        FileOutputStream fout = new FileOutputStream(location + "/" + safeName + "/" + ze.getName());
                        BufferedInputStream in = new BufferedInputStream(zin);
                        BufferedOutputStream out = new BufferedOutputStream(fout);
                        byte b[] = new byte[1024];
                        int n;
                        while ((n = in.read(b, 0, 1024)) >= 0) {
                            out.write(b, 0, n);
                        }

                        zin.closeEntry();
                        fout.close();

                    }
                }
                zin.close();
            } catch (Exception e) {
                e.printStackTrace();
            }
        }catch(Exception e){

        }
    }

    private boolean unpackZip(String path, String zipname)
    {
        InputStream is;
        ZipInputStream zis;
        try
        {
            File dir = new File(path + zipname.replace(".osz", "").replace(".", ""));
            dir.mkdirs();
            Log.e("file", dir.getPath() + ", " + dir.exists());

            String filename;
            is = new FileInputStream(path + zipname);
            zis = new ZipInputStream(new BufferedInputStream(is));
            ZipEntry ze;
            byte[] buffer = new byte[1024];
            int count;

            while ((ze = zis.getNextEntry()) != null)
            {
                filename = ze.getName();

                if (ze.isDirectory()) {
                    File fmd = new File(dir.getPath() + "/" + filename);
                    fmd.mkdirs();
                    continue;
                }

                FileOutputStream fout = new FileOutputStream(dir.getPath() + "/" + filename);

                while ((count = zis.read(buffer)) != -1)
                {
                    fout.write(buffer, 0, count);
                }

                fout.close();
                zis.closeEntry();
            }

            zis.close();

            File del = new File(path + zipname);
            del.delete();
        }
        catch(IOException e)
        {
            Log.e("unzip", "error : " + e.toString());
            e.printStackTrace();
            return false;
        }

        return true;
    }

    public static Context getAppContext(){
        return context;
    }

    public void newmap(View v){
        Intent intent=new Intent(MainActivity.this, LoadActivity.class);
        intent.putExtra("type", "new");
        startActivity(intent);
    }

    public void load(View v){
        Intent intent=new Intent(MainActivity.this, LoadActivity.class);
        intent.putExtra("type", "load");
        startActivity(intent);
    }

    @TargetApi(Build.VERSION_CODES.M)
    private void checkPermission() {
        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                != PackageManager.PERMISSION_GRANTED
                || checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE)
                != PackageManager.PERMISSION_GRANTED) {

            if (shouldShowRequestPermissionRationale(Manifest.permission.WRITE_EXTERNAL_STORAGE)) {
                Toast.makeText(this, "Read/Write external storage", Toast.LENGTH_SHORT).show();
            }

            requestPermissions(new String[]{Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE},
                    100);


        } else {

        }
    }

    private boolean requestAudioFocus(final Context context) {
        AudioManager am = (AudioManager)context.getSystemService(Context.AUDIO_SERVICE);

        // Request audio focus for playback
        int result = am.requestAudioFocus(null,
                // Use the music stream.
                AudioManager.STREAM_MUSIC,
                // Request permanent focus.
                AudioManager.AUDIOFOCUS_GAIN);

        if (result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            Toast.makeText(context,"Audio focus received", Toast.LENGTH_SHORT).show();
            return true;
        } else {
            Toast.makeText(context,"Audio focus NOT received", Toast.LENGTH_SHORT).show();
            return false;
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        switch (requestCode) {
            case 100:
                if (grantResults[0] == PackageManager.PERMISSION_GRANTED
                        && grantResults[1] == PackageManager.PERMISSION_GRANTED) {
                    Toast.makeText(this, "Read/Write external storage", Toast.LENGTH_SHORT).show();

                } else {

                }
                break;
        }
    }
}
