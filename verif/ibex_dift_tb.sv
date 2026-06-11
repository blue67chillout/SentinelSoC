// =============================================================================
// Ibex DIFT Testbench — corrected
//
// Key fixes vs previous version:
//  1. Tag RF path: dut.tag_register_file_i.mem[N]  (not rf_reg[N][0])
//  2. build_preamble was called twice per task, appending a second mtvec +
//     CSR setup block in the middle of the program.  Replaced with a single
//     load_imm32 helper + explicit per-task program construction so every
//     test emits exactly one contiguous instruction stream.
//  3. data_mem/tag_mem initialisation for tests that encode a runtime address
//     (jump/execute-pc tests) is now done AFTER do_reset(), which zeroes
//     those arrays.
//  4. Handler index mapped to 0x400 offset (word 256); mtvec set to
//     BOOT_ADDR + 0x400 = 0x1000_0400.  One handler serves all tests.
//  5. run_program cycle budget raised for multi-cycle tests (M-ext, chains).
// =============================================================================

`ifndef DIFT
  `define DIFT
`endif
`timescale 1ns/1ps

module ibex_dift_tb;
  import ibex_pkg::*;

  // =========================================================================
  // Clock and reset
  // =========================================================================
  localparam CLK_PERIOD = 10;
  logic clk, rst_n;
  initial clk = 0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // =========================================================================
  // Memory parameters
  // =========================================================================
  localparam MEM_DEPTH  = 512;   // instruction memory words
  localparam DMEM_DEPTH = 64;    // data memory words
  localparam logic [31:0] BOOT_ADDR = 32'h1000_0000;
  localparam logic [31:0] DMEM_BASE = 32'h0001_0000;
  // Instruction memory is indexed from 0 but the core fetches from BOOT_ADDR.
  // Word index 0 => byte address BOOT_ADDR.
  // Handler lives at word index 256 => byte address BOOT_ADDR + 0x400.
  localparam int HANDLER_IDX = 256;

  // =========================================================================
  // DUT signals
  // =========================================================================
  logic        instr_req, instr_gnt, instr_rvalid;
  logic [31:0] instr_addr, instr_rdata;
  logic        instr_err;

  logic        data_req, data_gnt, data_rvalid, data_we;
  logic [3:0]  data_be;
  logic [31:0] data_addr, data_wdata, data_rdata;
  logic        data_err;

  logic        dummy_instr_id, dummy_instr_wb;
  logic [4:0]  rf_raddr_a, rf_raddr_b, rf_waddr_wb;
  logic        rf_we_wb;
  logic [31:0] rf_wdata_wb_ecc, rf_rdata_a_ecc, rf_rdata_b_ecc;

  logic [IC_NUM_WAYS-1:0]  ic_tag_req;
  logic                    ic_tag_write;
  logic [IC_INDEX_W-1:0]   ic_tag_addr;
  logic [IC_TAG_SIZE-1:0]  ic_tag_wdata;
  logic [IC_TAG_SIZE-1:0]  ic_tag_rdata [IC_NUM_WAYS];
  logic [IC_NUM_WAYS-1:0]  ic_data_req;
  logic                    ic_data_write;
  logic [IC_INDEX_W-1:0]   ic_data_addr;
  logic [IC_LINE_SIZE-1:0] ic_data_wdata;
  logic [IC_LINE_SIZE-1:0] ic_data_rdata [IC_NUM_WAYS];
  logic                    ic_scr_key_valid, ic_scr_key_req;

  logic        irq_software, irq_timer, irq_external, irq_nm;
  logic [14:0] irq_fast;
  logic        irq_pending;
  logic        debug_req;
  crash_dump_t crash_dump;
  logic        double_fault;
  ibex_mubi_t  fetch_enable;
  logic        alert_minor, alert_major_int, alert_major_bus;
  ibex_mubi_t  core_busy;

  // DIFT
  logic data_rdata_tag, data_wdata_tag, dift_exception;

  // =========================================================================
  // Instruction memory
  // =========================================================================
  localparam logic [31:0] NOP = 32'h0000_0013; // addi x0, x0, 0

  logic [31:0] instr_mem [0:MEM_DEPTH-1];

  assign instr_gnt   = 1'b1;
  assign instr_err   = 1'b0;

  // Translate fetch address to word index; return NOP for out-of-range
  function automatic int imem_idx(input logic [31:0] addr);
    logic [31:0] off;
    off = addr - BOOT_ADDR;
    return (off >> 2);
  endfunction

  always_comb begin
    automatic int idx;
    idx = imem_idx(instr_addr);
    if (instr_addr >= BOOT_ADDR && idx < MEM_DEPTH)
      instr_rdata = instr_mem[idx];
    else
      instr_rdata = NOP;
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) instr_rvalid <= 1'b0;
    else        instr_rvalid <= instr_req;

  // =========================================================================
  // Data memory + tag RAM
  // =========================================================================
  logic [31:0] data_mem  [0:DMEM_DEPTH-1];
  logic        tag_mem   [0:DMEM_DEPTH-1];

  // dmem word index from byte address
  function automatic int dmem_idx_f(input logic [31:0] addr);
    return int'((addr - DMEM_BASE) >> 2);
  endfunction

  assign data_gnt = 1'b1;
  assign data_err = 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_rvalid    <= 1'b0;
      data_rdata     <= 32'h0;
      data_rdata_tag <= 1'b0;
    end else begin
      data_rvalid <= data_req;
      if (data_req) begin
        automatic int di;
        di = dmem_idx_f(data_addr);
        if (data_we && di >= 0 && di < DMEM_DEPTH) begin
          data_mem[di] <= data_wdata;
          tag_mem[di]  <= data_wdata_tag;
        end
        if (!data_we && di >= 0 && di < DMEM_DEPTH) begin
          data_rdata     <= data_mem[di];
          data_rdata_tag <= tag_mem[di];
        end else begin
          data_rdata     <= 32'h0;
          data_rdata_tag <= 1'b0;
        end
      end
    end
  end

  // =========================================================================
  // External register file (no ECC — RegFileECC=0)
  // =========================================================================
  logic [31:0] reg_file [0:31];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 32; i++) reg_file[i] <= 32'h0;
    end else if (rf_we_wb && rf_waddr_wb != 5'd0) begin
      reg_file[rf_waddr_wb] <= rf_wdata_wb_ecc;
    end
  end

  assign rf_rdata_a_ecc = reg_file[rf_raddr_a];
  assign rf_rdata_b_ecc = reg_file[rf_raddr_b];

  // =========================================================================
  // DUT
  // =========================================================================
  ibex_core #(
    .PMPEnable        (1'b0),
    .MHPMCounterNum   (0),
    .RV32M            (RV32MFast),
    .RV32B            (RV32BNone),
    .WritebackStage   (1'b0),
    .BranchTargetALU  (1'b0),
    .ICache           (1'b0),
    .BranchPredictor  (1'b0),
    .DbgTriggerEn     (1'b0),
    .SecureIbex       (1'b0),
    .DummyInstructions(1'b0),
    .RegFileECC       (1'b0),
    .MemECC           (1'b0),
    .ResetAll         (1'b0)
  ) dut (
    .clk_i (clk),
    .rst_ni(rst_n),
    .hart_id_i  (32'h0),
    .boot_addr_i(BOOT_ADDR),

    .instr_req_o    (instr_req),
    .instr_gnt_i    (instr_gnt),
    .instr_rvalid_i (instr_rvalid),
    .instr_addr_o   (instr_addr),
    .instr_rdata_i  (instr_rdata),
    .instr_err_i    (instr_err),

    .data_req_o    (data_req),
    .data_gnt_i    (data_gnt),
    .data_rvalid_i (data_rvalid),
    .data_we_o     (data_we),
    .data_be_o     (data_be),
    .data_addr_o   (data_addr),
    .data_wdata_o  (data_wdata),
    .data_rdata_i  (data_rdata),
    .data_err_i    (data_err),

    .dummy_instr_id_o (dummy_instr_id),
    .dummy_instr_wb_o (dummy_instr_wb),
    .rf_raddr_a_o     (rf_raddr_a),
    .rf_raddr_b_o     (rf_raddr_b),
    .rf_waddr_wb_o    (rf_waddr_wb),
    .rf_we_wb_o       (rf_we_wb),
    .rf_wdata_wb_ecc_o(rf_wdata_wb_ecc),
    .rf_rdata_a_ecc_i (rf_rdata_a_ecc),
    .rf_rdata_b_ecc_i (rf_rdata_b_ecc),

    .ic_tag_req_o      (ic_tag_req),
    .ic_tag_write_o    (ic_tag_write),
    .ic_tag_addr_o     (ic_tag_addr),
    .ic_tag_wdata_o    (ic_tag_wdata),
    .ic_tag_rdata_i    ('{default:'0}),
    .ic_data_req_o     (ic_data_req),
    .ic_data_write_o   (ic_data_write),
    .ic_data_addr_o    (ic_data_addr),
    .ic_data_wdata_o   (ic_data_wdata),
    .ic_data_rdata_i   ('{default:'0}),
    .ic_scr_key_valid_i(1'b1),
    .ic_scr_key_req_o  (ic_scr_key_req),

    .irq_software_i(1'b0),
    .irq_timer_i   (1'b0),
    .irq_external_i(1'b0),
    .irq_fast_i    (15'b0),
    .irq_nm_i      (1'b0),
    .irq_pending_o (irq_pending),

    .debug_req_i        (1'b0),
    .crash_dump_o       (crash_dump),
    .double_fault_seen_o(double_fault),

    .fetch_enable_i        (IbexMuBiOn),
    .alert_minor_o         (alert_minor),
    .alert_major_internal_o(alert_major_int),
    .alert_major_bus_o     (alert_major_bus),
    .core_busy_o           (core_busy),

    .data_rdata_tag_i(data_rdata_tag),
    .data_wdata_tag_o(data_wdata_tag),
    .dift_exception_o(dift_exception)
  );

  // =========================================================================
  // Test infrastructure
  // =========================================================================
  int  test_num;
  int  pass_count, fail_count;
  logic exception_seen;

  task automatic pass_t(input string msg);
    $display("[PASS] Test %0d: %s", test_num, msg);
    pass_count++;
  endtask

  task automatic fail_t(input string msg);
    $display("[FAIL] Test %0d: %s", test_num, msg);
    fail_count++;
  endtask

  // Run for max_cycles, latching any dift_exception pulse
  task automatic run_program(input int max_cycles = 200);
    exception_seen = 1'b0;
    repeat (max_cycles) begin
      @(posedge clk);
      if (dift_exception) exception_seen = 1'b1;
    end
  endtask

  // Hard reset: zero dmem, tag_mem, reg_file; keep instr_mem intact
  task automatic do_reset();
    rst_n = 0;
    for (int i = 0; i < DMEM_DEPTH; i++) data_mem[i] = 32'h0;
    for (int i = 0; i < DMEM_DEPTH; i++) tag_mem[i]  = 1'b0;
    for (int i = 0; i < 32;         i++) reg_file[i] = 32'h0;
    repeat(3) @(posedge clk);
    init_tag_rf();
    rst_n = 1;
    @(posedge clk);
  endtask

  task automatic init_tag_rf();
    for (int i = 0; i < 32; i++) begin
      $deposit(dut.tag_register_file_i.mem[i], 1'b0);
    end
  endtask

  // =========================================================================
  // Instruction encoding helpers
  // =========================================================================
  function automatic logic [31:0] f_rtype(
    input logic [6:0] funct7, input logic [4:0] rs2, rs1, rd,
    input logic [2:0] funct3, input logic [6:0] opcode);
    return {funct7, rs2, rs1, funct3, rd, opcode};
  endfunction

  function automatic logic [31:0] f_itype(
    input logic [11:0] imm, input logic [4:0] rs1, rd,
    input logic [2:0] funct3, input logic [6:0] opcode);
    return {imm, rs1, funct3, rd, opcode};
  endfunction

  function automatic logic [31:0] f_stype(
    input logic [11:0] imm, input logic [4:0] rs2, rs1,
    input logic [2:0] funct3);
    return {imm[11:5], rs2, rs1, funct3, imm[4:0], 7'h23};
  endfunction

  function automatic logic [31:0] f_utype(
    input logic [19:0] imm20, input logic [4:0] rd,
    input logic [6:0] opcode);
    return {imm20, rd, opcode};
  endfunction

  // CSR instructions
  function automatic logic [31:0] f_csrrw (input logic [11:0] csr, input logic [4:0] rs1, rd);
    return {csr, rs1, 3'b001, rd, 7'h73};
  endfunction
  function automatic logic [31:0] f_csrrs (input logic [11:0] csr, input logic [4:0] rs1, rd);
    return {csr, rs1, 3'b010, rd, 7'h73};
  endfunction
  function automatic logic [31:0] f_csrrc (input logic [11:0] csr, input logic [4:0] rs1, rd);
    return {csr, rs1, 3'b011, rd, 7'h73};
  endfunction
  function automatic logic [31:0] f_csrrwi(input logic [11:0] csr, input logic [4:0] uimm, rd);
    return {csr, uimm, 3'b101, rd, 7'h73};
  endfunction

  // Integer instructions
  function automatic logic [31:0] f_addi(input logic [4:0] rd, rs1, input logic [11:0] imm);
    return f_itype(imm, rs1, rd, 3'b000, 7'h13);
  endfunction
  function automatic logic [31:0] f_lui(input logic [4:0] rd, input logic [19:0] imm);
    return f_utype(imm, rd, 7'h37);
  endfunction
  function automatic logic [31:0] f_add(input logic [4:0] rd, rs1, rs2);
    return f_rtype(7'h00, rs2, rs1, rd, 3'b000, 7'h33);
  endfunction
  function automatic logic [31:0] f_or(input logic [4:0] rd, rs1, rs2);
    return f_rtype(7'h00, rs2, rs1, rd, 3'b110, 7'h33);
  endfunction
  function automatic logic [31:0] f_and(input logic [4:0] rd, rs1, rs2);
    return f_rtype(7'h00, rs2, rs1, rd, 3'b111, 7'h33);
  endfunction
  function automatic logic [31:0] f_xor(input logic [4:0] rd, rs1, rs2);
    return f_rtype(7'h00, rs2, rs1, rd, 3'b100, 7'h33);
  endfunction
  function automatic logic [31:0] f_slt(input logic [4:0] rd, rs1, rs2);
    return f_rtype(7'h00, rs2, rs1, rd, 3'b010, 7'h33);
  endfunction
  function automatic logic [31:0] f_sll(input logic [4:0] rd, rs1, rs2);
    return f_rtype(7'h00, rs2, rs1, rd, 3'b001, 7'h33);
  endfunction
  function automatic logic [31:0] f_slli(input logic [4:0] rd, rs1, input logic [4:0] shamt);
    return f_itype({7'b0, shamt}, rs1, rd, 3'b001, 7'h13);
  endfunction
  function automatic logic [31:0] f_srli(input logic [4:0] rd, rs1, input logic [4:0] shamt);
    return f_itype({7'b0, shamt}, rs1, rd, 3'b101, 7'h13);
  endfunction
  function automatic logic [31:0] f_lw(input logic [4:0] rd, rs1, input logic [11:0] imm);
    return f_itype(imm, rs1, rd, 3'b010, 7'h03);
  endfunction
  function automatic logic [31:0] f_sw(input logic [4:0] rs2, rs1, input logic [11:0] imm);
    return f_stype(imm, rs2, rs1, 3'b010);
  endfunction
  function automatic logic [31:0] f_jalr(input logic [4:0] rd, rs1, input logic [11:0] imm);
    return f_itype(imm, rs1, rd, 3'b000, 7'h67);
  endfunction
  function automatic logic [31:0] f_beq(input logic [4:0] rs1, rs2, input logic [12:0] imm);
    return {imm[12], imm[10:5], rs2, rs1, 3'b000, imm[4:1], imm[11], 7'h63};
  endfunction

  // M-extension
  function automatic logic [31:0] f_mul(input logic [4:0] rd, rs1, rs2);
    return f_rtype(7'h01, rs2, rs1, rd, 3'b000, 7'h33);
  endfunction
  function automatic logic [31:0] f_div(input logic [4:0] rd, rs1, rs2);
    return f_rtype(7'h01, rs2, rs1, rd, 3'b100, 7'h33);
  endfunction
  function automatic logic [31:0] f_rem(input logic [4:0] rd, rs1, rs2);
    return f_rtype(7'h01, rs2, rs1, rd, 3'b110, 7'h33);
  endfunction

  localparam logic [31:0] ECALL    = 32'h0000_0073;
  // beq x0,x0,-8  (infinite loop, used in handler)
  localparam logic [31:0] LOOP_INF = 32'hfe000ce3;

  // CSR addresses as plain 12-bit constants (ibex_pkg defines them as enums;
  // these are safe casts for the encoding functions)
  localparam logic [11:0] CSRA_MTVEC = 12'h305;
  localparam logic [11:0] CSRA_TCR   = 12'h7C2;
  localparam logic [11:0] CSRA_TPR   = 12'h7C3;

  // =========================================================================
  // Instruction stream writer
  // =========================================================================
  int pc_wr; // current write index into instr_mem[]

  task automatic emit(input logic [31:0] insn);
    instr_mem[pc_wr++] = insn;
  endtask

  // Load a full 32-bit immediate into register rd, using rd as scratch.
  // Two-instruction sequence: lui + addi (handles sign-extension of imm[11]).
  task automatic load_imm32(input logic [4:0] rd, input logic [31:0] val);
    logic [31:0] hi;
    logic [11:0] lo;
    lo = val[11:0];
    // If bit 11 of lo is set, addi will sign-extend and subtract 4096 from
    // the upper 20; compensate by adding 1 to the upper immediate.
    hi = val[31:12] + (val[11] ? 20'h1 : 20'h0);
    if (hi != 20'h0)
      emit(f_lui(rd, hi));
    else
      emit(f_addi(rd, 5'd0, 12'h0)); // clear rd
    if (lo != 12'h0)
      emit(f_addi(rd, rd, lo));
    else
      emit(f_addi(rd, rd, 12'h0)); // nop-like, keeps rd
  endtask

  // =========================================================================
  // Standard test preamble (written once, reused by all tests)
  //
  // Program layout in instr_mem[]:
  //   [0 .. HANDLER_IDX-1]  : handler + padding (filled once at TB init)
  //   [HANDLER_IDX .. ]     : handler code (infinite loop — traps park here)
  //   Tests start at index 0 and the handler is at HANDLER_IDX.
  //
  // Wait — the core boots at BOOT_ADDR which maps to instr_mem[0].
  // mtvec must point to the handler.  BOOT_ADDR + HANDLER_IDX*4
  //                                 = 0x1000_0000 + 0x400 = 0x1000_0400.
  //
  // Each test:
  //   1. pc_wr = 0 (start of instr_mem)
  //   2. emit_preamble(tpr, tcr) — sets mtvec, programs TPR and TCR
  //   3. emit test body instructions
  //   4. emit ECALL (causes trap; core jumps to handler; handler loops)
  //   5. do_reset() — initialises data/tag/reg memories
  //   6. set data_mem / tag_mem entries for this test
  //   7. run_program(N)
  //   8. check result
  // =========================================================================
  localparam logic [31:0] MTVEC_VAL = BOOT_ADDR + (HANDLER_IDX * 4);

  // Write the standard preamble: set mtvec, write TPR, write TCR.
  // Uses x28 (t3) and x29 (t4) as temporaries — test bodies must not
  // depend on those registers being clean.
  task automatic emit_preamble(input logic [31:0] tpr_val, tcr_val);
    // Set mtvec
    load_imm32(5'd28, MTVEC_VAL);
    emit(f_csrrw(CSRA_MTVEC, 5'd28, 5'd0));
    // Program TPR
    load_imm32(5'd28, tpr_val);
    emit(f_csrrw(CSRA_TPR,   5'd28, 5'd0));
    // Program TCR
    load_imm32(5'd29, tcr_val);
    emit(f_csrrw(CSRA_TCR,   5'd29, 5'd0));
  endtask

  // Write the handler at a fixed location.  Called once during init.
  task automatic write_handler();
    instr_mem[HANDLER_IDX]   = LOOP_INF;
    // fill forward so stray fetches see loops too
    for (int i = HANDLER_IDX+1; i < MEM_DEPTH; i++)
      instr_mem[i] = LOOP_INF;
  endtask

  // =========================================================================
  // Policy helper functions (return TPR / TCR words)
  // =========================================================================

  // Build a TPR with a single 2-bit ALU mode field set at [high:low].
  function automatic logic [31:0] tpr_alu_mode(
    input int low, high, input logic [1:0] mode);
    logic [31:0] v;
    v = 32'h0;
    v[low +: 2] = mode;
    return v;
  endfunction

  // Take a base TPR and OR in the LOADSTORE enable bits.
  function automatic logic [31:0] tpr_set_ls_en(
    input logic [31:0] base,
    input logic en_src_addr, en_src_data, en_dst_addr);
    logic [31:0] v;
    v = base;
    v[LOADSTORE_EN_SOURCE_ADDR] = en_src_addr;
    v[LOADSTORE_EN_SOURCE]      = en_src_data;
    v[LOADSTORE_EN_DEST_ADDR]   = en_dst_addr;
    return v;
  endfunction

  // Standard LOADSTORE TPR: OR propagation, all enable bits set (no dest-addr).
  function automatic logic [31:0] tpr_ls_or();
    return tpr_set_ls_en(tpr_alu_mode(LOADSTORE_LOW, LOADSTORE_HIGH, ALU_MODE_OR),
                         1'b1, 1'b1, 1'b0);
  endfunction

  // Compute expected destination tag given mode and two source tags.
  function automatic logic expected_tag(
    input logic [1:0] mode, input logic ta, tb);
    unique case (mode)
      ALU_MODE_OLD:   return 1'b0;  // RTL keeps OLD=0 at reset; sources untainted
      ALU_MODE_AND:   return ta & tb;
      ALU_MODE_OR:    return ta | tb;
      ALU_MODE_CLEAR: return 1'b0;
      default:        return 1'b0;
    endcase
  endfunction

  // =========================================================================
  // Shorthand: tag RF read (correct hierarchical path)
  // =========================================================================
  // dut.tag_register_file_i is ibex_register_file_latch_tag with DataWidth=1.
  // Its internal array is:  logic [DataWidth-1:0] mem[NUM_WORDS]
  // i.e. logic [0:0] mem[32] — a scalar 1-bit per entry.
  `define TAG_RF(n) dut.tag_register_file_i.mem[n]

  // =========================================================================
  // ======================= INDIVIDUAL TESTS ================================
  // =========================================================================
  //
  // Register conventions inside test bodies:
  //   x10 (a0) — base address of data memory (DMEM_BASE)
  //   x12 (a2), x13 (a3) — loaded values / primary operands
  //   x14 (a4), x15 (a5) — result registers (tag checked here)
  //   x28, x29 — reserved for preamble temporaries
  //
  // All test bodies must emit ECALL as the final instruction so the core
  // traps into the handler and stops retiring instructions.

  // -----------------------------------------------------------------------
  // Test group A: TPR ALU propagation modes (INTEGER, LOGICAL, SHIFT,
  //               COMPARISON).  Sweeps all 4 modes for each class.
  // -----------------------------------------------------------------------

  task automatic tpr_alu_propagation_tests();
    // Each iteration: load two words (tag_mem[0]=1, tag_mem[1]=0), run one
    // ALU op whose class is under test, check tag of result register.

    // Sub-test parameters: {name, class_low, class_high, use_two_src}
    typedef struct {
      string       name;
      int          low, high;
      logic [31:0] insn; // the ALU instruction to emit (built per-mode)
    } cls_t;

    for (int m = 0; m < 4; m++) begin
      automatic logic [1:0] mode = m[1:0];
      automatic logic exp;

      // ---- INTEGER: add x14, x12, x13 ----
      test_num++;
      pc_wr = 0;
      emit_preamble(
        tpr_set_ls_en(tpr_alu_mode(INTEGER_LOW, INTEGER_HIGH, mode),
                      1'b1, 1'b1, 1'b0) | tpr_ls_or(),
        32'h0
      );
      load_imm32(5'd10, DMEM_BASE);
      emit(f_lw(5'd12, 5'd10, 12'h0));
      emit(f_lw(5'd13, 5'd10, 12'h4));
      emit(f_add(5'd14, 5'd12, 5'd13));
      emit(ECALL);
      do_reset();
      tag_mem[0] = 1'b1; data_mem[0] = 32'd1;
      tag_mem[1] = 1'b0; data_mem[1] = 32'd2;
      run_program(150);
      exp = expected_tag(mode, 1'b1, 1'b0);
      if (`TAG_RF(14) === exp) pass_t($sformatf("TPR INTEGER mode=%0d propagation", m));
      else                     fail_t($sformatf("TPR INTEGER mode=%0d propagation (got %b exp %b)",
                                                m, `TAG_RF(14), exp));

      // ---- LOGICAL: or x14, x12, x13 ----
      test_num++;
      pc_wr = 0;
      emit_preamble(
        tpr_set_ls_en(tpr_alu_mode(LOGICAL_LOW, LOGICAL_HIGH, mode),
                      1'b1, 1'b1, 1'b0) | tpr_ls_or(),
        32'h0
      );
      load_imm32(5'd10, DMEM_BASE);
      emit(f_lw(5'd12, 5'd10, 12'h0));
      emit(f_lw(5'd13, 5'd10, 12'h4));
      emit(f_or(5'd14, 5'd12, 5'd13));
      emit(ECALL);
      do_reset();
      tag_mem[0] = 1'b1; data_mem[0] = 32'd3;
      tag_mem[1] = 1'b0; data_mem[1] = 32'd4;
      run_program(150);
      exp = expected_tag(mode, 1'b1, 1'b0);
      if (`TAG_RF(14) === exp) pass_t($sformatf("TPR LOGICAL mode=%0d propagation", m));
      else                     fail_t($sformatf("TPR LOGICAL mode=%0d propagation (got %b exp %b)",
                                                m, `TAG_RF(14), exp));

      // ---- SHIFT: slli x14, x12, 1 (single source) ----
      test_num++;
      pc_wr = 0;
      emit_preamble(
        tpr_set_ls_en(tpr_alu_mode(SHIFT_LOW, SHIFT_HIGH, mode),
                      1'b1, 1'b1, 1'b0) | tpr_ls_or(),
        32'h0
      );
      load_imm32(5'd10, DMEM_BASE);
      emit(f_lw(5'd12, 5'd10, 12'h0));
      emit(f_slli(5'd14, 5'd12, 5'd1));
      emit(ECALL);
      do_reset();
      tag_mem[0] = 1'b1; data_mem[0] = 32'd5;
      run_program(150);
      // Immediate shifts have no rs2; second source tag is 0.
      exp = expected_tag(mode, 1'b1, 1'b0);
      if (`TAG_RF(14) === exp) pass_t($sformatf("TPR SHIFT mode=%0d propagation", m));
      else                     fail_t($sformatf("TPR SHIFT mode=%0d propagation (got %b exp %b)",
                                                m, `TAG_RF(14), exp));

      // ---- COMPARISON: slt x14, x12, x13 ----
      test_num++;
      pc_wr = 0;
      emit_preamble(
        tpr_set_ls_en(tpr_alu_mode(COMPARISON_LOW, COMPARISON_HIGH, mode),
                      1'b1, 1'b1, 1'b0) | tpr_ls_or(),
        32'h0
      );
      load_imm32(5'd10, DMEM_BASE);
      emit(f_lw(5'd12, 5'd10, 12'h0));
      emit(f_lw(5'd13, 5'd10, 12'h4));
      emit(f_slt(5'd14, 5'd12, 5'd13));
      emit(ECALL);
      do_reset();
      tag_mem[0] = 1'b1; data_mem[0] = 32'd1;
      tag_mem[1] = 1'b0; data_mem[1] = 32'd2;
      run_program(150);
      exp = expected_tag(mode, 1'b1, 1'b0);
      if (`TAG_RF(14) === exp) pass_t($sformatf("TPR COMPARISON mode=%0d propagation", m));
      else                     fail_t($sformatf("TPR COMPARISON mode=%0d propagation (got %b exp %b)",
                                                m, `TAG_RF(14), exp));
    end
  endtask

  // -----------------------------------------------------------------------
  // Test group B: TPR LOADSTORE mode — load destination tag propagation
  //   tag_mem[0]=1 (tainted word), verify tag of destination register x12.
  //   For ALU_MODE_OR: exp = 0(addr_tag) | 1(data_tag) = 1.
  //   For ALU_MODE_AND: exp = 0 & 1 = 0.
  //   For ALU_MODE_OLD / CLEAR: exp = 0.
  // -----------------------------------------------------------------------
  task automatic tpr_load_propagation_tests();
    for (int m = 0; m < 4; m++) begin
      automatic logic [1:0] mode = m[1:0];
      automatic logic exp;
      test_num++;
      pc_wr = 0;
      emit_preamble(
        tpr_set_ls_en(tpr_alu_mode(LOADSTORE_LOW, LOADSTORE_HIGH, mode),
                      1'b1, 1'b1, 1'b0),
        32'h0
      );
      load_imm32(5'd10, DMEM_BASE);
      emit(f_lw(5'd12, 5'd10, 12'h0));
      emit(ECALL);
      do_reset();
      tag_mem[0] = 1'b1; data_mem[0] = 32'd9;
      run_program(150);
      // addr tag of base x10 = 0 (loaded from clean immediate), data tag = 1
      exp = expected_tag(mode, 1'b0, 1'b1);
      if (`TAG_RF(12) === exp) pass_t($sformatf("TPR LOAD mode=%0d destination tag", m));
      else                     fail_t($sformatf("TPR LOAD mode=%0d destination tag (got %b exp %b)",
                                                m, `TAG_RF(12), exp));
    end
  endtask

  // -----------------------------------------------------------------------
  // Test group C: TPR LOADSTORE — store propagates tag to shadow RAM
  //   Load tainted word into x12, store it; verify tag_mem[1].
  // -----------------------------------------------------------------------
  task automatic tpr_store_propagation_test();
    test_num++;
    pc_wr = 0;
    // en_dst_addr=1 so store data tag propagates to shadow RAM
    emit_preamble(
      tpr_set_ls_en(tpr_alu_mode(LOADSTORE_LOW, LOADSTORE_HIGH, ALU_MODE_OR),
                    1'b1, 1'b1, 1'b1),
      32'h0
    );
    load_imm32(5'd10, DMEM_BASE);
    emit(f_lw(5'd12, 5'd10, 12'h0));      // load tainted word
    emit(f_sw(5'd12, 5'd10, 12'h4));      // store it to dmem[1]
    emit(ECALL);
    do_reset();
    tag_mem[0] = 1'b1; data_mem[0] = 32'hDEAD_BEEF;
    tag_mem[1] = 1'b0; data_mem[1] = 32'h0;
    run_program(150);
    if (tag_mem[1] === 1'b1) pass_t("Store propagates tag to shadow RAM");
    else                     fail_t("Store propagates tag to shadow RAM");
  endtask

  // -----------------------------------------------------------------------
  // Test group D: TCR checks — ALU instructions
  //   Each test enables exactly one TCR check bit and verifies that a
  //   dift_exception fires when that condition is met.
  //   Also verifies the negative case: no exception when the tagged source
  //   doesn't match the enabled check.
  // -----------------------------------------------------------------------

  // Helper: one TCR ALU check test.
  // check_bit  — which TCR bit to enable
  // insn       — the instruction word to execute
  // tag_a/b    — tags of source registers (x12=rs1, x13=rs2 for 2-src;
  //              for 1-src (shift-imm), tag_b is ignored)
  // expect_exc — should dift_exception fire?
  // msg        — test name
  task automatic tcr_alu_check(
    input int          check_bit,
    input logic [31:0] insn,
    input logic        tag_a, tag_b,
    input logic        expect_exc,
    input string       msg
  );
    test_num++;
    pc_wr = 0;
    emit_preamble(
      tpr_ls_or(),
      32'h1 << check_bit
    );
    load_imm32(5'd10, DMEM_BASE);
    emit(f_lw(5'd12, 5'd10, 12'h0));   // x12 = data_mem[0], tag from tag_mem[0]
    emit(f_lw(5'd13, 5'd10, 12'h4));   // x13 = data_mem[1], tag from tag_mem[1]
    emit(insn);
    emit(ECALL);
    do_reset();
    tag_mem[0] = tag_a; data_mem[0] = 32'd1;
    tag_mem[1] = tag_b; data_mem[1] = 32'd2;
    run_program(150);
    if (exception_seen === expect_exc) pass_t(msg);
    else                               fail_t({msg, expect_exc ? " (expected exception)" :
                                                                 " (expected no exception)"});
  endtask

  task automatic tcr_alu_tests();
    // INTEGER checks
    // S1 tainted, S2 clean => S1 check fires
    tcr_alu_check(INTEGER_CHECK_S1, f_add(5'd14,5'd12,5'd13), 1'b1,1'b0, 1'b1,
                  "TCR INTEGER_CHECK_S1: S1 tainted fires");
    // S1 clean, S2 clean => S1 check silent
    tcr_alu_check(INTEGER_CHECK_S1, f_add(5'd14,5'd12,5'd13), 1'b0,1'b0, 1'b0,
                  "TCR INTEGER_CHECK_S1: both clean no exception");
    // S2 tainted fires
    tcr_alu_check(INTEGER_CHECK_S2, f_add(5'd14,5'd12,5'd13), 1'b0,1'b1, 1'b1,
                  "TCR INTEGER_CHECK_S2: S2 tainted fires");
    // dest check: S1 tainted => result tainted (OR mode) => D check fires
    tcr_alu_check(INTEGER_CHECK_D,  f_add(5'd14,5'd12,5'd13), 1'b1,1'b0, 1'b1,
                  "TCR INTEGER_CHECK_D: tainted result fires");

    // LOGICAL checks
    tcr_alu_check(LOGICAL_CHECK_S1, f_or(5'd14,5'd12,5'd13),  1'b1,1'b0, 1'b1,
                  "TCR LOGICAL_CHECK_S1: S1 tainted fires");
    tcr_alu_check(LOGICAL_CHECK_S2, f_xor(5'd14,5'd12,5'd13), 1'b0,1'b1, 1'b1,
                  "TCR LOGICAL_CHECK_S2: S2 tainted fires");
    tcr_alu_check(LOGICAL_CHECK_D,  f_and(5'd14,5'd12,5'd13), 1'b1,1'b0, 1'b1,
                  "TCR LOGICAL_CHECK_D: tainted result fires");

    // SHIFT checks (slli has no rs2; tag_b unused; SHIFT_CHECK_S2 uses
    // register-shift sll where rs2 is the shift amount)
    tcr_alu_check(SHIFT_CHECK_S1, f_slli(5'd14,5'd12,5'd1), 1'b1,1'b0, 1'b1,
                  "TCR SHIFT_CHECK_S1: slli S1 tainted fires");
    tcr_alu_check(SHIFT_CHECK_S2, f_sll(5'd14,5'd12,5'd13), 1'b0,1'b1, 1'b1,
                  "TCR SHIFT_CHECK_S2: sll S2 (shift amt) tainted fires");
    tcr_alu_check(SHIFT_CHECK_D,  f_slli(5'd14,5'd12,5'd1), 1'b1,1'b0, 1'b1,
                  "TCR SHIFT_CHECK_D: tainted result fires");

    // COMPARISON checks
    tcr_alu_check(COMPARISON_CHECK_S1, f_slt(5'd14,5'd12,5'd13), 1'b1,1'b0, 1'b1,
                  "TCR COMPARISON_CHECK_S1: S1 tainted fires");
    tcr_alu_check(COMPARISON_CHECK_S2, f_slt(5'd14,5'd12,5'd13), 1'b0,1'b1, 1'b1,
                  "TCR COMPARISON_CHECK_S2: S2 tainted fires");
    tcr_alu_check(COMPARISON_CHECK_D,  f_slt(5'd14,5'd12,5'd13), 1'b1,1'b0, 1'b1,
                  "TCR COMPARISON_CHECK_D: tainted result fires");
  endtask

  // -----------------------------------------------------------------------
  // Test group E: TCR BRANCH checks
  //   beq x12, x13, +4
  //   BRANCH_CHECK_S1 fires when rs1 (x12) is tainted.
  //   BRANCH_CHECK_S2 fires when rs2 (x13) is tainted.
  //   The branch taken/not-taken does not affect whether the check fires —
  //   the check is on the operands, not the outcome.
  // -----------------------------------------------------------------------
  task automatic tcr_branch_tests();
    // S1 tainted: check fires regardless of branch outcome
    test_num++;
    pc_wr = 0;
    emit_preamble(tpr_ls_or(), 32'h1 << BRANCH_CHECK_S1);
    load_imm32(5'd10, DMEM_BASE);
    emit(f_lw(5'd12, 5'd10, 12'h0));
    emit(f_lw(5'd13, 5'd10, 12'h4));
    emit(f_beq(5'd12, 5'd13, 13'h4)); // branch +4 (next instruction)
    emit(ECALL);
    do_reset();
    tag_mem[0] = 1'b1; data_mem[0] = 32'd1; // x12 tainted, values equal => taken
    tag_mem[1] = 1'b0; data_mem[1] = 32'd1;
    run_program(150);
    if (exception_seen) pass_t("TCR BRANCH_CHECK_S1: S1 tainted fires (branch taken)");
    else                fail_t("TCR BRANCH_CHECK_S1: S1 tainted fires (branch taken)");

    // S1 tainted, branch not taken (values differ)
    test_num++;
    pc_wr = 0;
    emit_preamble(tpr_ls_or(), 32'h1 << BRANCH_CHECK_S1);
    load_imm32(5'd10, DMEM_BASE);
    emit(f_lw(5'd12, 5'd10, 12'h0));
    emit(f_lw(5'd13, 5'd10, 12'h4));
    emit(f_beq(5'd12, 5'd13, 13'h4));
    emit(ECALL);
    do_reset();
    tag_mem[0] = 1'b1; data_mem[0] = 32'd1; // x12 tainted, values differ => not taken
    tag_mem[1] = 1'b0; data_mem[1] = 32'd2;
    run_program(150);
    if (exception_seen) pass_t("TCR BRANCH_CHECK_S1: S1 tainted fires (branch not taken)");
    else                fail_t("TCR BRANCH_CHECK_S1: S1 tainted fires (branch not taken)");

    // S2 tainted
    test_num++;
    pc_wr = 0;
    emit_preamble(tpr_ls_or(), 32'h1 << BRANCH_CHECK_S2);
    load_imm32(5'd10, DMEM_BASE);
    emit(f_lw(5'd12, 5'd10, 12'h0));
    emit(f_lw(5'd13, 5'd10, 12'h4));
    emit(f_beq(5'd12, 5'd13, 13'h4));
    emit(ECALL);
    do_reset();
    tag_mem[0] = 1'b0; data_mem[0] = 32'd1;
    tag_mem[1] = 1'b1; data_mem[1] = 32'd1; // x13 tainted
    run_program(150);
    if (exception_seen) pass_t("TCR BRANCH_CHECK_S2: S2 tainted fires");
    else                fail_t("TCR BRANCH_CHECK_S2: S2 tainted fires");

    // Neither tainted: no exception
    test_num++;
    pc_wr = 0;
    emit_preamble(tpr_ls_or(),
                  (32'h1 << BRANCH_CHECK_S1) | (32'h1 << BRANCH_CHECK_S2));
    load_imm32(5'd10, DMEM_BASE);
    emit(f_lw(5'd12, 5'd10, 12'h0));
    emit(f_lw(5'd13, 5'd10, 12'h4));
    emit(f_beq(5'd12, 5'd13, 13'h4));
    emit(ECALL);
    do_reset();
    tag_mem[0] = 1'b0; data_mem[0] = 32'd1;
    tag_mem[1] = 1'b0; data_mem[1] = 32'd1;
    run_program(150);
    if (!exception_seen) pass_t("TCR BRANCH checks: both clean no exception");
    else                 fail_t("TCR BRANCH checks: both clean no exception");
  endtask

  // -----------------------------------------------------------------------
  // Test group F: TCR JUMP checks (JALR)
  //   JUMP_CHECK_S1 — rs1 (the base register) is tainted => exception
  //   JUMP_CHECK_D  — rd (return address) tag would be tainted
  //                   (rd tag = PC tag; PC is clean => normally no exception)
  //                   To make JUMP_CHECK_D fire we need a tainted PC.
  //                   Instead test: use OR mode for JUMP to propagate rs1
  //                   tag to rd, then enable JUMP_CHECK_D.
  // -----------------------------------------------------------------------
  task automatic tcr_jump_tests();
    automatic logic [31:0] ecall_addr;
    automatic int          ecall_idx;

    // JUMP_CHECK_S1: rs1 (jump target address register) is tainted => exception
    test_num++;
    pc_wr = 0;
    emit_preamble(
      tpr_ls_or() | tpr_alu_mode(JUMP_LOW, JUMP_HIGH, ALU_MODE_OR),
      32'h1 << JUMP_CHECK_S1
    );
    load_imm32(5'd10, DMEM_BASE);
    emit(f_lw(5'd12, 5'd10, 12'h0));  // x12 = tainted jump target
    // We need x12 to hold a valid fetch address so the jump itself doesn't
    // cause a bus error.  Set data_mem[0] = ECALL instruction address.
    // The ecall_idx is pc_wr after the jalr + ecall are emitted.
    emit(f_jalr(5'd14, 5'd12, 12'h0)); // jump to address in x12
    ecall_idx = pc_wr;
    emit(ECALL);
    do_reset();
    tag_mem[0] = 1'b1;
    data_mem[0] = BOOT_ADDR + (ecall_idx * 4); // jump to ECALL
    run_program(200);
    if (exception_seen) pass_t("TCR JUMP_CHECK_S1: tainted rs1 fires");
    else                fail_t("TCR JUMP_CHECK_S1: tainted rs1 fires");

    // JUMP_CHECK_S1 negative: rs1 clean => no exception
    test_num++;
    pc_wr = 0;
    emit_preamble(
      tpr_ls_or(),
      32'h1 << JUMP_CHECK_S1
    );
    load_imm32(5'd10, DMEM_BASE);
    emit(f_lw(5'd12, 5'd10, 12'h0));
    emit(f_jalr(5'd14, 5'd12, 12'h0));
    ecall_idx = pc_wr;
    emit(ECALL);
    do_reset();
    tag_mem[0] = 1'b0;
    data_mem[0] = BOOT_ADDR + (ecall_idx * 4);
    run_program(200);
    if (!exception_seen) pass_t("TCR JUMP_CHECK_S1: clean rs1 no exception");
    else                 fail_t("TCR JUMP_CHECK_S1: clean rs1 no exception");
  endtask

  // -----------------------------------------------------------------------
  // Test group G: TCR LOADSTORE checks
  // -----------------------------------------------------------------------
  task automatic tcr_loadstore_tests();
    // LOADSTORE_CHECK_D (bit 8): exception when loaded word's dest tag is 1
    // i.e. the tainted data lands in a register under a check.
    // With OR mode, load of tag_mem[0]=1 gives dest tag=1 => fires.
    test_num++;
    pc_wr = 0;
    emit_preamble(
      tpr_ls_or(),
      32'h1 << LOADSTORE_CHECK_D
    );
    load_imm32(5'd10, DMEM_BASE);
    emit(f_lw(5'd12, 5'd10, 12'h0));
    emit(ECALL);
    do_reset();
    tag_mem[0] = 1'b1; data_mem[0] = 32'd12;
    run_program(150);
    if (exception_seen) pass_t("TCR LOADSTORE_CHECK_D: tainted load dest fires");
    else                fail_t("TCR LOADSTORE_CHECK_D: tainted load dest fires");

    // LOADSTORE_CHECK_SA (bit 21): exception when load base address register
    // is tainted.  x10 is loaded from a tainted source so it gets tainted;
    // the second lw uses x10 as base.
    test_num++;
    pc_wr = 0;
    emit_preamble(
      tpr_ls_or(),
      32'h1 << LOADSTORE_CHECK_SA
    );
    load_imm32(5'd11, DMEM_BASE);
    emit(f_lw(5'd10, 5'd11, 12'h0));   // x10 = tainted address value
    emit(f_lw(5'd12, 5'd10, 12'h0));   // load using tainted base => SA check
    emit(ECALL);
    do_reset();
    tag_mem[0] = 1'b1; data_mem[0] = DMEM_BASE; // x10 gets this tainted value
    run_program(150);
    if (exception_seen) pass_t("TCR LOADSTORE_CHECK_SA: tainted load address fires");
    else                fail_t("TCR LOADSTORE_CHECK_SA: tainted load address fires");

    // LOADSTORE_CHECK_S (bit 7): exception when store data is tainted.
    test_num++;
    pc_wr = 0;
    emit_preamble(
      tpr_set_ls_en(tpr_alu_mode(LOADSTORE_LOW, LOADSTORE_HIGH, ALU_MODE_OR),
                    1'b1, 1'b1, 1'b1),
      32'h1 << LOADSTORE_CHECK_S
    );
    load_imm32(5'd10, DMEM_BASE);
    emit(f_lw(5'd12, 5'd10, 12'h0));   // x12 = tainted
    emit(f_sw(5'd12, 5'd10, 12'h4));   // store tainted data => S check
    emit(ECALL);
    do_reset();
    tag_mem[0] = 1'b1; data_mem[0] = 32'd11;
    run_program(150);
    if (exception_seen) pass_t("TCR LOADSTORE_CHECK_S: tainted store data fires");
    else                fail_t("TCR LOADSTORE_CHECK_S: tainted store data fires");

    // LOADSTORE_CHECK_DA (bit 6): exception when store base address register
    // is tainted.  Load a tainted address into x10, use x10 as store base.
    test_num++;
    pc_wr = 0;
    emit_preamble(
      tpr_ls_or(),
      32'h1 << LOADSTORE_CHECK_DA
    );
    load_imm32(5'd11, DMEM_BASE);
    emit(f_lw(5'd10, 5'd11, 12'h0));   // x10 = tainted address value
    emit(f_lw(5'd12, 5'd11, 12'h4));   // x12 = clean data to store
    emit(f_sw(5'd12, 5'd10, 12'h0));   // store with tainted base => DA check
    emit(ECALL);
    do_reset();
    tag_mem[0] = 1'b1; data_mem[0] = DMEM_BASE + 8; // x10 = valid tainted addr
    tag_mem[1] = 1'b0; data_mem[1] = 32'd99;
    run_program(150);
    if (exception_seen) pass_t("TCR LOADSTORE_CHECK_DA: tainted store address fires");
    else                fail_t("TCR LOADSTORE_CHECK_DA: tainted store address fires");
  endtask

  // -----------------------------------------------------------------------
  // Test group H: EXECUTE_PC violation
  //   The core fires a pc_exception when pc_id_tag=1 and TCR[EXECUTE_PC]=1.
  //   pc_id_tag is set when a JALR with JUMP TPR=OR propagates a tainted
  //   rs1 tag to the PC destination.
  //   Flow:
  //     1. Load tainted address into x12.
  //     2. jalr x0, x12, 0  — jumps to ecall; the PC at ecall is tainted.
  //     3. At the ecall instruction the core has pc_id_tag=1, fires exception.
  // -----------------------------------------------------------------------
  task automatic execute_pc_test();
    automatic int ecall_idx;
    test_num++;
    pc_wr = 0;
    emit_preamble(
      tpr_ls_or() | tpr_alu_mode(JUMP_LOW, JUMP_HIGH, ALU_MODE_OR),
      32'h1 << EXECUTE_PC
    );
    load_imm32(5'd11, DMEM_BASE);
    emit(f_lw(5'd12, 5'd11, 12'h0));     // x12 = tainted jump target
    emit(f_jalr(5'd0,  5'd12, 12'h0));   // jump; PC now tainted
    ecall_idx = pc_wr;
    emit(ECALL);                          // this instruction has tainted PC => exception
    do_reset();
    tag_mem[0] = 1'b1;
    data_mem[0] = BOOT_ADDR + (ecall_idx * 4);
    run_program(200);
    if (exception_seen) pass_t("EXECUTE_PC: tainted PC fires exception");
    else                fail_t("EXECUTE_PC: tainted PC fires exception");
  endtask

  // -----------------------------------------------------------------------
  // Test group I: CSR read/write paths (TPR and TCR)
  //   Write known values via csrrw/csrrs/csrrc/csrrwi, read back and compare.
  //   No DIFT policy is exercised here; this is a functional CSR path test.
  // -----------------------------------------------------------------------
  task automatic csr_path_test();
    test_num++;
    pc_wr = 0;
    // No DIFT policy — TPR=0, TCR=0.  mtvec still needs setting.
    load_imm32(5'd28, MTVEC_VAL);
    emit(f_csrrw(CSRA_MTVEC, 5'd28, 5'd0));

    // TPR: csrrwi TPR, uimm=0x15, rd=x0  => TPR = 0x15
    //      csrrs  TPR, x5=0x0A,   rd=x0  => TPR = 0x1F
    //      csrrc  TPR, x6=0x05,   rd=x0  => TPR = 0x1A
    //      csrrs  TPR, x0,        rd=x7  => x7 = 0x1A (read-only op)
    emit(f_csrrwi(CSRA_TPR, 5'h15, 5'd0));
    emit(f_addi(5'd5, 5'd0, 12'h00A));
    emit(f_csrrs(CSRA_TPR, 5'd5, 5'd0));
    emit(f_addi(5'd6, 5'd0, 12'h005));
    emit(f_csrrc(CSRA_TPR, 5'd6, 5'd0));
    emit(f_csrrs(CSRA_TPR, 5'd0, 5'd7));  // x7 <- TPR

    // TCR: csrrw TCR, x5=0x3F, rd=x0  => TCR = 0x3F
    //      csrrc TCR, x6=0x05, rd=x0  => TCR = 0x3A
    //      csrrs TCR, x0,      rd=x8  => x8 = 0x3A
    emit(f_addi(5'd5, 5'd0, 12'h03F));
    emit(f_csrrw(CSRA_TCR, 5'd5, 5'd0));
    emit(f_addi(5'd6, 5'd0, 12'h005));
    emit(f_csrrc(CSRA_TCR, 5'd6, 5'd0));
    emit(f_csrrs(CSRA_TCR, 5'd0, 5'd8)); // x8 <- TCR

    emit(ECALL);
    do_reset();
    run_program(250);
    if (reg_file[7] == 32'h0000_001A && reg_file[8] == 32'h0000_003A)
      pass_t("CSR path: csrrw/csrrs/csrrc/csrrwi TPR and TCR readback");
    else
      fail_t($sformatf("CSR path: x7=%0h (exp 1A)  x8=%0h (exp 3A)",
                        reg_file[7], reg_file[8]));
  endtask

  // -----------------------------------------------------------------------
  // Test group J: M-extension — mul/div/rem tag propagation and check
  //   MUL/DIV/REM fall into the INTEGER TPR slot (same ALU class).
  // -----------------------------------------------------------------------
  task automatic m_ext_tests();
    // Sweep all 4 INTEGER modes for MUL
    for (int m = 0; m < 4; m++) begin
      automatic logic [1:0] mode = m[1:0];
      automatic logic exp;
      test_num++;
      pc_wr = 0;
      emit_preamble(
        tpr_set_ls_en(tpr_alu_mode(INTEGER_LOW, INTEGER_HIGH, mode),
                      1'b1, 1'b1, 1'b0) | tpr_ls_or(),
        32'h0
      );
      load_imm32(5'd10, DMEM_BASE);
      emit(f_lw(5'd12, 5'd10, 12'h0));
      emit(f_lw(5'd13, 5'd10, 12'h4));
      emit(f_mul(5'd14, 5'd12, 5'd13));
      emit(ECALL);
      do_reset();
      tag_mem[0] = 1'b1; data_mem[0] = 32'd3;
      tag_mem[1] = 1'b0; data_mem[1] = 32'd2;
      run_program(250);
      exp = expected_tag(mode, 1'b1, 1'b0);
      if (`TAG_RF(14) === exp) pass_t($sformatf("M-ext MUL INTEGER mode=%0d tag", m));
      else                     fail_t($sformatf("M-ext MUL INTEGER mode=%0d tag (got %b exp %b)",
                                                m, `TAG_RF(14), exp));
    end

    // DIV and REM with OR mode: both results should be tainted when S1 is tainted
    test_num++;
    pc_wr = 0;
    emit_preamble(
      tpr_set_ls_en(tpr_alu_mode(INTEGER_LOW, INTEGER_HIGH, ALU_MODE_OR),
                    1'b1, 1'b1, 1'b0) | tpr_ls_or(),
      32'h0
    );
    load_imm32(5'd10, DMEM_BASE);
    emit(f_lw(5'd12, 5'd10, 12'h0));
    emit(f_lw(5'd13, 5'd10, 12'h4));
    emit(f_div(5'd14, 5'd12, 5'd13));
    emit(f_rem(5'd15, 5'd12, 5'd13));
    emit(ECALL);
    do_reset();
    tag_mem[0] = 1'b1; data_mem[0] = 32'd9;
    tag_mem[1] = 1'b0; data_mem[1] = 32'd3;
    run_program(350);
    if (`TAG_RF(14) === 1'b1 && `TAG_RF(15) === 1'b1)
      pass_t("M-ext DIV/REM OR propagation: both results tainted");
    else
      fail_t($sformatf("M-ext DIV/REM OR: div_tag=%b rem_tag=%b (both exp 1)",
                        `TAG_RF(14), `TAG_RF(15)));

    // INTEGER_CHECK_D with MUL: should fire when result is tainted
    test_num++;
    pc_wr = 0;
    emit_preamble(
      tpr_set_ls_en(tpr_alu_mode(INTEGER_LOW, INTEGER_HIGH, ALU_MODE_OR),
                    1'b1, 1'b1, 1'b0) | tpr_ls_or(),
      32'h1 << INTEGER_CHECK_D
    );
    load_imm32(5'd10, DMEM_BASE);
    emit(f_lw(5'd12, 5'd10, 12'h0));
    emit(f_lw(5'd13, 5'd10, 12'h4));
    emit(f_mul(5'd14, 5'd12, 5'd13));
    emit(ECALL);
    do_reset();
    tag_mem[0] = 1'b1; data_mem[0] = 32'd6;
    tag_mem[1] = 1'b0; data_mem[1] = 32'd2;
    run_program(250);
    if (exception_seen) pass_t("M-ext MUL INTEGER_CHECK_D exception fires");
    else                fail_t("M-ext MUL INTEGER_CHECK_D exception fires");
  endtask

  // =========================================================================
  // MAIN
  // =========================================================================
  initial begin
    $timeformat(-9, 1, "ns", 8);
    pass_count = 0;
    fail_count = 0;
    test_num   = 0;

    // Initialise entire instruction memory to NOP, then write handler
    for (int i = 0; i < MEM_DEPTH; i++) instr_mem[i] = NOP;
    write_handler();

    rst_n = 0;
    repeat(3) @(posedge clk);

    // Run all test groups
    tpr_alu_propagation_tests();   // A: 16 tests (4 modes x 4 classes)
    tpr_load_propagation_tests();  // B:  4 tests
    tpr_store_propagation_test();  // C:  1 test
    tcr_alu_tests();               // D: 13 tests
    tcr_branch_tests();            // E:  4 tests
    tcr_jump_tests();              // F:  2 tests
    tcr_loadstore_tests();         // G:  4 tests
    execute_pc_test();             // H:  1 test
    csr_path_test();               // I:  1 test
    m_ext_tests();                 // J:  6 tests (4+1+1)

    $display("");
    $display("===== DIFT Testbench Complete =====");
    $display("  TOTAL  : %0d", pass_count + fail_count);
    $display("  PASSED : %0d", pass_count);
    $display("  FAILED : %0d", fail_count);
    if (fail_count == 0)
      $display("ALL TESTS PASSED");
    else
      $display("SOME TESTS FAILED");
    $finish;
  end

  // =========================================================================
  // Timeout watchdog
  // =========================================================================
  initial begin
    #1_000_000;
    $display("[TIMEOUT] Simulation exceeded 1ms — possible infinite loop");
    $finish;
  end

  // =========================================================================
  // Waveform dump (replace $dumpvars with $shm_probe for Xcelium/SimVision)
  // =========================================================================
`ifdef VCD_DUMP
  initial begin
    $dumpfile("dift_tb.vcd");
    $dumpvars(0, ibex_core_tb);
  end
`elsif SHM_DUMP
  initial begin
    $shm_open("dift_tb.shm");
    $shm_probe(ibex_core_tb, "AS");
  end
`endif

endmodule