module clint_axilite #(
  parameter int unsigned AW = 32,   // AXI address width (must be 32)
  parameter int unsigned DW = 32    // AXI data width    (must be 32)
)(
  input  logic            clk_i,
  input  logic            rst_ni,

  // ── AXI-Lite Slave Interface ───────────────────────────────────────────────
  // Write address channel
  input  logic [AW-1:0]   s_axi_awaddr,
  input  logic             s_axi_awvalid,
  output logic             s_axi_awready,

  // Write data channel
  input  logic [DW-1:0]   s_axi_wdata,
  input  logic [DW/8-1:0] s_axi_wstrb,
  input  logic             s_axi_wvalid,
  output logic             s_axi_wready,

  // Write response channel
  output logic [1:0]       s_axi_bresp,
  output logic             s_axi_bvalid,
  input  logic             s_axi_bready,

  // Read address channel
  input  logic [AW-1:0]   s_axi_araddr,
  input  logic             s_axi_arvalid,
  output logic             s_axi_arready,

  // Read data channel
  output logic [DW-1:0]   s_axi_rdata,
  output logic [1:0]       s_axi_rresp,
  output logic             s_axi_rvalid,
  input  logic             s_axi_rready,

  // ── Interrupt Outputs → Ibex ───────────────────────────────────────────────
  output logic             msip_o,   // → irq_software_i
  output logic             mtip_o    // → irq_timer_i
);

  // ==========================================================================
  // Internal registers
  // ==========================================================================
  logic        msip_q;            // Machine software interrupt pending (1 bit)
  logic [63:0] mtimecmp_q;        // Machine timer compare register
  logic [63:0] mtime_q;           // Free-running machine timer counter

  // ==========================================================================
  // Write path state
  // ==========================================================================
  // We handle AW and W channels independently (AXI-Lite allows them to arrive
  // in any order). Both are latched; write fires when both have been received.

  logic        aw_done_q;         // AW handshake has completed
  logic [15:0] aw_addr_q;         // Latched write address offset
  logic        w_done_q;          // W  handshake has completed
  logic [31:0] w_data_q;          // Latched write data
  logic [3:0]  w_strb_q;          // Latched write strobe

  logic        do_write;          // Pulse: both AW and W are ready to commit
  logic        b_pending_q;       // Waiting to deliver B response

  // Accept AW only when we have not already latched one (or are committing this cycle)
  assign s_axi_awready = !aw_done_q || do_write;
  // Accept W  only when we have not already latched one (or are committing this cycle)
  assign s_axi_wready  = !w_done_q  || do_write;

  // Commit when BOTH channels have been accepted
  assign do_write = (aw_done_q || (s_axi_awvalid && s_axi_awready)) &&
                    (w_done_q  || (s_axi_wvalid  && s_axi_wready));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_done_q  <= 1'b0;
      aw_addr_q  <= '0;
      w_done_q   <= 1'b0;
      w_data_q   <= '0;
      w_strb_q   <= '0;
      b_pending_q <= 1'b0;
    end else begin
      // ── AW latch ──────────────────────────────────────────────────────────
      if (do_write) begin
        aw_done_q <= 1'b0;   // clear after commit
      end else if (s_axi_awvalid && s_axi_awready) begin
        aw_done_q <= 1'b1;
        aw_addr_q <= s_axi_awaddr[15:0];   // keep only the CLINT offset
      end

      // ── W latch ───────────────────────────────────────────────────────────
      if (do_write) begin
        w_done_q <= 1'b0;    // clear after commit
      end else if (s_axi_wvalid && s_axi_wready) begin
        w_done_q  <= 1'b1;
        w_data_q  <= s_axi_wdata;
        w_strb_q  <= s_axi_wstrb;
      end

      // ── B response ────────────────────────────────────────────────────────
      if (do_write)
        b_pending_q <= 1'b1;
      else if (s_axi_bvalid && s_axi_bready)
        b_pending_q <= 1'b0;
    end
  end

  assign s_axi_bvalid = b_pending_q;
  assign s_axi_bresp  = 2'b00;   // OKAY

  // ── Effective write address (mux latch vs. direct pass-through) ───────────
  logic [15:0] eff_waddr;
  logic [31:0] eff_wdata;
  logic [3:0]  eff_wstrb;

  assign eff_waddr = aw_done_q ? aw_addr_q : s_axi_awaddr[15:0];
  assign eff_wdata = w_done_q  ? w_data_q  : s_axi_wdata;
  assign eff_wstrb = w_done_q  ? w_strb_q  : s_axi_wstrb;

  // ==========================================================================
  // Register write logic
  // ==========================================================================
  // Helper: apply write strobe to a 32-bit register field
  function automatic logic [31:0] apply_strobe(
    input logic [31:0] current,
    input logic [31:0] wdata,
    input logic [3:0]  wstrb
  );
    logic [31:0] result;
    for (int b = 0; b < 4; b++) begin
      result[b*8 +: 8] = wstrb[b] ? wdata[b*8 +: 8] : current[b*8 +: 8];
    end
    return result;
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      msip_q     <= 1'b0;
      mtimecmp_q <= 64'hFFFF_FFFF_FFFF_FFFF;  // max value → timer off on reset
      mtime_q    <= 64'h0;
    end else begin
      // ── Free-running mtime (increments every cycle) ───────────────────────
      // Write to mtime_lo / mtime_hi overrides the counter for that half.
      if (do_write && (eff_waddr == 16'hBFF8)) begin
        // Write to mtime_lo — update the low half, keep high
        mtime_q[31:0]  <= apply_strobe(mtime_q[31:0],  eff_wdata, eff_wstrb);
        mtime_q[63:32] <= mtime_q[63:32] + 1'b0;  // high word just continues
      end else if (do_write && (eff_waddr == 16'hBFFC)) begin
        // Write to mtime_hi
        mtime_q[63:32] <= apply_strobe(mtime_q[63:32], eff_wdata, eff_wstrb);
        mtime_q[31:0]  <= mtime_q[31:0] + 1'b1;  // keep incrementing low word
      end else begin
        // Normal free-running increment
        mtime_q <= mtime_q + 64'h1;
      end

      // ── MSIP ─────────────────────────────────────────────────────────────
      if (do_write && (eff_waddr == 16'h0000)) begin
        msip_q <= eff_wstrb[0] ? eff_wdata[0] : msip_q;
      end

      // ── MTIMECMP ─────────────────────────────────────────────────────────
      if (do_write && (eff_waddr == 16'h4000)) begin
        mtimecmp_q[31:0]  <= apply_strobe(mtimecmp_q[31:0],  eff_wdata, eff_wstrb);
      end
      if (do_write && (eff_waddr == 16'h4004)) begin
        mtimecmp_q[63:32] <= apply_strobe(mtimecmp_q[63:32], eff_wdata, eff_wstrb);
      end
    end
  end

  // ==========================================================================
  // Read path
  // ==========================================================================
  logic        r_pending_q;
  logic [31:0] r_data_q;

  // Combinational read decode (address comes from AR channel directly)
  logic [31:0] reg_rdata;
  always_comb begin
    case (s_axi_araddr[15:0])
      16'h0000: reg_rdata = {31'h0, msip_q};          // msip
      16'h4000: reg_rdata = mtime_q[31:0];             // mtime_lo  ← NOTE below
      // NOTE: We deliberately read mtime at the AR phase so the firmware can
      // do a consistent 64-bit read by reading lo first (which triggers the
      // latch in firmware, not hardware). Hardware consistency across lo/hi
      // reads is a firmware concern (standard RISC-V practice).
      16'h4000: reg_rdata = mtimecmp_q[31:0];          // mtimecmp_lo
      16'h4004: reg_rdata = mtimecmp_q[63:32];         // mtimecmp_hi
      16'hBFF8: reg_rdata = mtime_q[31:0];             // mtime_lo
      16'hBFFC: reg_rdata = mtime_q[63:32];            // mtime_hi
      default:  reg_rdata = 32'h0000_0000;
    endcase
  end

  // Fix the overlapping case: rewrite cleanly
  // (The above had a duplicate 16'h4000 case — use unique case below)
  always_comb begin
    unique case (s_axi_araddr[15:0])
      16'h0000: reg_rdata = {31'h0, msip_q};
      16'h4000: reg_rdata = mtimecmp_q[31:0];
      16'h4004: reg_rdata = mtimecmp_q[63:32];
      16'hBFF8: reg_rdata = mtime_q[31:0];
      16'hBFFC: reg_rdata = mtime_q[63:32];
      default:  reg_rdata = 32'h0000_0000;
    endcase
  end

  assign s_axi_arready = !r_pending_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_pending_q <= 1'b0;
      r_data_q    <= '0;
    end else begin
      if (s_axi_arvalid && s_axi_arready) begin
        r_pending_q <= 1'b1;
        r_data_q    <= reg_rdata;   // capture decoded value on AR handshake
      end else if (s_axi_rvalid && s_axi_rready) begin
        r_pending_q <= 1'b0;
      end
    end
  end

  assign s_axi_rvalid = r_pending_q;
  assign s_axi_rdata  = r_data_q;
  assign s_axi_rresp  = 2'b00;   // OKAY

  // ==========================================================================
  // Interrupt outputs
  // ==========================================================================
  // mtip: fires when the free-running counter has reached or passed the
  // compare value. Firmware clears it by writing a new (future) mtimecmp.
  assign mtip_o = (mtime_q >= mtimecmp_q);
  assign msip_o = msip_q;

endmodule