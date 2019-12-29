package inix.osuedit_opengl;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PathMeasure;
import android.graphics.RectF;
import android.util.Log;

import java.text.DecimalFormat;
import java.util.ArrayList;

import static android.view.View.Y;
import static inix.osuedit_opengl.Editor.CircleSize;
import static inix.osuedit_opengl.Editor.g;
import static inix.osuedit_opengl.Editor.h;
import static inix.osuedit_opengl.Editor.left;
import static inix.osuedit_opengl.Editor.maxCircleSize;
import static inix.osuedit_opengl.Editor.top;
import static inix.osuedit_opengl.Editor.comboColor;
import static inix.osuedit_opengl.Editor.comboColorCount;
import static inix.osuedit_opengl.Editor.w;
import static java.lang.Math.cos;
import static java.lang.Math.sin;

public class HitObject {
    boolean dead = false;
    public int x, y, endx, endy;
    public int offset;
    int combo;
    int spinnerEndOffset; // 슬라이더가 끝나는 시간
    double sliderLength = 0; // 슬라이더의 길이
    int sliderRepeat = 0; //슬라이더 반복수
    int sliderHitSound = 0; // 슬라이더에서 몇번째까지 히트사운드를 냈는지
    public int type; //1 = circle, 2 = slider, 4 = New combo, 8 = spinner, 16, 32, 64 =
    public int hitsound; //whistle = 2, finish = 4, clap = 8;
    public String extra = "";
    public boolean NC;
    public boolean isSelected = false;
    boolean isPlayed = false;
    boolean isPlayed_end = false;
    int mColor, mColorCount;
    int prevRepeatCount = 0;
    double totalLength = 0;
    boolean angleFound = false;
    boolean isRendering = false;

    int stackCount = 0;

    ArrayList<PathPoint> sliderCoordinates = new ArrayList<>();
    ArrayList<PathPoint> sliderPoints = new ArrayList<>();

    Bitmap sliderBody;
    public double Xmin = w, Xmax = 0, Ymin = h, Ymax = 0;
    double reverseAngle, reverseAngle2;

    public int skip = 0;
    public String notetype;
    public String sliderType;
    public Path sliderPath;

    boolean isInit = true;

    DecimalFormat dec = new DecimalFormat("00000000");

    ArrayList<PathPoint> arrPn;
    Bezier bezier;

    String info;

    public HitObject(String _info) {
        info = _info;
        String tmp[] = _info.split(",");
        x = Integer.parseInt(tmp[0]);
        y = Integer.parseInt(tmp[1]);
        offset = Integer.parseInt(tmp[2]);
        type = Integer.parseInt(tmp[3]);
        hitsound = Integer.parseInt(tmp[4]);

        sliderPath = new Path();

        for (int i = 6; i >= 4; i--) {
            if (Math.pow(2, i) < type) {
                NC = true;
                type -= (int) Math.pow(2, i);
                skip += Math.pow(2, i-4);
            }
        }
        if (type >= 8) {
            type = type - 8;
            notetype = "spinner";
            spinnerEndOffset = Integer.parseInt(tmp[5]);
            if(tmp.length > 6) extra += tmp[6];
        }
        if (type >= 4) {
            NC = true;
            type = type - 4;
        }
        if (type >= 2) {
            notetype = "slider";
            sliderType = tmp[5].split("\\|")[0];
            PathPoint asdf = new PathPoint();
            asdf.x = x;
            asdf.y = y;
            sliderPoints.add(asdf);
                for (int i = 1; i < (tmp[5].split("\\|")).length; i++) {
                    String str = tmp[5].split("\\|")[i];
                    PathPoint p = new PathPoint();
                    p.x = Double.parseDouble(str.split(":")[0]);
                    p.y = Double.parseDouble(str.split(":")[1]);
                    sliderPoints.add(p);
                }
            PathPoint pp = new PathPoint();
            pp.x = sliderPoints.get(sliderPoints.size() - 1).x;
            pp.y = sliderPoints.get(sliderPoints.size() - 1).y;
            //sliderPoints.add(pp);

            sliderRepeat = Integer.parseInt(tmp[6]);
            sliderLength = Double.parseDouble(tmp[7]);
            for(int i=8; i<tmp.length; i++){
                extra += "," + tmp[i];
            }

            if (sliderPoints.size() == 0) {

            } else if (sliderType.equals("P")) {
                slider_P();
            } else if(sliderType.equals("L")) {
                slider_L();
            }else{
                bezier();
            }
        } else if (type >= 1) {
            if(tmp.length > 5) extra = (tmp[5]);
            notetype = "circle";
            type -= 1;
        }

        if (NC) {
            comboColorCount++;

        } else {
        }
        isInit = false;
    }

