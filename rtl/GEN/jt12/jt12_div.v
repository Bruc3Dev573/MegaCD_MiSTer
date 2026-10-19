/*  This file is part of JT12.

    JT12 is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT12 is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT12.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 14-2-2017
    */


module jt12_div(
    input           rst,
    input           clk,
    input           cen /* synthesis direct_enable */,
    input     [1:0] div_setting,
    output          clk_en,      // after prescaler
    output          clk_en_2,    // cen divided by 2
    output          clk_en_ssg,
    output          clk_en_666,  // 666 kHz
    output          clk_en_111,  // 111 kHz
    output          clk_en_55,   //  55 kHz
    // Savestate. ss_hold stops the dividers and masks the enables they give, which
    // stops the whole chip. ss_scan shifts the scan chain (jt12_sh.v).
    input           ss_hold,
    input           ss_scan,
    input           ss_si,
    output          ss_so,
    output   [12:0] ss_n
);

parameter use_ssg=0;

reg [3:0] opn_pres, opn_cnt=4'd0;
reg [2:0] ssg_pres, ssg_cnt=3'd0;
reg [4:0] adpcm_cnt666  = 5'd0;
reg [2:0] adpcm_cnt111 = 3'd0, adpcm_cnt55=3'd0;
reg cen_int, cen_ssg_int, cen_adpcm_int, cen_adpcm3_int;

// prescaler values for FM
// reset: 1/3
// sel1/sel2
//    0 0    1/3
//    0 1    1/2
//    1 0    1/6  
//    1 1    1/2
//
// According to YM2608 document
//                  FM      SSG   div[1:0]
// reset value     1/6      1/4    10
// 2D              1/6      1/4    10   | 10
// 2D,2E           1/3      1/2    11   | 01
// 2F              1/2      1/1    00   & 00
//  

always @(*) begin
    casez( div_setting )
        2'b0?: begin // FM 1/2 - SSG 1/1
            opn_pres = 4'd2-4'd1;
            ssg_pres = 3'd0;
        end
        2'b10: begin // FM 1/6 - SSG 1/4 (reset value. Fixed for YM2610)
            opn_pres = 4'd6-4'd1;
            ssg_pres = 3'd3;
        end
        2'b11: begin // FM 1/3 - SSG 1/2
            opn_pres = 4'd3-4'd1;
            ssg_pres = 3'd1;
        end
    endcase // div_setting
end

reg cen_55_int;
reg [1:0] div2=2'b0;

reg pre_clk_en, pre_clk_en_2, pre_clk_en_ssg, pre_clk_en_666, pre_clk_en_111, pre_clk_en_55;
reg clk_en_r, clk_en_2_r, clk_en_ssg_r, clk_en_666_r, clk_en_111_r, clk_en_55_r;

`ifdef SIMULATION
initial clk_en_666_r = 1'b0;
`endif

// The negedge registers copy posedge registers within the same clock, so they hold
// no state of their own. The hold masks the enables.
assign clk_en     = clk_en_r     & ~ss_hold;
assign clk_en_2   = clk_en_2_r   & ~ss_hold;
assign clk_en_ssg = clk_en_ssg_r & ~ss_hold;
assign clk_en_666 = clk_en_666_r & ~ss_hold;
assign clk_en_111 = clk_en_111_r & ~ss_hold;
assign clk_en_55  = clk_en_55_r  & ~ss_hold;

always @(negedge clk) begin     // It's important to leave the negedge to use the physical clock enable input
    clk_en_r     <= pre_clk_en;
    clk_en_2_r   <= pre_clk_en_2;
    clk_en_ssg_r <= pre_clk_en_ssg;
    clk_en_666_r <= pre_clk_en_666;
    clk_en_111_r <= pre_clk_en_111;
    clk_en_55_r  <= pre_clk_en_55;
end

// Savestate scan chain: the registers below that the YM2612 uses (SSG, div/2,
// 666 kHz and 111 kHz enables are unused).
wire [5:0]  ss_q0 = { cen_int, cen_adpcm_int, cen_adpcm3_int, cen_55_int, pre_clk_en, pre_clk_en_55 };
wire [10:0] ss_q2 = { adpcm_cnt666, adpcm_cnt111, adpcm_cnt55 };
assign ss_so = ss_q2[10];
assign ss_n  = 13'd21;

always @(posedge clk) begin
    if( ss_scan )
        { cen_int, cen_adpcm_int, cen_adpcm3_int, cen_55_int, pre_clk_en, pre_clk_en_55 } <= { ss_q0[4:0], ss_si };
    else if( !ss_hold ) begin
    cen_int        <= opn_cnt      == 4'd0;
    cen_ssg_int    <= ssg_cnt      == 3'd0;
    cen_adpcm_int  <= adpcm_cnt666 == 5'd0;
    cen_adpcm3_int <= adpcm_cnt111 == 3'd0;
    cen_55_int     <= adpcm_cnt55  == 3'd0;
    `ifdef FASTDIV
    // always enabled for fast sims (use with GYM output, the timers will not work well)
    clk_en_r     <= 1'b1;
    clk_en_ssg_r <= 1'b1;
    clk_en_666_r <= 1'b1;
    clk_en_55_r  <= 1'b1;
    `else
    pre_clk_en     <= cen & cen_int;
    pre_clk_en_2   <= cen && (div2==2'b00);
    pre_clk_en_ssg <= use_ssg ? (cen & cen_ssg_int) : 1'b0;
    pre_clk_en_666 <= cen & cen_adpcm_int;
    pre_clk_en_111 <= cen & cen_adpcm_int & cen_adpcm3_int;
    pre_clk_en_55  <= cen & cen_adpcm_int & cen_adpcm3_int & cen_55_int;
    `endif
    end
end

// Div/2
always @(posedge clk)
    if( cen ) begin
        div2 <= div2==2'b10 ? 2'b00 : (div2+2'b01);
    end

// OPN
always @(posedge clk)
    if( ss_scan )
        opn_cnt <= { opn_cnt[2:0], ss_q0[5] };
    else if( cen & ~ss_hold ) begin
        if( opn_cnt == opn_pres ) begin
            opn_cnt <= 4'd0;  
        end
        else opn_cnt <= opn_cnt + 4'd1;
    end

// SSG
always @(posedge clk)
    if( cen ) begin
        if( ssg_cnt == ssg_pres ) begin
            ssg_cnt <= 3'd0;            
        end
        else ssg_cnt <= ssg_cnt + 3'd1;
    end

// ADPCM-A
always @(posedge clk)
    if( ss_scan )
        { adpcm_cnt666, adpcm_cnt111, adpcm_cnt55 } <= { ss_q2[9:0], opn_cnt[3] };
    else if( cen & ~ss_hold ) begin
        adpcm_cnt666 <= adpcm_cnt666==5'd11 ? 5'd0 : adpcm_cnt666 + 5'd1;
        if( adpcm_cnt666==5'd0 ) begin
            adpcm_cnt111 <= adpcm_cnt111==3'd5 ? 3'd0 : adpcm_cnt111+3'd1;
            if( adpcm_cnt111==3'd0)
                adpcm_cnt55 <= adpcm_cnt55==3'd1 ? 3'd0: adpcm_cnt55+3'd1;
        end
    end

endmodule // jt12_div
