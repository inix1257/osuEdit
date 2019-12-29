package inix.osuedit_opengl;

public class PathPoint {
    public double x;
    public double y;

    public float startX, startY, endX, endY;

    public PathPoint() {
        super();
    }
    public PathPoint(double x) {
        super();
        this.x = x;
    }
    public PathPoint(double x, double y) {
        super();
        this.x = x;
        this.y = y;
    }

    public PathPoint(PathPoint p){
        this.x = p.x;
        this.y = p.y;
    }
}
