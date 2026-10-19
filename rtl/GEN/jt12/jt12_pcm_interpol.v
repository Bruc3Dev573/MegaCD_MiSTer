/* This file is part of JT12.


    JT12 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT12 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT12.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 21-03-2019
*/

module jt12_pcm_interpol
#(parameter dw=9, stepw=5)
(
    input           rst_n,
    input           clk,
    input           cen,      // 8MHz cen
    input           cen55,    // clk & cen55  =  55 kHz
    input           pcm_wr,      // advance to next sample
    input      signed [dw-1:0] pcmin,
    output reg signed [dw-1:0] pcmout,
    // Savestate. ss_hold stops the interpolator, ss_scan shifts the scan chain
    // (jt12_sh.v)
    input           ss_hold,
    input           ss_scan,
    input           ss_si,
    output          ss_so,
    output   [12:0] ss_n
);

reg [stepw-1:0] dn, pre_dn={stepw{1'b1}};
wire posedge_pcmwr =  pcm_wr && !last_pcm_wr;
wire negedge_pcmwr = !pcm_wr &&  last_pcm_wr;

reg start_div = 0;
wire working;

reg signed [dw-1:0] pcmnew, dx, pcmlast, pcminter;
wire signed [dw:0]  dx_ext = { pcmin[dw-1], pcmin } - { pcmnew[dw-1], pcmnew };
reg sign, last_pcm_wr;

// Savestate scan chain: the three blocks below in order, then the divider
localparam SS_W1 = 3 + 2*stepw + 3*dw;
wire [SS_W1-1:0] ss_q1 = { last_pcm_wr, start_div, pre_dn, pcmnew, pcmlast, dn, dx, sign };
wire        ss_c_div;
wire [12:0] ss_n_div;
assign ss_so = ss_c_div;
assign ss_n  = SS_W1 + 2*dw + ss_n_div;

// latch new data and compute the two deltas : dx and dn, slope = dx/dn
always @(posedge clk) if( ss_scan )
    { last_pcm_wr, start_div, pre_dn, pcmnew, pcmlast, dn, dx, sign } <= { ss_q1[SS_W1-2:0], ss_si };
else if( !ss_hold ) begin
    last_pcm_wr <= pcm_wr;    
    start_div   <= posedge_pcmwr;

    if( posedge_pcmwr ) begin
        pre_dn    <= 1;
        pcmnew    <= pcmin;
        pcmlast   <= pcmnew;
        dn        <= pre_dn;
        dx        <= dx_ext[dw] ? ~dx_ext[dw-1:0] + 'd1 : dx_ext[dw-1:0];
        sign      <= dx_ext[dw];
        start_div <= 1;
    end

    if( !pcm_wr && cen55 ) begin
        if( pre_dn != {stepw{1'b1}} ) pre_dn <= pre_dn + 'd1;
    end
end

// interpolate samples
wire [dw-1:0] step;
wire signed [dw-1:0] next_up   = pcminter + step;
wire signed [dw-1:0] next_down = pcminter - step;
wire overflow_up   = 0;//next_up[dw-1]   != pcmnew[dw-1];
wire overflow_down = 0;//next_down[dw-1] != pcmnew[dw-1];


always @(posedge clk) if( ss_scan )
    pcminter <= { pcminter[dw-2:0], ss_q1[SS_W1-1] };
else if( !ss_hold ) begin
    if( negedge_pcmwr ) begin
        pcminter <= pcmlast;
    end else if(cen55 && !working && !pcm_wr) begin // only advance if the divider has finished
        if( sign ) begin // subtract
            if( next_down > pcmnew && !overflow_down )
                pcminter <= next_down;
            else
                pcminter <= pcmnew; // done
        end
        else begin // add
            if( next_up < pcmnew && !overflow_up )
                pcminter <= next_up;
            else
                pcminter <= pcmnew; // done
        end
    end
end

// output only at cen55

always @(posedge clk) if( ss_scan )
    pcmout <= { pcmout[dw-2:0], pcminter[dw-1] };
else if(cen55) pcmout <= pcminter;

jt10_adpcm_div #(.dw(dw)) u_div(
    .rst_n  ( rst_n       ),
    .clk    ( clk         ),
    .cen    ( ~ss_hold    ),
    .start  ( start_div   ),
    .a      ( dx          ),
    .b      ( { {dw-stepw{1'b0}}, dn }   ),
    .d      ( step        ),
    .r      (             ),
    .working( working     ),
    .ss_scan( ss_scan     ),
    .ss_si  ( pcmout[dw-1]),
    .ss_so  ( ss_c_div    ),
    .ss_n   ( ss_n_div    )
);


endmodule // jt10_adpcmb_interpol