    public HitObject(){
        sliderCoordinates = new ArrayList<>();
        sliderPoints = new ArrayList<>();
    }

    public void slider_P(){
        isRendering = true;
        Xmin = w;
        Xmax = 0;
        Ymin = h;
        Ymax = 0;
        endx = 0;
        endy = 0;
        totalLength = 0;
        arrPn = new ArrayList<>();
        sliderCoordinates = new ArrayList<>();
        bezier = new Bezier(); //베지어 곡선 생성
        sliderPath = new Path();
        if(sliderBody != null){
            //sliderBody.recycle();
            //sliderBody = null;
        }
        boolean reverse = false;
        float x1 = x;
        float y1 = y;
        float x2 = (float)sliderPoints.get(1).x;
        float y2 = (float)sliderPoints.get(1).y;
        float x3 = (float)sliderPoints.get(2).x;
        float y3 = (float)sliderPoints.get(2).y;

        float center_x, center_y;
        float yDelta_a = y2 - y1;
        if (yDelta_a == 0) yDelta_a = 0.001f;
        float xDelta_a = x2 - x1;
        if (xDelta_a == 0) xDelta_a = 0.001f;
        float yDelta_b = y3 - y2;
        if (yDelta_b == 0) yDelta_b = 0.001f;
        float xDelta_b = x3 - x2;
        if (xDelta_b == 0) xDelta_b = 0.001f;
        float aSlope = yDelta_a / xDelta_a;
        float bSlope = yDelta_b / xDelta_b;

        center_x = (aSlope * bSlope * (y1 - y3) + bSlope * (x1 + x2)
                - aSlope * (x2 + x3)) / (2 * (bSlope - aSlope));
        center_y = -1f * (center_x - (x1 + x2) / 2f) / aSlope + (y1 + y2) / 2f;
        float distance = (float) Math.sqrt(Math.pow(x1 - center_x, 2) + Math.pow(y1 - center_y, 2));
        if (distance >= 512) {
            bezier();
        } else {
            RectF rf = new RectF();
            rf.set(left + g * (center_x - distance), top + g * (center_y - distance), left + g * (center_x + distance), top + g * (center_y + distance));

            double dy = y1 - center_y;
            double dx = x1 - center_x;
            double startAngle = Math.atan2(dy, dx) * (180.0 / Math.PI);
            dy = y3 - center_y;
            dx = x3 - center_x;
            double endAngle = Math.atan2(dy, dx) * (180.0 / Math.PI);
            dy = y2 - center_y;
            dx = x2 - center_x;
            double middleAngle = Math.atan2(dy, dx) * (180.0 / Math.PI);

            double sweepAngle;
            double angleDifference1 = Math.min(Math.min(Math.abs(startAngle - middleAngle)%360, Math.abs(startAngle - (middleAngle+360))%360), Math.abs((startAngle+360) - middleAngle)%360);
            double angleDifference2 = Math.min(Math.min(Math.abs(middleAngle - endAngle)%360, Math.abs(middleAngle - (endAngle+360))%360), Math.abs((middleAngle+360) - endAngle)%360);

            if((middleAngle < startAngle && (middleAngle > endAngle || startAngle < endAngle)) || (middleAngle > endAngle && startAngle < middleAngle && startAngle < endAngle)) sweepAngle = -(angleDifference1 + angleDifference2);
            else sweepAngle = angleDifference1 + angleDifference2;

            double pmLength = 0;
            double _stLength = 0;
            int counter = 0;
            PathMeasure pm = new PathMeasure(sliderPath, false);
            while (pmLength < g * sliderLength) {
                pm.setPath(sliderPath, false);
                sliderPath.arcTo(rf, (float) startAngle, (float) (sweepAngle / sliderLength));
                PathPoint p = new PathPoint();
                p.x = left + g * center_x + g * distance * cos(startAngle * Math.PI / 180);
                p.y = top + g * center_y + g * distance * sin(startAngle * Math.PI / 180);

                double _x = left + center_x * g + g * distance * cos((startAngle + sweepAngle / sliderLength) * Math.PI / 180);
                double _y = top + center_y * g + g * distance * sin((startAngle + sweepAngle / sliderLength) * Math.PI / 180);

                if(pmLength == 0)  reverseAngle = Math.atan2(_y - p.y, _x - p.x) * (180.0 / Math.PI);
                reverseAngle2 = Math.atan2(_y - p.y, _x - p.x) * (180.0 / Math.PI);
                double sdistance = Math.sqrt(Math.pow(p.x - _x, 2) + Math.pow(p.y - _y, 2));
                _stLength += sdistance;
                if (_stLength >= 1) {
                    sliderCoordinates.add(p);
                    _stLength -= 1;
                }

                endx = (int) center_x + (int) Math.round(distance * cos(startAngle * Math.PI / 180));
                endy = (int) center_y + (int) Math.round(distance * sin(startAngle * Math.PI / 180));
                if (Xmin > endx) Xmin = endx;
                if (Xmax < endx) Xmax = endx;
                if (Ymin > endy) Ymin = endy;
                if (Ymax < endy) Ymax = endy;
                startAngle += sweepAngle / sliderLength;
                pmLength = pm.getLength();
                counter++;
            }
            sliderPath.offset((float) -Xmin * g - left + maxCircleSize / 2, (float) -Ymin * g - top + maxCircleSize / 2);
        }
        isRendering = false;
    }

