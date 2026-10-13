// Frame-event fixed-point PID for total exposure E * digital_gain_Q8.
// Gains are Q10 per brightness code / accepted update; filtered D defaults to 0.
module cvp_ae_control_v36_gold #(
 parameter signed [15:0] KP_Q10=4, KI_Q10=1, KD_Q10=0
)(
 input clk,rst_n,i_frame_done,i_en,i_ready,i_busy,i_cancel,
 input i_applied,i_apply_error,
 input [7:0] i_mean,input [31:0] i_clipped,i_samples,
 input [15:0] i_exp,input [7:0] i_gain,input [10:0] i_dgain,
 output reg o_valid,output reg [15:0] o_exp,output reg [7:0] o_gain,
 output reg [10:0] o_dgain,output [7:0] o_pid_flags,output [7:0] o_target_mean
);
 // Frame decisions have ample idle time: separate arithmetic stages instead
 // of chaining error, integral clamp and correction into a DSP data/CE pin.
 localparam IDLE=0,CHECK=1,MEASURE=2,HISTORY=3,ACCUM=4,LIMITS=5,
            TERMS=6,SUM=7,CLAMP=8,PID=9,MULTIPLY=10,DELTA=11,
            TARGET=12,ALLOCATE=13,DIVIDE=14,ISSUE=15;
 localparam [21:0] U_MIN=62*256,U_UNITY_MAX=1800*256,U_MAX=1800*1024;
 reg [3:0] state;reg [1:0] frames,settle;
 reg f1,wait_apply,previous_valid;
 reg [7:0] mean1;reg [31:0] clipped1,samples1;
 reg [9:0] mean_sum,window_mean;
 reg [33:0] clip_sum,sample_sum,window_samples;
 reg [38:0] window_scaled_clip;
 wire [9:0] next_mean=mean_sum+{2'd0,mean1};
 wire [33:0] next_clip=clip_sum+{2'd0,clipped1};
 wire [33:0] next_samples=sample_sum+{2'd0,samples1};
 reg highlight;
 // Retain a safe target in high-contrast scenes instead of alternately
 // darkening for highlights and brightening back to an unreachable mean.
 reg [9:0] target_mean_q2;
 wire high_clip=window_scaled_clip>{5'd0,window_samples};
 wire [9:0] protected_target=window_mean>160?window_mean-10'd32:10'd128;
 assign o_target_mean=target_mean_q2[9:2];
 reg in_band;
 wire signed [15:0] measured_error=$signed({6'd0,target_mean_q2})-$signed({6'd0,window_mean});
 reg signed [15:0] error_q2;
 reg signed [15:0] integral,previous_error,derivative;
 reg [9:0] previous_mean;
 wire reversed=previous_valid&&error_q2!=0&&previous_error!=0&&error_q2[15]!=previous_error[15];
 reg signed [15:0] integral_base,integral_candidate,raw_d,d_history,filtered_d;
 reg signed [16:0] integral_sum,d_sum;
 reg integral_limit_pipe;
 reg signed [31:0] p_term,i_term,d_term,correction_raw;
 // Keep the original 32-bit sum overflow, then arithmetic shift. Expanding
 // this intermediate or shifting each term would change configurable PID.
 wire signed [31:0] term_sum=p_term+i_term+d_term;
 wire far_error=error_q2>=96||error_q2<= -96;
 wire signed [31:0] correction_limit=far_error?32'sd256:32'sd64;
 // D may hold an adjustment but cannot reverse its requested direction.
 wire signed [31:0] correction_signed=(error_q2>0&&correction_raw<0)||(error_q2<0&&correction_raw>0)?32'sd0:correction_raw;
 wire signed [31:0] correction_clamped=correction_signed>correction_limit?correction_limit:
                                     correction_signed< -correction_limit?-correction_limit:correction_signed;
 reg signed [31:0] correction;
 reg correction_limited,windup;
 reg signed [15:0] held_integral,held_error,held_derivative;
 reg [9:0] held_mean;
 reg [15:0] held_exp,target_exp;reg [7:0] held_gain;
 reg [10:0] held_dgain,target_dgain;
 reg [21:0] current_total,target_total;
 reg [8:0] magnitude;reg decrease;reg [30:0] product;
 wire [21:0] delta_round=(product+31'd512)>>10;
 wire [21:0] delta=delta_round<256?22'd256:delta_round;
 wire [22:0] raised={1'b0,current_total}+{1'b0,delta};
 reg [21:0] delta_held,lower_limit;
 reg [22:0] raised_held;
 wire [21:0] requested_total=decrease?
   (current_total>lower_limit?current_total-delta_held:U_MIN):
   (raised_held>U_MAX?U_MAX:raised_held[21:0]);
 // Restoring division by constant 1800, 21 cycles; no general divider.
 reg [20:0] div_bits;reg [10:0] remainder,quotient;reg [4:0] left;
 wire [11:0] shifted_rem={remainder,div_bits[20]};
 wire div_ge=shifted_rem>=12'd1800;
 wire [11:0] next_rem=div_ge?shifted_rem-12'd1800:shifted_rem;
 reg limited_flag,integral_limit_flag;
 assign o_pid_flags={i_exp==1800,i_dgain==1024,i_dgain==256,
                     highlight,integral_limit_flag,limited_flag,wait_apply,state!=IDLE};
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;frames<=0;settle<=0;f1<=0;wait_apply<=0;previous_valid<=0;
   mean1<=0;clipped1<=0;samples1<=0;mean_sum<=0;clip_sum<=0;sample_sum<=0;
   window_mean<=448;window_samples<=0;window_scaled_clip<=0;highlight<=0;
   target_mean_q2<=448;
   integral<=0;previous_error<=0;derivative<=0;previous_mean<=448;
   in_band<=1;error_q2<=0;integral_base<=0;integral_candidate<=0;
   raw_d<=0;d_history<=0;filtered_d<=0;integral_sum<=0;d_sum<=0;integral_limit_pipe<=0;
   p_term<=0;i_term<=0;d_term<=0;correction_raw<=0;correction<=0;correction_limited<=0;windup<=0;
   held_integral<=0;held_error<=0;held_derivative<=0;held_mean<=448;
   held_exp<=500;target_exp<=500;held_gain<=108;held_dgain<=256;target_dgain<=256;
   current_total<=128000;target_total<=128000;product<=0;magnitude<=0;decrease<=0;
   delta_held<=0;lower_limit<=U_MIN;raised_held<=0;
   div_bits<=0;remainder<=0;quotient<=0;left<=0;limited_flag<=0;integral_limit_flag<=0;
   o_valid<=0;o_exp<=500;o_gain<=108;o_dgain<=256;
  end else begin
   o_valid<=0;
   f1<=i_frame_done&&i_en&&i_ready&&!i_busy&&!i_cancel&&!wait_apply&&state==IDLE;
   if(i_frame_done)begin mean1<=i_mean;clipped1<=i_clipped;samples1<=i_samples;end
   if(!i_en||!i_ready||i_cancel)begin
    state<=IDLE;frames<=0;settle<=0;mean_sum<=0;clip_sum<=0;sample_sum<=0;
    integral<=0;derivative<=0;previous_valid<=0;wait_apply<=0;
    target_mean_q2<=448;
   end else if(wait_apply&&i_apply_error)begin
    wait_apply<=0;state<=IDLE;frames<=0;mean_sum<=0;clip_sum<=0;sample_sum<=0;
   end else if(wait_apply&&i_applied)begin
    wait_apply<=0;settle<=2;frames<=0;mean_sum<=0;clip_sum<=0;sample_sum<=0;
    if(i_exp==o_exp&&i_dgain==o_dgain)begin
     integral<=held_integral;previous_error<=held_error;
     derivative<=held_derivative;previous_mean<=held_mean;previous_valid<=1;
    end else begin integral<=0;derivative<=0;previous_valid<=0;end
   end else if(i_applied)begin
    // A manual transaction may finish after AE has already been re-enabled.
    state<=IDLE;settle<=2;frames<=0;mean_sum<=0;clip_sum<=0;sample_sum<=0;
    integral<=0;derivative<=0;previous_valid<=0;
    target_mean_q2<=448;
   end else if(i_busy||wait_apply)begin
    state<=IDLE;frames<=0;mean_sum<=0;clip_sum<=0;sample_sum<=0;
   end else case(state)
    IDLE:if(f1)begin
     if(samples1==0||settle!=0)begin
      frames<=0;mean_sum<=0;clip_sum<=0;sample_sum<=0;
      if(samples1!=0&&settle!=0)settle<=settle-1'b1;
     end else if(frames==3)begin
      window_mean<=next_mean;window_samples<=next_samples;
      window_scaled_clip<=({5'd0,next_clip}<<4)+({5'd0,next_clip}<<2);
      frames<=0;mean_sum<=0;clip_sum<=0;sample_sum<=0;state<=CHECK;
     end else begin
      frames<=frames+1'b1;mean_sum<=next_mean;clip_sum<=next_clip;sample_sum<=next_samples;
     end
    end
    CHECK:begin
     highlight<=high_clip;
     if(high_clip&&protected_target<target_mean_q2)target_mean_q2<=protected_target;
     else if(!high_clip&&target_mean_q2<448&&
       (window_mean+96<target_mean_q2||window_mean>target_mean_q2+96))begin
       target_mean_q2<=448;integral<=0;derivative<=0;previous_valid<=0;
     end
     state<=MEASURE;
    end
    MEASURE:begin
     in_band<=window_mean+32>=target_mean_q2&&window_mean<=target_mean_q2+32&&!highlight;
     error_q2<=highlight&&measured_error>-32?-16'sd32:measured_error;
     raw_d<=previous_valid?($signed({6'd0,previous_mean})-$signed({6'd0,window_mean})):16'sd0;
     state<=HISTORY;
    end
    HISTORY:begin
     integral_base<=reversed?16'sd0:integral;
     d_history<=reversed?16'sd0:derivative;
     state<=ACCUM;
    end
    ACCUM:begin
     integral_sum<=$signed(integral_base)+$signed(error_q2);
     d_sum<=$signed(d_history)+$signed(raw_d);
     state<=LIMITS;
    end
    LIMITS:begin
     integral_candidate<=integral_sum>512?16'sd512:integral_sum< -512?-16'sd512:integral_sum[15:0];
     filtered_d<=d_sum>>>1;
     integral_limit_pipe<=integral_sum>512||integral_sum< -512;
     state<=TERMS;
    end
    TERMS:begin
     p_term<=KP_Q10*error_q2;i_term<=KI_Q10*integral_candidate;d_term<=KD_Q10*filtered_d;
     state<=SUM;
    end
    SUM:begin correction_raw<=term_sum>>>2;state<=CLAMP;end
    CLAMP:begin
     correction<=correction_clamped;
     correction_limited<=correction_signed!=correction_clamped;
     windup<=(correction_raw>correction_limit&&error_q2>0)||
             (correction_raw< -correction_limit&&error_q2<0);
     state<=PID;
    end
    PID:begin
     if(in_band)begin integral<=0;derivative<=0;previous_valid<=0;state<=IDLE;end
     else if(correction==0)begin
      // A derivative hold is still a measurement update. Let D decay while
      // holding I, otherwise a large configured KD can freeze outside band.
      integral<=integral_base;derivative<=filtered_d;
      previous_mean<=window_mean;previous_error<=error_q2;previous_valid<=1;
      state<=IDLE;
     end
     else begin
      current_total<=i_exp[10:0]*i_dgain;
      held_exp<=i_exp;held_gain<=i_gain;held_dgain<=i_dgain;
      magnitude<=correction<0?-correction:correction;decrease<=correction<0;
      held_integral<=windup?integral_base:integral_candidate;
      held_error<=error_q2;held_mean<=window_mean;held_derivative<=filtered_d;
      limited_flag<=correction_limited;integral_limit_flag<=integral_limit_pipe;
      state<=MULTIPLY;
     end
    end
    MULTIPLY:begin product<=current_total*magnitude;state<=DELTA;end
    DELTA:begin delta_held<=delta;lower_limit<=U_MIN+delta;raised_held<=raised;state<=TARGET;end
    TARGET:begin
     target_total<=requested_total;
     state<=ALLOCATE;
    end
    ALLOCATE:begin
     if(target_total==U_MIN||target_total==U_MAX)begin
      held_integral<=integral_base;limited_flag<=1;
     end
     if(target_total<=U_UNITY_MAX)begin
      target_exp<=(target_total+128)>>8;target_dgain<=256;state<=ISSUE;
     end else begin
      target_exp<=1800;div_bits<=target_total[20:0];remainder<=0;quotient<=0;left<=20;state<=DIVIDE;
     end
    end
    DIVIDE:begin
     div_bits<={div_bits[19:0],1'b0};remainder<=next_rem[10:0];quotient<={quotient[9:0],div_ge};
     if(left==0)begin target_dgain<={quotient[9:0],div_ge};state<=ISSUE;end
     else left<=left-1'b1;
    end
    ISSUE:begin
     state<=IDLE;
     if(i_exp==held_exp&&i_dgain==held_dgain&&
        (target_exp!=held_exp||target_dgain!=held_dgain))begin
      o_exp<=target_exp;o_gain<=held_gain;o_dgain<=target_dgain;o_valid<=1;wait_apply<=1;
     end
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
