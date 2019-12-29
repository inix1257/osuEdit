package inix.osuedit_opengl;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.ListActivity;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.os.Bundle;
import android.os.Environment;
import android.provider.MediaStore;
import android.util.Log;
import android.view.View;
import android.webkit.MimeTypeMap;
import android.widget.ArrayAdapter;
import android.widget.ListView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.FileWriter;
import java.util.ArrayList;
import java.util.List;

public class LoadActivity extends ListActivity {
    private List<String> item = null;
    private List<String> path = null;
    private String root = Environment.getExternalStorageDirectory().getPath()+"/osuEdit";
    private TextView mPath;
    public static StringBuilder s;
    static String type;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_load);

        mPath = (TextView) findViewById(R.id.path);
        Intent intent = getIntent();

        type = intent.getStringExtra("type");

        TextView nofity = (TextView) findViewById(R.id.notify);

        File file = new File(root);
        if( !file.exists() ) {
            file.mkdirs();}

        if(type.equals("new")){
            GetAllMp3Path();
            nofity.setText("Select an audio file you want to map");
        }else if(type.equals("load")){
            nofity.setText("");
            getDir(root);
        }
    }

    public void prefEdit(String name, String string){
        SharedPreferences pref = getApplicationContext().getSharedPreferences("variable", Activity.MODE_PRIVATE);
        SharedPreferences.Editor edit = pref.edit();
        edit.putString(name, string);
        edit.apply();
    }

    public String prefLoad(String name){
        SharedPreferences pref = getApplicationContext().getSharedPreferences("variable", Activity.MODE_PRIVATE);
        String a = pref.getString(name, "0");
        return a;
    }

    public String[] GetAllMp3Path() {
        item = new ArrayList<String>();
        path = new ArrayList<String>();
        String[] resultPath = null;


        String selectionMimeType = MediaStore.Files.FileColumns.MIME_TYPE + "=?";
        String mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension("mp3");

        String[] selectionArgsMp3 = new String[]{ mimeType };

        Cursor c = getContentResolver().query(
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                new String[]{MediaStore.Audio.Media.DATA}, selectionMimeType, selectionArgsMp3, null);

        if (c.getCount() == 0)
            return null;

        resultPath = new String[c.getCount()];

        while (c.moveToNext()) {
            resultPath[c.getPosition()] = c.getString(c.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA));
            File f = new File(resultPath[c.getPosition()]);
            path.add(f.getAbsolutePath());
            item.add(f.getName());
        }
        ArrayAdapter<String> fileList = new ArrayAdapter<String>(this, R.layout.row, item);
        setListAdapter(fileList);


        return resultPath;
    }

    private void getDir(String dirPath) {
        mPath.setText("Location: " + dirPath);
        item = new ArrayList<String>();
        path = new ArrayList<String>();
        File f = new File(dirPath);
        File[] files = f.listFiles();
        if (!dirPath.equals(root)) {
            item.add("../");
            path.add(f.getParent());
        }



        for (int i = 0; i < files.length; i++) {
            File file = files[i];

            if (file.isDirectory()) {
                path.add(file.getPath());
                item.add(file.getName() + "/");
            }else if(file.getName().contains(".osu")){
                path.add(file.getPath());
                String s = file.getName();
                if(s.contains("[") && s.contains("]")) s = s.substring(s.indexOf("[") + 1, s.indexOf("]"));
                item.add(s);
            }

        }
        ArrayAdapter<String> fileList = new ArrayAdapter<String>(this, R.layout.row, item);
        setListAdapter(fileList);
    }

    @Override
    protected void onListItemClick(ListView l, View v, int position, long id) {

        File file = new File(path.get(position));
        if (file.isDirectory()) {
            if(file.canRead())
                getDir(path.get(position));
            else{
                new AlertDialog.Builder(this)
                        .setTitle("[" + file.getName() + "] folder can't be read!")
                        .setPositiveButton("OK",
                                new DialogInterface.OnClickListener() {

                                    public void onClick(DialogInterface dialog, int which) {
                                        //  TODO Auto-generated method stub
                                    }
                                }).show();
            }
        }else {
            s = new StringBuilder();
            prefEdit("location", file.getParent() + "/");
            Intent intent = new Intent(this, EditorActivity.class);

            if (type.equals("new")){

                File folder = new File(root + "/artist - title");
                if (!folder.exists()) {
                    folder.mkdirs();
                }
                if (file != null && file.exists()) {
                    try {
                        FileInputStream fis = new FileInputStream(file);
                        FileOutputStream newfos = new FileOutputStream(folder.getPath() + "/" + file.getName());
                        int readcount = 0;
                        byte[] buffer = new byte[1024];
                        while ((readcount = fis.read(buffer, 0, 1024)) != -1) {
                            newfos.write(buffer, 0, readcount);
                        }
                        newfos.close();
                        fis.close();
                    } catch (Exception e) {
                        e.printStackTrace();
                    }
                }

                try {
                    BufferedWriter bfw = new BufferedWriter(new FileWriter(folder.getPath() + "/version.osu"));
                    bfw.write("osu file format v14\n\n");
                    bfw.write("[General]\n");
                    bfw.write("AudioFilename: " + file.getName() + "\n");
                    bfw.write("Mode: 0\n\n");
                    bfw.write("[Metadata]\n");
                    //bfw.write("Title: \n" + Editor.Title);
                    //bfw.write("Artist: \n" + Editor.Artist);
                    bfw.write("Creator: \n");
                    //bfw.write("Version: \n" + Editor.Version);
                    bfw.write("\n");
                    bfw.write("[Difficulty]\n");
                    bfw.write("HPDrainRate:5\n");
                    bfw.write("CircleSize:5\n");
                    bfw.write("OverallDifficulty:5\n");
                    bfw.write("ApproachRate:5\n");
                    bfw.write("SliderMultiplier:1.4\n");
                    bfw.write("SliderTickRate:1\n");
                    bfw.write("\n");
                    bfw.write("[TimingPoints]\n");
                    bfw.write("\n");
                    bfw.write("[HitObjects]\n");
                    bfw.flush();
                    bfw.close();

                } catch (Exception e) {

                }

                file = new File(folder.getPath() + "/version.osu");

            }


            //Editor sv = new Editor(getApplicationContext());

            FileReader fr = null ;
            BufferedReader bufrd = null ;
            boolean isOsuFile = false;
            char ch ;
            try {
                // open file.
                fr = new FileReader(file) ;
                bufrd = new BufferedReader(fr) ;
                String line;
                String header;

                while ((line = bufrd.readLine()) != null) {
                    if(line.contains("osu file format")){
                        isOsuFile = true;
                    }
                    s.append(line+"\n");
                }

                // close file.
                bufrd.close() ;
                fr.close() ;
            } catch (Exception e) {
                e.printStackTrace() ;
            }

            if(!isOsuFile && type.equals("load")){
                Toast.makeText(getApplicationContext(), "Unable to load file", Toast.LENGTH_SHORT).show();
                return;
            }

            finish();

            startActivity(intent);

        }


    }

}
