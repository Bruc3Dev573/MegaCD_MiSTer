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
    Date: 14-2-2016
    
    Based on information posted by Nemesis on:
http://gendev.spritesmind.net/forum/viewtopic.php?t=386&postdays=0&postorder=asc&start=167

    Based on jt51_phasegen.v, from JT51 
    
    */


/*

    tab size 4

*/

module jt12_pg(
    input               clk,
    input               clk_en /* synthesis direct_enable */,
    input               rst,
    // Channel frequency
    input       [10:0]  fnum_I,
    input       [ 2:0]  block_I,
    // Operator multiplying
    input       [ 3:0]  mul_II,
    // Operator detuning
    input       [ 2:0]  dt1_I, // same as JT51's DT1
    // phase modulation from LFO
    input       [ 6:0]  lfo_mod,
    input       [ 2:0]  pms_I,
    // phase operation
    input               pg_rst_II,
    input               pg_stop,    // not implemented
    
    output  reg [ 4:0]  keycode_II,
    output      [ 9:0]  phase_VIII,
    // Savestate scan chain, see jt12_sh.v
    input               ss_scan,
    input               ss_si,
    output              ss_so,
    output      [12:0]  ss_n
);

parameter num_ch=6;

wire [4:0] keycode_I;
wire signed [5:0] detune_mod_I;
reg signed [5:0] detune_mod_II;
wire [16:0] phinc_I;
reg  [16:0] phinc_II;
wire [19:0] phase_drop, phase_in;
wire [ 9:0] phase_II;

// Savestate scan chain: the stage II registers, the phase and the phase pad
wire [27:0] ss_q = { keycode_II, detune_mod_II, phinc_II };
wire        ss_c_ph;
wire [12:0] ss_n_ph, ss_n_pad;
assign ss_n = 13'd28 + ss_n_ph + ss_n_pad;

always @(posedge clk) if(ss_scan)
    { keycode_II, detune_mod_II, phinc_II } <= { ss_q[26:0], ss_si };
else if(clk_en) begin
    keycode_II      <= keycode_I;
    detune_mod_II   <= detune_mod_I;
    phinc_II        <= phinc_I;
end

jt12_pg_comb u_comb(
    .block      ( block_I       ),
    .fnum       ( fnum_I        ),
    // Phase Modulation
    .lfo_mod    ( lfo_mod[6:2]  ),
    .pms        ( pms_I         ),

    // Detune
    .detune     ( dt1_I         ),
    .keycode    ( keycode_I     ),
    .detune_out ( detune_mod_I  ),
    // Phase increment  
    .phinc_out  ( phinc_I       ),
    // Phase add
    .mul        ( mul_II        ),
    .phase_in   ( phase_drop    ),
    .pg_rst     ( pg_rst_II     ),
    .detune_in  ( detune_mod_II ),
    .phinc_in   ( phinc_II      ),

    .phase_out  ( phase_in      ),
    .phase_op   ( phase_II      )
);

jt12_sh_rst #( .width(20), .stages(4*num_ch) ) u_phsh(
    .clk    ( clk       ),
    .clk_en ( clk_en    ),
    .rst    ( rst       ),
    .din    ( phase_in  ),
    .drop   ( phase_drop),
    .ss_scan( ss_scan   ),
    .ss_si  ( ss_q[27]  ),
    .ss_so  ( ss_c_ph   ),
    .ss_n   ( ss_n_ph   )
);

jt12_sh_rst #( .width(10), .stages(6) ) u_pad(
    .clk    ( clk       ),
    .clk_en ( clk_en    ),
    .rst    ( rst       ),  
    .din    ( phase_II  ),
    .drop   ( phase_VIII),
    .ss_scan( ss_scan   ),
    .ss_si  ( ss_c_ph   ),
    .ss_so  ( ss_so     ),
    .ss_n   ( ss_n_pad  )
);

endmodule

