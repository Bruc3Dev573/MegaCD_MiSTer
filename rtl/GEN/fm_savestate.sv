// YM2612 (jt12) with its savestate logic, region FM_SHADOW of MegaCD.sv.
//
// Region layout, one 32-bit word per register of the shadow, 512 words:
//   word k bits 7-0    shadow of register k[7:0] of bank k[8]
//   word 0 bits 31-8   bit 31 set when the image holds the chip state, bits 20-8 the
//                      length of its chain in bits
//   words 1 to ceil(length/24) bits 31-8
//                      the chain, 24 bits per word, the first bit out in bit 31
// The chain is the two address latches of the shadow, then every register of jt12
// (jt12_top.v). Images without bit 31, and images whose chain length differs from this
// core's, load as before: the shadow is replayed into the chip.

module fm_savestate
(
	input         clk,
	input         cen,          // chip clock enable
	input         rst,

	// Z80 bus
	input         sel,
	input   [1:0] addr,
	input         we,
	input   [7:0] din,
	output  [7:0] dout,

	input         en_hifi_pcm,
	input         ladder,
	output signed [15:0] snd_left,
	output signed [15:0] snd_right,

	// Savestate
	input         ss_park,      // the CPUs are parked or the stream may run: stop the chip
	input         ss_active,    // freeze granted
	input   [8:0] ss_addr,      // word of the region
	input  [31:0] ss_wr_data,
	input         ss_wr_en,     // load
	input         ss_rd_en,     // save
	output [31:0] ss_rd_data,
	output        ss_ready,     // the word is done
	input         ss_replay,    // 1-cycle pulse after a load completes
	output        ss_replaying
);

//--------------------------------------------------------------
// FM register shadow for savestates
//--------------------------------------------------------------
// Mirror CPU writes because jt12's rotating register file has no readback.
// YM2612 A0 selects address or data. A1 selects one of two banks.
reg [7:0] fm_shadow[0:511];
reg [7:0] fm_addr_lat[0:1];
reg [7:0] fm_shadow_q;

reg  [9:0] fm_rp_idx;
reg        fm_rp_run = 0;

// The shadow is read either by the savestate stream or by the replay sequencer.
wire [8:0] fm_sh_rd_addr = fm_rp_run ? fm_rp_idx[8:0] : ss_addr;

// Mux CPU/restore writes into one port so Quartus infers a 1W1R memory.
wire [8:0] fm_wr_addr = ss_wr_en ? ss_addr : {addr[1], fm_addr_lat[addr[1]]};
wire [7:0] fm_wr_data = ss_wr_en ? ss_wr_data[7:0] : din;
wire       fm_wr_en   = ss_wr_en | (sel & we & addr[0]);

wire        sc_shift, sc_in;
wire [15:0] lat_q = {fm_addr_lat[1], fm_addr_lat[0]};

always @(posedge clk) begin
	// The register-index latch stays in flops: two bytes, one per bank.
	if (sc_shift) {fm_addr_lat[1], fm_addr_lat[0]} <= {lat_q[14:0], sc_in};
	else if (sel & we & ~addr[0]) fm_addr_lat[addr[1]] <= din;

	if (fm_wr_en) fm_shadow[fm_wr_addr] <= fm_wr_data;
	fm_shadow_q <= fm_shadow[fm_sh_rd_addr];
end

//--------------------------------------------------------------
// Chip state
//--------------------------------------------------------------
// The chip stops (jt12 ss_hold) while the CPUs are parked and while the stream runs,
// except during a replay. The hold changes only on the edge before an edge with cen
// (cen comes every 7 clocks), one of the two edges where the 68000 freeze engine of
// gen.sv stops or starts the 68000. The chip starts again at the phase of cen where it
// stopped, as if no clock had passed, and it misses the same clock enables as the
// 68000 unless that one parks last, on that same edge.
//
// A save word shifts 24 bits out of the chain and back into it, a load word shifts its
// 24 bits in. One bit per clock; ss_ready holds the engine meanwhile. The chain moves
// exactly its length per image, so a save leaves it as it was. One clock after the
// last bit ss_commit reloads the ROM address registers of the chip.
localparam LAT_N = 13'd16;

