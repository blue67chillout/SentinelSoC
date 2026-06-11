// =============================================================================
// soc_buffer.sv
// Firmware streaming buffer — sits between Ibex (OBI) and SHA+ED25519 accelerator
//
// Function:
//   1. Accepts firmware words from Ibex via OBI writes (data path)
//   2. Accepts control words from Ibex via OBI writes (control path)
//   3. When buffer full → drives accelerator input port word-by-word
//      (32 words × 1 word/cycle, addr 0→31)
//   4. Drives control signals to accelerator (addr 32–33)
//   5. After accelerator done → exposes output registers (addr 34–49)
//      as readable OBI registers back to Ibex
//   6. CSR plane for buffer status/control accessible via OBI
//
// Accelerator interface timing:
//   - 32 cycles to write one block (addr 0→31, one word per cycle)
//   - 80 cycles processing
//   - 1 cycle done asserts
//   - 113 cycles total per block
//   - Buffer waits for done before accepting next block
//
// Address map within 0x0004_0000 space (addr[11:0]):
//   0x000        — BUF_CTRL     (RW) : soft_reset[0], stream_enable[1], abort[2]
//   0x004        — BUF_STATUS   (RO) : empty[0], full[1], streaming[2], done[3], error[4]
//   0x008        — BUF_FILL_LVL (RO) : words written so far [5:0]
//   0x00C        — BUF_BLK_SIZE (RW) : block size in words, default 32 [5:0]
//   0x010        — IRQ_ENABLE   (RW) : irq_on_full[0], irq_on_done[1], irq_on_error[2]
//   0x014        — IRQ_STATUS   (W1C): full_pending[0], done_pending[1], error_pending[2]
//   0x018        — ACCEL_CTRL   (RW) : first_block[0], last_block[1]
//   0x01C        — MSG_LENGTH   (RW) : message length field sent to accelerator at addr 33
//   0x100–0x17F  — DATA FIFO    (WO) : writes push words into buffer (addr ignored within range)
//   0x200–0x23F  — ACCEL_OUT    (RO) : accelerator output regs (addr 34–49), 16 words
//
// NOTE: SEL_SHA slot kept in decoder — remove if SHA+ED25519 has no
//       additional OBI control registers after wrapper is finalized.
// =============================================================================

