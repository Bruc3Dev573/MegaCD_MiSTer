//============================================================================
//  FPGAGen port to MiSTer
//  Copyright (c) 2017-2019 Sorgelig
//
//  YM2612 implementation by Jose Tejada Gomez. Twitter: @topapate
//  Original Genesis code: Copyright (c) 2010-2013 Gregory Estrade (greg@torlus.com) 
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign BUTTONS   = {bk_reload, 1'b0};
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign LED_DISK  = {1'b1,MCD_LED_RED};
assign LED_POWER = {1'b1,MCD_LED_GREEN};
assign LED_USER  = rom_download | sav_pending;

assign VGA_SCALER= 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;
assign AUDIO_MIX = 0;
wire [1:0] ar = status[50:49];
wire [7:0] arx,ary;

always_comb begin
	case(res) // {V30, H40}
		2'b00: begin // 256 x 224
			arx = 8'd64;
			ary = 8'd49;
		end

		2'b01: begin // 320 x 224
			arx = status[30] ? 8'd10: 8'd64;
			ary = status[30] ? 8'd7 : 8'd49;
		end

		2'b10: begin // 256 x 240
			arx = 8'd128;
			ary = 8'd105;
		end

		2'b11: begin // 320 x 240
			arx = status[30] ? 8'd4 : 8'd128;
			ary = status[30] ? 8'd3 : 8'd105;
		end
	endcase
end

wire       vcrop_en = status[32];
wire [3:0] vcopt    = status[54:51];
reg        en216p;
reg  [4:0] voff;
always @(posedge CLK_VIDEO) begin
	en216p <= ((HDMI_WIDTH == 1920) && (HDMI_HEIGHT == 1080) && !forced_scandoubler && !scale);
	voff <= (vcopt < 6) ? {vcopt,1'b0} : ({vcopt,1'b0} - 5'd24);
end

wire vga_de;
video_freak video_freak
(
	.*,
	.VGA_DE_IN(vga_de),
	.ARX((!ar) ? arx : (ar - 1'd1)),
	.ARY((!ar) ? ary : 12'd0),
	.CROP_SIZE((en216p & vcrop_en) ? 10'd216 : 10'd0),
	.CROP_OFF(voff),
	.SCALE(status[56:55])
);

///////////////////////////////////////////////////
wire clk_sys, clk_ram, locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_ram),
	.outclk_1(clk_sys),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(locked)
);

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;
wire        cfg_waitrequest;
reg         cfg_write;
reg   [5:0] cfg_address;
reg  [31:0] cfg_data;

pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(cfg_waitrequest),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(cfg_write),
	.mgmt_address(cfg_address),
	.mgmt_writedata(cfg_data),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

always @(posedge CLK_50M) begin
	reg pald = 0, pald2 = 0;
	reg [2:0] state = 0;
	reg pal_r;

	pald <= PAL;
	pald2 <= pald;

	cfg_write <= 0;
	if(pald2 == pald && pald2 != pal_r) begin
		state <= 1;
		pal_r <= pald2;
	end

	if(!cfg_waitrequest) begin
		if(state) state<=state+1'd1;
		case(state)
			1: begin
					cfg_address <= 0;
					cfg_data <= 0;
					cfg_write <= 1;
				end
			5: begin
					cfg_address <= 7;
					cfg_data <= pal_r ? 2201376125 : 2537930535;
					cfg_write <= 1;
				end
			7: begin
					cfg_address <= 2;
					cfg_data <= 0;
					cfg_write <= 1;
				end
		endcase
	end
end

// Status Bit Map:
//             Upper                             Lower              
// 0         1         2         3          4         5         6   
// 01234567890123456789012345678901 23456789012345678901234567890123
// 0123456789ABCDEFGHIJKLMNOPQRSTUV 0123456789ABCDEFGHIJKLMNOPQRSTUV
// XXXXXXXXX XXXXXXXXXXXXXXXXXX XXX XXXXXXXXXXXXXXXXXXXXXXXXXXX

`include "build_id.v"
localparam CONF_STR = {
	// Four 4 MB savestate slots in DDR3 from 0x3E000000, declared to Main with
	// SS3E000000:400000. The core does not use DDR3 for anything else.
	// Main stores the slots under the core name, so renaming the core hides existing slots.
	"MegaCD;SS3E000000:400000;",
	"S0,CUECHD,Insert Disk;",
	"-;",
	"h6O67,Region,Auto(JP),JP,US,EU;",
	"h7O67,Region,Auto(US),JP,US,EU;",
	"h8O67,Region,Auto(EU),JP,US,EU;",
	"-;",
	"C,Cheats;",
	"H5OO,Cheats Enabled,Yes,No;",
	"-;",
	"O3,Backup RAM,Internal,Internal+Cart;",
	"D0RG,Reload Backup RAM;",
	"D0RH,Save Backup RAM;",
	"D0OD,Autosave,No,Yes;",
	"-;",

	"P1,Audio & Video;",
	"P1-;",
	"P1oHI,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1OU,320x224 Aspect,Original,Corrected;",
	"P1o13,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1-;",
	"d9P1o0,Vertical Crop,Disabled,216p(5x);",
	"d9P1oJM,Crop Offset,0,2,4,8,10,12,-12,-10,-8,-6,-4,-2;",
	"P1oNO,Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P1- ;",
	"P1OT,Border,No,Yes;",
	"P1oFG,Composite Blend,Off,On,Adaptive;",
	"P1OA,CRAM Dots,Off,On;",
	"P1OV,Sprite Limit,Normal,High;",
	"P1-;",
	"P1OEF,Audio Filter,Model 1,Model 2,Minimal,No Filter;",
	"P1OR,CD Audio,Unfiltered,Filtered;",
	"P1oPQ,Audio Boost,No,2x,4x;",
	"P1O8,FM Chip,YM2612,YM3438;",
	"P1ON,HiFi PCM,No,Yes;",

	"P2,Input;",
	"P2-;",
	"P2O4,Swap Joysticks,No,Yes;",
	"P2O5,6 Buttons Mode,No,Yes;",
	"P2OLM,Multitap,Disabled,4-Way,TeamPlayer: Port1,TeamPlayer: Port2;",
	"P2-;",
	"P2OIJ,Mouse,None,Port1,Port2;",
	"P2OK,Mouse Flip Y,No,Yes;",
	"P2-;",
	"P2o89,Gun Control,Disabled,Joy1,Joy2,Mouse;",
	"D4P2oA,Gun Fire,Joy,Mouse;",
	"D4P2oBC,Cross,Small,Medium,Big,None;",
	"D4P2oD,Gun Type,Justifier,Menacer;",
	"P2-;",
	"P2oE,Serial,OFF,SNAC;",

	"- ;",
	"H2OB,Enable FM,Yes,No;",//11
	"H2OC,Enable PSG,Yes,No;",//12
	"H2OP,Enable PCM,Yes,No;",//25
	"H2OQ,Enable CDDA,Yes,No;",//26
	"H2o4,Enable BGA,Yes,No;",//36
	"H2o5,Enable BGB,Yes,No;",//37
	"H2o6,Enable SPR,Yes,No;",//38
	"H2o7,MCD RAM,Banks 2&3,Banks 0&1;",//39
	"H2-;",
	// Savestate controls. Load is status[67], Save is status[66] and the slot is status[65:64].
	"-;",
	"R[67],Load State;",
	"R[66],Save State;",
	"O[65:64],Savestate Slot,1,2,3,4;",
	"R0,Reset & Eject CD;",
	// Metadata rows follow the selectable rows because Main skips I rows only when drawing.
	// Savestate overlay indices: help, slots 1-4, then save/load per slot.
	"I,",
	"Slot=DPAD|Save/Load=Mode+DPAD,",
	"Active Slot 1,",
	"Active Slot 2,",
	"Active Slot 3,",
	"Active Slot 4,",
	"Save to state 1,",
	"Restore state 1,",
	"Save to state 2,",
	"Restore state 2,",
	"Save to state 3,",
	"Restore state 3,",
	"Save to state 4,",
	"Restore state 4;",
	//"R1,Reset;"
	"J1,A,B,C,Start,Mode,X,Y,Z,Savestate;",
	"jn,A,B,R,Start,Select,X,Y,L;", // name map to SNES layout.
	"jp,Y,B,A,Start,Select,L,X,R;", // positional map to SNES layout (3 button friendly)  
	"V,v",`BUILD_DATE
};

wire [15:0] status_menumask = {en216p,region,!region,~gg_available,!gun_mode,1'b1,~dbg_menu,1'b0,~bk_ena};
// 128 bits because the savestate OSD controls are at status[67:64].
wire [127:0] status;
wire        ss_info_req;   // driven by savestate_ui
wire  [7:0] ss_info;
wire  [1:0] buttons;
wire [12:0] joystick_0,joystick_1,joystick_2,joystick_3,joystick_4;
wire  [7:0] joy0_x,joy0_y,joy1_x,joy1_y;
wire        ioctl_download;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire [15:0] ioctl_data;
wire  [7:0] ioctl_index;
reg         ioctl_wait;

reg  [31:0] sd_lba[1];
reg         sd_rd = 0;
reg         sd_wr = 0;
wire        sd_ack;
wire  [7:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din[1];
wire        sd_buff_wr;
wire        img_mounted;
wire        img_readonly;
wire [63:0] img_size;

wire        forced_scandoubler;
wire [10:0] ps2_key;
wire [24:0] ps2_mouse;

wire [21:0] gamma_bus;

wire [1:0] gun_mode = status[41:40];
wire       gun_btn_mode = status[42];
wire       gun_type = ~status[45];

assign sd_buff_din[0] = sd_lba[0][10:4] ? tmpram_sd_buff_data : bram_sd_buff_data;

// Keep the configuration string in BRAM to limit logic and routing pressure.
hps_io #(.CONF_STR(CONF_STR), .CONF_STR_BRAM(1), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(joystick_2),
	.joystick_3(joystick_3),
	.joystick_4(joystick_4),
	.joystick_l_analog_0({joy0_y, joy0_x}),
	.joystick_l_analog_1({joy1_y, joy1_x}),
	.buttons(buttons),
	.forced_scandoubler(forced_scandoubler),
	.new_vmode(new_vmode),

	.status(status),
	// Shortcut slot feedback must not clear an explicitly selected region.
	.status_in({status[127:66],ssui_slot,status[63:8],(region_reset ? 2'b00 : status[7:6]),status[5:0]}),
	.status_set(region_reset | ssui_status_upd),
	.status_menumask(status_menumask),

	// On-screen "Save 1" / "Load 1" text, driven by savestate_ui.
	.info_req(ss_info_req),
	.info(ss_info),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_data),
	.ioctl_wait(ioctl_wait),

	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	
	.gamma_bus(gamma_bus),
	
	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),

	.EXT_BUS(EXT_BUS)
);

wire [35:0] EXT_BUS;
hps_ext hps_ext
(
	.clk_sys(clk_sys),
	.EXT_BUS(EXT_BUS),

	// Stop the firmware drive model while the CPUs are held.
	.cd_data_ready(~ss_cpu_freeze),
	// Gated during the freeze. hps_ext returns this flag for CDDA sectors, and
	// cd_data_ready only throttles data sectors.
	.cdda_ready(MCD_CDDA_WR_READY & ~ss_cpu_freeze),

	.cd_in(cd_in),
	.cd_out(cd_out),

	// Keep the core held until Main has restored its saved drive context.
	.ss_load_pending(ss_load_pending),
	// Data uses the last decoded CDC sector. CDDA uses the guarded status MSF.
	// The saved type nibble lets Main advance to the next data sector.
	.ss_load_cdd_stat({4'd0, ss_cdd_stat_saved[35:32],
	                   (ss_cdd_stat_saved[35:32] == 4'h4) ? ss_cdc_head : ss_rsy_msf,
	                   4'h0, ss_cdd_stat_saved[3:0]}),
	.ss_load_taken(ss_load_taken)
);

reg  ss_load_pending = 0;
wire ss_load_taken;
always @(posedge clk_sys) begin
	reg taken_d;
	if (ss_load_done) begin
		ss_load_pending      <= 1;
	end
	else if (taken_d != ss_load_taken) begin
		ss_load_pending    <= 0;
	end
	taken_d <= ss_load_taken;
end

reg dbg_menu = 0;
always @(posedge clk_sys) begin
	reg old_stb;
	reg enter = 0;
	reg esc = 0;
	
	old_stb <= ps2_key[10];
	if(old_stb ^ ps2_key[10]) begin
		if(ps2_key[7:0] == 'h5A) enter <= ps2_key[9];
		if(ps2_key[7:0] == 'h76) esc   <= ps2_key[9];
	end
	
	if(enter & esc) begin
		dbg_menu <= ~dbg_menu;
		enter <= 0;
		esc <= 0;
	end
end

wire rom_download = ioctl_download & (ioctl_index[5:0] <= 6'h01);
wire cdc_dat_download = ioctl_download & (ioctl_index[5:0] == 6'h02);
wire cdc_sub_download = ioctl_download & (ioctl_index[5:0] == 6'h03);
wire cdc_cdda_download = ioctl_download & (ioctl_index[5:0] == 6'h04);
wire save_download = ioctl_download & (ioctl_index[5:0] == 6'h05);
wire code_download = ioctl_download & &ioctl_index;

wire reset = RESET | status[0] | buttons[1] | region_set;

///////////////////////////////////////////////////
// Code loading for WIDE IO (16 bit)
reg [128:0] gg_code;
wire        gg_available = gg_available1 | gg_available2;

// Code layout:
// {clock bit, code flags,     32'b address, 32'b compare, 32'b replace}
//  128        127:96          95:64         63:32         31:0
// Integer values are in BIG endian byte order, so it up to the loader
// or generator of the code to re-arrange them correctly.

always_ff @(posedge clk_sys) begin
	gg_code[128] <= 0;

	if (code_download & ioctl_wr) begin
		case (ioctl_addr[3:0])
			0:  gg_code[111:96]  <= ioctl_data; // Flags Bottom Word
			2:  gg_code[127:112] <= ioctl_data; // Flags Top Word
			4:  gg_code[79:64]   <= ioctl_data; // Address Bottom Word
			6:  gg_code[95:80]   <= ioctl_data; // Address Top Word
			8:  gg_code[47:32]   <= ioctl_data; // Compare Bottom Word
			10: gg_code[63:48]   <= ioctl_data; // Compare top Word
			12: gg_code[15:0]    <= ioctl_data; // Replace Bottom Word
			14: begin
				 gg_code[31:16]   <= ioctl_data; // Replace Top Word
				 gg_code[128]     <= 1;      // Clock it in
			end
		endcase
	end
end


//Genesis
wire [23:1] GEN_VA;
wire [15:0] GEN_VDI, GEN_VDO;
wire        GEN_RNW, GEN_LDS_N, GEN_UDS_N;
wire        GEN_AS_N, GEN_DTACK_N, GEN_ASEL_N;
wire        GEN_RAS2_N;
wire        EXT_ROM_N;
wire        EXT_FDC_N;
wire        GEN_VCLK_CE;
wire        GEN_CE0_N;
wire        GEN_WRL_N, GEN_WRH_N, GEN_OE_N;
wire        GEN_ROM_CE_N;
wire        GEN_RAM_CE_N;
wire        GEN_PAGE_CE_N;

wire [15:0] GEN_MEM_DO;
wire        GEN_MEM_BUSY;

wire [15:0] GEN_AUDL;
wire [15:0] GEN_AUDR;
wire        GEN_CE;

wire [7:0] color_lut[16] = '{
	8'd0,   8'd27,  8'd49,  8'd71,
	8'd87,  8'd103, 8'd119, 8'd130,
	8'd146, 8'd157, 8'd174, 8'd190,
	8'd206, 8'd228, 8'd255, 8'd255
};

wire [3:0] r, g, b;
wire vs,hs;
wire ce_pix;
wire hblank, vblank;
wire interlace;
wire [1:0] resolution;

wire EN_GEN_FM   = ~status[11] | ~dbg_menu;
wire EN_GEN_PSG  = ~status[12] | ~dbg_menu;
wire EN_MCD_PCM  = ~status[25] | ~dbg_menu;
wire EN_MCD_CDDA = ~status[26] | ~dbg_menu;
wire EN_VDP_BGA  = ~status[36] | ~dbg_menu;
wire EN_VDP_BGB  = ~status[37] | ~dbg_menu;
wire EN_VDP_SPR  = ~status[38] | ~dbg_menu;
wire MCD_BANK23  = ~status[39] | ~dbg_menu;

wire gg_available1;

gen gen
(
	.RESET_N(~reset),
	.MCLK(clk_sys),
	
	.VA(GEN_VA),
	.VDI(GEN_VDI),
	.VDO(GEN_VDO),
	.RNW(GEN_RNW),
	.LDS_N(GEN_LDS_N),
	.UDS_N(GEN_UDS_N),
	.AS_N(GEN_AS_N),
	.DTACK_N(GEN_DTACK_N),
	.ASEL_N(GEN_ASEL_N),
	.VCLK_CE(GEN_VCLK_CE),
	.CE0_N(GEN_CE0_N),
	.RAS2_N(GEN_RAS2_N),
	.ROM_N(EXT_ROM_N),
	.FDC_N(EXT_FDC_N),
	.CART_N(CART_CART_N),
	.DISK_N(0),
	.WRL_N(GEN_WRL_N),
	.WRH_N(GEN_WRH_N),
	.OE_N(GEN_OE_N),
	
	.TIME_N(GEN_PAGE_CE_N),
	.TIME_DI(GEN_PAGE_DI),

	.LOADING(rom_download),
	.EXPORT(|region),
	.PAL(PAL),

	.EXT_SL(mcd_l),
	.EXT_SR(mcd_r),
	.EXT_EN(status[27]),

	.DAC_LDATA(GEN_AUDL),
	.DAC_RDATA(GEN_AUDR),
	.DAC_CE(GEN_CE),

	.RED(r),
	.GREEN(g),
	.BLUE(b),
	.VS(vs),
	.HS(hs),
	.HBL(hblank),
	.VBL(vblank),
	.BORDER(status[29]),
	.CRAM_DOTS(status[10]),
	.CE_PIX(ce_pix),
	.FIELD(VGA_F1),
	.INTERLACE(interlace),
	.RESOLUTION(resolution),
	.EN_BGA(EN_VDP_BGA),
	.EN_BGB(EN_VDP_BGB),
	.EN_SPR(EN_VDP_SPR),

	.J3BUT(~status[5]),
	.JOY_1(status[4] ^ status[46] ? joystick_1[11:0] : joystick_0[11:0]),
	.JOY_2(status[4] ^ status[46] ? joystick_0[11:0] : joystick_1[11:0]),
	.JOY_3(joystick_2[11:0]),
	.JOY_4(joystick_3[11:0]),
	.JOY_5(joystick_4[11:0]),
	.MULTITAP(status[22:21]),

	.MOUSE(ps2_mouse),
	.MOUSE_OPT(status[20:18]),

	.GUN_OPT(|gun_mode),
	.GUN_TYPE(gun_type),
	.GUN_SENSOR(lg_sensor),
	.GUN_A(lg_a),
	.GUN_B(lg_b),
	.GUN_C(lg_c),
	.GUN_START(lg_start),

	.SERJOYSTICK_IN(SERJOYSTICK_IN),
	.SERJOYSTICK_OUT(SERJOYSTICK_OUT),
	.SER_OPT(SER_OPT),

	.ENABLE_FM(EN_GEN_FM),
	.ENABLE_PSG(EN_GEN_PSG),
	.EN_HIFI_PCM(status[23]), // Option "N"
	.LADDER(~status[8]),
	.LPF_MODE(status[15:14]),

	.OBJ_LIMIT_HIGH(status[31]),

	.RAM_CE_N(GEN_RAM_CE_N),
	.RAM_RDY(~GEN_MEM_BUSY),

	.TRANSP_DETECT(TRANSP_DETECT),

	.GG_RESET(code_download && ioctl_wr && !ioctl_addr),
	.GG_EN(status[24]),
	.GG_CODE({~gg_code[95] & gg_code[128], gg_code[127:0]}),
	.GG_AVAILABLE(gg_available1),

	.SS_FREEZE(ss_cpu_freeze),
	.SS_M68K_FROZEN(ss_m68k_frozen),
	.SS_M68K_ADDR(ss_m68k_addr),
	.SS_M68K_WR_DATA(ss_m68k_wr_data),
	.SS_M68K_WR_EN(ss_m68k_wr_en),
	.SS_M68K_RD_DATA(ss_m68k_rd_data),

	.SS_ACTIVE(ss_freeze_active),
	.SS_MEM_SEL(ss_gen_mem_sel),
	.SS_MEM_ADDR(ss_gen_mem_addr),
	.SS_MEM_WR_DATA(ss_mem_wr_data),
	.SS_MEM_WR_EN(ss_gen_mem_wr_en),
	.SS_MEM_RD_DATA(ss_gen_mem_rd_data),

	.SS_VDP_SEL(ss_vdp_sel),
	.SS_VDP_ADDR(ss_vdp_addr),
	.SS_VDP_WR_DATA(ss_state_dout),
	.SS_VDP_WR_EN(ss_vdp_wr_en),
	.SS_VDP_RD_DATA(ss_vdp_rd_data),
	.SS_VDP_QUIET(ss_vdp_quiet),
	// Capture the raster phase when the main CPU parks. Waiting for the VBlank
	// grant would mix a later raster line with earlier pending interrupts.
	// freeze_active also captures phase when the unparked backstop fires.
	.SS_VDP_PARK(ss_m68k_frozen | ss_freeze_active),
	.SS_VDP_RESUME(ss_vdp_resume),
	.SS_VDP_PHASE_OK(ss_vdp_phase_ok),

	.SS_FM_ADDR(ss_fm_addr),
	.SS_FM_WR_DATA(ss_state_dout[7:0]),
	.SS_FM_WR_EN(ss_fm_wr_en),
	.SS_FM_RD_DATA(ss_fm_rd_data),
	.SS_FM_REPLAY(ss_load_done),
	.SS_FM_REPLAYING(ss_fm_replaying),

	.SS_PSG_ADDR(ss_psg_addr),
	.SS_PSG_WR_DATA(ss_state_dout),
	.SS_PSG_WR_EN(ss_psg_wr_en),
	.SS_PSG_RD_DATA(ss_psg_rd_data),

	.SS_Z80_FROZEN(ss_z80_frozen),
	.SS_Z80_REG(ss_z80_reg),
	.SS_Z80_DIR(ss_z80_dir),
	.SS_Z80_DIRSET(ss_z80_dirset)
);

wire         ss_z80_frozen;
wire [211:0] ss_z80_reg;

wire  [2:0] ss_psg_addr;
wire        ss_psg_wr_en;
wire [31:0] ss_psg_rd_data;

wire       ss_vdp_quiet;
wire [8:0] ss_fm_addr;
wire       ss_fm_wr_en;
wire [7:0] ss_fm_rd_data;
wire       ss_fm_replaying;

wire  [1:0] ss_vdp_sel;
wire  [7:0] ss_vdp_addr;
wire        ss_vdp_wr_en;
wire [31:0] ss_vdp_rd_data;

// Genesis-side memory stream: VRAM and Z80 RAM.
wire        ss_gen_mem_sel;
wire [14:0] ss_gen_mem_addr;
wire        ss_gen_mem_wr_en;
wire [15:0] ss_gen_mem_rd_data;

// Savestate taps into the main CPU. The region decode is in the savestate block below.
wire        ss_m68k_frozen;
wire  [7:0] ss_m68k_addr;
wire [15:0] ss_m68k_wr_data;
wire        ss_m68k_wr_en;
wire [15:0] ss_m68k_rd_data;

wire TRANSP_DETECT;
wire cofi_enable = status[47] || (status[48] && TRANSP_DETECT);

assign GEN_VDI = !GEN_RAM_CE_N ? GEN_MEM_DO_R :
					  !CART_DTACK_N ? CART_DO :
					  MCD_DO;
assign GEN_DTACK_N = MCD_DTACK_N & CART_DTACK_N;

reg [15:0] GEN_MEM_DO_R;
always @(posedge clk_sys) begin
	reg old_bsy;
	
	old_bsy <= GEN_MEM_BUSY;
	if(old_bsy & ~GEN_MEM_BUSY) GEN_MEM_DO_R <= GEN_MEM_DO;
end

// MCD
wire [15:0] MCD_DO;
wire        MCD_DTACK_N;

wire [15:0] MCD_PCM_SL;
wire [15:0] MCD_PCM_SR;
wire [15:0] MCD_CDDA_SL;
wire [15:0] MCD_CDDA_SR;
wire        MCD_CDDA_WR_READY;

wire [17:0] MCD_PRG_ADDR;
wire [15:0] MCD_PRG_DO;
wire [15:0] MCD_PRG_DI;
wire        MCD_PRG_OE_N;
wire        MCD_PRG_WRL_N;
wire        MCD_PRG_WRH_N;
wire        MCD_PRG_BUSY;

wire [13:1] MCD_BRAM_ADDR;
wire  [7:0] MCD_BRAM_DO;
wire  [7:0] MCD_BRAM_DI;
wire        MCD_BRAM_WE;

wire        MCD_LED_RED;
wire        MCD_LED_GREEN;

wire        MCD_RST_N;

wire        gg_available2;

// Savestate taps into the sub-CPU. The region decode is in the savestate block
// at the end of this file.
wire        ss_s68k_frozen;
wire  [7:0] ss_s68k_addr;
wire [15:0] ss_s68k_wr_data;
wire        ss_s68k_wr_en;
wire [15:0] ss_s68k_rd_data;

MCD MCD
(
	.RST_N(~(reset|rom_download)),
	.CLK(clk_sys),
	.ENABLE(1),
	.MCD_RST_N(MCD_RST_N),
	.PALSW(PAL),

	.EXT_VA(GEN_VA[17:1]),
	.EXT_VDI(GEN_VDO),
	.EXT_VDO(MCD_DO),
	.EXT_AS_N(GEN_AS_N),
	.EXT_RNW(GEN_RNW),
	.EXT_LDS_N(GEN_LDS_N),
	.EXT_UDS_N(GEN_UDS_N),
	.EXT_DTACK_N(MCD_DTACK_N),
	.EXT_ASEL_N(GEN_ASEL_N),
	.EXT_VCLK_CE(GEN_VCLK_CE),
	.EXT_RAS2_N(GEN_RAS2_N),
	.EXT_ROM_N(EXT_ROM_N),
	.EXT_FDC_N(EXT_FDC_N),

	.PRG_A(MCD_PRG_ADDR),
	.PRG_DI(MCD_PRG_DI),
	.PRG_DO(MCD_PRG_DO),
	.PRG_WRL_N(MCD_PRG_WRL_N),
	.PRG_WRH_N(MCD_PRG_WRH_N),
	.PRG_OE_N(MCD_PRG_OE_N),
	.PRG_RDY(~MCD_PRG_BUSY),
	
	.ROM_DI(GEN_MEM_DO),
	.ROM_CE_N(GEN_ROM_CE_N),
	.ROM_RDY(~GEN_MEM_BUSY),
	
	.BRAM_A(MCD_BRAM_ADDR),
	.BRAM_DI(MCD_BRAM_DI),
	.BRAM_DO(MCD_BRAM_DO),
	.BRAM_WE(MCD_BRAM_WE),
	
	.CDD_STAT(scd_cdd_stat),
	.CDD_COMM(scd_cdd_comm),
	.CDD_SEND(scd_cdd_send),
	.CDD_RESEND(scd_cdd_resend),
	.CDD_REC(scd_cdd_rec),
	.CDD_DM(scd_cdd_dm),
	
	.CDC_DATA(cdc_d),
	.CDC_DAT_WR(cdc_wr & (cdc_dat_download | cdc_cdda_download)),
	.CDC_SC_WR(cdc_wr & cdc_sub_download),
	.CDC_CDDA_WR(cdc_wr & cdc_cdda_download),
	.CDDA_WR_READY(MCD_CDDA_WR_READY),

	.PCM_SL(MCD_PCM_SL),
	.PCM_SR(MCD_PCM_SR),
	.CDDA_SL(MCD_CDDA_SL),
	.CDDA_SR(MCD_CDDA_SR),
	
	.LED_RED(MCD_LED_RED),
	.LED_GREEN(MCD_LED_GREEN),

	.GG_RESET(code_download && ioctl_wr && !ioctl_addr),
	.GG_EN(status[24]),
	.GG_CODE({gg_code[95] & gg_code[128], gg_code[127:0]}),
	.GG_AVAILABLE(gg_available2),

	// Let an open host transfer drain before parking the sub-CPU.
	.SS_FREEZE((ss_freeze_req & ss_sub_park_ok) | ss_hold_any),
	.SS_QUIESCE(ss_freeze_req),
	.SS_S68K_FROZEN(ss_s68k_frozen),
	.SS_S68K_ADDR(ss_s68k_addr),
	.SS_S68K_WR_DATA(ss_s68k_wr_data),
	.SS_S68K_WR_EN(ss_s68k_wr_en),
	.SS_S68K_RD_DATA(ss_s68k_rd_data),

	.SS_ACTIVE(ss_freeze_active),
	.SS_MEM_SEL(ss_mcd_mem_sel),
	.SS_MEM_ADDR(ss_mcd_mem_addr),
	.SS_MEM_WR_DATA(ss_mem_wr_data),
	.SS_MEM_WR_EN(ss_mcd_mem_wr_en),
	.SS_MEM_RD_DATA(ss_mcd_mem_rd_data),

	.SS_ASIC_ADDR(ss_asic_addr),
	.SS_ASIC_WR_DATA(ss_state_dout),
	.SS_ASIC_WR_EN(ss_asic_wr_en),
	.SS_ASIC_RD_DATA(ss_asic_rd_data),
	.SS_QUIET(ss_mcd_quiet),
	.SS_QUIET_BITS(ss_quiet_bits),
	.SS_CDC_DBG(ss_cdc_dbg),
	.SS_CDC_HEAD(ss_cdc_head),

	.SS_DEV_SEL(ss_dev_sel),
	.SS_DEV_ADDR(ss_dev_addr),
	.SS_DEV_WR_DATA(ss_state_dout),
	.SS_DEV_WR_EN(ss_dev_wr_en),
	.SS_DEV_RD_DATA(ss_dev_rd_data)
);

wire  [1:0] ss_dev_sel;
wire  [5:0] ss_dev_addr;
wire        ss_dev_wr_en;
wire [31:0] ss_dev_rd_data;

wire  [7:0] ss_asic_addr;
wire        ss_asic_wr_en;
wire [31:0] ss_asic_rd_data;
wire        ss_mcd_quiet;
wire [13:0] ss_quiet_bits;
wire [15:0] ss_cdc_dbg;
wire [23:0] ss_cdc_head;

// MegaCD-side memory stream: Word RAM, PCM wave RAM, CDC buffer.
wire  [1:0] ss_mcd_mem_sel;
wire [16:0] ss_mcd_mem_addr;
wire        ss_mcd_mem_wr_en;
wire [15:0] ss_mcd_mem_rd_data;
wire [15:0] ss_mem_wr_data;

localparam [3:0] comp_f1 = 4;
localparam [3:0] comp_a1 = 2;
localparam       comp_x1 = ((32767 * (comp_f1 - 1)) / ((comp_f1 * comp_a1) - 1)) + 1; // +1 to make sure it won't overflow
localparam       comp_b1 = comp_x1 * comp_a1;

localparam [3:0] comp_f2 = 8;
localparam [3:0] comp_a2 = 4;
localparam       comp_x2 = ((32767 * (comp_f2 - 1)) / ((comp_f2 * comp_a2) - 1)) + 1; // +1 to make sure it won't overflow
localparam       comp_b2 = comp_x2 * comp_a2;

function [15:0] compr; input [15:0] inp;
	reg [15:0] v, v1, v2;
	begin
		v  = inp[15] ? (~inp) + 1'd1 : inp;
		v1 = (v < comp_x1[15:0]) ? (v * comp_a1) : (((v - comp_x1[15:0])/comp_f1) + comp_b1[15:0]);
		v2 = (v < comp_x2[15:0]) ? (v * comp_a2) : (((v - comp_x2[15:0])/comp_f2) + comp_b2[15:0]);
		v  = status[58] ? v2 : v1;
		compr = inp[15] ? ~(v-1'd1) : v;
	end
endfunction

reg [15:0] aud_l, aud_r;
reg [15:0] cmp_l, cmp_r;
reg [15:0] mcd_l, mcd_r;
always @(posedge clk_sys) begin
	mcd_l <= ({16{EN_MCD_PCM}} & {MCD_PCM_SL[15],MCD_PCM_SL[15:1]}) + ({16{EN_MCD_CDDA}} & {MCD_CDDA_SL[15],MCD_CDDA_SL[15:1]});
	mcd_r <= ({16{EN_MCD_PCM}} & {MCD_PCM_SR[15],MCD_PCM_SR[15:1]}) + ({16{EN_MCD_CDDA}} & {MCD_CDDA_SR[15],MCD_CDDA_SR[15:1]});

	if(~status[27]) begin
		aud_l <= {GEN_AUDL[15],GEN_AUDL[15:1]} + {mcd_l[15],mcd_l[15:1]};
		aud_r <= {GEN_AUDR[15],GEN_AUDR[15:1]} + {mcd_r[15],mcd_r[15:1]};
	end
	else begin
		aud_l <= GEN_AUDL;
		aud_r <= GEN_AUDR;
	end
	
	cmp_l <= compr(aud_l);
	cmp_r <= compr(aud_r);
end

audio_fix #(250) audio_fix // MCLK/504 in lpf, so choose half to get in the middle of sample period
(
	.*,
	.clk(clk_sys),
	.ce(GEN_CE),
	.l(status[58:57] ? cmp_l : aud_l),
	.r(status[58:57] ? cmp_r : aud_r)
);

//ROM/RAM Cart
wire [15:0] CART_DO;
wire        CART_DTACK_N;
wire        CART_CART_N;

wire        CART_ROM_CE_N;
wire        CART_RAM_CE_N;

wire [15:0] CART_ROM_DO;
wire        CART_ROM_BUSY;

wire        CART_EN = status[3];

CART CART
(
	.RST_N(~reset),
	.CLK(clk_sys),
	.ENABLE(1),
	
	.ROM_MODE(rom_cart_mode),
	.RAM_ID(CART_EN ? 8'd6 : 8'd255),	//backup ram size = (1<<n)*8192, n=0..6, when n=255 ram is not present

	.VA(GEN_VA),
	.VDI(GEN_VDO),
	.VDO(CART_DO),
	.AS_N(GEN_AS_N),
	.RNW(GEN_RNW),
	.LDS_N(GEN_LDS_N),
	.UDS_N(GEN_UDS_N),
	.DTACK_N(CART_DTACK_N),
	.ASEL_N(GEN_ASEL_N),
	.VCLK_CE(GEN_VCLK_CE),
	.CE0_N(GEN_CE0_N),
	.CART_N(CART_CART_N),
	
	.ROM_CE_N(CART_ROM_CE_N),
	.ROM_DI(PIER_HOOK ? PIER_DATA : GEN_MEM_DO),
	.ROM_RDY(~GEN_MEM_BUSY),
	
	.RAM_CE_N(CART_RAM_CE_N),
	.RAM_DI(GEN_MEM_DO),
	.RAM_RDY(~GEN_MEM_BUSY),

	.SS_WP_RD(ss_cart_wp),
	.SS_WP_WR_DATA(ss_cart_wp_wd),
	.SS_WP_WR_EN(ss_cart_wp_we)
);
wire [7:0] ss_cart_wp;
wire [7:0] ss_cart_wp_wd;
wire       ss_cart_wp_we;
// Declared early because the mapper block above uses it. SS_OFF_CART_REGS is
// declared in the savestate section.
wire       ss_sel_cart;

always @(posedge clk_sys) begin
	reg old_busy;
	
	old_busy <= tmpram_busy;
	if(rom_download & ioctl_wr) ioctl_wait <= 1;
	if(old_busy & ~tmpram_busy) ioctl_wait <= 0;
end

wire use_sdr = 1;

assign MCD_PRG_BUSY = use_sdr ? sdr_busy : ddr_busy;
assign MCD_PRG_DI   = use_sdr ? sdr_do   : ddr_do;

// PRG-RAM always uses SDRAM because use_sdr is constant 1, so the DDR path is
// tied off. The savestate engine is the only DDR3 master. Restoring the DDR
// PRG-RAM path needs an arbiter.
wire        ddr_busy = 1'b0;
wire [15:0] ddr_do   = 16'd0;
assign DDRAM_CLK = clk_sys;


//MCD PRGRAM, GEN ROM/RAM/CART RAM
wire sdr_busy;
wire [15:0] sdr_do;
sdram sdram
(
	.*,
	.init(~locked),
	.clk(clk_ram),

	//MCD: banks 2,3. While a savestate streams, port 0 carries the PRG-RAM region
	//because the sub-CPU is parked.
	.addr0({(MCD_BANK23 ? 6'b100000 : 6'b011111), (ss_freeze_active ? ss_prg_addr : MCD_PRG_ADDR)}), // 1000000-107FFFF / 0F80000-0FFFFFF
	.din0(ss_freeze_active ? ss_mem_wr_data : MCD_PRG_DO),
	.dout0(sdr_do),
	// Qualified by ss_sel_prg_ram so a work RAM write does not also hit port 0.
	.rd0(ss_freeze_active ? (ss_sdr_rd & ss_sel_prg_ram) : (use_sdr & ~MCD_PRG_OE_N)),
	.wrl0(ss_freeze_active ? (ss_sdr_wr & ss_sel_prg_ram) : (use_sdr & ~MCD_PRG_WRL_N)),
	.wrh0(ss_freeze_active ? (ss_sdr_wr & ss_sel_prg_ram) : (use_sdr & ~MCD_PRG_WRH_N)),
	.busy0(sdr_busy),

	//Genesis: banks 0,1. During a savestate this port carries the work RAM region
	//because the main 68000 and the Z80 are parked.
	.addr1(ss_freeze_active ? {9'b010000000,ss_work_addr}     : //Work RAM for the stream
			 !GEN_RAM_CE_N  ? {9'b010000000,GEN_VA[15:1]} : //WORK RAM 800000-80FFFF
			 !CART_RAM_CE_N ? {5'b01110,GEN_VA[19:1]}     : //CART RAM E00000-EFFFFF
			 !CART_ROM_CE_N ? {2'b00,ROM_VA[22:1]}        : //CART ROM 000000-7FFFFF
			                  {8'b01111000,GEN_VA[16:1]} ),	//BIOS ROM F00000-F1FFFF
	.din1(ss_freeze_active ? ss_mem_wr_data : GEN_VDO),
	.dout1(GEN_MEM_DO),
	.rd1(ss_freeze_active ? (ss_sdr_rd & ss_sel_work_ram) : ((~GEN_RAM_CE_N | ~GEN_ROM_CE_N | ~CART_RAM_CE_N | ~CART_ROM_CE_N) & ~GEN_OE_N)),
	.wrl1(ss_freeze_active ? (ss_sdr_wr & ss_sel_work_ram) : ((~GEN_RAM_CE_N | ~CART_RAM_CE_N) & ~GEN_WRL_N)),
	.wrh1(ss_freeze_active ? (ss_sdr_wr & ss_sel_work_ram) : ((~GEN_RAM_CE_N | ~CART_RAM_CE_N) & ~GEN_WRH_N)),
	.busy1(GEN_MEM_BUSY),

	//Load/Save: banks 0,1
	.addr2( rom_download ? (rom_cart_mode ? {2'b00,ioctl_addr[22:1]} : {6'b011110,ioctl_addr[18:1]}) : //ROM  000000-7FFFFF/F00000-F7FFFF
								  {5'b01110,tmpram_lba[9:0],tmpram_addr}),    //CART RAM E00000-EFFFFF for sd_*
	.din2(rom_download ? {ioctl_data[7:0],ioctl_data[15:8]} : {tmpram_dout,tmpram_dout}),
	.dout2(tmpram_din),
	.rd2(~rom_download & tmpram_req & ~bk_loading),
	.wrl2(rom_download ? ioctl_wait : (tmpram_req & bk_loading)),
	.wrh2(rom_download ? ioctl_wait : (tmpram_req & bk_loading)),
	.busy2(tmpram_busy)
);


wire [15:0] bram_sd_buff_data;
dpram_dif #(13,8,12,16) bram
(
	.clock(clk_sys),
	.address_a(ss_freeze_active ? ss_bram_addr : (PIER_QUIRK ? m95_addr : MCD_BRAM_ADDR)),
	.data_a(ss_freeze_active ? ss_mem_wr_data[7:0] : (PIER_QUIRK ? m95_di : MCD_BRAM_DO)),
	.wren_a(ss_freeze_active ? ss_bram_we : (PIER_QUIRK ? m95_we : MCD_BRAM_WE)),
	.q_a(MCD_BRAM_DI),

	.address_b({sd_lba[0][3:0],sd_buff_addr}),
	.data_b(sd_buff_dout),
	.wren_b(sd_buff_wr & sd_ack & !sd_lba[0][10:4]),
	.q_b(bram_sd_buff_data)
);

wire [7:0] tmpram_dout;
wire [7:0] tmpram_din;
wire       tmpram_busy;

wire [15:0] tmpram_sd_buff_data;
dpram_dif #(9,8,8,16) tmpram
(
	.clock(clk_sys),

	.address_a(tmpram_addr),
	.wren_a(~bk_loading & tmpram_busy_d & ~tmpram_busy),
	.data_a(tmpram_din),
	.q_a(tmpram_dout),

	.address_b(sd_buff_addr),
	.wren_b(sd_buff_wr & sd_ack & |sd_lba[0][10:4]),
	.data_b(sd_buff_dout),
	.q_b(tmpram_sd_buff_data)
);

reg [10:0] tmpram_lba;
reg  [8:0] tmpram_addr;
reg tmpram_tx_start;
reg tmpram_tx_finish;
reg tmpram_req;
reg tmpram_busy_d;
always @(posedge clk_sys) begin
	reg state;

	tmpram_lba <= sd_lba[0][10:0]-11'h10;
	
	tmpram_busy_d <= tmpram_busy;
	if(~tmpram_busy_d & tmpram_busy) tmpram_req <= 0;

	if(~tmpram_tx_start) {tmpram_addr, state, tmpram_tx_finish} <= 0;
	else if(~tmpram_tx_finish) begin
		if(!state) begin
			tmpram_req <= 1;
			state <= 1;
		end
		else if(tmpram_busy_d & ~tmpram_busy) begin
			state <= 0;
			if(~&tmpram_addr) tmpram_addr <= tmpram_addr + 1'd1;
			else tmpram_tx_finish <= 1;
		end
	end
end


//CD communication
reg [48:0] cd_in;
wire [48:0] cd_out;

reg [39:0] scd_cdd_stat;
reg scd_cdd_dm;
wire [39:0] scd_cdd_comm;
wire scd_cdd_send;
wire scd_cdd_resend;
reg scd_cdd_rec;

always @(posedge clk_sys) begin
	reg cd_out48_last = 1;
	reg scd_cdd_send_old = 0;
	reg [2:0] cnt = 0;
	reg rst_old = 0;
	
	if (cd_out[48] != cd_out48_last)  begin
		cd_out48_last <= cd_out[48];
		scd_cdd_stat <= cd_out[39:0];
		scd_cdd_dm <= cd_out[40];
		scd_cdd_rec <= 1;
		cnt <= 7;
	end
	else if (ss_freeze_active) begin
		// Hold the CDD receive pulse across the freeze. The MCD is frozen, so a
		// status packet arriving now would be missed and the BIOS CDD driver would
		// wait for it. Held high, the ASIC sees the latest status after release.
	end
	else if (cnt) begin
		cnt <= cnt - 1'd1;
	end
	else begin
		scd_cdd_rec <= 0;
	end
	
	scd_cdd_send_old <= scd_cdd_send;
	if (scd_cdd_send && !scd_cdd_send_old) begin
		// Bit 40 marks a command the gate array resends every frame, not a new write.
		cd_in[47:0] <= {7'h00,scd_cdd_resend,scd_cdd_comm};
		cd_in[48] <= ~cd_in[48];
	end
	else begin
		rst_old <= MCD_RST_N;
		if (rst_old & ~MCD_RST_N) begin
			cd_in[47:0] <= 8'hFF;
			cd_in[48] <= ~cd_in[48];
		end
	end
end




//extend cdc_wr for 8 cycles
reg  cdc_wr;
reg [15:0] cdc_d;
always @(posedge clk_sys) begin
	reg [2:0] cnt = 0;

	if (ioctl_wr) begin
		cnt <= 7;
		cdc_wr <= 1;
		cdc_d <= ioctl_data;
	end
	else if (cnt) begin
		cnt <= cnt - 1'd1;
	end
	else begin
		cdc_wr <= 0;
	end
end


/////////////////////////////////////////////////////////////
wire PAL = region[1];

reg new_vmode;
always @(posedge clk_sys) begin
	reg old_pal;
	int to;
	
	if(~(reset | rom_download)) begin
		old_pal <= PAL;
		if(old_pal != PAL) to <= 5000000;
	end
	else to <= 5000000;
	
	if(to) begin
		to <= to - 1;
		if(to == 1) new_vmode <= ~new_vmode;
	end
end

//lock resolution for the whole frame.
reg [1:0] res;
always @(posedge clk_sys) begin
	reg old_vbl;
	
	old_vbl <= vblank;
	if(old_vbl & ~vblank) res <= resolution;
end

wire [2:0] scale = status[35:33];
wire [2:0] sl = scale ? scale - 1'd1 : 3'd0;

assign CLK_VIDEO = clk_ram;
assign VGA_SL = {~interlace,~interlace}&sl[1:0];

reg old_ce_pix;
always @(posedge CLK_VIDEO) old_ce_pix <= ce_pix;

wire [7:0] red, green, blue;

cofi coffee (
	.clk(clk_sys),
	.pix_ce(ce_pix),
	.enable(cofi_enable),

	.hblank(hblank),
	.vblank(vblank),
	.hs(hs),
	.vs(vs),
	.red(color_lut[r]),
	.green(color_lut[g]),
	.blue(color_lut[b]),

	.hblank_out(hblank_c),
	.vblank_out(vblank_c),
	.hs_out(hs_c),
	.vs_out(vs_c),
	.red_out(red),
	.green_out(green),
	.blue_out(blue)
);

wire hs_c,vs_c,hblank_c,vblank_c;

video_mixer #(.LINE_LENGTH(320), .HALF_DEPTH(0), .GAMMA(1)) video_mixer
(
	.*,

	.ce_pix(~old_ce_pix & ce_pix),

	.scandoubler(~interlace && (scale || forced_scandoubler)),
	.hq2x(scale==1),
	.freeze_sync(),

	.VGA_DE(vga_de),
	.R((lg_target && gun_mode && (~&status[44:43])) ? {8{lg_target[0]}} : red),
	.G((lg_target && gun_mode && (~&status[44:43])) ? {8{lg_target[1]}} : green),
	.B((lg_target && gun_mode && (~&status[44:43])) ? {8{lg_target[2]}} : blue),

	// Positive pulses.
	.HSync(hs_c),
	.VSync(vs_c),
	.HBlank(hblank_c),
	.VBlank(vblank_c)
);

wire [2:0] lg_target;
wire       lg_sensor;
wire       lg_a;
wire       lg_b;
wire       lg_c;
wire       lg_start;

lightgun lightgun
(
	.CLK(clk_sys),
	.RESET(reset),

	.MOUSE(ps2_mouse),
	.MOUSE_XY(&gun_mode),

	.JOY_X(gun_mode[0] ? joy0_x : joy1_x),
	.JOY_Y(gun_mode[0] ? joy0_y : joy1_y),
	.JOY(gun_mode[0] ? joystick_0[11:0] : joystick_1[11:0]),

	.RELOAD(gun_type),

	.HDE(~hblank_c),
	.VDE(~vblank_c),
	.CE_PIX(ce_pix),
	.H40(res[0]),

	.BTN_MODE(gun_btn_mode),
	.SIZE(status[44:43]),
	.SENSOR_DELAY(gun_type ? 8'd32 : 8'd64),

	.TARGET(lg_target),
	.SENSOR(lg_sensor),
	.BTN_A(lg_a),
	.BTN_B(lg_b),
	.BTN_C(lg_c),
	.BTN_START(lg_start)
);

reg  [1:0] region_req;
reg        region_reset;
// F1 to F3 no longer select the region because savestate_ui uses F1 to F4.
// The region is set in the OSD or taken from the ROM header.
always @(posedge clk_sys) begin
	if(reset) region_reset <= 0;

	if(ioctl_wr & rom_download) begin
		if(ioctl_addr == 'h1F0) begin
			if(ioctl_data[7:0] == "J") region_req <= 0;
			else if(ioctl_data[7:0] == "U") region_req <= 1;
			else region_req <= 2;
		end
	end
end

wire [1:0] region_new = status[7:6] ? (status[7:6] - 1'd1) : region_req;

reg  [1:0] region;
reg        region_set = 0;
always @(posedge clk_sys) begin
	reg [15:0] to = 0;
	
	region <= region_new;
	if(region != region_new) to <= 0;
	
	region_set <= 0;
	if(~&to) begin
		to <= to + 1'd1;
		region_set <= 1;
	end
end


/////////////////////////  BRAM SAVE/LOAD  /////////////////////////////

wire downloading = save_download;
wire bk_change  = MCD_BRAM_WE | m95_we | (CART_EN & ~CART_RAM_CE_N & (~GEN_WRL_N | ~GEN_WRH_N));
wire autosave   = status[13];
wire bk_load    = status[16];
wire bk_save    = status[17];

reg bk_ena = 0;
reg sav_pending = 0;
always @(posedge clk_sys) begin
	reg old_downloading = 0;
	reg old_change = 0;

	old_downloading <= downloading;
	if(~old_downloading & downloading) bk_ena <= 0;

	//Save file always mounted in the end of downloading state.
	if(downloading && img_mounted && !img_readonly) bk_ena <= 1;

	old_change <= bk_change;
	if (~old_change & bk_change) sav_pending <= 1;
	else if (bk_state) sav_pending <= 0;
end

wire bk_save_a  = autosave & OSD_STATUS;
reg  bk_loading = 0;
reg  bk_state   = 0;
reg  bk_reload  = 0;

always @(posedge clk_sys) begin
	reg old_downloading = 0;
	reg old_load = 0, old_save = 0, old_save_a = 0, old_ack;
	reg [1:0] state;

	old_downloading <= downloading;

	old_load   <= bk_load;
	old_save   <= bk_save;
	old_save_a <= bk_save_a;
	old_ack    <= sd_ack;

	if(~old_ack & sd_ack) {sd_rd, sd_wr} <= 0;

	if(!bk_state) begin
		tmpram_tx_start <= 0;
		state <= 0;
		sd_lba[0] <= 0;
		bk_reload <= 0;
		bk_loading <= 0;
		if(bk_ena & ((~old_load & bk_load) | (~old_save & bk_save) | (~old_save_a & bk_save_a & sav_pending))) begin
			bk_state <= 1;
			bk_loading <= bk_load;
			bk_reload <= bk_load;
			sd_rd <=  bk_load;
			sd_wr <= ~bk_load;
		end
		if(old_downloading & ~rom_download & bk_ena) begin
			bk_state <= 1;
			bk_loading <= 1;
			sd_rd <= 1;
			sd_wr <= 0;
		end
	end
	else if(!sd_lba[0][10:4]) begin
		if(old_ack & ~sd_ack) begin
			sd_lba[0] <= sd_lba[0] + 1'd1;
			if(&sd_lba[0][3:0]) begin
				if(~CART_EN) bk_state <= 0;
			end else begin
				sd_rd <=  bk_loading;
				sd_wr <= ~bk_loading;
			end
		end
	end
	else if(bk_loading) begin
		case(state)
			0: begin
					sd_rd <= 1;
					state <= 1;
				end
			1: if(old_ack & ~sd_ack) begin
					tmpram_tx_start <= 1;
					state <= 2;
				end
			2: if(tmpram_tx_finish) begin
					tmpram_tx_start <= 0;
					state <= 0;
					sd_lba[0] <= sd_lba[0] + 1'd1;
					if(sd_lba[0][10:0] == 11'h40F) bk_state <= 0;
				end
		endcase
	end
	else begin
		case(state)
			0: begin
					tmpram_tx_start <= 1;
					state <= 1;
				end
			1: if(tmpram_tx_finish) begin
					tmpram_tx_start <= 0;
					sd_wr <= 1;
					state <= 2;
				end
			2: if(old_ack & ~sd_ack) begin
					state <= 0;
					sd_lba[0] <= sd_lba[0] + 1'd1;
					if(sd_lba[0][10:0] == 11'h40F) bk_state <= 0;
				end
		endcase
	end
end

wire [7:0] SERJOYSTICK_IN;
wire [7:0] SERJOYSTICK_OUT;
wire [1:0] SER_OPT;

always @(posedge clk_sys) begin
	if (status[46]) begin
		SERJOYSTICK_IN[0] <= USER_IN[1];//up
		SERJOYSTICK_IN[1] <= USER_IN[0];//down	
		SERJOYSTICK_IN[2] <= USER_IN[5];//left	
		SERJOYSTICK_IN[3] <= USER_IN[3];//right
		SERJOYSTICK_IN[4] <= USER_IN[2];//b TL		
		SERJOYSTICK_IN[5] <= USER_IN[6];//c TR GPIO7			
		SERJOYSTICK_IN[6] <= USER_IN[4];//  TH
		SERJOYSTICK_IN[7] <= 0;
		SER_OPT[0] <= ~status[4];
		SER_OPT[1] <= status[4];
		USER_OUT[1] <= SERJOYSTICK_OUT[0];
		USER_OUT[0] <= SERJOYSTICK_OUT[1];
		USER_OUT[5] <= SERJOYSTICK_OUT[2];
		USER_OUT[3] <= SERJOYSTICK_OUT[3];
		USER_OUT[2] <= SERJOYSTICK_OUT[4];
		USER_OUT[6] <= SERJOYSTICK_OUT[5];
		USER_OUT[4] <= SERJOYSTICK_OUT[6];
	end else begin
		SER_OPT  <= 0;
		USER_OUT <= '1;
	end
end


///////////////////////////////////////////////

reg         ep_si, m95_so, ep_sck, ep_hold, ep_cs;
wire  [7:0] m95_di, m95_q;
wire [11:0] m95_addr;
wire        m95_we;

STM95XXX pier_eeprom
(
	.clk(clk_sys),
	.enable(PIER_QUIRK),
	.so(m95_so),
	.si(ep_si),
	.sck(ep_sck),
	.hold_n(ep_hold),
	.cs_n(ep_cs),
	.wp_n(1'b1),
	.ram_addr(m95_addr),
	.ram_q(MCD_BRAM_DI),
	.ram_di(m95_di),
	.ram_we(m95_we)
);

reg  [15:0] GEN_PAGE_DI;
reg   [4:0] BANK_REG[8];
wire [23:1] ROM_VA = {BANK_REG[GEN_VA[21:19]], GEN_VA[18:1]} & {rom_mask,12'hFFF};

// MAPPERS
always @(posedge clk_sys) begin
	reg old_ce;

	old_ce <= GEN_PAGE_CE_N;

	if (reset | rom_download) begin
		BANK_REG <= '{0,1,2,3,4,5,6,7};
	end
	// Savestate restore. It is in this block because BANK_REG and the Pier SPI
	// pins are driven here, and a second driver would not compile.
	else if (ss_state_we & ss_sel_cart) begin
		if (ss_state_addr == SS_OFF_CART_REGS)
			{ep_cs, ep_hold, ep_sck, ep_si} <= ss_state_dout[15:12];
		if (ss_state_addr == SS_OFF_CART_REGS + 1) begin
			BANK_REG[0] <= ss_state_dout[ 4: 0];
			BANK_REG[1] <= ss_state_dout[ 9: 5];
			BANK_REG[2] <= ss_state_dout[14:10];
			BANK_REG[3] <= ss_state_dout[19:15];
			BANK_REG[4] <= ss_state_dout[24:20];
			BANK_REG[5] <= ss_state_dout[29:25];
		end
		if (ss_state_addr == SS_OFF_CART_REGS + 2) begin
			BANK_REG[6] <= ss_state_dout[4:0];
			BANK_REG[7] <= ss_state_dout[9:5];
		end
	end
	else if(old_ce && ~GEN_PAGE_CE_N) begin
		GEN_PAGE_DI <= '1;
		if(PIER_QUIRK) begin
			if (GEN_RNW) begin
				if (GEN_VA[3:1] == 'h5) begin
					GEN_PAGE_DI[0] <= m95_so;
				end
			end
			else if (GEN_VA[3:1]) begin
				if (GEN_VA[3:1] == 4) begin // Pier EEPROM
					{ep_cs, ep_hold, ep_sck, ep_si} <= GEN_VDO[3:0];
				end
				else if (~GEN_VA[3]) begin // Pier Banks
					BANK_REG[{1'b1, GEN_VA[2:1]}] <= GEN_VDO[3:0];
				end
			end
		end
		else if (rom_mask[23:22]) begin // >4MB
			if (~GEN_RNW && GEN_VA[3:1]) begin
				BANK_REG[GEN_VA[3:1]] <= GEN_VDO[4:0];
			end
		end
	end
end

reg [15:0] PIER_DATA;
reg        PIER_HOOK;

always @(posedge clk_sys) begin
	reg       old_sel;
	reg [3:0] pier_count;

	old_sel <= GEN_ASEL_N;
	if (reset | rom_download) begin
		pier_count <= 0;
		PIER_HOOK <= 0;
	end
	else if(PIER_QUIRK & old_sel & ~GEN_ASEL_N) begin
		PIER_HOOK <= 0;
		if ({GEN_VA,1'b0} == 'h0015E6 || {GEN_VA,1'b0} == 'h0015E8) begin
			if (pier_count < 'h6) begin
				pier_count <= pier_count + 1'h1;
				PIER_DATA <= GEN_VA[1] ? 16'h0000 : 16'h0010;
			end
			else begin
				PIER_DATA <= GEN_VA[1] ? 16'h0001 : 16'h8010;
			end
			PIER_HOOK <= 1;
		end
	end
end

reg PIER_QUIRK = 0;
always @(posedge clk_sys) begin
	reg [63:0] cart_id;
	reg old_download;

	old_download <= rom_download;
	if(~old_download && rom_download) {PIER_QUIRK} <= 0;

	if(ioctl_wr & rom_download & ioctl_index[6]) begin
		if(ioctl_addr == 'h182) cart_id[63:56] <= ioctl_data[15:8];
		if(ioctl_addr == 'h184) cart_id[55:40] <= {ioctl_data[7:0],ioctl_data[15:8]};
		if(ioctl_addr == 'h186) cart_id[39:24] <= {ioctl_data[7:0],ioctl_data[15:8]};
		if(ioctl_addr == 'h188) cart_id[23:08] <= {ioctl_data[7:0],ioctl_data[15:8]};
		if(ioctl_addr == 'h18A) cart_id[07:00] <= ioctl_data[7:0];
		if(ioctl_addr == 'h18C) begin
			     if(cart_id == "T-574023") PIER_QUIRK <= 1; // Pier Solar Reprint
			else if(cart_id == "T-574013") PIER_QUIRK <= 1; // Pier Solar 1st Edition
		end
	end
end

reg [23:13] rom_mask;
reg         rom_cart_mode;
always @(posedge clk_sys) begin
	if (rom_download & ioctl_wr) begin
		rom_cart_mode <= ioctl_index[6];
		if (ioctl_index[6]) begin
			rom_mask <= rom_mask | ioctl_addr[23:13];
			if(!ioctl_addr) rom_mask <= 0;
		end
	end
end

//////////////////////////////  Savestates  ////////////////////////////////////
// Changing a region offset or size requires an SS_VERSION bump.

localparam [31:0] SS_MAGIC   = 32'h4D435353;  // "MCSS"
localparam [31:0] SS_VERSION = 32'h00000001;

// Region sizes are in 32-bit words: one native byte or 16-bit value per word.
// Register-region spare words preserve existing native image offsets.
localparam [31:0] SS_HEADER_SIZE    = 32'd2;
localparam [31:0] SS_PRG_RAM_SIZE   = 32'd262144; // 512KB as 256K x 16-bit (SDRAM)
localparam [31:0] SS_WORD_RAM_SIZE  = 32'd131072; // 256KB as 128K x 16-bit (WORDRAM0+1)
localparam [31:0] SS_PCM_RAM_SIZE   = 32'd65536;  // 64KB wave RAM, 1 byte/word
localparam [31:0] SS_CDC_RAM_SIZE   = 32'd16384;  // 16KB CDC buffer, 1 byte/word
localparam [31:0] SS_BRAM_SIZE      = 32'd8192;   // 8KB internal backup RAM, 1 byte/word
localparam [31:0] SS_WORK_RAM_SIZE  = 32'd32768;  // 64KB work RAM as 32K x 16-bit (SDRAM)
localparam [31:0] SS_VRAM_SIZE      = 32'd32768;  // 64KB VRAM as 32K x 16-bit
localparam [31:0] SS_ZRAM_SIZE      = 32'd8192;   // 8KB Z80 RAM, 1 byte/word
localparam [31:0] SS_OBJ_CACHE_SIZE = 32'd128;    // VDP sprite cache, 128x32
localparam [31:0] SS_CRAM_SIZE      = 32'd64;     // 64 x 9-bit
localparam [31:0] SS_VSRAM_SIZE     = 32'd64;     // 2 x 32 x 11-bit (full physical)
localparam [31:0] SS_M68K_REGS_SIZE = 32'd128;    // fx68k main
localparam [31:0] SS_S68K_REGS_SIZE = 32'd128;    // fx68k sub
localparam [31:0] SS_Z80_REGS_SIZE  = 32'd32;
localparam [31:0] SS_VDP_REGS_SIZE  = 32'd64;
localparam [31:0] SS_FM_SHADOW_SIZE = 32'd512;    // YM2612 shadow, 1 register per word
localparam [31:0] SS_PSG_REGS_SIZE  = 32'd16;
localparam [31:0] SS_ASIC_REGS_SIZE = 32'd128;
localparam [31:0] SS_CDC_REGS_SIZE  = 32'd16;
localparam [31:0] SS_PCM_REGS_SIZE  = 32'd32;
localparam [31:0] SS_CDDA_REGS_SIZE = 32'd16;
localparam [31:0] SS_CART_REGS_SIZE = 32'd4;      // cart mapper banks + WP + Pier SPI
localparam [31:0] SS_CD_RESYNC_SIZE = 32'd8;      // drive state replayed to the HPS
localparam [31:0] SS_MISC_SIZE      = 32'd32;

localparam [31:0] SS_OFF_PRG_RAM   = SS_HEADER_SIZE;
localparam [31:0] SS_OFF_WORD_RAM  = SS_OFF_PRG_RAM   + SS_PRG_RAM_SIZE;
localparam [31:0] SS_OFF_PCM_RAM   = SS_OFF_WORD_RAM  + SS_WORD_RAM_SIZE;
localparam [31:0] SS_OFF_CDC_RAM   = SS_OFF_PCM_RAM   + SS_PCM_RAM_SIZE;
localparam [31:0] SS_OFF_BRAM      = SS_OFF_CDC_RAM   + SS_CDC_RAM_SIZE;
localparam [31:0] SS_OFF_WORK_RAM  = SS_OFF_BRAM      + SS_BRAM_SIZE;
localparam [31:0] SS_OFF_VRAM      = SS_OFF_WORK_RAM  + SS_WORK_RAM_SIZE;
localparam [31:0] SS_OFF_ZRAM      = SS_OFF_VRAM      + SS_VRAM_SIZE;
localparam [31:0] SS_OFF_OBJ_CACHE = SS_OFF_ZRAM      + SS_ZRAM_SIZE;
localparam [31:0] SS_OFF_CRAM      = SS_OFF_OBJ_CACHE + SS_OBJ_CACHE_SIZE;
localparam [31:0] SS_OFF_VSRAM     = SS_OFF_CRAM      + SS_CRAM_SIZE;
localparam [31:0] SS_OFF_M68K_REGS = SS_OFF_VSRAM     + SS_VSRAM_SIZE;
localparam [31:0] SS_OFF_S68K_REGS = SS_OFF_M68K_REGS + SS_M68K_REGS_SIZE;
localparam [31:0] SS_OFF_Z80_REGS  = SS_OFF_S68K_REGS + SS_S68K_REGS_SIZE;
localparam [31:0] SS_OFF_VDP_REGS  = SS_OFF_Z80_REGS  + SS_Z80_REGS_SIZE;
localparam [31:0] SS_OFF_FM_SHADOW = SS_OFF_VDP_REGS  + SS_VDP_REGS_SIZE;
localparam [31:0] SS_OFF_PSG_REGS  = SS_OFF_FM_SHADOW + SS_FM_SHADOW_SIZE;
localparam [31:0] SS_OFF_ASIC_REGS = SS_OFF_PSG_REGS  + SS_PSG_REGS_SIZE;
localparam [31:0] SS_OFF_CDC_REGS  = SS_OFF_ASIC_REGS + SS_ASIC_REGS_SIZE;
localparam [31:0] SS_OFF_PCM_REGS  = SS_OFF_CDC_REGS  + SS_CDC_REGS_SIZE;
localparam [31:0] SS_OFF_CDDA_REGS = SS_OFF_PCM_REGS  + SS_PCM_REGS_SIZE;
localparam [31:0] SS_OFF_CART_REGS = SS_OFF_CDDA_REGS + SS_CDDA_REGS_SIZE;
localparam [31:0] SS_OFF_CD_RESYNC = SS_OFF_CART_REGS + SS_CART_REGS_SIZE;
localparam [31:0] SS_OFF_MISC      = SS_OFF_CD_RESYNC + SS_CD_RESYNC_SIZE;

localparam [31:0] SS_FULL_SIZE     = SS_OFF_MISC      + SS_MISC_SIZE; // 558430
// The file on SD is an 8 byte preamble plus SS_FULL_SIZE*4, 2233728 bytes.

wire        ss_busy;
wire        ss_save_done, ss_load_done;
wire        ss_freeze_req;
wire [31:0] ss_state_addr;
wire        ss_state_wr, ss_state_rd, ss_state_we;
wire [31:0] ss_state_dout;

// savestate_ui. F1 to F4 load slots 1 to 4 and Alt with F1 to F4 saves.
// On a gamepad, hold the Savestate button, J1 bit 12, which is unmapped by default.
// With it held, Left and Right select the slot, Mode+Down saves and Mode+Up loads.
wire       ssui_save, ssui_load, ssui_status_upd;
wire [1:0] ssui_slot;
wire       ssui_allow = ~rom_download & ~ss_busy;

savestate_ui #(.INFO_TIMEOUT_BITS(25)) savestate_ui
(
	.clk          (clk_sys),
	.ps2_key      (ps2_key),
	.allow_ss     (ssui_allow),
	.joySS        (joystick_0[12]),
	.joyRight     (joystick_0[0]),
	.joyLeft      (joystick_0[1]),
	.joyDown      (joystick_0[2]),
	.joyUp        (joystick_0[3]),
	.joyStart     (joystick_0[8]),   // Mode, because Start pauses most games.
	.status_slot  (status[65:64]),
	.OSD_saveload ({status[67], status[66]}),  // Bit 1 loads, bit 0 saves.
	.ss_save      (ssui_save),
	.ss_load      (ssui_load),
	.ss_info_req  (ss_info_req),
	.ss_info      (ss_info),
	.statusUpdate (ssui_status_upd),
	.selected_slot(ssui_slot)
);

// savestate_ui emits 1-cycle pulses and the engine samples through a 2-FF
// synchronizer, so stretch them.
reg [7:0] ss_save_cnt = 0;
reg [7:0] ss_load_cnt = 0;
reg [1:0] ss_slot_reg = 0;
always @(posedge clk_sys) begin
	if(ssui_save) begin ss_save_cnt <= 8'd100; ss_slot_reg <= ssui_slot; end
	else if(ss_save_cnt) ss_save_cnt <= ss_save_cnt - 1'd1;

	if(ssui_load) begin ss_load_cnt <= 8'd100; ss_slot_reg <= ssui_slot; end
	else if(ss_load_cnt) ss_load_cnt <= ss_load_cnt - 1'd1;
end
wire ss_save_req = |ss_save_cnt;
wire ss_load_req = |ss_load_cnt;

// Grant capture only after VBlank, parked CPUs, and quiescent peripherals.
// VDP line buffers are re-derived rather than stored.
reg ss_vbl_parked = 0;
always @(posedge clk_sys) begin
	if(!ss_freeze_req) ss_vbl_parked <= 0;
	else if(vblank)    ss_vbl_parked <= 1;
end

// Wait for a representable CDC transfer state before parking the sub-CPU.
// A bounded wait avoids hanging on a transfer that never drains.
reg        ss_sub_park_ok = 0;
reg [22:0] ss_park_wait = 0;
// Pending DECI is captured. TS_IDLE and a staged TS_SEND_WAIT word are safe.
wire ss_cdc_park_quiet = (ss_cdc_dbg[15:13] == 3'd0) | (ss_cdc_dbg[15:13] == 3'd4);
// The sub-CPU must remain running while a host-read word is outstanding.
wire ss_sub_park_gate = ss_cdc_park_quiet & ss_quiet_bits[0];
always @(posedge clk_sys) begin
	if(!ss_freeze_req) begin
		ss_sub_park_ok <= 0;
		ss_park_wait   <= 0;
	end
	else if(!ss_sub_park_ok) begin
		if(ss_sub_park_gate || ss_park_wait[22]) ss_sub_park_ok <= 1;
		else ss_park_wait <= ss_park_wait + 1'd1;
	end
end

// A ~100 ms fallback prevents an unresponsive peripheral from hanging capture.
// MISC bit 0 records fallback use. Such an image may be incoherent.
localparam SS_FREEZE_TIMEOUT = 24'd5_400_000;
reg [23:0] ss_freeze_wait = 0;
reg        ss_backstop = 0;      // this operation used the backstop
always @(posedge clk_sys) begin
	if(!ss_freeze_req) begin
		ss_freeze_wait <= 0;
		ss_backstop    <= 0;
	end
	else if(!ss_freeze_ack_clean) begin
		if(ss_freeze_wait == SS_FREEZE_TIMEOUT) begin
			ss_backstop      <= 1;
		end
		else ss_freeze_wait <= ss_freeze_wait + 1'd1;
	end
end

// HPS sends whole sectors once ready is sampled. Wait for 16384 idle clocks,
// longer than the gaps between words but shorter than a sector period.
reg [14:0] ss_cd_ingest_cnt = 0;
always @(posedge clk_sys) begin
	if (cdc_wr) ss_cd_ingest_cnt <= 0;
	else if (!ss_cd_ingest_cnt[14]) ss_cd_ingest_cnt <= ss_cd_ingest_cnt + 1'd1;
end
wire ss_cd_ingest_quiet = ss_cd_ingest_cnt[14];

wire ss_freeze_ack_clean = ss_vbl_parked & ss_s68k_frozen & ss_m68k_frozen &
                           ss_z80_frozen & ss_mcd_quiet & ss_vdp_quiet &
                           ss_cart_quiet & ss_cd_ingest_quiet;
wire ss_freeze_ack       = ss_freeze_ack_clean | ss_backstop;
// Latch the grant so the port muxes do not switch during the stream.
reg ss_freeze_active = 0;
always @(posedge clk_sys) begin
	if (!ss_freeze_req)      ss_freeze_active <= 0;
	else if (ss_freeze_ack)  ss_freeze_active <= 1;
end

// The raster keeps running. Hold CPUs and CD delivery until the saved H/V phase,
// then restore pending interrupts and HINT countdown. A mode change that makes
// the phase unreachable is bounded by 2^22 clocks (~78 ms).
wire ss_vdp_phase_ok;
reg  ss_resume_hold = 0;
reg  ss_vdp_resume  = 0;
reg  ss_phase_ok_d  = 0;
reg [21:0] ss_resume_to = 0;
wire ss_rel_cond = (ss_vdp_phase_ok & ~ss_phase_ok_d) | (&ss_resume_to);
always @(posedge clk_sys) begin
	ss_vdp_resume <= 0;
	ss_phase_ok_d <= ss_vdp_phase_ok;
	if (ss_freeze_active & ~ss_freeze_req) begin
		ss_resume_hold <= 1;
		ss_resume_to   <= 0;
	end
	else if (ss_freeze_req) begin
		ss_resume_hold <= 0;
	end
	else if (ss_resume_hold) begin
		ss_resume_to <= ss_resume_to + 1'd1;
		if (ss_rel_cond) begin
			ss_resume_hold <= 0;
			ss_vdp_resume  <= 1;
		end
	end
end
// (freeze_active & ~freeze_req) covers the one clock between the request
// dropping and the hold being registered, so the CPUs never see a gap.
wire ss_hold_any   = (ss_freeze_active & ~ss_freeze_req) | ss_resume_hold;
wire ss_cpu_freeze = ss_freeze_req | ss_hold_any;


// Region decode.
// Sub-CPU. One 16-bit fx68k word per 32-bit word, upper half zero. fx68k reads
// 0 above its used range and ignores writes there, so the reserved tail is inert.
`define SS_IN(off, size) ((ss_state_addr >= (off)) && (ss_state_addr < (off) + (size)))

wire ss_sel_m68k     = `SS_IN(SS_OFF_M68K_REGS, SS_M68K_REGS_SIZE);
wire ss_sel_s68k     = `SS_IN(SS_OFF_S68K_REGS, SS_S68K_REGS_SIZE);
wire ss_sel_word_ram = `SS_IN(SS_OFF_WORD_RAM, SS_WORD_RAM_SIZE);
wire ss_sel_pcm_ram  = `SS_IN(SS_OFF_PCM_RAM,  SS_PCM_RAM_SIZE);
wire ss_sel_cdc_ram  = `SS_IN(SS_OFF_CDC_RAM,  SS_CDC_RAM_SIZE);
wire ss_sel_bram     = `SS_IN(SS_OFF_BRAM,     SS_BRAM_SIZE);

// The three MegaCD memories share one port into MCD and the selector picks one.
// Only one ss_sel_* is high at a time, so the priority order does not matter.
assign ss_mcd_mem_sel  = ss_sel_word_ram ? 2'd0 :
                         ss_sel_pcm_ram  ? 2'd1 :
                         ss_sel_cdc_ram  ? 2'd2 : 2'd3;
assign ss_mcd_mem_addr = ss_sel_word_ram ? 17'(ss_state_addr - SS_OFF_WORD_RAM) :
                         ss_sel_pcm_ram  ? 17'(ss_state_addr - SS_OFF_PCM_RAM)  :
                         ss_sel_cdc_ram  ? 17'(ss_state_addr - SS_OFF_CDC_RAM)  : 17'd0;
assign ss_mcd_mem_wr_en = ss_state_we & (ss_sel_word_ram | ss_sel_pcm_ram | ss_sel_cdc_ram);
assign ss_mem_wr_data   = ss_state_dout[15:0];

wire ss_sel_vram = `SS_IN(SS_OFF_VRAM, SS_VRAM_SIZE);
wire ss_sel_zram = `SS_IN(SS_OFF_ZRAM, SS_ZRAM_SIZE);

assign ss_gen_mem_sel   = ss_sel_zram;                      // 0 = VRAM, 1 = Z80 RAM
assign ss_gen_mem_addr  = ss_sel_zram ? 15'(ss_state_addr - SS_OFF_ZRAM)
                                      : 15'(ss_state_addr - SS_OFF_VRAM);
assign ss_gen_mem_wr_en = ss_state_we & (ss_sel_vram | ss_sel_zram);

// VDP internals. CRAM and obj_cache are exact copies of physical memory.
// VSRAM covers both 32-entry halves, not only the 20 entries the VDP uses.
wire ss_sel_cram      = `SS_IN(SS_OFF_CRAM,      SS_CRAM_SIZE);
wire ss_sel_vsram     = `SS_IN(SS_OFF_VSRAM,     SS_VSRAM_SIZE);
wire ss_sel_obj_cache = `SS_IN(SS_OFF_OBJ_CACHE, SS_OBJ_CACHE_SIZE);
wire ss_sel_vdp_regs  = `SS_IN(SS_OFF_VDP_REGS,  SS_VDP_REGS_SIZE);
wire ss_sel_vdp       = ss_sel_cram | ss_sel_vsram | ss_sel_obj_cache | ss_sel_vdp_regs;

assign ss_vdp_sel   = ss_sel_cram      ? 2'd0 :
                      ss_sel_vsram     ? 2'd1 :
                      ss_sel_obj_cache ? 2'd2 : 2'd3;
assign ss_vdp_addr  = ss_sel_cram      ? 8'(ss_state_addr - SS_OFF_CRAM)  :
                      ss_sel_vsram     ? 8'(ss_state_addr - SS_OFF_VSRAM) :
                      ss_sel_obj_cache ? 8'(ss_state_addr - SS_OFF_OBJ_CACHE) :
                                         8'(ss_state_addr - SS_OFF_VDP_REGS);
assign ss_vdp_wr_en = ss_state_we & ss_sel_vdp;

// Gate Array registers.
wire ss_sel_asic   = `SS_IN(SS_OFF_ASIC_REGS, SS_ASIC_REGS_SIZE);
assign ss_asic_addr  = 8'(ss_state_addr - SS_OFF_ASIC_REGS);
assign ss_asic_wr_en = ss_state_we & ss_sel_asic;

// CDC / PCM / CD_DAC registers share one narrow bus into MCD.
wire ss_sel_cdc_regs  = `SS_IN(SS_OFF_CDC_REGS,  SS_CDC_REGS_SIZE);
wire ss_sel_pcm_regs  = `SS_IN(SS_OFF_PCM_REGS,  SS_PCM_REGS_SIZE);
wire ss_sel_cdda_regs = `SS_IN(SS_OFF_CDDA_REGS, SS_CDDA_REGS_SIZE);
wire ss_sel_dev       = ss_sel_cdc_regs | ss_sel_pcm_regs | ss_sel_cdda_regs;

assign ss_dev_sel   = ss_sel_cdc_regs ? 2'd0 : ss_sel_pcm_regs ? 2'd1 : 2'd2;
assign ss_dev_addr  = ss_sel_cdc_regs ? 6'(ss_state_addr - SS_OFF_CDC_REGS)  :
                      ss_sel_pcm_regs ? 6'(ss_state_addr - SS_OFF_PCM_REGS)  :
                                        6'(ss_state_addr - SS_OFF_CDDA_REGS);
assign ss_dev_wr_en = ss_state_we & ss_sel_dev;

// FM register shadow: one YM2612 register per word, 512 of them.
wire ss_sel_fm = `SS_IN(SS_OFF_FM_SHADOW, SS_FM_SHADOW_SIZE);
assign ss_fm_addr  = 9'(ss_state_addr - SS_OFF_FM_SHADOW);
assign ss_fm_wr_en = ss_state_we & ss_sel_fm;

// PSG.
wire ss_sel_psg = `SS_IN(SS_OFF_PSG_REGS, SS_PSG_REGS_SIZE);
assign ss_psg_addr  = 3'(ss_state_addr - SS_OFF_PSG_REGS);
assign ss_psg_wr_en = ss_state_we & ss_sel_psg;

//////////////////////  Savestate CD drive handoff  ////////////////////////////
// Main owns the drive model. Preserve status and guarded MSF for its load ack.
// Status nibbles: status, type, minute, second, frame, flag, checksum.

// Cart mapper state. BANK_REG is the Pier Solar and SSF2 style bank mapper.
// The Pier EEPROM data is in the BRAM region. This region holds its SPI pin state.
assign ss_sel_cart = `SS_IN(SS_OFF_CART_REGS, SS_CART_REGS_SIZE);
assign ss_cart_wp_wd = ss_state_dout[7:0];
assign ss_cart_wp_we = ss_state_we & ss_sel_cart & (ss_state_addr == SS_OFF_CART_REGS);

// The STM95 EEPROM transfer state is not captured. The freeze waits for chip
// select to go high so no SPI transaction is in flight.
wire ss_cart_quiet = ~PIER_QUIRK | ep_cs;


reg [39:0] ss_cdd_stat_saved;   // last status seen, saved in CD_RESYNC
reg [23:0] ss_cdd_msf_saved;    // last position from an MSF-format status packet
reg  [3:0] ss_cdd_lastcmd;      // last non-IDLE command the game issued
reg [23:0] ss_rsy_msf;          // restored position, untouched by the running machine

// Only MSF-format status packets carry a valid position.
wire ss_cdd_stat_has_msf = (scd_cdd_stat[7:4] == 4'h0);

wire ss_sel_resync = `SS_IN(SS_OFF_CD_RESYNC, SS_CD_RESYNC_SIZE);
always @(posedge clk_sys) begin
	reg ss_cdd_send_old;
	if (scd_cdd_rec) begin
		ss_cdd_stat_saved <= scd_cdd_stat;
		if (ss_cdd_stat_has_msf) ss_cdd_msf_saved <= scd_cdd_stat[31:8];
	end

	ss_cdd_send_old <= scd_cdd_send;
	if (scd_cdd_send && !ss_cdd_send_old && scd_cdd_comm[3:0] != 4'h0)
		ss_cdd_lastcmd <= scd_cdd_comm[3:0];

	// Restore the saved status and guarded position for the firmware handoff.
	if (ss_state_we && ss_sel_resync) begin
		if (ss_state_addr == SS_OFF_CD_RESYNC)     ss_cdd_stat_saved[31:0]  <= ss_state_dout;
		if (ss_state_addr == SS_OFF_CD_RESYNC + 1) ss_cdd_stat_saved[39:32] <= ss_state_dout[7:0];
		if (ss_state_addr == SS_OFF_CD_RESYNC + 2) ss_rsy_msf <= ss_state_dout[23:0];
	end
end


// Z80 architectural state, 212 bits over 7 words. The restore is one DIRSet
// pulse after the last word because T80 latches the whole register file at once.
wire ss_sel_z80 = `SS_IN(SS_OFF_Z80_REGS, SS_Z80_REGS_SIZE);
wire [2:0] ss_z80_word = 3'(ss_state_addr - SS_OFF_Z80_REGS);

reg [211:0] ss_z80_dir_r;
reg         ss_z80_dirset_r;
always @(posedge clk_sys) begin
	ss_z80_dirset_r <= 0;
	if(ss_state_we & ss_sel_z80) begin
		case(ss_z80_word)
			3'd0: ss_z80_dir_r[ 31:  0] <= ss_state_dout;
			3'd1: ss_z80_dir_r[ 63: 32] <= ss_state_dout;
			3'd2: ss_z80_dir_r[ 95: 64] <= ss_state_dout;
			3'd3: ss_z80_dir_r[127: 96] <= ss_state_dout;
			3'd4: ss_z80_dir_r[159:128] <= ss_state_dout;
			3'd5: ss_z80_dir_r[191:160] <= ss_state_dout;
			3'd6: begin
				ss_z80_dir_r[211:192] <= ss_state_dout[19:0];
				ss_z80_dirset_r <= 1;   // Last word, latch all registers.
			end
			default: ;
		endcase
	end
end
wire [211:0] ss_z80_dir    = ss_z80_dir_r;
wire         ss_z80_dirset = ss_z80_dirset_r;

// Internal backup RAM. Port A is the MegaCD side and port B is the SD card save
// path, which cannot run during a savestate. The stream uses port A.
wire [12:0] ss_bram_addr = 13'(ss_state_addr - SS_OFF_BRAM);
// Captured but not restored. The internal backup RAM holds the player's saves,
// and a savestate load must not roll them back.
wire        ss_bram_we   = 1'b0;

//////////////////  SDRAM-backed regions: PRG-RAM and work RAM  //////////////////
//
// These are the only regions not in block RAM or flops. All three SDRAM ports
// are in use, but ports 0 and 1 are idle while the CPUs are frozen, so the
// stream borrows them.
//
// SDRAM latency varies because sdram.sv arbitrates three requesters round-robin,
// so the engine uses a state_ready handshake instead of a fixed wait.
wire ss_sel_prg_ram  = `SS_IN(SS_OFF_PRG_RAM,  SS_PRG_RAM_SIZE);
wire ss_sel_work_ram = `SS_IN(SS_OFF_WORK_RAM, SS_WORK_RAM_SIZE);
wire ss_sel_sdram    = ss_sel_prg_ram | ss_sel_work_ram;

wire [17:0] ss_prg_addr  = 18'(ss_state_addr - SS_OFF_PRG_RAM);
wire [14:0] ss_work_addr = 15'(ss_state_addr - SS_OFF_WORK_RAM);

wire        ss_sdr_busy_i = ss_sel_prg_ram ? sdr_busy : GEN_MEM_BUSY;
wire [15:0] ss_sdr_dout_i = ss_sel_prg_ram ? sdr_do   : GEN_MEM_DO;

reg  [1:0] ss_sdr_st = 0;
reg [15:0] ss_sdr_data;
reg        ss_sdr_ready = 0;
reg        ss_sdr_rd = 0, ss_sdr_wr = 0;
reg [31:0] ss_sdr_addr_d;

always @(posedge clk_sys) begin
	ss_sdr_addr_d <= ss_state_addr;

	if(!ss_freeze_active) begin
		ss_sdr_st <= 0; ss_sdr_rd <= 0; ss_sdr_wr <= 0; ss_sdr_ready <= 0;
	end else case(ss_sdr_st)
		// Idle. Wait for the engine to request this word. state_wr reads from the
		// core for a save and state_we writes into the core for a load.
		2'd0: begin
			ss_sdr_ready <= 0;
			if(ss_sel_sdram && (ss_state_wr | ss_state_we)) begin
				ss_sdr_rd <= ~ss_state_we;
				ss_sdr_wr <=  ss_state_we;
				ss_sdr_st <= 2'd1;
			end
		end
		// Wait for the controller to accept the request (busy rises).
		2'd1: if(ss_sdr_busy_i) ss_sdr_st <= 2'd2;
		// Request accepted: drop the strobes and wait for completion. dout is
		// registered by sdram.sv at STATE_READY, so it is valid as busy falls.
		2'd2: begin
			ss_sdr_rd <= 0;
			ss_sdr_wr <= 0;
			if(!ss_sdr_busy_i) begin
				ss_sdr_data  <= ss_sdr_dout_i;
				ss_sdr_ready <= 1;
				ss_sdr_st    <= 2'd3;
			end
		end
		// Hold ready until the engine moves on, then arm for the next word.
		2'd3: if(ss_state_addr != ss_sdr_addr_d) begin
			ss_sdr_ready <= 0;
			ss_sdr_st    <= 2'd0;
		end
	endcase
end

// Regions that answer in the engine's fixed 4-cycle window never stall it.
wire ss_state_ready = ss_sel_sdram ? ss_sdr_ready : 1'b1;

// Inside a 128-word region the low 8 offset bits are the whole address. The
// explicit slice avoids a truncation warning.
assign ss_m68k_addr    = 8'(ss_state_addr - SS_OFF_M68K_REGS);
assign ss_m68k_wr_data = ss_state_dout[15:0];
assign ss_s68k_addr    = 8'(ss_state_addr - SS_OFF_S68K_REGS);
assign ss_s68k_wr_data = ss_state_dout[15:0];

// ss_wr_en may only pulse while the CPU is frozen. The engine asserts state_we
// only in LOAD_DATA_READY and LOAD_RESTORE, which require freeze_ack, and
// freeze_ack includes both CPUs' frozen reports.
assign ss_m68k_wr_en   = ss_state_we & ss_sel_m68k;
assign ss_s68k_wr_en   = ss_state_we & ss_sel_s68k;

// Read chain. Words 0 and 1 are the header checked on load. Regions not yet
// implemented and all reserved tails read 0.
reg [31:0] ss_state_din_r;
always @(posedge clk_sys) begin
	if(ss_sel_m68k)
		ss_state_din_r <= {16'd0, ss_m68k_rd_data};
	else if(ss_sel_s68k)
		ss_state_din_r <= {16'd0, ss_s68k_rd_data};
	else if(ss_sel_word_ram | ss_sel_pcm_ram | ss_sel_cdc_ram)
		ss_state_din_r <= {16'd0, ss_mcd_mem_rd_data};
	else if(ss_sel_bram)
		ss_state_din_r <= {24'd0, MCD_BRAM_DI};
	else if(ss_sel_sdram)
		ss_state_din_r <= {16'd0, ss_sdr_data};
	else if(ss_sel_vram | ss_sel_zram)
		ss_state_din_r <= {16'd0, ss_gen_mem_rd_data};
	else if(ss_sel_vdp)
		ss_state_din_r <= ss_vdp_rd_data;
	else if(ss_sel_asic)
		ss_state_din_r <= ss_asic_rd_data;
	else if(ss_sel_dev)
		ss_state_din_r <= ss_dev_rd_data;
	else if(ss_sel_fm)
		ss_state_din_r <= {24'd0, ss_fm_rd_data};
	else if(ss_sel_psg)
		ss_state_din_r <= ss_psg_rd_data;
	else if(ss_sel_z80)
		ss_state_din_r <= (ss_z80_word == 3'd0) ? ss_z80_reg[ 31:  0] :
		                  (ss_z80_word == 3'd1) ? ss_z80_reg[ 63: 32] :
		                  (ss_z80_word == 3'd2) ? ss_z80_reg[ 95: 64] :
		                  (ss_z80_word == 3'd3) ? ss_z80_reg[127: 96] :
		                  (ss_z80_word == 3'd4) ? ss_z80_reg[159:128] :
		                  (ss_z80_word == 3'd5) ? ss_z80_reg[191:160] :
		                  (ss_z80_word == 3'd6) ? {12'd0, ss_z80_reg[211:192]} : 32'd0;
	else case(ss_state_addr)
		0: ss_state_din_r <= SS_MAGIC;
		1: ss_state_din_r <= {SS_VERSION[7:0], SS_FULL_SIZE[23:0]};
		// Reserved diagnostics region. Its size remains fixed for native images.
		SS_OFF_MISC: ss_state_din_r <= {31'd0, ss_backstop};
		SS_OFF_CART_REGS:     ss_state_din_r <= {16'd0, ep_cs, ep_hold, ep_sck, ep_si,
		                                         4'd0, ss_cart_wp};
		SS_OFF_CART_REGS + 1: ss_state_din_r <= {2'd0, BANK_REG[5], BANK_REG[4], BANK_REG[3],
		                                         BANK_REG[2], BANK_REG[1], BANK_REG[0]};
		SS_OFF_CART_REGS + 2: ss_state_din_r <= {22'd0, BANK_REG[7], BANK_REG[6]};
		SS_OFF_CART_REGS + 3: ss_state_din_r <= 32'd0;
		SS_OFF_CD_RESYNC:     ss_state_din_r <= ss_cdd_stat_saved[31:0];
		SS_OFF_CD_RESYNC + 1: ss_state_din_r <= {24'd0, ss_cdd_stat_saved[39:32]};
		SS_OFF_CD_RESYNC + 2: ss_state_din_r <= {4'd0, ss_cdd_lastcmd, ss_cdd_msf_saved};
		// Remaining CD_RESYNC words are reserved for the Main drive context.
		default: ss_state_din_r <= 32'd0;
	endcase
end
wire [31:0] ss_state_din = ss_state_din_r;



savestate savestate_inst
(
	.clk(clk_sys),
	.reset(reset),

	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),

	.ss_slot(ss_slot_reg),
	.ss_save(ss_save_req),
	.ss_load(ss_load_req),
	.state_size(SS_FULL_SIZE),
	.ss_busy(ss_busy),
	.ss_save_done(ss_save_done),
	.ss_load_done(ss_load_done),
	.load_hold(ss_load_pending),

	.freeze_req(ss_freeze_req),
	.freeze_ack(ss_freeze_ack),

	.state_addr(ss_state_addr),
	.state_wr(ss_state_wr),
	.state_rd(ss_state_rd),
	.state_din(ss_state_din),
	.state_dout(ss_state_dout),
	.state_we(ss_state_we),
	.state_ready(ss_state_ready),

	.hdr_magic(SS_MAGIC),
	.hdr_version(SS_VERSION),
	.hdr_size(SS_FULL_SIZE)
);

endmodule
