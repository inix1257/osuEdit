package inix.osuedit_opengl;

import java.text.DecimalFormat;

import static inix.osuedit_opengl.Editor.fileFormatVersion;

public class TimingPoint {
    public int offset = 0; //오프셋
    public double speed; //BPM 또는 슬라이더 속도
    public int metro; //박자
    public int sampleset; //1 = Normal, 2 = Soft, 3 = Drum
    public int customnum; //0 = Default
    public int volume = 50;
    public boolean status; //true -> BPM / false -> green
    public boolean kiai;

    DecimalFormat dec = new DecimalFormat("00000000");

    public TimingPoint(String info){
        String tmp[] = info.split(",");
        offset = (int)Double.parseDouble(tmp[0]);
        speed = Double.parseDouble(tmp[1]);
        metro = Integer.parseInt(tmp[2]);
        sampleset = Integer.parseInt(tmp[3]);
        customnum = Integer.parseInt(tmp[4]);
        if(fileFormatVersion < 6) return;
        volume = Integer.parseInt(tmp[5]);
        if(tmp[6].equals("1")){
            //status=true;
        }else{
            //status=false;
        }
        kiai = tmp[7].equals("1");

        if(speed > 0){
            status = true;
        }else{
            status = false;
        }
    }

    public TimingPoint(){

    }

    public String getOffset(){
        return dec.format(offset);
    }
}