    public void slider_L(){
        bezier();
        for(PathPoint pp : sliderPoints){
        }
        float x1 = x;
        float y1 = y;
        float x2 = (float)sliderPoints.get(0).x;
        float y2 = (float)sliderPoints.get(0).y;
        double distance = Math.sqrt(Math.pow(x2 - x1, 2) + Math.pow(y2 - y1, 2));
        double firstScale = sliderLength;
        double lastScale = distance - sliderLength;
        double calcX = (firstScale * x2 + lastScale * x1) / distance;
        double calcY = (firstScale * y2 + lastScale * y1) / distance;
    }

    public void bezier() {
        isRendering = true;
        Xmin = w;
        Xmax = 0;
        Ymin = h;
        Ymax = 0;
        endx = 0;
        endy = 0;
        totalLength = 0;
        arrPn = new ArrayList<>();
        sliderCoordinates = new ArrayList<>();
        bezier = new Bezier();
        sliderPath = new Path();
        int counter = 0;

        for (int index = 0; index < sliderPoints.size(); index++) {
            if(index != 0){
                if (((sliderPoints.get(index).x == sliderPoints.get(index-1).x && sliderPoints.get(index).y == sliderPoints.get(index-1).y) || index == sliderPoints.size() - 1)) {
                    if(index ==  sliderPoints.size() - 1){
                        PathPoint _p = new PathPoint();
                        _p.x = sliderPoints.get(index).x;
                        _p.y = sliderPoints.get(index).y;
                        arrPn.add(_p);
                    }

                    bezier.setBezierN(arrPn);
                    double muGap = 0.5f / sliderLength;

                    PathPoint startP = new PathPoint();
                    PathPoint endP = new PathPoint();
                    boolean tmpb = false;
                    double _stLength = 0;

                    for (double mu = 0; mu <= 1; mu += muGap) {
                        startP.x = bezier.getResult().x;
                        startP.y = bezier.getResult().y;
                        bezier.setMu(mu);
                        bezier.bezierCalc();
                        endP.x = bezier.getResult().x;
                        endP.y = bezier.getResult().y;

                        if (mu == 0) continue;

                        if (Xmin > startP.x || Xmin > endP.x) Xmin = Math.min(startP.x, endP.x);
                        if (Xmax < startP.x || Xmax < endP.x) Xmax = Math.max(startP.x, endP.x);
                        if (Ymin > startP.y || Ymin > endP.y) Ymin = Math.min(startP.y, endP.y);
                        if (Ymax < startP.y || Ymax < endP.y) Ymax = Math.max(startP.y, endP.y);

                        reverseAngle2 = Math.atan2(endP.y - startP.y, endP.x - startP.x) * (180.0 / Math.PI);

                        if (!tmpb) {
                            tmpb = true;
                            sliderPath.moveTo((float) (left + g * startP.x), (float) (top + g * startP.y));
                        }
                        PathPoint p = new PathPoint();
                        p.x = left + g * startP.x;
                        p.y = top + g * startP.y;
                        endx = (int) Math.round(startP.x);
                        endy = (int) Math.round(startP.y);

                        double sdistance = Math.sqrt(Math.pow(startP.x - endP.x, 2) + Math.pow(startP.y - endP.y, 2));

                        _stLength += sdistance;
                        if (_stLength >= 1) {
                            sliderCoordinates.add(p);
                            _stLength = _stLength - 1;
                        }


                        sliderPath.lineTo((float) (left + g * endP.x), (float) (top + g * endP.y));
                        totalLength += Math.sqrt(Math.pow(Math.abs(startP.x - endP.x), 2) + Math.pow(Math.abs(startP.y - endP.y), 2));
                        counter++;
                        if (totalLength >= sliderLength) break;
                    }




                    arrPn.clear();
                    bezier = new Bezier();

                    PathPoint p = new PathPoint();
                    if (index < sliderPoints.size() - 1) {
                        p.x = sliderPoints.get(index - 1).x;
                        p.y = sliderPoints.get(index - 1).y;
                        arrPn.add(p);
                    }else if(index == sliderPoints.size() - 1){
                        p.x = sliderPoints.get(index).x;
                        p.y = sliderPoints.get(index).y;

                        arrPn.add(p);
                    }



                    continue;
                }
            }

            PathPoint p = new PathPoint();
            p.x = sliderPoints.get(index).x;
            p.y = sliderPoints.get(index).y;

            arrPn.add(p);
        }

        sliderPath.offset((float) -Xmin * g - left + maxCircleSize / 2, (float) -Ymin * g - top + maxCircleSize / 2);
        isRendering = false;
    }

