package inix.osuedit_opengl;

import android.content.Context;
import android.util.Log;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.view.animation.Animation;
import android.view.animation.AnimationUtils;
import android.widget.ArrayAdapter;
import android.widget.CheckBox;
import android.widget.TextView;

import java.text.DecimalFormat;
import java.util.ArrayList;

import static android.view.View.GONE;
import static android.view.View.VISIBLE;

public class TimingPointAdapter extends ArrayAdapter<TimingPoint> implements View.OnClickListener  {
    private ArrayList<TimingPoint> dataSet;
    Context mContext;

    DecimalFormat dec3 = new DecimalFormat("000");
    DecimalFormat dec2 = new DecimalFormat("00");
    DecimalFormat dec1_3 = new DecimalFormat("0.000");
    DecimalFormat dec1_2 = new DecimalFormat("0.00");

    int selectedPos = -1;

    // View lookup cache
    private static class ViewHolder {
        TextView txtOffset;
        TextView txtType;
        TextView txtValue;
        TextView txtVolume;
        View statusCircle;
        TextView cbKiai;
    }

    public TimingPointAdapter(ArrayList<TimingPoint> data, Context context) {
        super(context, R.layout.row_item, data);
        this.dataSet = data;
        this.mContext=context;

    }

    @Override
    public void onClick(View v) {

        int position=(Integer) v.getTag();
        Object object= getItem(position);
        TimingPoint dataModel=(TimingPoint) object;

        switch (v.getId())
        {
            /*
            case R.id.item_info:
                Snackbar.make(v, "Release date " +dataModel.getFeature(), Snackbar.LENGTH_LONG)
                        .setAction("No action", null).show();
                break;

             */
        }
    }

    private int lastPosition = -1;

    @Override
    public View getView(int position, View convertView, ViewGroup parent) {
        // Get the data item for this position
        TimingPoint timingPoint = getItem(position);
        // Check if an existing view is being reused, otherwise inflate the view
        ViewHolder viewHolder; // view lookup cache stored in tag

        final View result;

        if (convertView == null) {

            viewHolder = new ViewHolder();
            LayoutInflater inflater = LayoutInflater.from(getContext());
            convertView = inflater.inflate(R.layout.row_item, parent, false);
            viewHolder.txtOffset = (TextView) convertView.findViewById(R.id.offset);
            viewHolder.txtValue = (TextView) convertView.findViewById(R.id.value);
            //viewHolder.txtVolume = (TextView) convertView.findViewById(R.id.volume);
            viewHolder.statusCircle = (View) convertView.findViewById(R.id.status);
            viewHolder.cbKiai = (TextView) convertView.findViewById(R.id.kiai);

            result=convertView;

            convertView.setTag(viewHolder);
        } else {
            viewHolder = (ViewHolder) convertView.getTag();
            result=convertView;
        }

        //Animation animation = AnimationUtils.loadAnimation(mContext, (position > lastPosition) ? R.anim.up_from_bottom : R.anim.down_from_top);
        //result.startAnimation(animation);
        lastPosition = position;

        double speedValue;


        viewHolder.txtOffset.setText(dec2.format(timingPoint.offset/60000) + ":" + dec2.format(timingPoint.offset/1000%60) + ":" + dec3.format(timingPoint.offset%1000));
        //viewHolder.txtValue.setText(String.valueOf(timingPoint.speed));
        //viewHolder.txtVolume.setText(timingPoint.volume + "%");
        if(timingPoint.speed > 0){
            speedValue = 60000f / timingPoint.speed;
            viewHolder.txtValue.setText(dec1_3.format(speedValue));
            viewHolder.statusCircle.setBackgroundResource(R.drawable.circle_red);
        }else{
            speedValue = -100f / timingPoint.speed;
            viewHolder.txtValue.setText("x" + dec1_2.format(speedValue));
            viewHolder.statusCircle.setBackgroundResource(R.drawable.circle_green);
        }
        if(timingPoint.kiai){
            viewHolder.cbKiai.setVisibility(VISIBLE);
        }else{
            viewHolder.cbKiai.setVisibility(View.INVISIBLE);
        }
        Log.e("XD", selectedPos+"");
        convertView.setBackgroundResource(0);
        if(selectedPos == position) convertView.setBackgroundResource(android.R.color.darker_gray);


        return convertView;
    }
}