module soc_buffer (
  input  logic        clk_i,
  input  logic        rst_ni,

  // -------------------------------------------------------------------------
  // OBI subordinate interface (flat)
  // -------------------------------------------------------------------------
  input  logic        req_i,
  input  logic        we_i,
  input  logic [ 3:0] be_i,
  input  logic [31:0] addr_i,
  input  logic [31:0] wdata_i,
  output logic        gnt_o,
  output logic        rvalid_o,
  output logic [31:0] rdata_o,
  output logic        err_o,

  // -------------------------------------------------------------------------
  // Accelerator interface — custom parallel port
  // -------------------------------------------------------------------------
  output logic [31:0] accel_data_o,   // data to accelerator
  output logic [ 5:0] accel_addr_o,   // address 0-63
  output logic        accel_valid_o,  // write strobe to accelerator
  input  logic [31:0] accel_data_i,   // output data from accelerator (addr 34-49)
  input  logic        accel_done_i,   // accelerator done / crypto_verified

  // -------------------------------------------------------------------------
  // IRQ output → PLIC
  // -------------------------------------------------------------------------
  output logic        irq_o
);

  // --------------------------------------------------------------------------
  // Address offsets
  // --------------------------------------------------------------------------
  localparam logic [11:0] BUF_CTRL_OFF     = 12'h000;
  localparam logic [11:0] BUF_STATUS_OFF   = 12'h004;
  localparam logic [11:0] BUF_FILL_OFF     = 12'h008;
  localparam logic [11:0] BUF_BLK_SIZE_OFF = 12'h00C;
  localparam logic [11:0] IRQ_EN_OFF       = 12'h010;
  localparam logic [11:0] IRQ_STAT_OFF     = 12'h014;
  localparam logic [11:0] ACCEL_CTRL_OFF   = 12'h018;
  localparam logic [11:0] MSG_LEN_OFF      = 12'h01C;
  // 0x100–0x17F : data fifo write region
  // 0x200–0x23F : accelerator output read region (16 words)

  localparam logic [11:0] DATA_FIFO_BASE   = 12'h100;
  localparam logic [11:0] DATA_FIFO_TOP    = 12'h17F;
  localparam logic [11:0] ACCEL_OUT_BASE   = 12'h200;
  localparam logic [11:0] ACCEL_OUT_TOP    = 12'h23F;

  localparam int unsigned MAX_BLK_SIZE     = 32;
  localparam int unsigned ACCEL_OUT_WORDS  = 16;

  // --------------------------------------------------------------------------
  // CSR registers
  // --------------------------------------------------------------------------
  logic        csr_soft_reset;
  logic        csr_stream_enable;
  logic        csr_abort;
  logic [ 5:0] csr_blk_size;        // default 32
  logic        csr_irq_on_full;
  logic        csr_irq_on_done;
  logic        csr_irq_on_error;
  logic        csr_irq_full_pend;
  logic        csr_irq_done_pend;
  logic        csr_irq_error_pend;
  logic        csr_first_block;
  logic        csr_last_block;
  logic [31:0] csr_msg_length;

  // --------------------------------------------------------------------------
  // Data buffer — single block, MAX_BLK_SIZE words
  // --------------------------------------------------------------------------
  logic [31:0] buf_mem [0:MAX_BLK_SIZE-1];
  logic [ 5:0] fill_ptr;            // words written by Ibex
  logic [ 5:0] stream_ptr;          // words sent to accelerator

  // --------------------------------------------------------------------------
  // Accelerator output capture registers (addr 34–49 → indices 0–15)
  // --------------------------------------------------------------------------
  logic [31:0] accel_out_regs [0:ACCEL_OUT_WORDS-1];
  logic        capturing_output;
  logic [ 3:0] cap_ptr;

  // --------------------------------------------------------------------------
  // FSM
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,       // waiting for stream_enable
    FILLING,    // accepting words from Ibex
    STREAMING,  // driving accelerator input port
    CTRL_SEND,  // sending control words (addr 32–33)
    WAITING,    // waiting for accel_done
    CAPTURING,  // reading back accel output registers
    ERROR
  } buf_state_e;

  buf_state_e state_q, state_d;

  // Status signals
  logic buf_empty, buf_full, buf_streaming, buf_done, buf_error;

  assign buf_empty     = (fill_ptr == 6'h0);
  assign buf_full      = (fill_ptr == csr_blk_size);
  assign buf_streaming = (state_q == STREAMING) || (state_q == CTRL_SEND);
  assign buf_done      = (state_q == CAPTURING) || accel_done_i;
  assign buf_error     = (state_q == ERROR);

  // --------------------------------------------------------------------------
  // OBI handshake
  // Stall (gnt=0) only during STREAMING/CTRL_SEND/WAITING — Ibex must not
  // write new data while accelerator is being fed or processing
  // --------------------------------------------------------------------------
  logic obi_stall;
  assign obi_stall = (state_q == STREAMING) ||
                     (state_q == CTRL_SEND)  ||
                     (state_q == WAITING);

  assign gnt_o = req_i & ~obi_stall;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) rvalid_o <= 1'b0;
    else         rvalid_o <= req_i & gnt_o;
  end

  assign err_o = 1'b0;

  // --------------------------------------------------------------------------
  // FSM — next state logic
  // --------------------------------------------------------------------------
  always_comb begin
    state_d = state_q;

    case (state_q)
      IDLE: begin
        if (csr_stream_enable && !csr_soft_reset)
          state_d = FILLING;
      end

      FILLING: begin
        if (csr_abort)
          state_d = ERROR;
        else if (csr_soft_reset)
          state_d = IDLE;
        else if (buf_full)
          state_d = STREAMING;
      end

      STREAMING: begin
        // All data words sent (addr 0 to blk_size-1)
        if (stream_ptr == csr_blk_size)
          state_d = CTRL_SEND;
      end

      CTRL_SEND: begin
        // Sent both control words (addr 32 and 33)
        // stream_ptr reused as ctrl word counter here (32→33)
        if (stream_ptr == 6'd34)
          state_d = WAITING;
      end

      WAITING: begin
        if (csr_abort)
          state_d = ERROR;
        else if (accel_done_i)
          state_d = CAPTURING;
      end

      CAPTURING: begin
        // Read back all 16 output words from accelerator (addr 34–49)
        if (cap_ptr == 4'd15)
          state_d = FILLING; // ready for next block
      end

      ERROR: begin
        if (csr_soft_reset)
          state_d = IDLE;
      end

      default: state_d = IDLE;
    endcase
  end

  // --------------------------------------------------------------------------
  // FSM — registered state + datapath
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= IDLE;
      fill_ptr   <= 6'h0;
      stream_ptr <= 6'h0;
      cap_ptr    <= 4'h0;
      for (int i = 0; i < MAX_BLK_SIZE; i++)
        buf_mem[i] <= 32'h0;
      for (int i = 0; i < ACCEL_OUT_WORDS; i++)
        accel_out_regs[i] <= 32'h0;
    end else begin
      state_q <= state_d;

      // Soft reset clears fill pointer and buffer
      if (csr_soft_reset) begin
        fill_ptr   <= 6'h0;
        stream_ptr <= 6'h0;
        cap_ptr    <= 4'h0;
      end

      // FILLING: accept words from Ibex into buffer
      if (state_q == FILLING && req_i && gnt_o && we_i) begin
        if (addr_i[11:0] >= DATA_FIFO_BASE && addr_i[11:0] <= DATA_FIFO_TOP) begin
          if (fill_ptr < csr_blk_size) begin
            buf_mem[fill_ptr] <= wdata_i;
            fill_ptr          <= fill_ptr + 6'h1;
          end
        end
      end

      // STREAMING: drive accelerator data port addr 0 to blk_size-1
      if (state_q == STREAMING) begin
        if (stream_ptr < csr_blk_size)
          stream_ptr <= stream_ptr + 6'h1;
      end

      // CTRL_SEND: drive control words at addr 32 and 33
      // addr 32: {30'h0, last_block, first_block}
      // addr 33: msg_length
      if (state_q == CTRL_SEND) begin
        if (stream_ptr < 6'd34)
          stream_ptr <= stream_ptr + 6'h1;
      end

      // WAITING → CAPTURING transition: reset cap_ptr
      if (state_q == WAITING && state_d == CAPTURING)
        cap_ptr <= 4'h0;

      // CAPTURING: latch accelerator output words
      if (state_q == CAPTURING) begin
        accel_out_regs[cap_ptr] <= accel_data_i;
        if (cap_ptr < 4'd15)
          cap_ptr <= cap_ptr + 4'h1;
      end

      // Reset stream_ptr when starting a new streaming phase
      if (state_q == FILLING && state_d == STREAMING) begin
        stream_ptr <= 6'h0;
        fill_ptr   <= 6'h0; // clear for next block
      end

      // Reset stream_ptr to 32 when entering CTRL_SEND
      if (state_q == STREAMING && state_d == CTRL_SEND)
        stream_ptr <= 6'd32;
    end
  end

  // --------------------------------------------------------------------------
  // Accelerator output port drive
  // --------------------------------------------------------------------------
  always_comb begin
    accel_data_o  = 32'h0;
    accel_addr_o  = 6'h0;
    accel_valid_o = 1'b0;

    case (state_q)
      STREAMING: begin
        accel_data_o  = buf_mem[stream_ptr];
        accel_addr_o  = stream_ptr;
        accel_valid_o = 1'b1;
      end

      CTRL_SEND: begin
        accel_valid_o = 1'b1;
        accel_addr_o  = stream_ptr; // 32 or 33
        if (stream_ptr == 6'd32)
          accel_data_o = {30'h0, csr_last_block, csr_first_block};
        else
          accel_data_o = csr_msg_length;
      end

      CAPTURING: begin
        // Drive read address to accelerator output bank (34–49)
        accel_addr_o  = 6'd34 + {2'h0, cap_ptr};
        accel_valid_o = 1'b0; // read, not write
        accel_data_o  = 32'h0;
      end

      default: begin
        accel_data_o  = 32'h0;
        accel_addr_o  = 6'h0;
        accel_valid_o = 1'b0;
      end
    endcase
  end

  // --------------------------------------------------------------------------
  // CSR write logic
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      csr_soft_reset    <= 1'b0;
      csr_stream_enable <= 1'b0;
      csr_abort         <= 1'b0;
      csr_blk_size      <= 6'd32;
      csr_irq_on_full   <= 1'b0;
      csr_irq_on_done   <= 1'b0;
      csr_irq_on_error  <= 1'b0;
      csr_irq_full_pend <= 1'b0;
      csr_irq_done_pend <= 1'b0;
      csr_irq_error_pend<= 1'b0;
      csr_first_block   <= 1'b0;
      csr_last_block    <= 1'b0;
      csr_msg_length    <= 32'h0;
    end else begin
      // soft_reset self-clears after one cycle
      csr_soft_reset <= 1'b0;
      csr_abort      <= 1'b0;

      // IRQ pending — set by hardware events
      if (buf_full)       csr_irq_full_pend  <= 1'b1;
      if (accel_done_i)   csr_irq_done_pend  <= 1'b1;
      if (state_q==ERROR) csr_irq_error_pend <= 1'b1;

      // OBI write to CSR plane
      if (req_i && gnt_o && we_i) begin
        case (addr_i[11:0])
          BUF_CTRL_OFF: begin
            if (be_i[0]) begin
              csr_soft_reset    <= wdata_i[0];
              csr_stream_enable <= wdata_i[1];
              csr_abort         <= wdata_i[2];
            end
          end
          BUF_BLK_SIZE_OFF: begin
            if (be_i[0]) csr_blk_size <= wdata_i[5:0];
          end
          IRQ_EN_OFF: begin
            if (be_i[0]) begin
              csr_irq_on_full  <= wdata_i[0];
              csr_irq_on_done  <= wdata_i[1];
              csr_irq_on_error <= wdata_i[2];
            end
          end
          IRQ_STAT_OFF: begin
            // W1C — write 1 to clear pending bits
            if (be_i[0]) begin
              if (wdata_i[0]) csr_irq_full_pend  <= 1'b0;
              if (wdata_i[1]) csr_irq_done_pend  <= 1'b0;
              if (wdata_i[2]) csr_irq_error_pend <= 1'b0;
            end
          end
          ACCEL_CTRL_OFF: begin
            if (be_i[0]) begin
              csr_first_block <= wdata_i[0];
              csr_last_block  <= wdata_i[1];
            end
          end
          MSG_LEN_OFF: begin
            csr_msg_length <= wdata_i;
          end
          default: ; // data fifo writes handled in FSM datapath above
        endcase
      end
    end
  end

  // --------------------------------------------------------------------------
  // CSR read logic
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rdata_o <= 32'h0;
    end else begin
      if (req_i && gnt_o && !we_i) begin
        if (addr_i[11:0] >= ACCEL_OUT_BASE &&
            addr_i[11:0] <= ACCEL_OUT_TOP) begin
          // Accelerator output register read (16 words)
          rdata_o <= accel_out_regs[addr_i[5:2]];
        end else begin
          case (addr_i[11:0])
            BUF_CTRL_OFF: begin
              rdata_o <= {29'h0,
                          csr_abort,
                          csr_stream_enable,
                          csr_soft_reset};
            end
            BUF_STATUS_OFF: begin
              rdata_o <= {27'h0,
                          buf_error,
                          buf_done,
                          buf_streaming,
                          buf_full,
                          buf_empty};
            end
            BUF_FILL_OFF: begin
              rdata_o <= {26'h0, fill_ptr};
            end
            BUF_BLK_SIZE_OFF: begin
              rdata_o <= {26'h0, csr_blk_size};
            end
            IRQ_EN_OFF: begin
              rdata_o <= {29'h0,
                          csr_irq_on_error,
                          csr_irq_on_done,
                          csr_irq_on_full};
            end
            IRQ_STAT_OFF: begin
              rdata_o <= {29'h0,
                          csr_irq_error_pend,
                          csr_irq_done_pend,
                          csr_irq_full_pend};
            end
            ACCEL_CTRL_OFF: begin
              rdata_o <= {30'h0,
                          csr_last_block,
                          csr_first_block};
            end
            MSG_LEN_OFF: begin
              rdata_o <= csr_msg_length;
            end
            default: rdata_o <= 32'hDEAD_BEEF;
          endcase
        end
      end
    end
  end

  // --------------------------------------------------------------------------
  // IRQ generation
  // --------------------------------------------------------------------------
  assign irq_o = (csr_irq_on_full  & csr_irq_full_pend)  |
                 (csr_irq_on_done  & csr_irq_done_pend)  |
                 (csr_irq_on_error & csr_irq_error_pend);

endmodule
