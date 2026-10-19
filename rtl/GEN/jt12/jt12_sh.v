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
	Date: 1-31-2017
	*/


// stages must be greater than 2
module jt12_sh #(parameter width=5, stages=24 )
(
	input 				clk,
	input				clk_en /* synthesis direct_enable */,
	input	[width-1:0]	din,
   	output	[width-1:0]	drop,
	// Savestate scan chain. While ss_scan is high every lane shifts one stage and
	// lane i takes the last stage of lane i-1 instead of din, so the register is
	// one chain of ss_n bits from ss_si to ss_so. Only the input of the first
	// stage changes, so the register still maps to a RAM shift register.
	input				ss_scan,
	input				ss_si,
	output				ss_so,
	output		[12:0]	ss_n
);

reg [stages-1:0] bits[width-1:0];

wire [width:0]   ss_lanes = { drop, ss_si };
wire [width-1:0] din_m    = ss_scan ? ss_lanes[width-1:0] : din;
assign ss_so = drop[width-1];
assign ss_n  = width*stages;

genvar i;
generate
	for (i=0; i < width; i=i+1) begin: bit_shifter
		always @(posedge clk) if(clk_en | ss_scan) begin
			bits[i] <= {bits[i][stages-2:0], din_m[i]};
		end
		assign drop[i] = bits[i][stages-1];
	end
endgenerate

endmodule
