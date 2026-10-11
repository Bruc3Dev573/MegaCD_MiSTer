// Checks an fx68k savestate restore taken while a bus cycle is pending.
//
// A CPU parked while a DMA holds the bus has bcPend=1 and its Irc/dbin capture
// armed for a read that has not run yet. The restore must keep that capture
// armed, or the CPU runs on with whatever the DMA left on the bus. With no cycle
// pending the capture must stay off, or it grabs a stale bus hold.
//
// Each trial resets the CPU and runs the program. Even trials let a DMA take the
// bus. A freeze is requested at a varying offset and parks the CPU as the core
// does: after enPhi2, before enPhi1, AS high and not in S0. All 128 savestate
// words are read, the DMA ends and a foreign word goes on the bus hold. The words
// are written back in ascending order, the CPU resumes with the owed enPhi1 and
// its next writes must follow the program.
//
// Prints PASS on success, otherwise prints FAIL or INVALID and stops with $fatal.
//
// Program, looping at $106 with a6 = $C00004:
//   move.l #$940193A0,(a6)
//   move.l #$96129501,(a6)
//   move.w #$8174,(a6)
//   bra.b loop
//
// Run: bash sim/run_smoke.sh cpu
`timescale 1ns/1ps

module tb_fx68k_pending;

	localparam logic [15:0] STALE = 16'h0388;
	localparam int NTRIAL = 48;

	logic clk = 0;
	always #5 clk = ~clk;

	// ---- phase generator, a freeze lands between P2 and P1 --------------------
	logic run = 0, freeze_req = 0, resume_req = 0, frozen = 0;
	logic enPhi1 = 0, enPhi2 = 0;
	logic [1:0] ph = 0;
	wire ASn, busStarting;
	always_ff @(posedge clk) begin
		enPhi1 <= 0; enPhi2 <= 0;
		if (resume_req) frozen <= 0;
		else if (run && !frozen) begin
			if (ph == 2'd3 && freeze_req && ASn && !busStarting) frozen <= 1;
			else begin
				ph <= ph + 1'd1;
				if (ph == 2'd3) enPhi1 <= 1;
				if (ph == 2'd1) enPhi2 <= 1;
			end
		end
	end

	logic extReset = 1, pwrUp = 1;
	logic BRn = 1, BGACKn = 1;
	logic [15:0] iEdb;
	logic DTACKn;
	wire eRWn, LDSn, UDSn, BGn, FC0, FC1, FC2, E, VMAn, oRESETn, oHALTEDn;
	wire addrOe, dataOe;
	wire [15:0] oEdb;
	wire [23:1] eab;
	logic [7:0] ss_addr = 0;
	logic [15:0] ss_wr_data = 0;
	logic ss_wr_en = 0;
	wire [15:0] ss_rd_data;

	fx68k cpu(.clk, .HALTn(1'b1), .extReset, .pwrUp, .enPhi1, .enPhi2,
		.eRWn, .ASn, .LDSn, .UDSn, .E, .VMAn, .FC0, .FC1, .FC2, .BGn,
		.oRESETn, .oHALTEDn, .DTACKn, .VPAn(1'b1), .BERRn(1'b1),
		.BRn, .BGACKn, .IPL0n(1'b1), .IPL1n(1'b1), .IPL2n(1'b1),
		.iEdb, .oEdb, .eab, .addrOe_o(addrOe), .dataOe_o(dataOe),
		.busStarting_o(busStarting),
		.ss_addr, .ss_wr_data, .ss_wr_en, .ss_rd_data);

	// ---- memory and bus hold --------------------------------------------------
	logic [15:0] rom [0:255];
	initial begin
		for (int i = 0; i < 256; i++) rom[i] = 16'h4E71;	// nop
		rom[0] = 16'h0000; rom[1] = 16'h8000;			// SSP
		rom[2] = 16'h0000; rom[3] = 16'h0100;			// PC
		rom['h80] = 16'h2C7C; rom['h81] = 16'h00C0; rom['h82] = 16'h0004;	// movea.l #$C00004,a6
		rom['h83] = 16'h2CBC; rom['h84] = 16'h9401; rom['h85] = 16'h93A0;	// $106 move.l #$940193A0,(a6)
		rom['h86] = 16'h2CBC; rom['h87] = 16'h9612; rom['h88] = 16'h9501;	// $10C move.l #$96129501,(a6)
		rom['h89] = 16'h3CBC; rom['h8A] = 16'h8174;				// $112 move.w #$8174,(a6)
		rom['h8B] = 16'h60EE;							// $116 bra.b $106
	end

	logic dma = 0, poison = 0;
	logic [15:0] hold = 16'h4E71;
	logic [1:0] dly = 0;
	wire rd_cycle = ~ASn & eRWn;
	wire [15:0] rd_data = (eab[23:9] == 0) ? rom[eab[8:1]] : 16'hFFFF;
	assign iEdb = dma ? STALE : ((rd_cycle & dly == 2'd2) ? rd_data : hold);
	assign DTACKn = ~(~ASn & dly == 2'd2);
	always_ff @(posedge clk) begin
		if (ASn) dly <= 0;
		else if (dly != 2'd2) dly <= dly + 1'd1;
		if (dma | poison) hold <= STALE;
		else if (rd_cycle & dly == 2'd2) hold <= rd_data;
	end

	// ---- writes seen after the resume -----------------------------------------
	logic [15:0] wlog [0:31];
	int wn = 0, bad_cycles = 0;
	logic logging = 0, clear_log = 0;
	logic as_d = 1, wr_seen = 0;
	logic [23:1] wa;
	logic [15:0] wd;
	always_ff @(posedge clk) begin
		as_d <= ASn;
		if (clear_log) begin wn <= 0; bad_cycles <= 0; end
		if (~ASn & ~eRWn & (~LDSn | ~UDSn)) begin wa <= eab; wd <= oEdb; wr_seen <= 1; end
		if (~as_d & ASn) begin
			if (logging & wr_seen) begin
				if ({wa, 1'b0} == 24'hC00004 || {wa, 1'b0} == 24'hC00006) begin
					if (wn < 32) wlog[wn] <= wd;
					wn <= wn + 1;
				end
				else bad_cycles <= bad_cycles + 1;	// stack / exception frame
			end
			wr_seen <= 0;
		end
	end

	// ---- trials ---------------------------------------------------------------
	logic [15:0] img [0:127];
	localparam logic [15:0] SEQ [0:4] = '{16'h9401, 16'h93A0, 16'h9612, 16'h9501, 16'h8174};
	int fails [0:2] = '{0, 0, 0};
	int pend_trials = 0, idle_trials = 0;

	task automatic tick(int n); repeat (n) @(posedge clk); endtask

	// Mode 0 runs the DMA without a freeze to check the bus model alone.
	// Mode 1 freezes and releases without a restore, as a save does.
	// Mode 2 freezes, restores every word and releases, as a load does.
	task automatic trial(int t, int mode);
		int off, k, pos;
		logic use_dma, ok, pend, armed;
		use_dma = (t % 2) == 0;
		off = 3 + (t * 7) % 41;
		run = 0; freeze_req = 0; extReset = 1; pwrUp = 1; BRn = 1; BGACKn = 1;
		dma = 0; poison = 0; logging = 0;
		tick(4); run = 1; tick(40); extReset = 0; pwrUp = 0;
		tick(400 + 3 * t);
		if (use_dma) begin
			// Like the VDP: assert BRn, wait for BGn, then assert BGACKn and start traffic.
			BRn = 0;
			wait (BGn == 1'b0);
			tick(6); BGACKn = 0; BRn = 1;
			tick(4); dma = 1;
		end
		tick(off);
		pend = 0; armed = 0;
		if (mode == 0) begin
			tick(24);
			if (use_dma) begin dma = 0; tick(4); BGACKn = 1; end
		end
		else begin
			freeze_req = 1;
			wait (frozen == 1'b1);
			tick(4);
			for (k = 0; k < 128; k++) begin ss_addr = k[7:0]; #1; img[k] = ss_rd_data; end
			pend  = img[97][8];
			armed = |img[94][1:0];
			if (use_dma) begin dma = 0; tick(4); BGACKn = 1; end
			if (mode == 2) begin
				poison = 1;			// another machine's last word on the bus
				tick(2);
				for (k = 0; k < 128; k++) begin
					@(negedge clk); ss_addr = k[7:0]; ss_wr_data = img[k]; ss_wr_en = 1;
					@(negedge clk); ss_wr_en = 0;
				end
			end
			tick(2);
		end
		clear_log = 1; tick(1); clear_log = 0;
		logging = 1; poison = 0; freeze_req = 0;
		if (mode != 0) begin resume_req = 1; tick(1); resume_req = 0; end	// owed enPhi1 first
		tick(1500);
		logging = 0;
		ok = (wn >= 10) && (bad_cycles == 0);
		pos = -1;
		for (k = 0; k < 5; k++) if (wn > 0 && wlog[0] == SEQ[k]) pos = k;
		if (pos < 0) ok = 0;
		for (k = 0; ok && k < 10; k++) if (wlog[k] != SEQ[(pos + k) % 5]) ok = 0;
		if (mode == 2) begin
			if (pend & armed) pend_trials++; else idle_trials++;
		end
		if (!ok) begin
			fails[mode]++;
			$display("mode %0d trial %0d FAIL dma=%0d bcPend=%0d armed=%0d Irc=%h writes=%0d first=%h %h %h %h bad=%0d",
				mode, t, use_dma, pend, armed, img[91], wn, wlog[0], wlog[1], wlog[2], wlog[3], bad_cycles);
		end
	endtask

	initial begin
		for (int t = 0; t < NTRIAL; t++)
			for (int m = 0; m < 3; m++) trial(t, m);
		$display("LOAD trials parked with a pending armed capture: %0d, others: %0d", pend_trials, idle_trials);
		$display("failures: DMA alone %0d, SAVE path %0d, LOAD path %0d (of %0d each)",
			fails[0], fails[1], fails[2], NTRIAL);
		if (fails[0] != 0 || fails[1] != 0) begin
			$display("INVALID: the bus model or the freeze fails without a restore");
			$fatal(1);
		end
		if (pend_trials == 0) begin
			$display("INVALID: no trial parked with a pending cycle, so the case is not exercised");
			$fatal(1);
		end
		if (fails[2] == 0) $display("PASS");
		else begin $display("FAIL"); $fatal(1); end
		$finish;
	end

	initial begin
		#20_000_000;
		$fatal(1, "FAIL: pending-cycle smoke timeout");
	end

endmodule
