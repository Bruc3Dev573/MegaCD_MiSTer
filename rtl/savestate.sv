// Savestate engine for the Mega CD core.
// Streams state words straight between the core and four 4 MB slots in DDR3.
//
// Slot layout in DDR3, in 64-bit words:
// Word 0 bits 31:0 hold the change detector, bits 63:32 the size in 32-bit words.
// Word 1 onward holds the payload. Payload header word 1 is {version[7:0], size[23:0]}.

module savestate
(
	input         clk,
	input         reset,

	// DDR3 interface
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output reg    DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output reg    DDRAM_WE,

	// Save state control
	input   [1:0] ss_slot,      // Slot selection (0-3)
	input         ss_save,      // Save request (edge triggered)
	input         ss_load,      // Load request (edge triggered)
	input  [31:0] state_size,   // Actual state size in 32-bit words
	output        ss_busy,      // Operation in progress
	output reg    ss_save_done, // Save operation completed (single-cycle pulse)
	output reg    ss_load_done, // Load operation completed (single-cycle pulse)

	// Core freeze control
	output        freeze_req,   // Request to freeze core
	input         freeze_ack,   // Core frozen acknowledgment

	// State data interface
	output [31:0] state_addr,   // Address for state data (in 32-bit words)
	output        state_wr,     // Write enable for save
	output        state_rd,     // Read enable for load
	input  [31:0] state_din,    // Data from core (for save)
	output [31:0] state_dout,   // Data to core (for load)
	output        state_we,     // Write enable to core (for load)

	// Stalls slow SDRAM regions. Fixed-latency regions tie this high.
	input         state_ready,
	// Keep the freeze until Main acknowledges its restored CD drive context.
	input         load_hold,

	// Payload words 0 and 1 must match before applying a load.
	input  [31:0] hdr_magic,
	input  [31:0] hdr_version,
	input  [31:0] hdr_size
);

// Four 4 MB slots in DDR3 from 0x3E000000, declared to Main with SS3E000000:400000.
// The core does not use DDR3 for anything else.
localparam [28:0] SS_BASE = 29'h7C00000;  // 0x3E000000 >> 3 (64-bit aligned)
localparam [31:0] SS_SIZE = 32'h400000;   // 4MB per slot
localparam [31:0] SS_SIZE_WORDS = SS_SIZE >> 2; // Size in 32-bit words (524288)

// Shorter delays for simulation.
`ifdef SIM_FAST
	localparam [19:0] COOLDOWN_CYCLES = 20'd10;
	localparam [15:0] UNFREEZE_CYCLES = 16'd10;
	localparam [25:0] TIMEOUT_CYCLES  = 26'd1000;   // ~20us equivalent for sim
`else
	localparam [19:0] COOLDOWN_CYCLES = 20'd530000;
	localparam [15:0] UNFREEZE_CYCLES = 16'd65000;
	localparam [25:0] TIMEOUT_CYCLES  = 26'd50000000; // 1 second @ 50MHz
`endif

// State machine
`ifdef IVERILOG
// Icarus Verilog workaround: typedef enum has incomplete support
localparam [4:0]
	IDLE            = 5'd0,
	FREEZE_WAIT     = 5'd1,
	READ_CTRL       = 5'd2,
	READ_CTRL_WAIT  = 5'd3,
	SAVE_WAIT       = 5'd4,
	SAVE_CAPTURE    = 5'd5,
	SAVE_WRITE      = 5'd6,
	SAVE_WRITE_WAIT = 5'd7,
	SAVE_CTRL_WRITE = 5'd8,
	SAVE_CTRL_WAIT  = 5'd9,
	LOAD_READ       = 5'd10,
	LOAD_READ_WAIT  = 5'd11,
	LOAD_DATA_READY = 5'd12,
	LOAD_RESTORE    = 5'd13,
	LOAD_WRITE_WAIT = 5'd14,
	LOAD_CTRL_WRITE = 5'd15,
	LOAD_CTRL_WAIT  = 5'd16,
	UNFREEZE        = 5'd17,
	COOLDOWN        = 5'd18,
	FW_HOLD         = 5'd19;
