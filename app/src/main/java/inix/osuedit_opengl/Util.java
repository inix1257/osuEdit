package inix.osuedit_opengl;

import android.app.Activity;
import android.content.SharedPreferences;

public class Util {
    public static void prefEdit(String name, String string){
        SharedPreferences pref = MainActivity.getAppContext().getSharedPreferences("variable", Activity.MODE_PRIVATE);
        SharedPreferences.Editor edit = pref.edit();
        edit.putString(name, string);
        edit.apply();
    }

    public static String prefLoad(String name){
        SharedPreferences pref = MainActivity.getAppContext().getSharedPreferences("variable", Activity.MODE_PRIVATE);
        String a = pref.getString(name, "0");
        return a;
    }

    public static int map(int value, int a, int b){
        return Math.min(Math.max(value, a), b);
    }

    public static double pDistance(float x, float y, float x1, float y1, float x2, float y2) {

        float A = x - x1;
        float B = y - y1;
        float C = x2 - x1;
        float D = y2 - y1;
        float E = -D;
        float F = C;

        float dot = A * E + B * F;
        float len_sq = E * E + F * F;

        return Math.abs(dot) / Math.sqrt(len_sq);
    }
}