    public double getBezierLength() {
        double _totalLength = 0;
        ArrayList<PathPoint> _arrPn = new ArrayList<>();
        Bezier _bezier = new Bezier();

        for (int index = 0; index < sliderPoints.size(); index++) {
            if(index != 0){
                if (((sliderPoints.get(index).x == sliderPoints.get(index-1).x && sliderPoints.get(index).y == sliderPoints.get(index-1).y) || index == sliderPoints.size() - 1)) {
                    if(index ==  sliderPoints.size() - 1){
                        PathPoint _p = new PathPoint();
                        _p.x = sliderPoints.get(index).x;
                        _p.y = sliderPoints.get(index).y;
                        _arrPn.add(_p);
                    }
                    _bezier.setBezierN(_arrPn);
                    double muGap = 0.5f / sliderLength;

                    PathPoint startP = new PathPoint();
                    PathPoint endP = new PathPoint();
                    boolean tmpb = false;

                    for (double mu = 0; mu <= 1; mu += muGap) {
                        startP.x = _bezier.getResult().x;
                        startP.y = _bezier.getResult().y;
                        _bezier.setMu(mu);
                        _bezier.bezierCalc();
                        endP.x = _bezier.getResult().x;
                        endP.y = _bezier.getResult().y;

                        if (mu == 0) continue;

                        PathPoint p = new PathPoint();
                        p.x = left + g * startP.x;
                        p.y = top + g * startP.y;

                        _totalLength += Math.sqrt(Math.pow(Math.abs(startP.x - endP.x), 2) + Math.pow(Math.abs(startP.y - endP.y), 2));
                    }




                    _arrPn.clear();
                    _bezier = new Bezier();

                    PathPoint p = new PathPoint();
                    if (index < sliderPoints.size() - 1) {
                        p.x = sliderPoints.get(index - 1).x;
                        p.y = sliderPoints.get(index - 1).y;

                    }

                    _arrPn.add(p);

                    continue;
                }
            }

            PathPoint p = new PathPoint();
            p.x = sliderPoints.get(index).x;
            p.y = sliderPoints.get(index).y;

            _arrPn.add(p);
        }

        return _totalLength;
    }