reg [4:0] state = IDLE;
`else
typedef enum {
	IDLE,
	FREEZE_WAIT,
	READ_CTRL,
	READ_CTRL_WAIT,
	SAVE_WAIT,        // Wait for RAM read latency (2 cycles)
	SAVE_CAPTURE,     // Capture data after latency
	SAVE_WRITE,
	SAVE_WRITE_WAIT,
	SAVE_CTRL_WRITE,
	SAVE_CTRL_WAIT,
	LOAD_READ,
	LOAD_READ_WAIT,
	LOAD_DATA_READY,  // Data stable, ready to write
	LOAD_RESTORE,     // Write enable active
	LOAD_WRITE_WAIT,  // Wait for component write to complete
	LOAD_CTRL_WRITE,  // Write change detector to notify firmware
	LOAD_CTRL_WAIT,   // Wait for change detector write to complete
	UNFREEZE,
	COOLDOWN,         // Wait before accepting new commands
	FW_HOLD           // Frozen post-load, waiting for the firmware drive-model ack
} state_t;

state_t state = IDLE;
`endif

reg [1:0] slot_reg;
reg [31:0] change_detector;
reg [31:0] saved_size;
reg [31:0] word_count;
reg [28:0] ddr_addr;
reg [63:0] ddr_data;
reg [31:0] state_data_reg;
reg [31:0] data_buffer;
// Two-stage synchronizers for the OSD requests.
reg [1:0] ss_load_sync = 0;
reg [1:0] ss_save_sync = 0;
reg old_ss_save;
reg old_ss_load;
reg data_ready;
reg [1:0] wait_count;   // Counter for RAM read latency
reg is_loading;  // Flag to distinguish save vs load operation
reg [19:0] cooldown_count;  // Delay before the next request is accepted
reg [15:0] unfreeze_delay;
reg [25:0] fw_hold_cnt;  // Wait counter for the firmware ack
reg        hdr_bad;         // Stored image header does not match this build

// Aborts a stuck operation after about one second.
reg [25:0] timeout_counter;
wire timeout = (timeout_counter == TIMEOUT_CYCLES);

// DDR3 addresses for the current slot.
wire [28:0] slot_base = SS_BASE + (slot_reg * (SS_SIZE >> 3));
wire [28:0] ctrl_addr = slot_base;
wire [28:0] data_addr = slot_base + 1;

// Control address taken straight from ss_slot, because slot_reg is not yet updated
// on the first READ_CTRL cycle.
wire [28:0] new_slot_base = SS_BASE + (ss_slot * (SS_SIZE >> 3));
wire [28:0] new_ctrl_addr = new_slot_base;

assign DDRAM_BURSTCNT = 1;
assign DDRAM_ADDR = ddr_addr;
assign DDRAM_DIN = ddr_data;
assign DDRAM_BE = 8'hFF;

assign ss_busy = (state != IDLE);
// freeze_req stays high through the whole load, including the control write and the
// firmware ack. A gap would release the core before the raster-phase release point.
assign freeze_req = (state == FREEZE_WAIT) ||
                    (state == SAVE_WAIT) || (state == SAVE_CAPTURE) ||
                    (state == SAVE_WRITE) || (state == SAVE_WRITE_WAIT) ||
                    (state == SAVE_CTRL_WRITE) || (state == SAVE_CTRL_WAIT) ||
                    (state == LOAD_READ) || (state == LOAD_READ_WAIT) ||
                    (state == LOAD_DATA_READY) || (state == LOAD_RESTORE) ||
                    (state == LOAD_WRITE_WAIT) ||
                    (state == LOAD_CTRL_WRITE) || (state == LOAD_CTRL_WAIT) ||
                    (state == FW_HOLD);

