// Checks that freeze_req stays high without a gap for a whole load.
// A load must show one rising and one falling freeze_req edge, including the
// control-word write and the firmware handoff.
`timescale 1ns/1ps

module tb_load_freeze;

localparam [31:0] MAGIC   = 32'h5353_434D;
localparam [31:0] VERSION = 32'd1;
localparam [31:0] WORDS   = 32'd16;

reg clk = 0;
always #5 clk = ~clk;
reg reset = 1;

// DDR: never busy, one-cycle read latency. Read 1 = control word
// {size, change detector}, read 2 = payload header, then zeros.
wire        ddr_rd, ddr_we;
wire [28:0] ddr_addr;
wire [63:0] ddr_din;
reg  [63:0] ddr_dout = 0;
reg         ddr_ready = 0;
integer     reads = 0;
always @(posedge clk) begin
	ddr_ready <= 0;
	if (ddr_rd) begin
		reads <= reads + 1;
		ddr_ready <= 1;
		ddr_dout <= (reads == 0) ? {WORDS, 32'd7} :
		            (reads == 1) ? {VERSION[7:0], WORDS[23:0], MAGIC} : 64'd0;
	end
end

// Core: acknowledges a few clocks after the request, drops the ack with it.
wire freeze_req;
reg  [3:0] ack_sr = 0;
always @(posedge clk) ack_sr <= freeze_req ? {ack_sr[2:0], 1'b1} : 4'd0;
wire freeze_ack = ack_sr[3];

// Firmware: collects the load a few clocks after ss_load_done.
wire  ss_load_done;
reg   load_hold = 0;
reg [7:0] fw_cnt = 0;
always @(posedge clk) begin
	if (ss_load_done) begin load_hold <= 1; fw_cnt <= 0; end
	else if (load_hold) begin
		fw_cnt <= fw_cnt + 1'd1;
		if (fw_cnt == 8'd20) load_hold <= 0;
	end
end

reg ss_load = 0;
wire ss_busy;

savestate dut (
	.clk(clk), .reset(reset),
	.DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(), .DDRAM_ADDR(ddr_addr),
	.DDRAM_DOUT(ddr_dout), .DDRAM_DOUT_READY(ddr_ready),
	.DDRAM_RD(ddr_rd), .DDRAM_DIN(ddr_din), .DDRAM_BE(), .DDRAM_WE(ddr_we),
	.ss_slot(2'd1), .ss_save(1'b0), .ss_load(ss_load), .state_size(WORDS),
	.ss_busy(ss_busy), .ss_save_done(), .ss_load_done(ss_load_done),
	.freeze_req(freeze_req), .freeze_ack(freeze_ack),
	.state_addr(), .state_wr(), .state_rd(), .state_din(32'd0),
	.state_dout(), .state_we(), .state_ready(1'b1), .load_hold(load_hold),
	.hdr_magic(MAGIC), .hdr_version(VERSION), .hdr_size(WORDS)
);

integer rises = 0, falls = 0, loads_done = 0;
reg req_d = 0;
always @(posedge clk) begin
	req_d <= freeze_req;
	if (freeze_req & ~req_d) rises <= rises + 1;
	if (~freeze_req & req_d) falls <= falls + 1;
	if (ss_load_done)        loads_done <= loads_done + 1;
end

initial begin
	repeat (4) @(posedge clk);
	reset = 0;
	repeat (4) @(posedge clk);
	ss_load = 1;
	repeat (8) @(posedge clk);
	ss_load = 0;
	wait (ss_busy);
	wait (!ss_busy);
	repeat (4) @(posedge clk);
	$display("freeze_req rises=%0d falls=%0d loads_done=%0d", rises, falls, loads_done);
	if (loads_done != 1)
		$fatal(1, "FAIL: the load did not complete");
	if (rises != 1 || falls != 1)
		$fatal(1, "FAIL: freeze_req dropped and rose again during one LOAD");
	$display("PASS");
	$finish;
end

initial begin
	#2_000_000;
	$fatal(1, "FAIL: timeout");
end

endmodule
