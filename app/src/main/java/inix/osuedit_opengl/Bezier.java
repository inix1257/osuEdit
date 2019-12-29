package inix.osuedit_opengl;

import java.util.ArrayList;

public class Bezier {
    private PathPoint[] arrPn;
    private double mu;

    private PathPoint resultPoint;
    public Bezier() {
        super();

        resultPoint = new PathPoint();
        initResultPoint();
    }

    //곡선 포인터 설정 PathPoint[] arrPn
    public void setBezierN(ArrayList<PathPoint> arrPn){
        //PathPoint[] tmp = new PathPoint[arrPn.size()];
        this.arrPn = new PathPoint[arrPn.size()];
        int size = 0;
        for(PathPoint p : arrPn){
            this.arrPn[size++] = p;
        }
    }

    public void bezierCalc(){
        int k,kn,nn,nkn;
        double blend,muk,munk;
        int n = arrPn.length-1;

        initResultPoint();
        muk = 1;
        munk = Math.pow(1-mu,(double)n);
        for (k=0;k<=n;k++)
        {
            nn = n;
            kn = k;
            nkn = n - k;
            blend = muk * munk;
            muk *= mu;
            munk /= (1-mu);
            while (nn >= 1) {
                blend *= nn;
                nn--;
                if (kn > 1) {
                    blend /= (double)kn;
                    kn--;
                }
                if (nkn > 1) {
                    blend /= (double)nkn;
                    nkn--;
                }
            }
            resultPoint.x += arrPn[k].x * blend;
            resultPoint.y += arrPn[k].y * blend;
        }
    }


    public void initResultPoint(){
        resultPoint.x = 0.0;
        resultPoint.y = 0.0;
    }


    public void setMu(double mu){
        this.mu = mu;
    }
    public PathPoint getResult(){
        return resultPoint;
    }
}