    public double getPerfectLength(){
        double _totalLength = 0;
        ArrayList<PathPoint> _arrPn = new ArrayList<>();
        Bezier _bezier = new Bezier(); //베지어 곡선 생성
        Path _sliderPath = new Path();
        boolean reverse = false;
        float x1 = x;
        float y1 = y;
        float x2 = (float)sliderPoints.get(1).x;
        float y2 = (float)sliderPoints.get(1).y;
        float x3 = (float)sliderPoints.get(2).x;
        float y3 = (float)sliderPoints.get(2).y;

        float center_x, center_y;
        float yDelta_a = y2 - y1;
        if (yDelta_a == 0) yDelta_a = 0.001f;
        float xDelta_a = x2 - x1;
        if (xDelta_a == 0) xDelta_a = 0.001f;
        float yDelta_b = y3 - y2;
        if (yDelta_b == 0) yDelta_b = 0.001f;
        float xDelta_b = x3 - x2;
        if (xDelta_b == 0) xDelta_b = 0.001f;
        float aSlope = yDelta_a / xDelta_a;
        float bSlope = yDelta_b / xDelta_b;

        center_x = (aSlope * bSlope * (y1 - y3) + bSlope * (x1 + x2)
                - aSlope * (x2 + x3)) / (2 * (bSlope - aSlope));
        center_y = -1f * (center_x - (x1 + x2) / 2f) / aSlope + (y1 + y2) / 2f;
        float distance = (float) Math.sqrt(Math.pow(x1 - center_x, 2) + Math.pow(y1 - center_y, 2));
        if (distance >= 512) {
            return getBezierLength();
        } else {
            RectF rf = new RectF();
            rf.set((center_x - distance), (center_y - distance), (center_x + distance), (center_y + distance));

            double dy = y1 - center_y;
            double dx = x1 - center_x;
            double startAngle = Math.atan2(dy, dx) * (180.0 / Math.PI);
            dy = y3 - center_y;
            dx = x3 - center_x;
            double endAngle = Math.atan2(dy, dx) * (180.0 / Math.PI);
            dy = y2 - center_y;
            dx = x2 - center_x;
            double middleAngle = Math.atan2(dy, dx) * (180.0 / Math.PI);

            double sweepAngle;
            double angleDifference1 = Math.min(Math.min(Math.abs(startAngle - middleAngle)%360, Math.abs(startAngle - (middleAngle+360))%360), Math.abs((startAngle+360) - middleAngle)%360);
            double angleDifference2 = Math.min(Math.min(Math.abs(middleAngle - endAngle)%360, Math.abs(middleAngle - (endAngle+360))%360), Math.abs((middleAngle+360) - endAngle)%360);

            if((middleAngle < startAngle && (middleAngle > endAngle || startAngle < endAngle)) || (middleAngle > endAngle && startAngle < middleAngle && startAngle < endAngle)) sweepAngle = -(angleDifference1 + angleDifference2);
            else sweepAngle = angleDifference1 + angleDifference2;

            double pmLength = 0;
            double _stLength = 0;
                _sliderPath.arcTo(rf, (float) startAngle, (float) (sweepAngle));
                PathMeasure pm = new PathMeasure(_sliderPath, false);
                PathPoint p = new PathPoint();
                p.x = center_x + distance * cos(startAngle * Math.PI / 180);
                p.y = center_y + distance * sin(startAngle * Math.PI / 180);

                startAngle += sweepAngle / sliderLength;
                pmLength = pm.getLength();
            return pmLength;
        }
    }

    @Override
    public String toString() {
        return dec.format(offset);
    }

}