wire [12:0] chip_n;
wire [12:0] sc_n = chip_n + LAT_N;
wire        sc_out;

reg         hold = 0;
reg   [2:0] cen_ph = 0;     // clocks since cen
reg  [12:0] sc_cnt = 0;     // chain bits moved since word 0
reg   [4:0] sc_left = 0;    // steps left for the current word
reg  [23:0] sc_buf;
reg   [8:0] sc_word;
reg         sc_valid = 0;   // sc_word is the word being served
reg         sc_load = 0;    // that word is a load
reg         sc_have = 0;    // the image being loaded holds the chip state
reg         sc_commit = 0;

// A save cut short (engine timeout) finishes moving the chain once the freeze ends.
wire sc_spin = ~ss_active & ~sc_load & (sc_cnt != 13'd0) & (sc_cnt < sc_n);
wire sc_step = hold & (sc_left != 5'd0);
assign sc_shift = hold & (sc_cnt < sc_n) & ((sc_left != 5'd0) | sc_spin);
assign sc_in    = sc_load ? sc_buf[23] : sc_out;

always @(posedge clk) begin
	cen_ph <= cen ? 3'd1 : cen_ph + 1'd1;
	if (cen_ph == 3'd6) hold <= (ss_park & ~fm_rp_run) | sc_spin;
end

always @(posedge clk) begin
	sc_commit <= sc_shift & (sc_cnt == sc_n - 1'd1);
	if (~ss_active) sc_valid <= 0;

	if ((ss_rd_en | ss_wr_en) & ~(sc_valid & (sc_word == ss_addr))) begin
		sc_word  <= ss_addr;
		sc_valid <= 1;
		sc_load  <= ss_wr_en;
		if (ss_addr == 9'd0) begin
			sc_cnt  <= 0;
			sc_left <= 0;
			sc_buf  <= {1'b1, 10'd0, sc_n};
			if (ss_wr_en) sc_have <= ss_wr_data[31] & (ss_wr_data[20:8] == sc_n);
		end
		else begin
			sc_left <= (ss_wr_en & ~sc_have) ? 5'd0 : 5'd24;
			sc_buf  <= ss_wr_en ? ss_wr_data[31:8] : 24'd0;
		end
	end
	else begin
		if (sc_step) begin
			sc_left <= sc_left - 1'd1;
			sc_buf  <= {sc_buf[22:0], sc_shift & sc_out};
		end
		if (sc_shift) sc_cnt <= sc_cnt + 1'd1;
	end
end

assign ss_rd_data = {sc_buf, fm_shadow_q};
assign ss_ready   = sc_valid & (sc_word == ss_addr) & (sc_left == 5'd0);

//--------------------------------------------------------------
// FM replay sequencer
//--------------------------------------------------------------
// For images without the chip state. The YM2612 register file is shift registers,
// not RAM. A write lands only when its target slot comes round, so back to back
// writes are dropped. The sequencer polls the busy bit in the status byte between
// writes, as a sound driver does.
//
// Replay order:
//   $28  key on/off last, after every operator's TL/AR/DR/SL/RR is in place.
//   $27  timer control late, so timers and IRQs do not start mid-sweep.
//   $24-$26 timer periods, replayed with $27.
//   $2A $2B  DAC data and enable are skipped. $2A is a sample stream and
//        $2B moves the output mux.
//   $21 $2C  test registers are skipped.
//
// Envelope phase, phase accumulators and the LFO counter are not restored this way.
// Audio becomes correct within a note or two.
reg  [1:0] fm_rp_st;
reg        fm_rp_wr;
reg        fm_rp_phase;   // 0 = write the register index, 1 = write its value

assign ss_replaying = fm_rp_run;

wire [7:0] fm_rp_reg  = fm_rp_idx[7:0];
wire       fm_rp_bank = fm_rp_idx[8];

// Registers to skip during the main sweep. The tail (idx 512, 513) replays the
// two that were held back, in order.
wire fm_rp_skip = (fm_rp_idx < 10'd512) &&
                  ( (fm_rp_reg < 8'h22) || (fm_rp_reg >= 8'hB7) ||
                    (~fm_rp_bank & (fm_rp_reg == 8'h24 || fm_rp_reg == 8'h25 ||
                                    fm_rp_reg == 8'h26 || fm_rp_reg == 8'h27 ||
                                    fm_rp_reg == 8'h28 || fm_rp_reg == 8'h2A ||
                                    fm_rp_reg == 8'h2B || fm_rp_reg == 8'h2C)) ||
                    ( fm_rp_bank & (fm_rp_reg < 8'h30)) );

// idx 512 is $27 (timers), idx 513 is $28 (key on/off). Both bank 0.
wire [7:0] fm_rp_reg_eff  = (fm_rp_idx == 10'd512) ? 8'h27 :
                            (fm_rp_idx == 10'd513) ? 8'h28 : fm_rp_reg;
wire       fm_rp_bank_eff = (fm_rp_idx >= 10'd512) ? 1'b0 : fm_rp_bank;

wire fm_busy = dout[7];

always @(posedge clk) begin
	if (ss_replay & ~sc_have) begin
		fm_rp_idx <= 0;
		fm_rp_st  <= 0;
		fm_rp_run <= 1;
		fm_rp_wr  <= 0;
	end
	else if (fm_rp_run) begin
		case (fm_rp_st)
			// Pick the next register, or finish.
			2'd0: begin
				fm_rp_wr <= 0;
				if (fm_rp_idx > 10'd513) fm_rp_run <= 0;
				else if (fm_rp_skip)     fm_rp_idx <= fm_rp_idx + 1'd1;
				else if (!fm_busy) begin
					fm_rp_phase <= 0;      // address port
					fm_rp_wr    <= 1;
					fm_rp_st    <= 2'd1;
				end
			end
			// Address written. Wait for the chip to take it.
			2'd1: begin
				fm_rp_wr <= 0;
				if (!fm_busy) begin
					fm_rp_phase <= 1;      // data port
					fm_rp_wr    <= 1;
					fm_rp_st    <= 2'd2;
				end
			end
			// Data written. Wait, then step.
			2'd2: begin
				fm_rp_wr <= 0;
				if (!fm_busy) begin
					fm_rp_idx <= fm_rp_idx + 1'd1;
					fm_rp_st  <= 2'd0;
				end
			end
			default: fm_rp_st <= 2'd0;
		endcase
	end
end

// Bus mux. While replaying, the Z80 path is disconnected so a driver write cannot
// land on a half-restored chip.
wire [1:0] fm_addr_m = fm_rp_run ? {fm_rp_bank_eff, fm_rp_phase} : addr;
wire [7:0] fm_din_m  = fm_rp_run ? (fm_rp_phase ? fm_shadow_q : fm_rp_reg_eff) : din;
wire       fm_wr_n_m = fm_rp_run ? ~fm_rp_wr : ~(sel & we);

jt12 fm
(
	.rst(rst),
	.clk(clk),
	.cen(cen),

	.cs_n(0),
	.addr(fm_addr_m),
	.wr_n(fm_wr_n_m),
	.din(fm_din_m),
	.dout(dout),
	.en_hifi_pcm(en_hifi_pcm),
	.ladder(ladder),
	.snd_left(snd_left),
	.snd_right(snd_right),

	.ss_hold(hold),
	.ss_scan(sc_shift),
	.ss_si(lat_q[15]),
	.ss_so(sc_out),
	.ss_n(chip_n),
	.ss_commit(sc_commit)
);

endmodule
