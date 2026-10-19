

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
    Date: 27-1-2017

*/

module jt12_kon(
    input           rst,
    input           clk,
    input           clk_en /* synthesis direct_enable */,
    input   [3:0]   keyon_op,
    input   [2:0]   keyon_ch,
    input   [1:0]   next_op,
    input   [2:0]   next_ch,
    input           up_keyon,
    input           csm,
    // input            flag_A,
    input           overflow_A,

    output  reg     keyon_I,
    // Savestate scan chain, see jt12_sh.v
    input           ss_scan,
    input           ss_si,
    output          ss_so,
    output  [12:0]  ss_n
);

parameter num_ch=6;

wire csr_out;

generate
if(num_ch==6) begin
    // capture overflow signal so it lasts long enough
    reg overflow2;
    reg [4:0] overflow_cycle;

    // Savestate scan chain: overflow2/overflow_cycle, keyon_I, the key-on latch,
    // then the four key-on shift registers.
    wire [5:0] ss_q0 = { overflow2, overflow_cycle };
    wire [7:0] ss_q2;
    wire [12:0] ss_n0, ss_n1, ss_n2, ss_n3;
    wire ss_c0, ss_c1, ss_c2, ss_c3;

    always @(posedge clk) if( ss_scan )
        { overflow2, overflow_cycle } <= { ss_q0[4:0], ss_si };
    else if( clk_en ) begin
        if(overflow_A) begin
            overflow2 <= 1'b1;
            overflow_cycle <= { next_op, next_ch };
        end else begin
            if(overflow_cycle == {next_op, next_ch}) overflow2<=1'b0;
        end
    end

    always @(posedge clk) if( ss_scan )
        keyon_I <= ss_q0[5];
    else if( clk_en )
        keyon_I <= (csm&&next_ch==3'd2&&overflow2) || csr_out;

    reg        up_keyon_reg;
    reg  [3:0] tkeyon_op;
    reg  [2:0] tkeyon_ch;
    wire       key_upnow;

    assign key_upnow = up_keyon_reg && (tkeyon_ch==next_ch) && (next_op == 2'd3);
    assign ss_q2 = { up_keyon_reg, tkeyon_op, tkeyon_ch };

    always @(posedge clk) if( ss_scan )
        { up_keyon_reg, tkeyon_op, tkeyon_ch } <= { ss_q2[6:0], keyon_I };
    else if( clk_en ) begin
        if (rst)
            up_keyon_reg <= 1'b0;
        if (up_keyon) begin
            up_keyon_reg <= 1'b1;
            tkeyon_op <= keyon_op;
            tkeyon_ch <= keyon_ch;      end
        else if (key_upnow)
            up_keyon_reg <= 1'b0;
     end


    wire middle1;
    wire middle2;
    wire middle3;
    wire din      = key_upnow ? tkeyon_op[3] : csr_out;
    wire mid_din2 = key_upnow ? tkeyon_op[1] : middle1;
    wire mid_din3 = key_upnow ? tkeyon_op[2] : middle2;
    wire mid_din4 = key_upnow ? tkeyon_op[0] : middle3;

    jt12_sh_rst #(.width(1),.stages(6),.rstval(1'b0)) u_konch0(
        .clk    ( clk       ),
        .clk_en ( clk_en    ),
        .rst    ( rst       ),
        .din    ( din       ),
        .drop   ( middle1   ),
        .ss_scan( ss_scan   ),
        .ss_si  ( ss_q2[7]  ),
        .ss_so  ( ss_c0     ),
        .ss_n   ( ss_n0     )
    );

    jt12_sh_rst #(.width(1),.stages(6),.rstval(1'b0)) u_konch1(
        .clk    ( clk       ),
        .clk_en ( clk_en    ),
        .rst    ( rst       ),
        .din    ( mid_din2  ),
        .drop   ( middle2   ),
        .ss_scan( ss_scan   ),
        .ss_si  ( ss_c0     ),
        .ss_so  ( ss_c1     ),
        .ss_n   ( ss_n1     )
    );

    jt12_sh_rst #(.width(1),.stages(6),.rstval(1'b0)) u_konch2(
        .clk    ( clk       ),
        .clk_en ( clk_en    ),
        .rst    ( rst       ),
        .din    ( mid_din3  ),
        .drop   ( middle3   ),
        .ss_scan( ss_scan   ),
        .ss_si  ( ss_c1     ),
        .ss_so  ( ss_c2     ),
        .ss_n   ( ss_n2     )
    );

    jt12_sh_rst #(.width(1),.stages(6),.rstval(1'b0)) u_konch3(
        .clk    ( clk       ),
        .clk_en ( clk_en    ),
        .rst    ( rst       ),
        .din    ( mid_din4  ),
        .drop   ( csr_out   ),
        .ss_scan( ss_scan   ),
        .ss_si  ( ss_c2     ),
        .ss_so  ( ss_c3     ),
        .ss_n   ( ss_n3     )
    );

    assign ss_so = ss_c3;
    assign ss_n  = 13'd15 + ss_n0 + ss_n1 + ss_n2 + ss_n3;
end
else begin // 3 channels
    reg din;
    reg [3:0] next_op_hot;

    always @(*) begin
        case( next_op )
            2'd0: next_op_hot = 4'b0001; // S1
            2'd1: next_op_hot = 4'b0100; // S3
            2'd2: next_op_hot = 4'b0010; // S2
            2'd3: next_op_hot = 4'b1000; // S4
        endcase
        din = keyon_ch[1:0]==next_ch[1:0] && up_keyon ? |(keyon_op&next_op_hot) : csr_out;
    end

    wire [12:0] ss_c0n;

    always @(posedge clk) if( ss_scan )
        keyon_I <= ss_si;
    else if( clk_en )
        keyon_I <= csr_out; // No CSM for YM2203

    jt12_sh_rst #(.width(1),.stages(12),.rstval(1'b0)) u_konch1(
        .clk    ( clk       ),
        .clk_en ( clk_en    ),
        .rst    ( rst       ),
        .din    ( din       ),
        .drop   ( csr_out   ),
        .ss_scan( ss_scan   ),
        .ss_si  ( keyon_I   ),
        .ss_so  ( ss_so     ),
        .ss_n   ( ss_c0n    )
    );
    assign ss_n = 13'd1 + ss_c0n;
end
endgenerate


endmodule