assign state_addr = word_count;
assign state_wr = (state == SAVE_WAIT) || (state == SAVE_CAPTURE);  // Reading from core
assign state_rd = (state == LOAD_READ) && DDRAM_DOUT_READY;
assign state_dout = state_data_reg;
// Write enable is held for two cycles so every region can latch the data.
assign state_we = (state == LOAD_DATA_READY) || (state == LOAD_RESTORE);


always @(posedge clk) begin
	// Synchronize ss_load and ss_save to clk domain
	ss_load_sync <= {ss_load_sync[0], ss_load};
	ss_save_sync <= {ss_save_sync[0], ss_save};

	DDRAM_RD <= 0;
	DDRAM_WE <= 0;
	data_ready <= 0;
	ss_save_done <= 0;
	ss_load_done <= 0;

	if(reset) begin
		state <= IDLE;
		word_count <= 0;
		change_detector <= 0;
		saved_size <= 0;
		slot_reg <= 0;
		data_buffer <= 0;
		state_data_reg <= 0;
		is_loading <= 0;
		old_ss_save <= 0;
		old_ss_load <= 0;
		timeout_counter <= 0;
		wait_count <= 0;
		cooldown_count <= 0;
		unfreeze_delay <= 0;
		hdr_bad <= 0;
		// Clear DDR3 interface registers to prevent stale data
		ddr_addr <= 0;
		ddr_data <= 0;
	end else begin
		// On timeout, leave through UNFREEZE so the core still gets the settling delay.
		if(state != IDLE && state != COOLDOWN) begin
			timeout_counter <= timeout_counter + 1'd1;
			if(timeout) begin
				state <= UNFREEZE;
				timeout_counter <= 0;
				unfreeze_delay <= 0;
			end
		end else begin
			timeout_counter <= 0;
		end

		// Edge detectors update only in IDLE, so presses during an operation are ignored.
		case(state)
			IDLE: begin
				old_ss_save <= ss_save_sync[1];
				old_ss_load <= ss_load_sync[1];

				if(~old_ss_save & ss_save_sync[1]) begin
					slot_reg <= ss_slot;
					state <= FREEZE_WAIT;
					word_count <= 0;
					timeout_counter <= 0;
					change_detector <= change_detector + 1'd1;
					is_loading <= 0;
				end
				else if(~old_ss_load & ss_load_sync[1]) begin
					slot_reg <= ss_slot;
					hdr_bad <= 0;
					state <= READ_CTRL;
					ddr_addr <= new_ctrl_addr;
					timeout_counter <= 0;
					is_loading <= 1;
				end
			end

			FREEZE_WAIT: begin
				if(freeze_ack) begin
					if(is_loading) begin
						state <= LOAD_READ;
					end else begin
						state <= SAVE_WAIT;
						wait_count <= 0;
					end
					ddr_addr <= data_addr;
					word_count <= 0;
					data_buffer <= 0;
				end
			end

			// Wait for the region read latency of three cycles.
			SAVE_WAIT: begin
				if(wait_count < 2'd3) begin
					wait_count <= wait_count + 1'd1;
				end else if(state_ready) begin
					// state_ready gates the capture, not the counter, so fixed-latency
					// regions keep the four-cycle timing of the Mega Drive core.
					state <= SAVE_CAPTURE;
				end
			end

			// Capture a word and pack pairs into one 64-bit DDR3 write.
			SAVE_CAPTURE: begin
				if(word_count < state_size) begin
					if(word_count[0] == 0) begin
						// First word of the pair is buffered.
						data_buffer[31:0] <= state_din;
						data_ready <= 1;
						word_count <= word_count + 1'd1;
						wait_count <= 0;
						state <= SAVE_WAIT;
					end else begin
						// Second word completes the pair.
						ddr_data[31:0] <= data_buffer[31:0];
						ddr_data[63:32] <= state_din;
						ddr_addr <= data_addr + ((word_count - 1) >> 1);
						state <= SAVE_WRITE;
					end
				end else if(word_count == state_size && state_size[0] == 1) begin
					// Odd state_size: write the last buffered word padded with zero.
					// SAVE_WRITE then moves word_count past state_size.
					ddr_data[31:0] <= data_buffer[31:0];
					ddr_data[63:32] <= 32'h0;
					ddr_addr <= data_addr + (word_count >> 1);
					state <= SAVE_WRITE;
				end else begin
					// All data written. Write the control word.
					state <= SAVE_CTRL_WRITE;
					ddr_addr <= ctrl_addr;
					ddr_data[31:0] <= change_detector;
					ddr_data[63:32] <= word_count;
				end
			end

			SAVE_WRITE: begin
				if(!DDRAM_BUSY) begin
					DDRAM_WE <= 1;
					word_count <= word_count + 1'd1;
					state <= SAVE_WRITE_WAIT;
				end
			end

			SAVE_WRITE_WAIT: begin
				if(!DDRAM_BUSY) begin
					wait_count <= 0;
					state <= SAVE_WAIT;
				end
			end

			SAVE_CTRL_WRITE: begin
				if(!DDRAM_BUSY) begin
					DDRAM_WE <= 1;
					state <= SAVE_CTRL_WAIT;
				end
			end

			SAVE_CTRL_WAIT: begin
				if(!DDRAM_BUSY) begin
					state <= UNFREEZE;
				end
			end

			READ_CTRL: begin
				if(!DDRAM_BUSY) begin
					DDRAM_RD <= 1;
					state <= READ_CTRL_WAIT;
				end
			end

			READ_CTRL_WAIT: begin
				if(DDRAM_DOUT_READY) begin
					change_detector <= DDRAM_DOUT[31:0];
					saved_size <= DDRAM_DOUT[63:32];
					// Abort if the slot is empty or the size is out of range.
					if(DDRAM_DOUT[63:32] == 0 || DDRAM_DOUT[63:32] > SS_SIZE_WORDS) begin
						state <= IDLE;
					end else begin
						state <= FREEZE_WAIT;
						word_count <= 0;
					end
				end
			end

			LOAD_READ: begin
				if(freeze_ack) begin
					if(word_count < saved_size) begin
						if(word_count[0] == 0) begin
							// Even word: read the next pair from DDR3.
							if(!DDRAM_BUSY) begin
								ddr_addr <= data_addr + (word_count >> 1);
								DDRAM_RD <= 1;
								state <= LOAD_READ_WAIT;
							end
						end else begin
							// Odd word: use the buffered upper half.
							state_data_reg <= data_buffer;
							state <= LOAD_DATA_READY;
						end
					end else begin
						// Load complete. Write the control word to notify Main.
						state <= LOAD_CTRL_WRITE;
					end
				end
			end

			LOAD_READ_WAIT: begin
				// No abort when freeze_ack drops. freeze_ack is combinational and can drop
				// briefly while the core stays frozen, and an abort would leave the core
				// half restored. The timeout still catches a stuck transfer.
				if(1'b0) begin
					state <= UNFREEZE;
					unfreeze_delay <= 0;
				end
				else if(DDRAM_DOUT_READY) begin
					// Header check. The first DDR3 read of the payload holds both header words:
					//   DDRAM_DOUT[31:0]  = word 0 = SS_MAGIC, "MCSS"
					//   DDRAM_DOUT[63:32] = word 1 = {SS_VERSION[7:0], SS_FULL_SIZE[23:0]}
					// The size field is 24 bits because the payload is about 262144 words
					// and a 16-bit field would wrap. Any layout change must bump SS_VERSION.
					// No state_we has been issued yet, so a rejected image writes nothing.
					// UNFREEZE skips LOAD_CTRL_WRITE, so the change detector is left as is,
					// and hdr_bad suppresses ss_load_done.
					if(word_count == 0 &&
					   ((DDRAM_DOUT[31:0]  != hdr_magic)         ||
					    (DDRAM_DOUT[63:56] != hdr_version[7:0])  ||
					    (DDRAM_DOUT[55:32] != hdr_size[23:0]))) begin
						hdr_bad <= 1'b1;
						state <= UNFREEZE;
						unfreeze_delay <= 0;
					end else
					begin
						// Even word: output the low half and buffer the high half.
						state_data_reg <= DDRAM_DOUT[31:0];
						data_buffer <= DDRAM_DOUT[63:32];
						state <= LOAD_DATA_READY;
					end
				end
			end

			LOAD_DATA_READY: begin
				// No abort when freeze_ack drops, see LOAD_READ_WAIT.
				if(1'b0) begin
					state <= UNFREEZE;
					unfreeze_delay <= 0;
				end else begin
					// Data is stable in state_data_reg.
					state <= LOAD_RESTORE;
				end
			end

			LOAD_RESTORE: begin
				// No abort when freeze_ack drops, see LOAD_READ_WAIT.
				if(1'b0) begin
					state <= UNFREEZE;
					unfreeze_delay <= 0;
				end else begin
					// state_we is active with stable data and address.
					state <= LOAD_WRITE_WAIT;
				end
			end

			LOAD_WRITE_WAIT: begin
				// No abort when freeze_ack drops, see LOAD_READ_WAIT.
				if(1'b0) begin
					state <= UNFREEZE;
					unfreeze_delay <= 0;
				end else if(state_ready) begin
					// state_ready holds this state until a slow SDRAM region accepts
					// the write.
					word_count <= word_count + 1'd1;
					state <= LOAD_READ;
				end
			end

			LOAD_CTRL_WRITE: begin
				// Writing the control word makes Main show the slot loaded message.
				if(!DDRAM_BUSY) begin
					ddr_addr <= ctrl_addr;
					change_detector <= change_detector + 1'd1;
					ddr_data[31:0] <= change_detector + 1'd1;
					ddr_data[63:32] <= saved_size;
					DDRAM_WE <= 1;
					state <= LOAD_CTRL_WAIT;
				end
			end

			LOAD_CTRL_WAIT: begin
				if(!DDRAM_BUSY) begin
					// Signal the load while the core is still frozen, so Main restores
					// its drive model before the core runs.
					ss_load_done <= ~hdr_bad;
					fw_hold_cnt <= 0;
					state <= FW_HOLD;
				end
			end

			FW_HOLD: begin
				// The core stays frozen here. Release on the Main ack, or after about
				// 0.6 s so that firmware without the ack does not hang the core.
				// The first cycles are skipped because load_hold is a registered copy of
				// ss_load_done and still reads 0 on entry.
				if (fw_hold_cnt > 8 && (!load_hold || fw_hold_cnt[25])) begin
					state <= UNFREEZE;
					unfreeze_delay <= 0;
				end
				else fw_hold_cnt <= fw_hold_cnt + 1'd1;
			end

			UNFREEZE: begin
				// Wait for freeze_ack to drop, then let the core settle.
				if(!freeze_ack) begin
					if(unfreeze_delay < UNFREEZE_CYCLES) begin
						// About 1.2 ms at 53 MHz.
						unfreeze_delay <= unfreeze_delay + 1'd1;
					end else begin
						state <= COOLDOWN;
						cooldown_count <= COOLDOWN_CYCLES;
						unfreeze_delay <= 0;
						// Clear working registers for the next operation.
						word_count <= 0;
						data_buffer <= 0;
						state_data_reg <= 0;
						wait_count <= 0;
						// DDRAM_RD and DDRAM_WE are pulses cleared every cycle.
						ddr_addr <= 0;
						ddr_data <= 0;
					end
				end
			end

			COOLDOWN: begin
				if(cooldown_count > 0)
					cooldown_count <= cooldown_count - 1'd1;
				else begin
					state <= IDLE;
					// Loads pulsed ss_load_done on FW_HOLD entry, so only saves pulse here.
					if(!is_loading)
						ss_save_done <= 1;
				end
			end

			default: state <= IDLE;
		endcase
	end
end

endmodule

