package inix.osuedit_opengl;

import android.graphics.Point;
import android.graphics.PointF;

import java.util.ArrayList;

class Polygon {

    private ArrayList<PointF>     mVertexs = new ArrayList<PointF>();
    private Point mCenterPoint = null;

    public void addPoint(float xPos, float yPos) {
        mVertexs.add(new PointF(xPos, yPos));
        mCenterPoint = null;
    }

    public void clear() {
        mVertexs.clear();
    }

    public Point centroidOfPolygon() {
        if (mCenterPoint != null) {
            return mCenterPoint;
        }

        double centerX = 0, centerY = 0;
        double area = 0;

        mCenterPoint = new Point();
        int firstIndex, secondIndex, sizeOfVertexs = mVertexs.size();

        PointF  firstPoint;
        PointF  secondPoint;

        double factor = 0;

        for (firstIndex = 0; firstIndex < sizeOfVertexs; firstIndex++) {
            secondIndex = (firstIndex + 1) % sizeOfVertexs;

            firstPoint  = mVertexs.get(firstIndex);
            secondPoint = mVertexs.get(secondIndex);

            factor = ((firstPoint.x * secondPoint.y) - (secondPoint.x * firstPoint.y));

            area += factor;

            centerX += (firstPoint.x + secondPoint.x) * factor;
            centerY += (firstPoint.y + secondPoint.y) * factor;
        }

        area /= 2.0;
        area *= 6.0f;

        factor = 1 / area;

        centerX *= factor;
        centerY *= factor;

        mCenterPoint.set((int) centerX, (int) centerY);
        return mCenterPoint;
    }

    public double getArea() {
        double area = 0;

        mCenterPoint = new Point();
        int firstIndex, secondIndex, sizeOfVertexs = mVertexs.size();

        PointF  firstPoint;
        PointF  secondPoint;

        double factor = 0;

        for (firstIndex = 0; firstIndex < sizeOfVertexs; firstIndex++) {
            secondIndex = (firstIndex + 1) % sizeOfVertexs;

            firstPoint  = mVertexs.get(firstIndex);
            secondPoint = mVertexs.get(secondIndex);

            factor = ((firstPoint.x * secondPoint.y) - (secondPoint.x * firstPoint.y));

            area += factor;
        }

        area /= 2.0;
        return area;
    }
}