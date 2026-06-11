// Copyright lowRISC contributors.
// Copyright 2018 ETH Zurich and University of Bologna, see also CREDITS.md.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

//`define DIFT 1'b1  // Set to 1 to enable DIFT features (guarded by `ifdef DIFT in the code)

`ifdef RISCV_FORMAL
  `define RVFI
`endif

`include "prim_assert.sv"
`include "dv_fcov_macros.svh"

/**
 * Top level module of the ibex RISC-V core
 *
 * All DIFT additions are guarded by `ifdef DIFT.
 * The original core architecture is 100% preserved when DIFT is not defined.
 */
module ibex_core import ibex_pkg::*; #(
  parameter bit                     PMPEnable                   = 1'b0,
  parameter int unsigned            PMPGranularity              = 0,
  parameter int unsigned            PMPNumRegions               = 4,
  parameter ibex_pkg::pmp_cfg_t     PMPRstCfg[PMP_MAX_REGIONS]  = ibex_pkg::PmpCfgRst,
  parameter logic [PMP_ADDR_MSB:0]  PMPRstAddr[PMP_MAX_REGIONS] = ibex_pkg::PmpAddrRst,
  parameter ibex_pkg::pmp_mseccfg_t PMPRstMsecCfg               = ibex_pkg::PmpMseccfgRst,
  parameter int unsigned            MHPMCounterNum              = 0,
  parameter int unsigned            MHPMCounterWidth            = 40,
  parameter bit                     RV32E                       = 1'b0,
  parameter rv32m_e                 RV32M                       = RV32MFast,
  parameter rv32b_e                 RV32B                       = RV32BNone,
  parameter rv32zc_e                RV32ZC                      = RV32ZcaZcbZcmp,
  parameter bit                     BranchTargetALU             = 1'b0,
  parameter bit                     WritebackStage              = 1'b0,
  parameter bit                     ICache                      = 1'b0,
  parameter bit                     ICacheECC                   = 1'b0,
  parameter int unsigned            BusSizeECC                  = BUS_SIZE,
  parameter int unsigned            TagSizeECC                  = IC_TAG_SIZE,
  parameter int unsigned            LineSizeECC                 = IC_LINE_SIZE,
  parameter bit                     BranchPredictor             = 1'b0,
  parameter bit                     DbgTriggerEn                = 1'b0,
  parameter int unsigned            DbgHwBreakNum               = 1,
  parameter bit                     ResetAll                    = 1'b0,
  parameter lfsr_seed_t             RndCnstLfsrSeed             = RndCnstLfsrSeedDefault,
  parameter lfsr_perm_t             RndCnstLfsrPerm             = RndCnstLfsrPermDefault,
  parameter bit                     SecureIbex                  = 1'b0,
  parameter bit                     DummyInstructions           = 1'b0,
  parameter bit                     RegFileECC                  = 1'b0,
  parameter int unsigned            RegFileDataWidth            = 32,
  parameter bit                     MemECC                      = 1'b0,
  parameter int unsigned            MemDataWidth                = MemECC ? 32 + 7 : 32,
  parameter int unsigned            DmBaseAddr                  = 32'h1A110000,
  parameter int unsigned            DmAddrMask                  = 32'h00000FFF,
  parameter int unsigned            DmHaltAddr                  = 32'h1A110800,
  parameter int unsigned            DmExceptionAddr             = 32'h1A110808,
  parameter logic [31:0]            CsrMvendorId                = 32'b0,
  parameter logic [31:0]            CsrMimpId                   = 32'b0
) (
  // Clock and Reset
  input  logic                         clk_i,
  input  logic                         rst_ni,

  input  logic [31:0]                  hart_id_i,
  input  logic [31:0]                  boot_addr_i,

  // Instruction memory interface
  output logic                         instr_req_o,
  input  logic                         instr_gnt_i,
  input  logic                         instr_rvalid_i,
  output logic [31:0]                  instr_addr_o,
  input  logic [MemDataWidth-1:0]      instr_rdata_i,
  input  logic                         instr_err_i,

  // Data memory interface
  output logic                         data_req_o,
  input  logic                         data_gnt_i,
  input  logic                         data_rvalid_i,
  output logic                         data_we_o,
  output logic [3:0]                   data_be_o,
  output logic [31:0]                  data_addr_o,
  output logic [MemDataWidth-1:0]      data_wdata_o,
  input  logic [MemDataWidth-1:0]      data_rdata_i,
  input  logic                         data_err_i,

  // Register file interface
  output logic                         dummy_instr_id_o,
  output logic                         dummy_instr_wb_o,
  output logic [4:0]                   rf_raddr_a_o,
  output logic [4:0]                   rf_raddr_b_o,
  output logic [4:0]                   rf_waddr_wb_o,
  output logic                         rf_we_wb_o,
  output logic [RegFileDataWidth-1:0]  rf_wdata_wb_ecc_o,
  input  logic [RegFileDataWidth-1:0]  rf_rdata_a_ecc_i,
  input  logic [RegFileDataWidth-1:0]  rf_rdata_b_ecc_i,

  // RAMs interface
  output logic [IC_NUM_WAYS-1:0]       ic_tag_req_o,
  output logic                         ic_tag_write_o,
  output logic [IC_INDEX_W-1:0]        ic_tag_addr_o,
  output logic [TagSizeECC-1:0]        ic_tag_wdata_o,
  input  logic [TagSizeECC-1:0]        ic_tag_rdata_i [IC_NUM_WAYS],
  output logic [IC_NUM_WAYS-1:0]       ic_data_req_o,
  output logic                         ic_data_write_o,
  output logic [IC_INDEX_W-1:0]        ic_data_addr_o,
  output logic [LineSizeECC-1:0]       ic_data_wdata_o,
  input  logic [LineSizeECC-1:0]       ic_data_rdata_i [IC_NUM_WAYS],
  input  logic                         ic_scr_key_valid_i,
  output logic                         ic_scr_key_req_o,

  // Interrupt inputs
  input  logic                         irq_software_i,
  input  logic                         irq_timer_i,
  input  logic                         irq_external_i,
  input  logic [14:0]                  irq_fast_i,
  input  logic                         irq_nm_i,
  output logic                         irq_pending_o,

  // Debug Interface
  input  logic                         debug_req_i,
  output crash_dump_t                  crash_dump_o,
  // SEC_CM: EXCEPTION.CTRL_FLOW.LOCAL_ESC
  // SEC_CM: EXCEPTION.CTRL_FLOW.GLOBAL_ESC
  output logic                         double_fault_seen_o,

  // RISC-V Formal Interface
`ifdef RVFI
  output logic                         rvfi_valid,
  output logic [63:0]                  rvfi_order,
  output logic [31:0]                  rvfi_insn,
  output logic                         rvfi_trap,
  output logic                         rvfi_halt,
  output logic                         rvfi_intr,
  output logic [ 1:0]                  rvfi_mode,
  output logic [ 1:0]                  rvfi_ixl,
  output logic [ 4:0]                  rvfi_rs1_addr,
  output logic [ 4:0]                  rvfi_rs2_addr,
  output logic [ 4:0]                  rvfi_rs3_addr,
  output logic [31:0]                  rvfi_rs1_rdata,
  output logic [31:0]                  rvfi_rs2_rdata,
  output logic [31:0]                  rvfi_rs3_rdata,
  output logic [ 4:0]                  rvfi_rd_addr,
  output logic [31:0]                  rvfi_rd_wdata,
  output logic [31:0]                  rvfi_pc_rdata,
  output logic [31:0]                  rvfi_pc_wdata,
  output logic [31:0]                  rvfi_mem_addr,
  output logic [ 3:0]                  rvfi_mem_rmask,
  output logic [ 3:0]                  rvfi_mem_wmask,
  output logic [31:0]                  rvfi_mem_rdata,
  output logic [31:0]                  rvfi_mem_wdata,
  output logic [31:0]                  rvfi_ext_pre_mip,
  output logic [31:0]                  rvfi_ext_post_mip,
  output logic                         rvfi_ext_nmi,
  output logic                         rvfi_ext_nmi_int,
  output logic                         rvfi_ext_debug_req,
  output logic                         rvfi_ext_debug_mode,
  output logic                         rvfi_ext_rf_wr_suppress,
  output logic [63:0]                  rvfi_ext_mcycle,
  output logic [31:0]                  rvfi_ext_mhpmcounters [10],
  output logic [31:0]                  rvfi_ext_mhpmcountersh [10],
  output logic                         rvfi_ext_ic_scr_key_valid,
  output logic                         rvfi_ext_irq_valid,
  output logic                         rvfi_ext_expanded_insn_valid,
  output logic [15:0]                  rvfi_ext_expanded_insn,
  output logic                         rvfi_ext_expanded_insn_last,
`endif

  // CPU Control Signals
  // SEC_CM: FETCH.CTRL.LC_GATED
  input  ibex_mubi_t                   fetch_enable_i,
  output logic                         alert_minor_o,
  output logic                         alert_major_internal_o,
  output logic                         alert_major_bus_o,
  output ibex_mubi_t                   core_busy_o

  // *** DIFT *** Tag memory interface and security exception output
  // The tag shadow RAM is parallel to the data RAM.
  // ibex_core drives data_wdata_tag_o and reads data_rdata_tag_i in parallel
  // uses the normal data memory bus 
  // tag memory model (1 bit per word )
`ifdef DIFT
  ,
  input  logic                         data_rdata_tag_i,  // Tag bit read from shadow RAM
  output logic                         data_wdata_tag_o,  // Tag bit written to shadow RAM
  output logic                         dift_exception_o   // DIFT security exception
`endif
);

  localparam int unsigned PMPNumChan      = 3;
  // SEC_CM: CORE.DATA_REG_SW.SCA
  localparam bit          DataIndTiming     = SecureIbex;
  localparam bit          PCIncrCheck       = SecureIbex;
  localparam bit          ShadowCSR         = 1'b0;

  // ---------------------------------------------------------------------------
  // IF/ID signals  (original — untouched)
  // ---------------------------------------------------------------------------
  logic        dummy_instr_id;
  logic        instr_valid_id;
  logic        instr_new_id;
  logic [31:0] instr_rdata_id;
  logic [31:0] instr_rdata_alu_id;
  logic [15:0] instr_rdata_c_id;
  logic        instr_is_compressed_id;
  instr_exp_e  instr_gets_expanded_id;
  logic [15:0] instr_expanded_id;
  logic        instr_perf_count_id;
  logic        instr_bp_taken_id;
  logic        instr_fetch_err;
  logic        instr_fetch_err_plus2;
  logic        illegal_c_insn_id;
  logic [31:0] pc_if;
  logic [31:0] pc_id;
  logic [31:0] pc_wb;
  logic [33:0] imd_val_d_ex[2];
  logic [33:0] imd_val_q_ex[2];
  logic [1:0]  imd_val_we_ex;

  logic        data_ind_timing;
  logic        dummy_instr_en;
  logic [2:0]  dummy_instr_mask;
  logic        dummy_instr_seed_en;
  logic [31:0] dummy_instr_seed;
  logic        icache_enable;
  logic        icache_inval;
  logic        icache_ecc_error;
  logic        pc_mismatch_alert;
  logic        csr_shadow_err;

  logic        instr_first_cycle_id;
  logic        instr_valid_clear;
  logic        pc_set;
  logic        nt_branch_mispredict;
  logic [31:0] nt_branch_addr;
  pc_sel_e     pc_mux_id;
  exc_pc_sel_e exc_pc_mux_id;
  exc_cause_t  exc_cause;

  logic        instr_intg_err;
  logic        lsu_load_err, lsu_load_err_raw;
  logic        lsu_store_err, lsu_store_err_raw;
  logic        lsu_load_resp_intg_err;
  logic        lsu_store_resp_intg_err;

  logic        expecting_load_resp_id;
  logic        expecting_store_resp_id;

  logic        lsu_addr_incr_req;
  logic [31:0] lsu_addr_last;

  logic [31:0] branch_target_ex;
  logic        branch_decision;

  logic        ctrl_busy;
  logic        if_busy;
  logic        lsu_busy;

  logic [4:0]  rf_raddr_a;
  logic [31:0] rf_rdata_a;
  logic [4:0]  rf_raddr_b;
  logic [31:0] rf_rdata_b;
  logic        rf_ren_a;
  logic        rf_ren_b;
  logic [4:0]  rf_waddr_wb;
  logic [31:0] rf_wdata_wb;
  logic [31:0] rf_wdata_fwd_wb;
  logic [31:0] rf_wdata_lsu;
  logic        rf_we_wb;
  logic        rf_we_lsu;
  logic        rf_ecc_err_comb;

  logic [4:0]  rf_waddr_id;
  logic [31:0] rf_wdata_id;
  logic        rf_we_id;
  logic        rf_rd_a_wb_match;
  logic        rf_rd_b_wb_match;

  alu_op_e     alu_operator_ex;
  logic [31:0] alu_operand_a_ex;
  logic [31:0] alu_operand_b_ex;

  logic [31:0] bt_a_operand;
  logic [31:0] bt_b_operand;

  logic [31:0] alu_adder_result_ex;
  logic [31:0] result_ex;

  logic        mult_en_ex;
  logic        div_en_ex;
  logic        mult_sel_ex;
  logic        div_sel_ex;
  md_op_e      multdiv_operator_ex;
  logic [1:0]  multdiv_signed_mode_ex;
  logic [31:0] multdiv_operand_a_ex;
  logic [31:0] multdiv_operand_b_ex;
  logic        multdiv_ready_id;

  logic        csr_access;
  csr_op_e     csr_op;
  logic        csr_op_en;
  csr_num_e    csr_addr;
  logic [31:0] csr_rdata;
  logic [31:0] csr_wdata;
  logic        illegal_csr_insn_id;

  logic        lsu_we;
  logic [1:0]  lsu_type;
  logic        lsu_sign_ext;
  logic        lsu_req;
  logic        lsu_rdata_valid;
  logic [31:0] lsu_wdata;
  logic        lsu_req_done;

  logic        id_in_ready;
  logic        ex_valid;

  logic        lsu_resp_valid;
  logic        lsu_resp_err;

  logic        instr_req_int;
  logic        instr_req_gated;
  logic        instr_exec;

  logic           en_wb;
  wb_instr_type_e instr_type_wb;
  logic           ready_wb;
  logic           rf_write_wb;
  logic           outstanding_load_wb;
  logic           outstanding_store_wb;
  logic           dummy_instr_wb;

  logic        nmi_mode;
  irqs_t       irqs;
  logic        csr_mstatus_mie;
  logic [31:0] csr_mepc, csr_depc;

  logic [PMP_ADDR_MSB:0]  csr_pmp_addr [PMPNumRegions];
  pmp_cfg_t               csr_pmp_cfg  [PMPNumRegions];
  pmp_mseccfg_t           csr_pmp_mseccfg;
  logic                   pmp_req_err  [PMPNumChan];
  logic                   data_req_out;

  logic        csr_save_if;
  logic        csr_save_id;
  logic        csr_save_wb;
  logic        csr_restore_mret_id;
  logic        csr_restore_dret_id;
  logic        csr_save_cause;
  logic        csr_mtvec_init;
  logic [31:0] csr_mtvec;
  logic [31:0] csr_mtval;
  logic        csr_mstatus_tw;
  priv_lvl_e   priv_mode_id;
  priv_lvl_e   priv_mode_lsu;

  logic        debug_mode;
  logic        debug_mode_entering;
  dbg_cause_e  debug_cause;
  logic        debug_csr_save;
  logic        debug_single_step;
  logic        debug_ebreakm;
  logic        debug_ebreaku;
  logic        trigger_match;

  logic        instr_id_done;
  logic        instr_done_wb;

  logic        perf_instr_ret_wb;
  logic        perf_instr_ret_compressed_wb;
  logic        perf_instr_ret_wb_spec;
  logic        perf_instr_ret_compressed_wb_spec;
  logic        perf_iside_wait;
  logic        perf_dside_wait;
  logic        perf_mul_wait;
  logic        perf_div_wait;
  logic        perf_jump;
  logic        perf_branch;
  logic        perf_tbranch;
  logic        perf_load;
  logic        perf_store;

  logic        illegal_insn_id, unused_illegal_insn_id;

  // ---------------------------------------------------------------------------
  // * DIFT Internal signal declarations
  //
  //   CSR (TPR/TCR) → ID (policy decode + operand-tag mux) → EX (propagate)
  //                                                        → LSU (tag mem)
  //                                                        → WB  (tag RF write)
  //
  // Core-level modules:
  //   ibex_dift_tmu          – decodes TCR per-instruction check bits
  //   riscv_mode_tag         – decodes TPR ALU propagation mode
  //   riscv_enable_tag       – decodes TPR store-enable bits
  //   riscv_load_check       – raises exception on load-address taint violation
  //   riscv_load_propagation – computes destination tag for LOAD operations
  // ---------------------------------------------------------------------------
`ifdef DIFT
  // Policy CSRs – driven by ibex_cs_registers outputs
  logic [31:0] tpr_csr;             // Tag Propagation Register (17 bits)
  logic [31:0] tcr_csr;             // Tag Check Register       (22 bits)

  // IF → ID instruction tag (tag of the PC currently in the ID stage)
  logic        pc_if_tag;
  logic        pc_id_tag;

  // Tag register file read ports (shadow the integer RF addresses)
  logic        rf_rdata_a_tag;       // Tag of rs1
  logic        rf_rdata_b_tag;       // Tag of rs2

  // ID → EX tag pipeline registers
  logic        alu_op_a_tag_ex;      // Resolved operand-A tag (latched by id_stage FF)
  logic        alu_op_b_tag_ex;      // Resolved operand-B tag
  logic        lsu_wdata_tag_id;     // Store-data tag leaving ID
  logic        rf_we_tag_id;         // RF write-enable tag leaving ID
  logic        pc_set_tag;           // Tainted branch/jump target tag (ID → IF)

  // EX block tag outputs
  logic        rf_wdata_ex_tag;      // Result tag fed back to ID for forwarding
  logic        regfile_wdata_tag;    // Result tag to WB
  logic        rf_we_tag_ex_out;     // WE tag to WB
  logic        lsu_wdata_tag_lsu;    // Store-data tag forwarded to LSU

  // LSU tag signals
  logic        lsu_rdata_tag;        // Loaded-word tag (LSU → WB)
  logic        lsu_tag_err;          // Load-address taint violation (LSU)

  // WB stage tag signals
  logic        rf_wdata_tag_wb;      // Tag to be written to the tag register file
  logic        rf_we_tag_wb;         // Write-enable for tag register file
  logic        rf_wdata_fwd_tag_wb;  // Forwarded tag from WB to ID (hazard resolution)

  //TMU decode outputs 
  logic        dift_s1_check;        // TCR: check source-1 tag
  logic        dift_s2_check;        // TCR: check source-2 tag
  logic        dift_dest_check;      // TCR: check destination tag
  logic        dift_pc_check;        // TCR: check PC (execute-check bit)
  logic [ALU_MODE_WIDTH-1:0] alu_tag_mode;  // TPR: ALU propagation mode (AND/OR/CLEAR/OLD)
  logic        rf_tag_we_tmu;        // TPR mode decoder: tag write enable for ALU instrs
  logic        is_store_tmu;         // Enable decoder: current instruction is a store
  logic        memory_set_tmu;       // Mode decoder: memory-set special case
  logic        is_store_post_tmu;    // Mode decoder: post-increment store

  // Load check / propagation (uses WB-stage signals)
  logic        load_exception;       // Raised when load violates TCR policy
  logic        rf_we_tag_load;       // Tag value for the load destination register
  logic        rf_tag_we_load;       // Enable writing rf_we_tag_load to tag RF
  logic        ex_exception;         // EX-stage taint violation from ibex_dift_logic
  logic        pc_exception;         // PC tag violation in EX
`endif

  //////////////////////
  // Clock management //
  //////////////////////

  if (SecureIbex) begin : g_core_busy_secure
    localparam int unsigned NumBusySignals = 3;
    localparam int unsigned NumBusyBits = $bits(ibex_mubi_t) * NumBusySignals;
    logic [NumBusyBits-1:0] busy_bits_buf;
    prim_buf #(
      .Width(NumBusyBits)
    ) u_fetch_enable_buf (
      .in_i ({$bits(ibex_mubi_t){ctrl_busy, if_busy, lsu_busy}}),
      .out_o(busy_bits_buf)
    );
    for (genvar i = 0; i < $bits(ibex_mubi_t); i++) begin : g_core_busy_bits
      if (IbexMuBiOn[i] == 1'b1) begin : g_pos
        assign core_busy_o[i] =  |busy_bits_buf[i*NumBusySignals +: NumBusySignals];
      end else begin : g_neg
        assign core_busy_o[i] = ~|busy_bits_buf[i*NumBusySignals +: NumBusySignals];
      end
    end
  end else begin : g_core_busy_non_secure
    assign core_busy_o = (ctrl_busy || if_busy || lsu_busy) ? IbexMuBiOn : IbexMuBiOff;
  end

  // ===========================================================================
`ifdef DIFT
  // decoding per-instruction TAG CHECK bits from TCR
  ibex_dift_tmu u_ibex_dift_tmu (
    .instr_rdata_i ( instr_rdata_id  ),
    .tcr_i         ( tcr_csr         ),
    .source_1_o    ( dift_s1_check   ),
    .source_2_o    ( dift_s2_check   ),
    .dest_o        ( dift_dest_check ),
    .execute_pc_o  ( dift_pc_check   )
  );

  //checking if a LOAD operation violates the security policy based on TCR
  // usigng wb signals = runs when rf_we_wb_o is asserted
  riscv_load_check u_ibex_load_check (
    .regfile_wdata_wb_i_tag ( lsu_rdata_tag    ),  // tag of loaded word (from tag RAM)
    .rs1_i_tag              ( rf_rdata_a_tag   ),  // tag of base-address register
    .regfile_dest_tag       ( rf_wdata_tag_wb  ),  // tag to be written to destination
    .tcr_i                  ( tcr_csr          ),
    .regfile_we_wb_i        ( rf_we_lsu         ),  // WB write enable 
    .exception_o            ( load_exception   )
  );

  // computing destination tag for LOAD based on TPR and source tags
  // output rf_we_tag_load is the computed tag value for the loaded register.
  riscv_load_propagation u_ibex_load_propagation (
    .regfile_wdata_wb_i_tag ( lsu_rdata_tag    ),  // tag of loaded word
    .rs1_i_tag              ( rf_rdata_a_tag   ),  // tag of base-address register
    .regfile_we_wb_i        ( rf_we_lsu         ),
    .tpr_i                  ( tpr_csr          ),
    .regfile_dest_tag       ( rf_we_tag_load   ),  // computed tag for destination
    .regfile_enable_tag     ( rf_tag_we_load   )
  );

  // decoding ALU tag propagation MODE from TPR
  riscv_mode_tag u_ibex_mode_tag (
    .instr_rdata_i       ( instr_rdata_id    ),
    .tpr_i               ( tpr_csr           ),
    .alu_operator_o_mode ( alu_tag_mode      ),
    .register_set_o      ( rf_tag_we_tmu     ),
    .is_store_post_o     ( is_store_post_tmu ),
    .memory_set_o        ( memory_set_tmu    )
  );

  //decode store enable bits from TPR
  riscv_enable_tag u_ibex_enable_tag (
    .instr_rdata_i ( instr_rdata_id ),
    .tpr_i         ( tpr_csr        ),
    .is_store_o    ( is_store_tmu   ),
    .enable_a_o    (                ),  // handled internally by id_stage via tpr_i
    .enable_b_o    (                )
  );

  // Suppress unused-signal warnings for TMU outputs consumed inside sub-modules
  logic unused_dift_tmu;
  assign unused_dift_tmu = rf_tag_we_tmu ^ is_store_tmu ^ memory_set_tmu ^ is_store_post_tmu;
  assign pc_exception = instr_valid_id & dift_pc_check & pc_id_tag;                           //PC tag violation : new add
  assign dift_exception_o = load_exception | lsu_tag_err | ex_exception | pc_exception;
`endif

  //////////////
  // IF stage //
  //////////////

  ibex_if_stage #(
    .DmHaltAddr       (DmHaltAddr),
    .DmExceptionAddr  (DmExceptionAddr),
    .DummyInstructions(DummyInstructions),
    .ICache           (ICache),
    .RV32ZC           (RV32ZC),
    .ICacheECC        (ICacheECC),
    .BusSizeECC       (BusSizeECC),
    .TagSizeECC       (TagSizeECC),
    .LineSizeECC      (LineSizeECC),
    .PCIncrCheck      (PCIncrCheck),
    .ResetAll         (ResetAll),
    .RndCnstLfsrSeed  (RndCnstLfsrSeed),
    .RndCnstLfsrPerm  (RndCnstLfsrPerm),
    .BranchPredictor  (BranchPredictor),
    .MemECC           (MemECC),
    .MemDataWidth     (MemDataWidth)
  ) if_stage_i (
    .clk_i (clk_i),
    .rst_ni(rst_ni),

    .boot_addr_i(boot_addr_i),
    .req_i      (instr_req_gated),

    // instruction cache interface
    .instr_req_o       (instr_req_o),
    .instr_addr_o      (instr_addr_o),
    .instr_gnt_i       (instr_gnt_i),
    .instr_rvalid_i    (instr_rvalid_i),
    .instr_rdata_i     (instr_rdata_i),
    .instr_bus_err_i   (instr_err_i),
    .instr_intg_err_o  (instr_intg_err),

    .ic_tag_req_o      (ic_tag_req_o),
    .ic_tag_write_o    (ic_tag_write_o),
    .ic_tag_addr_o     (ic_tag_addr_o),
    .ic_tag_wdata_o    (ic_tag_wdata_o),
    .ic_tag_rdata_i    (ic_tag_rdata_i),
    .ic_data_req_o     (ic_data_req_o),
    .ic_data_write_o   (ic_data_write_o),
    .ic_data_addr_o    (ic_data_addr_o),
    .ic_data_wdata_o   (ic_data_wdata_o),
    .ic_data_rdata_i   (ic_data_rdata_i),
    .ic_scr_key_valid_i(ic_scr_key_valid_i),
    .ic_scr_key_req_o  (ic_scr_key_req_o),

    // outputs to ID stage
    .instr_valid_id_o        (instr_valid_id),
    .instr_new_id_o          (instr_new_id),
    .instr_rdata_id_o        (instr_rdata_id),
    .instr_rdata_alu_id_o    (instr_rdata_alu_id),
    .instr_rdata_c_id_o      (instr_rdata_c_id),
    .instr_is_compressed_id_o(instr_is_compressed_id),
    .instr_gets_expanded_id_o(instr_gets_expanded_id),
    .instr_expanded_id_o     (instr_expanded_id),
    .instr_bp_taken_o        (instr_bp_taken_id),
    .instr_fetch_err_o       (instr_fetch_err),
    .instr_fetch_err_plus2_o (instr_fetch_err_plus2),
    .illegal_c_insn_id_o     (illegal_c_insn_id),
    .dummy_instr_id_o        (dummy_instr_id),
    .pc_if_o                 (pc_if),
    .pc_id_o                 (pc_id),
    .pmp_err_if_i            (pmp_req_err[PMP_I]),
    .pmp_err_if_plus2_i      (pmp_req_err[PMP_I2]),

    // control signals
    .instr_valid_clear_i   (instr_valid_clear),
    .pc_set_i              (pc_set),
    .pc_mux_i              (pc_mux_id),
    .nt_branch_mispredict_i(nt_branch_mispredict),
    .exc_pc_mux_i          (exc_pc_mux_id),
    .exc_cause             (exc_cause),
    .dummy_instr_en_i      (dummy_instr_en),
    .dummy_instr_mask_i    (dummy_instr_mask),
    .dummy_instr_seed_en_i (dummy_instr_seed_en),
    .dummy_instr_seed_i    (dummy_instr_seed),
    .icache_enable_i       (icache_enable),
    .icache_inval_i        (icache_inval),
    .icache_ecc_error_o    (icache_ecc_error),

    // branch targets
    .branch_target_ex_i(branch_target_ex),
    .nt_branch_addr_i  (nt_branch_addr),

    // CSRs
    .csr_mepc_i      (csr_mepc),
    .csr_depc_i      (csr_depc),
    .csr_mtvec_i     (csr_mtvec),
    .csr_mtvec_init_o(csr_mtvec_init),

    // pipeline stalls
    .id_in_ready_i(id_in_ready),

    .pc_mismatch_alert_o(pc_mismatch_alert),
    .if_busy_o          (if_busy)

    // DIFT PC tag tracking through the IF stage
`ifdef DIFT
    ,
    .branch_target_ex_i_tag (pc_set_tag), //tag of the branch/jump target PC computed in EX
    .pc_if_o_tag            (pc_if_tag), //tag of the PC currently being fetched, becomes the instruction tag (instr_tag_i) for the instruction in the ID stage.
    .pc_id_o_tag            (pc_id_tag)
`endif
  );

  // Core is waiting for the ISide when ID/EX stage is ready for a new instruction but none are
  // available
  assign perf_iside_wait = id_in_ready & ~instr_valid_id;

  `ASSERT_INIT(IbexMuBiSecureOnBottomBitSet,    IbexMuBiOn[0] == 1'b1)
  `ASSERT_INIT(IbexMuBiSecureOffBottomBitClear, IbexMuBiOff[0] == 1'b0)

  if (SecureIbex) begin : g_instr_req_gated_secure
    // SEC_CM: FETCH.CTRL.LC_GATED
    assign instr_req_gated = instr_req_int & (fetch_enable_i == IbexMuBiOn);
    assign instr_exec      = fetch_enable_i == IbexMuBiOn;
  end else begin : g_instr_req_gated_non_secure
    logic unused_fetch_enable;
    assign unused_fetch_enable = ^fetch_enable_i[$bits(ibex_mubi_t)-1:1];
    assign instr_req_gated = instr_req_int & fetch_enable_i[0];
    assign instr_exec      = fetch_enable_i[0];
  end

  //////////////
  // ID stage //
  //////////////

  ibex_id_stage #(
    .RV32E          (RV32E),
    .RV32M          (RV32M),
    .RV32B          (RV32B),
    .BranchTargetALU(BranchTargetALU),
    .DataIndTiming  (DataIndTiming),
    .WritebackStage (WritebackStage),
    .BranchPredictor(BranchPredictor),
    .MemECC         (MemECC)
  ) id_stage_i (
    .clk_i (clk_i),
    .rst_ni(rst_ni),

    .ctrl_busy_o   (ctrl_busy),
    .illegal_insn_o(illegal_insn_id),

    .instr_valid_i        (instr_valid_id),
    .instr_rdata_i        (instr_rdata_id),
    .instr_rdata_alu_i    (instr_rdata_alu_id),
    .instr_rdata_c_i      (instr_rdata_c_id),
    .instr_is_compressed_i(instr_is_compressed_id),
    .instr_bp_taken_i     (instr_bp_taken_id),

    .branch_decision_i(branch_decision),

    .instr_first_cycle_id_o(instr_first_cycle_id),
    .instr_valid_clear_o   (instr_valid_clear),
    .id_in_ready_o         (id_in_ready),
    .instr_exec_i          (instr_exec),
    .instr_req_o           (instr_req_int),
    .pc_set_o              (pc_set),
    .pc_mux_o              (pc_mux_id),
    .nt_branch_mispredict_o(nt_branch_mispredict),
    .nt_branch_addr_o      (nt_branch_addr),
    .exc_pc_mux_o          (exc_pc_mux_id),
    .exc_cause_o           (exc_cause),
    .icache_inval_o        (icache_inval),

    .instr_fetch_err_i      (instr_fetch_err),
    .instr_fetch_err_plus2_i(instr_fetch_err_plus2),
    .illegal_c_insn_i       (illegal_c_insn_id),

    .pc_id_i(pc_id),

    .ex_valid_i      (ex_valid),
    .lsu_resp_valid_i(lsu_resp_valid),

    .alu_operator_ex_o (alu_operator_ex),
    .alu_operand_a_ex_o(alu_operand_a_ex),
    .alu_operand_b_ex_o(alu_operand_b_ex),

    .imd_val_q_ex_o (imd_val_q_ex),
    .imd_val_d_ex_i (imd_val_d_ex),
    .imd_val_we_ex_i(imd_val_we_ex),

    .bt_a_operand_o(bt_a_operand),
    .bt_b_operand_o(bt_b_operand),

    .mult_en_ex_o            (mult_en_ex),
    .div_en_ex_o             (div_en_ex),
    .mult_sel_ex_o           (mult_sel_ex),
    .div_sel_ex_o            (div_sel_ex),
    .multdiv_operator_ex_o   (multdiv_operator_ex),
    .multdiv_signed_mode_ex_o(multdiv_signed_mode_ex),
    .multdiv_operand_a_ex_o  (multdiv_operand_a_ex),
    .multdiv_operand_b_ex_o  (multdiv_operand_b_ex),
    .multdiv_ready_id_o      (multdiv_ready_id),

    .csr_access_o         (csr_access),
    .csr_op_o             (csr_op),
    .csr_addr_o           (csr_addr),
    .csr_op_en_o          (csr_op_en),
    .csr_save_if_o        (csr_save_if),
    .csr_save_id_o        (csr_save_id),
    .csr_save_wb_o        (csr_save_wb),
    .csr_restore_mret_id_o(csr_restore_mret_id),
    .csr_restore_dret_id_o(csr_restore_dret_id),
    .csr_save_cause_o     (csr_save_cause),
    .csr_mtval_o          (csr_mtval),
    .priv_mode_i          (priv_mode_id),
    .csr_mstatus_tw_i     (csr_mstatus_tw),
    .illegal_csr_insn_i   (illegal_csr_insn_id),
    .data_ind_timing_i    (data_ind_timing),

    .lsu_req_o     (lsu_req),
    .lsu_we_o      (lsu_we),
    .lsu_type_o    (lsu_type),
    .lsu_sign_ext_o(lsu_sign_ext),
    .lsu_wdata_o   (lsu_wdata),
    .lsu_req_done_i(lsu_req_done),

    .lsu_addr_incr_req_i(lsu_addr_incr_req),
    .lsu_addr_last_i    (lsu_addr_last),

    .lsu_load_err_i           (lsu_load_err),
    .lsu_load_resp_intg_err_i (lsu_load_resp_intg_err),
    .lsu_store_err_i          (lsu_store_err),
    .lsu_store_resp_intg_err_i(lsu_store_resp_intg_err),

    .expecting_load_resp_o (expecting_load_resp_id),
    .expecting_store_resp_o(expecting_store_resp_id),

    .csr_mstatus_mie_i(csr_mstatus_mie),
    .irq_pending_i    (irq_pending_o),
    .irqs_i           (irqs),
    .irq_nm_i         (irq_nm_i),
    .nmi_mode_o       (nmi_mode),

    .debug_mode_o         (debug_mode),
    .debug_mode_entering_o(debug_mode_entering),
    .debug_cause_o        (debug_cause),
    .debug_csr_save_o     (debug_csr_save),
    .debug_req_i          (debug_req_i),
    .debug_single_step_i  (debug_single_step),
    .debug_ebreakm_i      (debug_ebreakm),
    .debug_ebreaku_i      (debug_ebreaku),
    .trigger_match_i      (trigger_match),

    .result_ex_i(result_ex),
    .csr_rdata_i(csr_rdata),

    .rf_raddr_a_o      (rf_raddr_a),
    .rf_rdata_a_i      (rf_rdata_a),
    .rf_raddr_b_o      (rf_raddr_b),
    .rf_rdata_b_i      (rf_rdata_b),
    .rf_ren_a_o        (rf_ren_a),
    .rf_ren_b_o        (rf_ren_b),
    .rf_waddr_id_o     (rf_waddr_id),
    .rf_wdata_id_o     (rf_wdata_id),
    .rf_we_id_o        (rf_we_id),
    .rf_rd_a_wb_match_o(rf_rd_a_wb_match),
    .rf_rd_b_wb_match_o(rf_rd_b_wb_match),

    .rf_waddr_wb_i    (rf_waddr_wb),
    .rf_wdata_fwd_wb_i(rf_wdata_fwd_wb),
    .rf_write_wb_i    (rf_write_wb),

    .en_wb_o               (en_wb),
    .instr_type_wb_o       (instr_type_wb),
    .instr_perf_count_id_o (instr_perf_count_id),
    .ready_wb_i            (ready_wb),
    .outstanding_load_wb_i (outstanding_load_wb),
    .outstanding_store_wb_i(outstanding_store_wb),

    .perf_jump_o      (perf_jump),
    .perf_branch_o    (perf_branch),
    .perf_tbranch_o   (perf_tbranch),
    .perf_dside_wait_o(perf_dside_wait),
    .perf_mul_wait_o  (perf_mul_wait),
    .perf_div_wait_o  (perf_div_wait),
    .instr_id_done_o  (instr_id_done)

    // DIFT ID stage tag wiring
    // Inputs: register tags (direct + forwarded), policy CSRs, instruction PC tag
    // Outputs: resolved operand tags pipelined to EX, branch/jump PC tag to IF
`ifdef DIFT
    ,
    // Forwarded tags from EX and WB for operand hazard resolution
    .rf_wdata_ex_tag_i   (rf_wdata_ex_tag),       // EX result tag (forwarding)
    .rf_wdata_wb_tag_i   (rf_wdata_fwd_tag_wb),   // WB result tag (forwarding)
    // Register file tag reads (same addresses as RF)
    .rf_rdata_a_tag_i    (rf_rdata_a_tag),
    .rf_rdata_b_tag_i    (rf_rdata_b_tag),
    // Policy registers from CSR file (programmed by startup routine)
    .tpr_i               (tpr_csr),
    .tcr_i               (tcr_csr),
    // Instruction tag = tag of the PC in the ID stage
    .instr_tag_i         (pc_id_tag),
    // Resolved operand tags latched into EX pipeline registers by id_stage
    .alu_op_a_tag_ex_o   (alu_op_a_tag_ex),
    .alu_op_b_tag_ex_o   (alu_op_b_tag_ex),
    .lsu_wdata_tag_ex_o  (lsu_wdata_tag_id),
    .pc_set_tag_o        (pc_set_tag),
    .rf_we_tag_ex_o      (rf_we_tag_id),
    // New TMU ports
    .alu_tag_mode_i      (alu_tag_mode),
    .dift_s1_check_i     (dift_s1_check),
    .dift_s2_check_i     (dift_s2_check),
    .dift_dest_check_i   (dift_dest_check),
    .is_load_i           (instr_rdata_id[6:0] == OPCODE_LOAD),
    .ex_tag_err_i        (ex_exception | pc_exception)  //PC VIOLATION 
`endif
  );

  assign unused_illegal_insn_id = illegal_insn_id;

  /////////////////
  // EX block    //
  /////////////////

  ibex_ex_block #(
    .RV32M          (RV32M),
    .RV32B          (RV32B),
    .BranchTargetALU(BranchTargetALU)
  ) ex_block_i (
    .clk_i (clk_i),
    .rst_ni(rst_ni),

    .alu_operator_i         (alu_operator_ex),
    .alu_operand_a_i        (alu_operand_a_ex),
    .alu_operand_b_i        (alu_operand_b_ex),
    .alu_instr_first_cycle_i(instr_first_cycle_id),

    .bt_a_operand_i(bt_a_operand),
    .bt_b_operand_i(bt_b_operand),
    .instr_tag_i     (pc_id_tag),

    .multdiv_operator_i   (multdiv_operator_ex),
    .mult_en_i            (mult_en_ex),
    .div_en_i             (div_en_ex),
    .mult_sel_i           (mult_sel_ex),
    .div_sel_i            (div_sel_ex),
    .multdiv_signed_mode_i(multdiv_signed_mode_ex),
    .multdiv_operand_a_i  (multdiv_operand_a_ex),
    .multdiv_operand_b_i  (multdiv_operand_b_ex),
    .multdiv_ready_id_i   (multdiv_ready_id),
    .data_ind_timing_i    (data_ind_timing),

    .imd_val_we_o(imd_val_we_ex),
    .imd_val_d_o (imd_val_d_ex),
    .imd_val_q_i (imd_val_q_ex),

    .alu_adder_result_ex_o(alu_adder_result_ex),
    .result_ex_o          (result_ex),

    .branch_target_o  (branch_target_ex),
    .branch_decision_o(branch_decision),

    .ex_valid_o(ex_valid)

    //DIFT EX block tag wiring
    // Inputs: resolved operand tags from ID pipeline registers
    // Outputs: computed result tag (forwarding + WB path), store-data tag to LSU
    // ibex_dift_logic (inside ex_block) applies alu_tag_mode propagation rule.
`ifdef DIFT
    ,
    .alu_op_a_tag_i      (alu_op_a_tag_ex),     // operand A tag (from ID FF)
    .alu_op_b_tag_i      (alu_op_b_tag_ex),     // operand B tag (from ID FF)
    .rf_we_tag_i         (rf_we_tag_id),         // RF write-enable tag
    .lsu_wdata_tag_i     (lsu_wdata_tag_id),     // store-data tag
    .alu_tag_mode_i  (alu_tag_mode),
    .check_s1_i      (dift_s1_check), 
    .check_s2_i      (dift_s2_check),
    .check_d_i       (dift_dest_check),
    .is_load_i       (instr_rdata_id[6:0] == OPCODE_LOAD),
    .rf_wdata_ex_tag_o   (rf_wdata_ex_tag),      // result tag → ID forwarding mux
    .regfile_wdata_tag_o (regfile_wdata_tag),    // result tag → WB stage
    .rf_we_tag_o         (rf_we_tag_ex_out),     // WE tag → WB stage
    .lsu_wdata_tag_o     (lsu_wdata_tag_lsu),     // store-data tag → LSU
    .ex_tag_err_o        (ex_exception)
`endif
  );

  /////////////////////
  // Load/store unit //
  /////////////////////

  assign data_req_o   = data_req_out & ~pmp_req_err[PMP_D];
  assign lsu_resp_err = lsu_load_err | lsu_store_err;

  ibex_load_store_unit #(
    .MemECC(MemECC),
    .MemDataWidth(MemDataWidth)
  ) load_store_unit_i (
    .clk_i (clk_i),
    .rst_ni(rst_ni),

    .data_req_o    (data_req_out),
    .data_gnt_i    (data_gnt_i),
    .data_rvalid_i (data_rvalid_i),
    .data_bus_err_i(data_err_i),
    .data_pmp_err_i(pmp_req_err[PMP_D]),

    .data_addr_o      (data_addr_o),
    .data_we_o        (data_we_o),
    .data_be_o        (data_be_o),
    .data_wdata_o     (data_wdata_o),
    .data_rdata_i     (data_rdata_i),

    .lsu_we_i      (lsu_we),
    .lsu_type_i    (lsu_type),
    .lsu_wdata_i   (lsu_wdata),
    .lsu_sign_ext_i(lsu_sign_ext),

    .lsu_rdata_o      (rf_wdata_lsu),
    .lsu_rdata_valid_o(lsu_rdata_valid),
    .lsu_req_i        (lsu_req),
    .lsu_req_done_o   (lsu_req_done),

    .adder_result_ex_i(alu_adder_result_ex),

    .addr_incr_req_o(lsu_addr_incr_req),
    .addr_last_o    (lsu_addr_last),

    .lsu_resp_valid_o(lsu_resp_valid),

    .load_err_o           (lsu_load_err_raw),
    .load_resp_intg_err_o (lsu_load_resp_intg_err),
    .store_err_o          (lsu_store_err_raw),
    .store_resp_intg_err_o(lsu_store_resp_intg_err),

    .busy_o(lsu_busy),

    .perf_load_o (perf_load),
    .perf_store_o(perf_store)

    // DIFT LSU tag wiring
    // Connects to the external tag RAM.
    // data_wdata_tag_o / data_rdata_tag_i mirror data_wdata_o / data_rdata_i
    // lsu_tag_err_o is raised when a tainted address is used for a load/store
`ifdef DIFT
    ,
    .data_wdata_tag_o  (data_wdata_tag_o),    // tag to shadow RAM
    .data_rdata_tag_i  (data_rdata_tag_i),    // tag from shadow RAM
    .lsu_wdata_tag_i   (lsu_wdata_tag_lsu),   // store-data tag from EX
    .lsu_rdata_tag_o   (lsu_rdata_tag),       // loaded-data tag → WB
    .lsu_tag_err_o     (lsu_tag_err),         // address taint violation
    .tcr_load_check_i  (tcr_csr[LOADSTORE_CHECK_DA])  // policy bit: check address tag
`endif
  );

  //////////////////////
  // Writeback stage  //
  //////////////////////

  ibex_wb_stage #(
    .ResetAll         (ResetAll),
    .WritebackStage   (WritebackStage),
    .DummyInstructions(DummyInstructions)
  ) wb_stage_i (
    .clk_i                   (clk_i),
    .rst_ni                  (rst_ni),
    .en_wb_i                 (en_wb),
    .instr_type_wb_i         (instr_type_wb),
    .pc_id_i                 (pc_id),
    .instr_is_compressed_id_i(instr_is_compressed_id),
    .instr_perf_count_id_i   (instr_perf_count_id),

    .ready_wb_o                         (ready_wb),
    .rf_write_wb_o                      (rf_write_wb),
    .outstanding_load_wb_o              (outstanding_load_wb),
    .outstanding_store_wb_o             (outstanding_store_wb),
    .pc_wb_o                            (pc_wb),
    .perf_instr_ret_wb_o                (perf_instr_ret_wb),
    .perf_instr_ret_compressed_wb_o     (perf_instr_ret_compressed_wb),
    .perf_instr_ret_wb_spec_o           (perf_instr_ret_wb_spec),
    .perf_instr_ret_compressed_wb_spec_o(perf_instr_ret_compressed_wb_spec),

    .rf_waddr_id_i(rf_waddr_id),
    .rf_wdata_id_i(rf_wdata_id),
    .rf_we_id_i   (rf_we_id),

    .dummy_instr_id_i(dummy_instr_id),

    .rf_wdata_lsu_i(rf_wdata_lsu),
    .rf_we_lsu_i   (rf_we_lsu),

    .rf_wdata_fwd_wb_o(rf_wdata_fwd_wb),

    .rf_waddr_wb_o(rf_waddr_wb),
    .rf_wdata_wb_o(rf_wdata_wb),
    .rf_we_wb_o   (rf_we_wb),

    .dummy_instr_wb_o(dummy_instr_wb),

    .lsu_resp_valid_i(lsu_resp_valid),
    .lsu_resp_err_i  (lsu_resp_err),

    .instr_done_wb_o(instr_done_wb)

    // DIFT WB stage tag wiring
    // The WB stage selects between the EX result tag (ALU/mult) and the LSU data tag, then drives the tag register file write port.
    // rf_wdata_fwd_tag_wb_o provides the forwarded tag to ID for hazard resolution.
`ifdef DIFT
    ,
    // From EX block: ALU/mult result tag
    .rf_wdata_tag_id_i     (regfile_wdata_tag),   // EX result tag
    .rf_we_tag_id_i        (rf_we_tag_ex_out),    // EX write-enable tag
    // From LSU: loaded data tag
    .rf_wdata_tag_lsu_i    (rf_we_tag_load),       // loaded-word tag
    .rf_we_tag_lsu_i       (rf_tag_we_load),       // LSU write enable (same as data)
    // To tag register file
    .rf_wdata_tag_wb_o     (rf_wdata_tag_wb),     // final tag to write
    .rf_we_tag_wb_o        (rf_we_tag_wb),        // tag RF write enable
    // Forwarding to ID stage
    .rf_wdata_fwd_tag_wb_o (rf_wdata_fwd_tag_wb)  // hazard-forwarding tag
`endif
  );

  if (SecureIbex) begin : g_check_mem_response
    assign lsu_load_err  = lsu_load_err_raw  & (outstanding_load_wb  | expecting_load_resp_id);
    assign lsu_store_err = lsu_store_err_raw & (outstanding_store_wb | expecting_store_resp_id);
    assign rf_we_lsu     = lsu_rdata_valid   & (outstanding_load_wb  | expecting_load_resp_id);
  end else begin : g_no_check_mem_response
    assign lsu_load_err  = lsu_load_err_raw;
    assign lsu_store_err = lsu_store_err_raw;
    assign rf_we_lsu     = lsu_rdata_valid;

    logic unused_expecting_load_resp_id;
    logic unused_expecting_store_resp_id;

    assign unused_expecting_load_resp_id  = expecting_load_resp_id;
    assign unused_expecting_store_resp_id = expecting_store_resp_id;
  end

  /////////////////////////////
  // Register file interface //
  /////////////////////////////

  assign dummy_instr_id_o = dummy_instr_id;
  assign dummy_instr_wb_o = dummy_instr_wb;
  assign rf_raddr_a_o     = rf_raddr_a;
  assign rf_waddr_wb_o    = rf_waddr_wb;
  assign rf_we_wb_o       = rf_we_wb;
  assign rf_raddr_b_o     = rf_raddr_b;

  if (RegFileECC) begin : gen_regfile_ecc
    // SEC_CM: DATA_REG_SW.INTEGRITY
    logic [1:0] rf_ecc_err_a, rf_ecc_err_b;
    logic       rf_ecc_err_a_id, rf_ecc_err_b_id;

    prim_secded_inv_39_32_enc regfile_ecc_enc (
      .data_i(rf_wdata_wb),
      .data_o(rf_wdata_wb_ecc_o)
    );

    prim_secded_inv_39_32_dec regfile_ecc_dec_a (
      .data_i    (rf_rdata_a_ecc_i),
      .data_o    (),
      .syndrome_o(),
      .err_o     (rf_ecc_err_a)
    );
    prim_secded_inv_39_32_dec regfile_ecc_dec_b (
      .data_i    (rf_rdata_b_ecc_i),
      .data_o    (),
      .syndrome_o(),
      .err_o     (rf_ecc_err_b)
    );

    assign rf_rdata_a = rf_rdata_a_ecc_i[31:0];
    assign rf_rdata_b = rf_rdata_b_ecc_i[31:0];

    assign rf_ecc_err_a_id = |rf_ecc_err_a & rf_ren_a & ~(rf_rd_a_wb_match & rf_write_wb);
    assign rf_ecc_err_b_id = |rf_ecc_err_b & rf_ren_b & ~(rf_rd_b_wb_match & rf_write_wb);

    assign rf_ecc_err_comb = instr_valid_id & (rf_ecc_err_a_id | rf_ecc_err_b_id);
  end else begin : gen_no_regfile_ecc
    logic unused_rf_ren_a, unused_rf_ren_b;
    logic unused_rf_rd_a_wb_match, unused_rf_rd_b_wb_match;

    assign unused_rf_ren_a         = rf_ren_a;
    assign unused_rf_ren_b         = rf_ren_b;
    assign unused_rf_rd_a_wb_match = rf_rd_a_wb_match;
    assign unused_rf_rd_b_wb_match = rf_rd_b_wb_match;
    assign rf_wdata_wb_ecc_o       = rf_wdata_wb;
    assign rf_rdata_a              = rf_rdata_a_ecc_i;
    assign rf_rdata_b              = rf_rdata_b_ecc_i;
    assign rf_ecc_err_comb         = 1'b0;
  end

  // ===========================================================================
  // DIFT Tag register file
  // One tag bit per register, implemented as a shadow register file using
  // identical read/write addresses to the integer RF.  Instantiated internally. No ECC
  // ===========================================================================
`ifdef DIFT
  ibex_register_file_latch_tag #(
    .RV32E            (RV32E),
    .DataWidth        (1),          // 1-bit tag per register
    .DummyInstructions(DummyInstructions),
    .WordZeroVal      (1'b0)        // tags initialised to 0 (authentic) at reset
  ) tag_register_file_i (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .test_en_i        (1'b0),
    .dummy_instr_id_i (dummy_instr_id),
    .dummy_instr_wb_i (dummy_instr_wb),
    // Read addresses — identical to integer RF so tags are always co-read
    .raddr_a_i        (rf_raddr_a),
    .rdata_a_o        (rf_rdata_a_tag),
    .raddr_b_i        (rf_raddr_b),
    .rdata_b_o        (rf_rdata_b_tag),
    // Write address — identical to integer RF; tag written with result tag from WB
    .waddr_a_i        (rf_waddr_wb),
    .wdata_a_i        (rf_wdata_tag_wb),
    .we_a_i           (rf_we_tag_wb)
  );
`endif

  ///////////////////////
  // Crash dump output //
  ///////////////////////

  logic [31:0] crash_dump_mtval;
  assign crash_dump_o.current_pc     = pc_id;
  assign crash_dump_o.next_pc        = pc_if;
  assign crash_dump_o.last_data_addr = lsu_addr_last;
  assign crash_dump_o.exception_pc   = csr_mepc;
  assign crash_dump_o.exception_addr = crash_dump_mtval;

  ///////////////////
  // Alert outputs //
  ///////////////////

  assign alert_minor_o = icache_ecc_error;
  assign alert_major_internal_o = rf_ecc_err_comb | pc_mismatch_alert | csr_shadow_err;
  assign alert_major_bus_o = lsu_load_resp_intg_err | lsu_store_resp_intg_err | instr_intg_err;

`ifdef INC_ASSERT
  logic outstanding_load_resp;
  logic outstanding_store_resp;
  logic outstanding_load_id;
  logic outstanding_store_id;

  assign outstanding_load_id  = id_stage_i.instr_executing & id_stage_i.lsu_req_dec &
                                ~id_stage_i.lsu_we;
  assign outstanding_store_id = id_stage_i.instr_executing & id_stage_i.lsu_req_dec &
                                id_stage_i.lsu_we;

  if (WritebackStage) begin : gen_wb_stage
    assign outstanding_load_resp  = outstanding_load_wb |
      (outstanding_load_id  & load_store_unit_i.split_misaligned_access);
    assign outstanding_store_resp = outstanding_store_wb |
      (outstanding_store_id & load_store_unit_i.split_misaligned_access);
    `ASSERT(NoMemRFWriteWithoutPendingLoad, rf_we_lsu |-> outstanding_load_wb, clk_i, !rst_ni)
  end else begin : gen_no_wb_stage
    assign outstanding_load_resp  = outstanding_load_id;
    assign outstanding_store_resp = outstanding_store_id;
    `ASSERT(NoMemRFWriteWithoutPendingLoad, rf_we_lsu |-> outstanding_load_id, clk_i, !rst_ni)
  end

  `ASSERT(NoMemResponseWithoutPendingAccess,
    data_rvalid_i |-> outstanding_load_resp | outstanding_store_resp, clk_i, !rst_ni)

  logic [31:0]   pc_at_fetch_disable;
  ibex_mubi_t    last_fetch_enable;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_at_fetch_disable <= '0;
      last_fetch_enable   <= '0;
    end else begin
      last_fetch_enable <= fetch_enable_i;
      if ((fetch_enable_i != IbexMuBiOn) && (last_fetch_enable == IbexMuBiOn)) begin
        pc_at_fetch_disable <= pc_id;
      end
    end
  end

  logic fetch_enable_raw;
  assign fetch_enable_raw = SecureIbex ? (fetch_enable_i == IbexMuBiOn) : fetch_enable_i[0];

  `ASSERT(NoExecWhenFetchEnableNotOn,
          !fetch_enable_raw |=>
          (~instr_valid_id || (pc_id == pc_at_fetch_disable)) && ~$rose(instr_valid_id))
`endif

  /////////////////////////////////////////
  // CSRs (Control and Status Registers) //
  /////////////////////////////////////////

  assign csr_wdata  = alu_operand_a_ex;

  ibex_cs_registers #(
    .DbgTriggerEn     (DbgTriggerEn),
    .DbgHwBreakNum    (DbgHwBreakNum),
    .DataIndTiming    (DataIndTiming),
    .DummyInstructions(DummyInstructions),
    .ShadowCSR        (ShadowCSR),
    .ICache           (ICache),
    .MHPMCounterNum   (MHPMCounterNum),
    .MHPMCounterWidth (MHPMCounterWidth),
    .PMPEnable        (PMPEnable),
    .PMPGranularity   (PMPGranularity),
    .PMPNumRegions    (PMPNumRegions),
    .PMPRstCfg        (PMPRstCfg),
    .PMPRstAddr       (PMPRstAddr),
    .PMPRstMsecCfg    (PMPRstMsecCfg),
    .RV32E            (RV32E),
    .RV32M            (RV32M),
    .RV32B            (RV32B),
    .CsrMvendorId     (CsrMvendorId),
    .CsrMimpId        (CsrMimpId)
  ) cs_registers_i (
    .clk_i (clk_i),
    .rst_ni(rst_ni),

    .hart_id_i      (hart_id_i),
    .priv_mode_id_o (priv_mode_id),
    .priv_mode_lsu_o(priv_mode_lsu),

    .csr_mtvec_o     (csr_mtvec),
    .csr_mtvec_init_i(csr_mtvec_init),
    .boot_addr_i     (boot_addr_i),

    .csr_access_i(csr_access),
    .csr_addr_i  (csr_addr),
    .csr_wdata_i (csr_wdata),
    .csr_op_i    (csr_op),
    .csr_op_en_i (csr_op_en),
    .csr_rdata_o (csr_rdata),

    //DIFT TPR and TCR outputs
    // programmed at startup by a runtime routine, mapped as 32-bit CSR
    // registers at addresses CSR_TPR=0x7C3 and CSR_TCR=0x7C2 (in ibex_pkg.sv).
`ifdef DIFT
    .tpr_o (tpr_csr),
    .tcr_o (tcr_csr),
`endif

    .irq_software_i   (irq_software_i),
    .irq_timer_i      (irq_timer_i),
    .irq_external_i   (irq_external_i),
    .irq_fast_i       (irq_fast_i),
    .nmi_mode_i       (nmi_mode),
    .irq_pending_o    (irq_pending_o),
    .irqs_o           (irqs),
    .csr_mstatus_mie_o(csr_mstatus_mie),
    .csr_mstatus_tw_o (csr_mstatus_tw),
    .csr_mepc_o       (csr_mepc),
    .csr_mtval_o      (crash_dump_mtval),

    .csr_pmp_cfg_o    (csr_pmp_cfg),
    .csr_pmp_addr_o   (csr_pmp_addr),
    .csr_pmp_mseccfg_o(csr_pmp_mseccfg),

    .csr_depc_o           (csr_depc),
    .debug_mode_i         (debug_mode),
    .debug_mode_entering_i(debug_mode_entering),
    .debug_cause_i        (debug_cause),
    .debug_csr_save_i     (debug_csr_save),
    .debug_single_step_o  (debug_single_step),
    .debug_ebreakm_o      (debug_ebreakm),
    .debug_ebreaku_o      (debug_ebreaku),
    .trigger_match_o      (trigger_match),

    .pc_if_i(pc_if),
    .pc_id_i(pc_id),
    .pc_wb_i(pc_wb),

    .data_ind_timing_o    (data_ind_timing),
    .dummy_instr_en_o     (dummy_instr_en),
    .dummy_instr_mask_o   (dummy_instr_mask),
    .dummy_instr_seed_en_o(dummy_instr_seed_en),
    .dummy_instr_seed_o   (dummy_instr_seed),
    .icache_enable_o      (icache_enable),
    .csr_shadow_err_o     (csr_shadow_err),
    .ic_scr_key_valid_i   (ic_scr_key_valid_i),

    .csr_save_if_i     (csr_save_if),
    .csr_save_id_i     (csr_save_id),
    .csr_save_wb_i     (csr_save_wb),
    .csr_restore_mret_i(csr_restore_mret_id),
    .csr_restore_dret_i(csr_restore_dret_id),
    .csr_save_cause_i  (csr_save_cause),
    .csr_mcause_i      (exc_cause),
    .csr_mtval_i       (csr_mtval),
    .illegal_csr_insn_o(illegal_csr_insn_id),

    .double_fault_seen_o,

    .instr_ret_i                (perf_instr_ret_wb),
    .instr_ret_compressed_i     (perf_instr_ret_compressed_wb),
    .instr_ret_spec_i           (perf_instr_ret_wb_spec),
    .instr_ret_compressed_spec_i(perf_instr_ret_compressed_wb_spec),
    .iside_wait_i               (perf_iside_wait),
    .jump_i                     (perf_jump),
    .branch_i                   (perf_branch),
    .branch_taken_i             (perf_tbranch),
    .mem_load_i                 (perf_load),
    .mem_store_i                (perf_store),
    .dside_wait_i               (perf_dside_wait),
    .mul_wait_i                 (perf_mul_wait),
    .div_wait_i                 (perf_div_wait)
  );

  `ASSERT(IbexCsrOpValid, instr_valid_id |-> csr_op inside {
      CSR_OP_READ, CSR_OP_WRITE, CSR_OP_SET, CSR_OP_CLEAR })
  `ASSERT_KNOWN_IF(IbexCsrWdataIntKnown, cs_registers_i.csr_wdata_int, csr_op_en)

  // ===========================================================================
  // DIFT Security exception output
  // Sources of DIFT exceptions in this implementation:
  //   load_exception : raised by riscv_load_check when a load violates TCR
  //                    (tainted address or tainted source used as load address)
  //   lsu_tag_err    : raised by ibex_load_store_unit when the memory address
  //                    itself is tainted and LOADSTORE_CHECK_DA bit is set
  // ===========================================================================


  if (PMPEnable) begin : g_pmp
    logic [31:0]           pc_if_inc;
    logic [PMP_ADDR_MSB:0] pmp_req_addr [PMPNumChan];
    pmp_req_e              pmp_req_type [PMPNumChan];
    priv_lvl_e             pmp_priv_lvl [PMPNumChan];

    assign pc_if_inc            = pc_if + 32'd2;
    assign pmp_req_addr[PMP_I]  = {2'b00, pc_if};
    assign pmp_req_type[PMP_I]  = PMP_ACC_EXEC;
    assign pmp_priv_lvl[PMP_I]  = priv_mode_id;
    assign pmp_req_addr[PMP_I2] = {2'b00, pc_if_inc};
    assign pmp_req_type[PMP_I2] = PMP_ACC_EXEC;
    assign pmp_priv_lvl[PMP_I2] = priv_mode_id;
    assign pmp_req_addr[PMP_D]  = {2'b00, data_addr_o[31:0]};
    assign pmp_req_type[PMP_D]  = data_we_o ? PMP_ACC_WRITE : PMP_ACC_READ;
    assign pmp_priv_lvl[PMP_D]  = priv_mode_lsu;

    ibex_pmp #(
      .DmBaseAddr    (DmBaseAddr),
      .DmAddrMask    (DmAddrMask),
      .PMPGranularity(PMPGranularity),
      .PMPNumChan    (PMPNumChan),
      .PMPNumRegions (PMPNumRegions)
    ) pmp_i (
      .csr_pmp_cfg_i    (csr_pmp_cfg),
      .csr_pmp_addr_i   (csr_pmp_addr),
      .csr_pmp_mseccfg_i(csr_pmp_mseccfg),
      .debug_mode_i     (debug_mode),
      .priv_mode_i      (pmp_priv_lvl),
      .pmp_req_addr_i   (pmp_req_addr),
      .pmp_req_type_i   (pmp_req_type),
      .pmp_req_err_o    (pmp_req_err)
    );
  end else begin : g_no_pmp
    priv_lvl_e             unused_priv_lvl_ls;
    logic [PMP_ADDR_MSB:0] unused_csr_pmp_addr [PMPNumRegions];
    pmp_cfg_t              unused_csr_pmp_cfg  [PMPNumRegions];
    pmp_mseccfg_t          unused_csr_pmp_mseccfg;
    assign unused_priv_lvl_ls    = priv_mode_lsu;
    assign unused_csr_pmp_addr   = csr_pmp_addr;
    assign unused_csr_pmp_cfg    = csr_pmp_cfg;
    assign unused_csr_pmp_mseccfg = csr_pmp_mseccfg;
    assign pmp_req_err[PMP_I]  = 1'b0;
    assign pmp_req_err[PMP_I2] = 1'b0;
    assign pmp_req_err[PMP_D]  = 1'b0;
  end

`ifdef RVFI
    // When writeback stage is present RVFI information is emitted when instruction is finished in
  // third stage but some information must be captured whilst the instruction is in the second
  // stage. Without writeback stage RVFI information is all emitted when instruction retires in
  // second stage. RVFI outputs are all straight from flops. So 2 stage pipeline requires a single
  // set of flops (instr_info => RVFI_out), 3 stage pipeline requires two sets (instr_info => wb
  // => RVFI_out)
  localparam int RVFI_STAGES = WritebackStage ? 2 : 1;

  logic        rvfi_stage_valid     [RVFI_STAGES];
  logic [63:0] rvfi_stage_order     [RVFI_STAGES];
  logic [31:0] rvfi_stage_insn      [RVFI_STAGES];
  logic        rvfi_stage_trap      [RVFI_STAGES];
  logic        rvfi_stage_halt      [RVFI_STAGES];
  logic        rvfi_stage_intr      [RVFI_STAGES];
  logic [ 1:0] rvfi_stage_mode      [RVFI_STAGES];
  logic [ 1:0] rvfi_stage_ixl       [RVFI_STAGES];
  logic [ 4:0] rvfi_stage_rs1_addr  [RVFI_STAGES];
  logic [ 4:0] rvfi_stage_rs2_addr  [RVFI_STAGES];
  logic [ 4:0] rvfi_stage_rs3_addr  [RVFI_STAGES];
  logic [31:0] rvfi_stage_rs1_rdata [RVFI_STAGES];
  logic [31:0] rvfi_stage_rs2_rdata [RVFI_STAGES];
  logic [31:0] rvfi_stage_rs3_rdata [RVFI_STAGES];
  logic [ 4:0] rvfi_stage_rd_addr   [RVFI_STAGES];
  logic [31:0] rvfi_stage_rd_wdata  [RVFI_STAGES];
  logic [31:0] rvfi_stage_pc_rdata  [RVFI_STAGES];
  logic [31:0] rvfi_stage_pc_wdata  [RVFI_STAGES];
  logic [31:0] rvfi_stage_mem_addr  [RVFI_STAGES];
  logic [ 3:0] rvfi_stage_mem_rmask [RVFI_STAGES];
  logic [ 3:0] rvfi_stage_mem_wmask [RVFI_STAGES];
  logic [31:0] rvfi_stage_mem_rdata [RVFI_STAGES];
  logic [31:0] rvfi_stage_mem_wdata [RVFI_STAGES];

  logic        rvfi_instr_new_wb;
  logic        rvfi_intr_d;
  logic        rvfi_intr_q;
  logic        rvfi_set_trap_pc_d;
  logic        rvfi_set_trap_pc_q;
  logic [31:0] rvfi_insn_id;
  logic [4:0]  rvfi_rs1_addr_d;
  logic [4:0]  rvfi_rs1_addr_q;
  logic [4:0]  rvfi_rs2_addr_d;
  logic [4:0]  rvfi_rs2_addr_q;
  logic [4:0]  rvfi_rs3_addr_d;
  logic [31:0] rvfi_rs1_data_d;
  logic [31:0] rvfi_rs1_data_q;
  logic [31:0] rvfi_rs2_data_d;
  logic [31:0] rvfi_rs2_data_q;
  logic [31:0] rvfi_rs3_data_d;
  logic [4:0]  rvfi_rd_addr_wb;
  logic [4:0]  rvfi_rd_addr_q;
  logic [4:0]  rvfi_rd_addr_d;
  logic [31:0] rvfi_rd_wdata_wb;
  logic [31:0] rvfi_rd_wdata_d;
  logic [31:0] rvfi_rd_wdata_q;
  logic        rvfi_rd_we_wb;
  logic [3:0]  rvfi_mem_mask_int;
  logic [31:0] rvfi_mem_rdata_d;
  logic [31:0] rvfi_mem_rdata_q;
  logic [31:0] rvfi_mem_wdata_d;
  logic [31:0] rvfi_mem_wdata_q;
  logic [31:0] rvfi_mem_addr_d;
  logic [31:0] rvfi_mem_addr_q;
  logic        rvfi_trap_id;
  logic        rvfi_trap_wb;
  logic        rvfi_irq_valid;
  logic [63:0] rvfi_stage_order_d;
  logic        rvfi_id_done;
  logic        rvfi_wb_done;

  logic            new_debug_req;
  logic            new_nmi;
  logic            new_nmi_int;
  logic            new_irq;
  ibex_pkg::irqs_t captured_mip;
  logic            captured_nmi;
  logic            captured_nmi_int;
  logic            captured_debug_req;
  logic            captured_valid;

  // RVFI extension for co-simulation support
  // debug_req and MIP captured at IF -> ID transition so one extra stage
  ibex_pkg::irqs_t rvfi_ext_stage_pre_mip             [RVFI_STAGES+1];
  ibex_pkg::irqs_t rvfi_ext_stage_post_mip            [RVFI_STAGES];
  logic            rvfi_ext_stage_nmi                 [RVFI_STAGES+1];
  logic            rvfi_ext_stage_nmi_int             [RVFI_STAGES+1];
  logic            rvfi_ext_stage_debug_req           [RVFI_STAGES+1];
  logic            rvfi_ext_stage_debug_mode          [RVFI_STAGES];
  logic [63:0]     rvfi_ext_stage_mcycle              [RVFI_STAGES];
  logic [31:0]     rvfi_ext_stage_mhpmcounters        [RVFI_STAGES][10];
  logic [31:0]     rvfi_ext_stage_mhpmcountersh       [RVFI_STAGES][10];
  logic            rvfi_ext_stage_ic_scr_key_valid    [RVFI_STAGES];
  logic            rvfi_ext_stage_irq_valid           [RVFI_STAGES+1];
  logic            rvfi_ext_stage_expanded_insn_valid [RVFI_STAGES];
  logic [15:0]     rvfi_ext_stage_expanded_insn       [RVFI_STAGES];
  logic            rvfi_ext_stage_expanded_insn_last  [RVFI_STAGES];

  logic            rvfi_expanded_insn_valid;
  logic [15:0]     rvfi_expanded_insn;
  logic            rvfi_expanded_insn_last;


  logic        rvfi_stage_valid_d   [RVFI_STAGES];

  assign rvfi_valid     = rvfi_stage_valid    [RVFI_STAGES-1];
  assign rvfi_order     = rvfi_stage_order    [RVFI_STAGES-1];
  assign rvfi_insn      = rvfi_stage_insn     [RVFI_STAGES-1];
  assign rvfi_trap      = rvfi_stage_trap     [RVFI_STAGES-1];
  assign rvfi_halt      = rvfi_stage_halt     [RVFI_STAGES-1];
  assign rvfi_intr      = rvfi_stage_intr     [RVFI_STAGES-1];
  assign rvfi_mode      = rvfi_stage_mode     [RVFI_STAGES-1];
  assign rvfi_ixl       = rvfi_stage_ixl      [RVFI_STAGES-1];
  assign rvfi_rs1_addr  = rvfi_stage_rs1_addr [RVFI_STAGES-1];
  assign rvfi_rs2_addr  = rvfi_stage_rs2_addr [RVFI_STAGES-1];
  assign rvfi_rs3_addr  = rvfi_stage_rs3_addr [RVFI_STAGES-1];
  assign rvfi_rs1_rdata = rvfi_stage_rs1_rdata[RVFI_STAGES-1];
  assign rvfi_rs2_rdata = rvfi_stage_rs2_rdata[RVFI_STAGES-1];
  assign rvfi_rs3_rdata = rvfi_stage_rs3_rdata[RVFI_STAGES-1];
  assign rvfi_rd_addr   = rvfi_stage_rd_addr  [RVFI_STAGES-1];
  assign rvfi_rd_wdata  = rvfi_stage_rd_wdata [RVFI_STAGES-1];
  assign rvfi_pc_rdata  = rvfi_stage_pc_rdata [RVFI_STAGES-1];
  assign rvfi_pc_wdata  = rvfi_stage_pc_wdata [RVFI_STAGES-1];
  assign rvfi_mem_addr  = rvfi_stage_mem_addr [RVFI_STAGES-1];
  assign rvfi_mem_rmask = rvfi_stage_mem_rmask[RVFI_STAGES-1];
  assign rvfi_mem_wmask = rvfi_stage_mem_wmask[RVFI_STAGES-1];
  assign rvfi_mem_rdata = rvfi_stage_mem_rdata[RVFI_STAGES-1];
  assign rvfi_mem_wdata = rvfi_stage_mem_wdata[RVFI_STAGES-1];

  assign rvfi_rd_addr_wb  = rf_waddr_wb;
  assign rvfi_rd_wdata_wb = rf_we_wb ? rf_wdata_wb : rf_wdata_lsu;
  assign rvfi_rd_we_wb    = rf_we_wb | rf_we_lsu;

  always_comb begin
    // Use always_comb instead of continuous assign so first assign can set 0 as default everywhere
    // that is overridden by more specific settings.
    rvfi_ext_pre_mip               = '0;
    rvfi_ext_pre_mip[CSR_MSIX_BIT] = rvfi_ext_stage_pre_mip[RVFI_STAGES].irq_software;
    rvfi_ext_pre_mip[CSR_MTIX_BIT] = rvfi_ext_stage_pre_mip[RVFI_STAGES].irq_timer;
    rvfi_ext_pre_mip[CSR_MEIX_BIT] = rvfi_ext_stage_pre_mip[RVFI_STAGES].irq_external;

    rvfi_ext_pre_mip[CSR_MFIX_BIT_HIGH:CSR_MFIX_BIT_LOW] =
      rvfi_ext_stage_pre_mip[RVFI_STAGES].irq_fast;

    rvfi_ext_post_mip               = '0;
    rvfi_ext_post_mip[CSR_MSIX_BIT] = rvfi_ext_stage_post_mip[RVFI_STAGES-1].irq_software;
    rvfi_ext_post_mip[CSR_MTIX_BIT] = rvfi_ext_stage_post_mip[RVFI_STAGES-1].irq_timer;
    rvfi_ext_post_mip[CSR_MEIX_BIT] = rvfi_ext_stage_post_mip[RVFI_STAGES-1].irq_external;

    rvfi_ext_post_mip[CSR_MFIX_BIT_HIGH:CSR_MFIX_BIT_LOW] =
      rvfi_ext_stage_post_mip[RVFI_STAGES-1].irq_fast;
  end

  assign rvfi_ext_nmi                 = rvfi_ext_stage_nmi                 [RVFI_STAGES];
  assign rvfi_ext_nmi_int             = rvfi_ext_stage_nmi_int             [RVFI_STAGES];
  assign rvfi_ext_debug_req           = rvfi_ext_stage_debug_req           [RVFI_STAGES];
  assign rvfi_ext_debug_mode          = rvfi_ext_stage_debug_mode          [RVFI_STAGES-1];
  assign rvfi_ext_mcycle              = rvfi_ext_stage_mcycle              [RVFI_STAGES-1];
  assign rvfi_ext_mhpmcounters        = rvfi_ext_stage_mhpmcounters        [RVFI_STAGES-1];
  assign rvfi_ext_mhpmcountersh       = rvfi_ext_stage_mhpmcountersh       [RVFI_STAGES-1];
  assign rvfi_ext_ic_scr_key_valid    = rvfi_ext_stage_ic_scr_key_valid    [RVFI_STAGES-1];
  assign rvfi_ext_irq_valid           = rvfi_ext_stage_irq_valid           [RVFI_STAGES];
  assign rvfi_ext_expanded_insn_valid = rvfi_ext_stage_expanded_insn_valid [RVFI_STAGES-1];
  assign rvfi_ext_expanded_insn       = rvfi_ext_stage_expanded_insn       [RVFI_STAGES-1];
  assign rvfi_ext_expanded_insn_last  = rvfi_ext_stage_expanded_insn_last  [RVFI_STAGES-1];

  // When an instruction takes a trap the `rvfi_trap` signal will be set. Instructions that take
  // traps flush the pipeline so ordinarily wouldn't be seen to be retire. The RVFI tracking
  // pipeline is kept going for flushed instructions that trapped so they are still visible on the
  // RVFI interface.

  // Factor in exceptions taken in ID so RVFI tracking picks up flushed instructions that took
  // a trap
  assign rvfi_id_done = instr_id_done | (id_stage_i.controller_i.rvfi_flush_next &
                                         id_stage_i.controller_i.id_exception_o);

  if (WritebackStage) begin : gen_rvfi_wb_stage
    logic unused_instr_new_id;

    assign unused_instr_new_id = instr_new_id;

    // With writeback stage first RVFI stage buffers instruction information captured in ID/EX
    // awaiting instruction retirement and RF Write data/Mem read data whilst instruction is in WB
    // So first stage becomes valid when instruction leaves ID/EX stage and remains valid until
    // instruction leaves WB
    assign rvfi_stage_valid_d[0] = (rvfi_id_done & ~dummy_instr_id) |
                                   (rvfi_stage_valid[0] & ~rvfi_wb_done);
    // Second stage is output stage so simple valid cycle after instruction leaves WB (and so has
    // retired)
    assign rvfi_stage_valid_d[1] = rvfi_wb_done;

    // Signal new instruction in WB cycle after instruction leaves ID/EX (to enter WB)
    logic rvfi_instr_new_wb_q;

    // Signal new instruction in WB either when one has just entered or when a trap is progressing
    // through the tracking pipeline
    assign rvfi_instr_new_wb = rvfi_instr_new_wb_q | (rvfi_stage_valid[0] & rvfi_stage_trap[0]);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        rvfi_instr_new_wb_q <= 0;
      end else begin
        rvfi_instr_new_wb_q <= rvfi_id_done;
      end
    end

    assign rvfi_trap_id = id_stage_i.controller_i.id_exception_o &
      ~(id_stage_i.ebrk_insn & id_stage_i.controller_i.ebreak_into_debug);

    assign rvfi_trap_wb = id_stage_i.controller_i.exc_req_lsu;
    // WB is instantly done in the tracking pipeline when a trap is progress through the pipeline
    assign rvfi_wb_done = rvfi_stage_valid[0] & (instr_done_wb | rvfi_stage_trap[0]);
  end else begin : gen_rvfi_no_wb_stage
    // Without writeback stage first RVFI stage is output stage so simply valid the cycle after
    // instruction leaves ID/EX (and so has retired)
    assign rvfi_stage_valid_d[0] = rvfi_id_done & ~dummy_instr_id;
    // Without writeback stage signal new instr_new_wb when instruction enters ID/EX to correctly
    // setup register write signals
    assign rvfi_instr_new_wb = instr_new_id;
    assign rvfi_trap_id =
      (id_stage_i.controller_i.exc_req_d | id_stage_i.controller_i.exc_req_lsu) &
      ~(id_stage_i.ebrk_insn & id_stage_i.controller_i.ebreak_into_debug);
    assign rvfi_trap_wb = 1'b0;
    assign rvfi_wb_done = instr_done_wb;
  end

  assign rvfi_stage_order_d = dummy_instr_id ? rvfi_stage_order[0] : rvfi_stage_order[0] + 64'd1;

  // For interrupts and debug Ibex will take the relevant trap as soon as whatever instruction in ID
  // finishes or immediately if the ID stage is empty. The rvfi_ext interface provides the DV
  // environment with information about the irq/debug_req/nmi state that applies to a particular
  // instruction.
  //
  // When a irq/debug_req/nmi appears the ID stage will finish whatever instruction it is currently
  // executing (if any) then take the trap the cycle after that instruction leaves the ID stage. The
  // trap taken depends upon the state of irq/debug_req/nmi on that cycle. In the cycles following
  // that before the first instruction of the trap handler enters the ID stage the state of
  // irq/debug_req/nmi could change but this has no effect on the trap handler (e.g. a higher
  // priority interrupt might appear but this wouldn't stop the lower priority interrupt trap
  // handler executing first as it's already being fetched). To provide the DV environment with the
  // correct information for it to verify execution we need to capture the irq/debug_req/nmi state
  // the cycle the trap decision is made. Which the captured_X signals below do.
  //
  // The new_X signals take the raw irq/debug_req/nmi inputs and factor in the enable terms required
  // to determine if a trap will actually happen.
  //
  // These signals and the comment above are referred to in the documentation (cosim.rst). If
  // altering the names or meanings of these signals or this comment please adjust the documentation
  // appropriately.
  assign new_debug_req = (debug_req_i & ~debug_mode);
  assign new_nmi = irq_nm_i & ~nmi_mode & ~debug_mode;
  assign new_nmi_int = id_stage_i.controller_i.irq_nm_int & ~nmi_mode & ~debug_mode;
  assign new_irq = irq_pending_o & (csr_mstatus_mie || (priv_mode_id == PRIV_LVL_U)) & ~nmi_mode &
                   ~debug_mode;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      captured_valid     <= 1'b0;
      captured_mip       <= '0;
      captured_nmi       <= 1'b0;
      captured_nmi_int   <= 1'b0;
      captured_debug_req <= 1'b0;
      rvfi_irq_valid     <= 1'b0;
    end else  begin
      // Capture when ID stage has emptied out and something occurs that will cause a trap and we
      // haven't yet captured
      //
      // When we already captured a trap, and there is upcoming nmi interrupt or
      // a debug request then recapture as nmi or debug request are supposed to
      // be serviced.
      if (~instr_valid_id & (new_debug_req | new_irq | new_nmi | new_nmi_int) &
          ((~captured_valid) |
           (new_debug_req & ~captured_debug_req) |
           (new_nmi & ~captured_nmi & ~captured_debug_req))) begin
        captured_valid     <= 1'b1;
        captured_nmi       <= irq_nm_i;
        captured_nmi_int   <= id_stage_i.controller_i.irq_nm_int;
        captured_mip       <= cs_registers_i.mip;
        captured_debug_req <= debug_req_i;
      end

      // When the pipeline has emptied in preparation for handling a new interrupt send
      // a notification up the RVFI pipeline. This is used by the cosim to deal with cases where an
      // interrupt occurs before another interrupt or debug request but both occur before the first
      // instruction of the handler is executed and retired (where the cosim will see all the
      // interrupts and debug requests at once with no way to determine which occurred first).
      if (~instr_valid_id & ~new_debug_req & (new_irq | new_nmi | new_nmi_int) & ready_wb &
          ~captured_valid) begin
        rvfi_irq_valid <= 1'b1;
      end else begin
        rvfi_irq_valid <= 1'b0;
      end

      // Capture cleared out as soon as a new instruction appears in ID
      if (if_stage_i.instr_valid_id_d) begin
        captured_valid <= 1'b0;
      end
    end
  end

  // Pass the captured irq/debug_req/nmi state to the rvfi_ext interface tracking pipeline.
  //
  // To correctly capture we need to factor in various enable terms, should there be a fault in this
  // logic we won't tell the DV environment about a trap that should have been taken. So if there's
  // no valid capture we grab the raw values of the irq/debug_req/nmi inputs whatever they are and
  // the DV environment will see if a trap should have been taken but wasn't.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvfi_ext_stage_pre_mip[0]       <= '0;
      rvfi_ext_stage_nmi[0]       <= '0;
      rvfi_ext_stage_nmi_int[0]   <= '0;
      rvfi_ext_stage_debug_req[0] <= '0;
    end else if ((if_stage_i.instr_valid_id_d & if_stage_i.instr_new_id_d) | rvfi_irq_valid) begin
      rvfi_ext_stage_pre_mip[0]   <= instr_valid_id | ~captured_valid ? cs_registers_i.mip :
                                                                        captured_mip;
      rvfi_ext_stage_nmi[0]       <= instr_valid_id | ~captured_valid ? irq_nm_i :
                                                                        captured_nmi;
      rvfi_ext_stage_nmi_int[0]   <=
        instr_valid_id | ~captured_valid ? id_stage_i.controller_i.irq_nm_int :
                                           captured_nmi_int;
      rvfi_ext_stage_debug_req[0] <= instr_valid_id | ~captured_valid ? debug_req_i        :
                                                                        captured_debug_req;
    end
  end


  // rvfi_irq_valid signals an interrupt event to the cosim. These should only occur when the RVFI
  // pipe is empty so just send it straight through.
  for (genvar i = 0; i < RVFI_STAGES + 1; i = i + 1) begin : g_rvfi_irq_valid
    if (i == 0) begin : g_rvfi_irq_valid_first_stage
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          rvfi_ext_stage_irq_valid[i] <= 1'b0;
        end else begin
          rvfi_ext_stage_irq_valid[i] <= rvfi_irq_valid;
        end
      end
    end else begin : g_rvfi_irq_valid_other_stages
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          rvfi_ext_stage_irq_valid[i] <= 1'b0;
        end else begin
          rvfi_ext_stage_irq_valid[i] <= rvfi_ext_stage_irq_valid[i-1];
        end
      end
    end
  end

  for (genvar i = 0; i < RVFI_STAGES; i = i + 1) begin : g_rvfi_stages
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        rvfi_stage_halt[i]                    <= '0;
        rvfi_stage_trap[i]                    <= '0;
        rvfi_stage_intr[i]                    <= '0;
        rvfi_stage_order[i]                   <= '0;
        rvfi_stage_insn[i]                    <= '0;
        rvfi_stage_mode[i]                    <= {PRIV_LVL_M};
        rvfi_stage_ixl[i]                     <= CSR_MISA_MXL;
        rvfi_stage_rs1_addr[i]                <= '0;
        rvfi_stage_rs2_addr[i]                <= '0;
        rvfi_stage_rs3_addr[i]                <= '0;
        rvfi_stage_pc_rdata[i]                <= '0;
        rvfi_stage_pc_wdata[i]                <= '0;
        rvfi_stage_mem_rmask[i]               <= '0;
        rvfi_stage_mem_wmask[i]               <= '0;
        rvfi_stage_valid[i]                   <= '0;
        rvfi_stage_rs1_rdata[i]               <= '0;
        rvfi_stage_rs2_rdata[i]               <= '0;
        rvfi_stage_rs3_rdata[i]               <= '0;
        rvfi_stage_rd_wdata[i]                <= '0;
        rvfi_stage_rd_addr[i]                 <= '0;
        rvfi_stage_mem_rdata[i]               <= '0;
        rvfi_stage_mem_wdata[i]               <= '0;
        rvfi_stage_mem_addr[i]                <= '0;
        rvfi_ext_stage_pre_mip[i+1]           <= '0;
        rvfi_ext_stage_post_mip[i]            <= '0;
        rvfi_ext_stage_nmi[i+1]               <= '0;
        rvfi_ext_stage_nmi_int[i+1]           <= '0;
        rvfi_ext_stage_debug_req[i+1]         <= '0;
        rvfi_ext_stage_debug_mode[i]          <= '0;
        rvfi_ext_stage_mcycle[i]              <= '0;
        rvfi_ext_stage_ic_scr_key_valid[i]    <= '0;
        rvfi_ext_stage_expanded_insn_valid[i] <= '0;
        rvfi_ext_stage_expanded_insn[i]       <= '0;
        rvfi_ext_stage_expanded_insn_last[i]  <= '0;
        // DSim does not properly support array assignment in for loop, so unroll
        rvfi_ext_stage_mhpmcounters[i][0]     <= '0;
        rvfi_ext_stage_mhpmcountersh[i][0]    <= '0;
        rvfi_ext_stage_mhpmcounters[i][1]     <= '0;
        rvfi_ext_stage_mhpmcountersh[i][1]    <= '0;
        rvfi_ext_stage_mhpmcounters[i][2]     <= '0;
        rvfi_ext_stage_mhpmcountersh[i][2]    <= '0;
        rvfi_ext_stage_mhpmcounters[i][3]     <= '0;
        rvfi_ext_stage_mhpmcountersh[i][3]    <= '0;
        rvfi_ext_stage_mhpmcounters[i][4]     <= '0;
        rvfi_ext_stage_mhpmcountersh[i][4]    <= '0;
        rvfi_ext_stage_mhpmcounters[i][5]     <= '0;
        rvfi_ext_stage_mhpmcountersh[i][5]    <= '0;
        rvfi_ext_stage_mhpmcounters[i][6]     <= '0;
        rvfi_ext_stage_mhpmcountersh[i][6]    <= '0;
        rvfi_ext_stage_mhpmcounters[i][7]     <= '0;
        rvfi_ext_stage_mhpmcountersh[i][7]    <= '0;
        rvfi_ext_stage_mhpmcounters[i][8]     <= '0;
        rvfi_ext_stage_mhpmcountersh[i][8]    <= '0;
        rvfi_ext_stage_mhpmcounters[i][9]     <= '0;
        rvfi_ext_stage_mhpmcountersh[i][9]    <= '0;
      end else begin
        rvfi_stage_valid[i] <= rvfi_stage_valid_d[i];

        if (i == 0) begin
          if (rvfi_id_done) begin
            rvfi_stage_halt[i]                    <= '0;
            rvfi_stage_trap[i]                    <= rvfi_trap_id;
            rvfi_stage_intr[i]                    <= rvfi_intr_d;
            rvfi_stage_order[i]                   <= rvfi_stage_order_d;
            rvfi_stage_insn[i]                    <= rvfi_insn_id;
            rvfi_stage_mode[i]                    <= {priv_mode_id};
            rvfi_stage_ixl[i]                     <= CSR_MISA_MXL;
            rvfi_stage_rs1_addr[i]                <= rvfi_rs1_addr_d;
            rvfi_stage_rs2_addr[i]                <= rvfi_rs2_addr_d;
            rvfi_stage_rs3_addr[i]                <= rvfi_rs3_addr_d;
            rvfi_stage_pc_rdata[i]                <= pc_id;
            rvfi_stage_pc_wdata[i]                <= pc_set ? branch_target_ex : pc_if;
            rvfi_stage_mem_rmask[i]               <= data_we_o ? 4'b0000 : rvfi_mem_mask_int;
            rvfi_stage_mem_wmask[i]               <= data_we_o ? rvfi_mem_mask_int : 4'b0000;
            rvfi_stage_rs1_rdata[i]               <= rvfi_rs1_data_d;
            rvfi_stage_rs2_rdata[i]               <= rvfi_rs2_data_d;
            rvfi_stage_rs3_rdata[i]               <= rvfi_rs3_data_d;
            rvfi_stage_rd_addr[i]                 <= rvfi_rd_addr_d;
            rvfi_stage_rd_wdata[i]                <= rvfi_rd_wdata_d;
            rvfi_stage_mem_rdata[i]               <= rvfi_mem_rdata_d;
            rvfi_stage_mem_wdata[i]               <= rvfi_mem_wdata_d;
            rvfi_stage_mem_addr[i]                <= rvfi_mem_addr_d;
            rvfi_ext_stage_debug_mode[i]          <= debug_mode;
            rvfi_ext_stage_mcycle[i]              <= cs_registers_i.mcycle_counter_i.counter_val_o;
            rvfi_ext_stage_ic_scr_key_valid[i]    <= cs_registers_i.cpuctrlsts_ic_scr_key_valid_q;
            rvfi_ext_stage_expanded_insn_valid[i] <= rvfi_expanded_insn_valid;
            rvfi_ext_stage_expanded_insn[i]       <= rvfi_expanded_insn;
            rvfi_ext_stage_expanded_insn_last[i]  <= rvfi_expanded_insn_last;
            // DSim does not properly support array assignment in for loop, so unroll
            rvfi_ext_stage_mhpmcounters[i][0]     <= cs_registers_i.mhpmcounter[3][31:0];
            rvfi_ext_stage_mhpmcountersh[i][0]    <= cs_registers_i.mhpmcounter[3][63:32];
            rvfi_ext_stage_mhpmcounters[i][1]     <= cs_registers_i.mhpmcounter[4][31:0];
            rvfi_ext_stage_mhpmcountersh[i][1]    <= cs_registers_i.mhpmcounter[4][63:32];
            rvfi_ext_stage_mhpmcounters[i][2]     <= cs_registers_i.mhpmcounter[5][31:0];
            rvfi_ext_stage_mhpmcountersh[i][2]    <= cs_registers_i.mhpmcounter[5][63:32];
            rvfi_ext_stage_mhpmcounters[i][3]     <= cs_registers_i.mhpmcounter[6][31:0];
            rvfi_ext_stage_mhpmcountersh[i][3]    <= cs_registers_i.mhpmcounter[6][63:32];
            rvfi_ext_stage_mhpmcounters[i][4]     <= cs_registers_i.mhpmcounter[7][31:0];
            rvfi_ext_stage_mhpmcountersh[i][4]    <= cs_registers_i.mhpmcounter[7][63:32];
            rvfi_ext_stage_mhpmcounters[i][5]     <= cs_registers_i.mhpmcounter[8][31:0];
            rvfi_ext_stage_mhpmcountersh[i][5]    <= cs_registers_i.mhpmcounter[8][63:32];
            rvfi_ext_stage_mhpmcounters[i][6]     <= cs_registers_i.mhpmcounter[9][31:0];
            rvfi_ext_stage_mhpmcountersh[i][6]    <= cs_registers_i.mhpmcounter[9][63:32];
            rvfi_ext_stage_mhpmcounters[i][7]     <= cs_registers_i.mhpmcounter[10][31:0];
            rvfi_ext_stage_mhpmcountersh[i][7]    <= cs_registers_i.mhpmcounter[10][63:32];
            rvfi_ext_stage_mhpmcounters[i][8]     <= cs_registers_i.mhpmcounter[11][31:0];
            rvfi_ext_stage_mhpmcountersh[i][8]    <= cs_registers_i.mhpmcounter[11][63:32];
            rvfi_ext_stage_mhpmcounters[i][9]     <= cs_registers_i.mhpmcounter[12][31:0];
            rvfi_ext_stage_mhpmcountersh[i][9]    <= cs_registers_i.mhpmcounter[12][63:32];
          end

          // Some of the rvfi_ext_* signals are used to provide an interrupt notification (signalled
          // via rvfi_ext_irq_valid) when there isn't a valid retired instruction as well as
          // providing information along with a retired instruction. Move these up the rvfi pipeline
          // for both cases.
          if (rvfi_id_done | rvfi_ext_stage_irq_valid[i]) begin
            rvfi_ext_stage_pre_mip[i+1]   <= rvfi_ext_stage_pre_mip[i];
            rvfi_ext_stage_post_mip[i]    <= cs_registers_i.mip;
            rvfi_ext_stage_nmi[i+1]       <= rvfi_ext_stage_nmi[i];
            rvfi_ext_stage_nmi_int[i+1]   <= rvfi_ext_stage_nmi_int[i];
            rvfi_ext_stage_debug_req[i+1] <= rvfi_ext_stage_debug_req[i];
          end
        end else begin
          if (rvfi_wb_done) begin
            rvfi_stage_halt[i]      <= rvfi_stage_halt[i-1];
            rvfi_stage_trap[i]      <= rvfi_stage_trap[i-1] | rvfi_trap_wb;
            rvfi_stage_intr[i]      <= rvfi_stage_intr[i-1];
            rvfi_stage_order[i]     <= rvfi_stage_order[i-1];
            rvfi_stage_insn[i]      <= rvfi_stage_insn[i-1];
            rvfi_stage_mode[i]      <= rvfi_stage_mode[i-1];
            rvfi_stage_ixl[i]       <= rvfi_stage_ixl[i-1];
            rvfi_stage_rs1_addr[i]  <= rvfi_stage_rs1_addr[i-1];
            rvfi_stage_rs2_addr[i]  <= rvfi_stage_rs2_addr[i-1];
            rvfi_stage_rs3_addr[i]  <= rvfi_stage_rs3_addr[i-1];
            rvfi_stage_pc_rdata[i]  <= rvfi_stage_pc_rdata[i-1];
            rvfi_stage_pc_wdata[i]  <= rvfi_stage_pc_wdata[i-1];
            rvfi_stage_mem_rmask[i] <= rvfi_stage_mem_rmask[i-1];
            rvfi_stage_mem_wmask[i] <= rvfi_stage_mem_wmask[i-1];
            rvfi_stage_rs1_rdata[i] <= rvfi_stage_rs1_rdata[i-1];
            rvfi_stage_rs2_rdata[i] <= rvfi_stage_rs2_rdata[i-1];
            rvfi_stage_rs3_rdata[i] <= rvfi_stage_rs3_rdata[i-1];
            rvfi_stage_mem_wdata[i] <= rvfi_stage_mem_wdata[i-1];
            rvfi_stage_mem_addr[i]  <= rvfi_stage_mem_addr[i-1];

            // For 2 RVFI_STAGES/Writeback Stage ignore first stage flops for rd_addr, rd_wdata and
            // mem_rdata. For RF write addr/data actual write happens in writeback so capture
            // address/data there. For mem_rdata that is only available from the writeback stage.
            // Previous stage flops still exist in RTL as they are used by the non writeback config
            rvfi_stage_rd_addr[i]   <= rvfi_rd_addr_d;
            rvfi_stage_rd_wdata[i]  <= rvfi_rd_wdata_d;
            rvfi_stage_mem_rdata[i] <= rvfi_mem_rdata_d;

            rvfi_ext_stage_debug_mode[i]          <= rvfi_ext_stage_debug_mode[i-1];
            rvfi_ext_stage_mcycle[i]              <= rvfi_ext_stage_mcycle[i-1];
            rvfi_ext_stage_ic_scr_key_valid[i]    <= rvfi_ext_stage_ic_scr_key_valid[i-1];
            rvfi_ext_stage_mhpmcounters[i]        <= rvfi_ext_stage_mhpmcounters[i-1];
            rvfi_ext_stage_mhpmcountersh[i]       <= rvfi_ext_stage_mhpmcountersh[i-1];
            rvfi_ext_stage_expanded_insn_valid[i] <= rvfi_ext_stage_expanded_insn_valid[i-1];
            rvfi_ext_stage_expanded_insn[i]       <= rvfi_ext_stage_expanded_insn[i-1];
            rvfi_ext_stage_expanded_insn_last[i]  <= rvfi_ext_stage_expanded_insn_last[i-1];
          end

          // Some of the rvfi_ext_* signals are used to provide an interrupt notification (signalled
          // via rvfi_ext_irq_valid) when there isn't a valid retired instruction as well as
          // providing information along with a retired instruction. Move these up the rvfi pipeline
          // for both cases.
          if (rvfi_wb_done | rvfi_ext_stage_irq_valid[i]) begin
            rvfi_ext_stage_pre_mip[i+1]   <= rvfi_ext_stage_pre_mip[i];
            rvfi_ext_stage_post_mip[i]    <= rvfi_ext_stage_post_mip[i-1];
            rvfi_ext_stage_nmi[i+1]       <= rvfi_ext_stage_nmi[i];
            rvfi_ext_stage_nmi_int[i+1]   <= rvfi_ext_stage_nmi_int[i];
            rvfi_ext_stage_debug_req[i+1] <= rvfi_ext_stage_debug_req[i];
          end
        end
      end
    end
  end


  // Memory address/write data available first cycle of ld/st instruction from register read
  always_comb begin
    if (instr_first_cycle_id) begin
      rvfi_mem_addr_d  = alu_adder_result_ex;
      rvfi_mem_wdata_d = lsu_wdata;
    end else begin
      rvfi_mem_addr_d  = rvfi_mem_addr_q;
      rvfi_mem_wdata_d = rvfi_mem_wdata_q;
    end
  end

  // Capture read data from LSU when it becomes valid
  always_comb begin
    if (lsu_resp_valid) begin
      rvfi_mem_rdata_d = rf_wdata_lsu;
    end else begin
      rvfi_mem_rdata_d = rvfi_mem_rdata_q;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvfi_mem_addr_q  <= '0;
      rvfi_mem_rdata_q <= '0;
      rvfi_mem_wdata_q <= '0;
    end else begin
      rvfi_mem_addr_q  <= rvfi_mem_addr_d;
      rvfi_mem_rdata_q <= rvfi_mem_rdata_d;
      rvfi_mem_wdata_q <= rvfi_mem_wdata_d;
    end
  end
  // Byte enable based on data type
  always_comb begin
    unique case (lsu_type)
      2'b00:   rvfi_mem_mask_int = 4'b1111;
      2'b01:   rvfi_mem_mask_int = 4'b0011;
      2'b10:   rvfi_mem_mask_int = 4'b0001;
      default: rvfi_mem_mask_int = 4'b0000;
    endcase
  end

  always_comb begin
    if (instr_is_compressed_id && (instr_gets_expanded_id == INSTR_NOT_EXPANDED)) begin
      rvfi_insn_id = {16'b0, instr_rdata_c_id};
    end else begin
      rvfi_insn_id = instr_rdata_id;
    end
  end

  always_comb begin
    rvfi_expanded_insn_valid = 1'b0;
    rvfi_expanded_insn = '0;
    rvfi_expanded_insn_last = 1'b0;
    if (instr_gets_expanded_id != INSTR_NOT_EXPANDED) begin
      rvfi_expanded_insn_valid = 1'b1;
      rvfi_expanded_insn = instr_expanded_id;
      if (instr_gets_expanded_id == INSTR_EXPANDED_LAST) begin
        rvfi_expanded_insn_last = 1'b1;
      end
    end
  end

  // Source registers 1 and 2 are read in the first instruction cycle
  // Source register 3 is read in the second instruction cycle.
  always_comb begin
    if (instr_first_cycle_id) begin
      rvfi_rs1_data_d = rf_ren_a ? multdiv_operand_a_ex : '0;
      rvfi_rs1_addr_d = rf_ren_a ? rf_raddr_a : '0;
      rvfi_rs2_data_d = rf_ren_b ? multdiv_operand_b_ex : '0;
      rvfi_rs2_addr_d = rf_ren_b ? rf_raddr_b : '0;
      rvfi_rs3_data_d = '0;
      rvfi_rs3_addr_d = '0;
    end else begin
      rvfi_rs1_data_d = rvfi_rs1_data_q;
      rvfi_rs1_addr_d = rvfi_rs1_addr_q;
      rvfi_rs2_data_d = rvfi_rs2_data_q;
      rvfi_rs2_addr_d = rvfi_rs2_addr_q;
      rvfi_rs3_data_d = multdiv_operand_a_ex;
      rvfi_rs3_addr_d = rf_raddr_a;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvfi_rs1_data_q <= '0;
      rvfi_rs1_addr_q <= '0;
      rvfi_rs2_data_q <= '0;
      rvfi_rs2_addr_q <= '0;

    end else begin
      rvfi_rs1_data_q <= rvfi_rs1_data_d;
      rvfi_rs1_addr_q <= rvfi_rs1_addr_d;
      rvfi_rs2_data_q <= rvfi_rs2_data_d;
      rvfi_rs2_addr_q <= rvfi_rs2_addr_d;
    end
  end

  always_comb begin
    if (rvfi_rd_we_wb) begin
      // Capture address/data of write to register file
      rvfi_rd_addr_d = rvfi_rd_addr_wb;
      // If writing to x0 zero write data as required by RVFI specification
      if (rvfi_rd_addr_wb == 5'b0) begin
        rvfi_rd_wdata_d = '0;
      end else begin
        rvfi_rd_wdata_d = rvfi_rd_wdata_wb;
      end
    end else if (rvfi_instr_new_wb) begin
      // If no RF write but new instruction in Writeback (when present) or ID/EX (when no writeback
      // stage present) then zero RF write address/data as required by RVFI specification
      rvfi_rd_addr_d  = '0;
      rvfi_rd_wdata_d = '0;
    end else begin
      // Otherwise maintain previous value
      rvfi_rd_addr_d  = rvfi_rd_addr_q;
      rvfi_rd_wdata_d = rvfi_rd_wdata_q;
    end
  end

  // RD write register is refreshed only once per cycle and
  // then it is kept stable for the cycle.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvfi_rd_addr_q    <= '0;
      rvfi_rd_wdata_q   <= '0;
    end else begin
      rvfi_rd_addr_q    <= rvfi_rd_addr_d;
      rvfi_rd_wdata_q   <= rvfi_rd_wdata_d;
    end
  end

  if (WritebackStage) begin : g_rvfi_rf_wr_suppress_wb
    logic rvfi_stage_rf_wr_suppress_wb;
    logic rvfi_rf_wr_suppress_wb;

    // Set when RF write from load data is suppressed due to an integrity error
    assign rvfi_rf_wr_suppress_wb =
      instr_done_wb & ~rf_we_wb_o & outstanding_load_wb & lsu_load_resp_intg_err;

    always@(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        rvfi_stage_rf_wr_suppress_wb <= 1'b0;
      end else if (rvfi_wb_done) begin
        rvfi_stage_rf_wr_suppress_wb <= rvfi_rf_wr_suppress_wb;
      end
    end

    assign rvfi_ext_rf_wr_suppress = rvfi_stage_rf_wr_suppress_wb;
  end else begin : g_rvfi_no_rf_wr_suppress_wb
    assign rvfi_ext_rf_wr_suppress = 1'b0;
  end

  // rvfi_intr must be set for first instruction that is part of a trap handler.
  // On the first cycle of a new instruction see if a trap PC was set by the previous instruction,
  // otherwise maintain value.
  assign rvfi_intr_d = instr_first_cycle_id ? rvfi_set_trap_pc_q : rvfi_intr_q;

  always_comb begin
    rvfi_set_trap_pc_d = rvfi_set_trap_pc_q;

    if (pc_set && pc_mux_id == PC_EXC &&
        (exc_pc_mux_id == EXC_PC_EXC || exc_pc_mux_id == EXC_PC_IRQ)) begin
      // PC is set to enter a trap handler
      rvfi_set_trap_pc_d = 1'b1;
    end else if (rvfi_set_trap_pc_q && rvfi_id_done) begin
      // first instruction has been executed after PC is set to trap handler
      rvfi_set_trap_pc_d = 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvfi_set_trap_pc_q <= 1'b0;
      rvfi_intr_q        <= 1'b0;
    end else begin
      rvfi_set_trap_pc_q <= rvfi_set_trap_pc_d;
      rvfi_intr_q        <= rvfi_intr_d;
    end
  end

`else
  logic unused_instr_new_id, unused_instr_id_done, unused_instr_done_wb,
        unused_instr_expanded_id, unused_instr_gets_expanded_id;
  assign unused_instr_id_done = instr_id_done;
  assign unused_instr_new_id = instr_new_id;
  assign unused_instr_done_wb = instr_done_wb;
  assign unused_instr_expanded_id = ^instr_expanded_id;
  assign unused_instr_gets_expanded_id = ^instr_gets_expanded_id;
`endif

  `ASSERT_INIT(IllegalParamSecure, !(SecureIbex && (RV32M == RV32MNone)))
//`ifndef MTI_SVSIM
 // `ASSERT(MultDivFSMIdleOnIdReady, id_in_ready |=> ex_block_i.sva_multdiv_fsm_idle)
//`endif

  //////////
  // FCOV //
  //////////

`ifndef SYNTHESIS
  // fcov signals for V2S
  `DV_FCOV_SIGNAL_GEN_IF(logic, rf_ecc_err_a_id, gen_regfile_ecc.rf_ecc_err_a_id, RegFileECC)
  `DV_FCOV_SIGNAL_GEN_IF(logic, rf_ecc_err_b_id, gen_regfile_ecc.rf_ecc_err_b_id, RegFileECC)

  // fcov signals for CSR access. These are complicated by illegal accesses. Where an access is
  // legal `csr_op_en` signals the operation occurring, but this is deasserted where an access is
  // illegal. Instead `illegal_insn_id` confirms the instruction is taking an illegal instruction
  // exception.
  // All CSR operations perform a read, `CSR_OP_READ` is the only one that only performs a read
  `DV_FCOV_SIGNAL(logic, csr_read_only,
      (csr_op == CSR_OP_READ) && csr_access && (csr_op_en || illegal_insn_id))
  `DV_FCOV_SIGNAL(logic, csr_write,
      cs_registers_i.csr_wr && csr_access && (csr_op_en || illegal_insn_id))

  if (PMPEnable) begin : g_pmp_fcov_signals
    logic [PMPNumRegions-1:0] fcov_pmp_region_ichan_priority;
    logic [PMPNumRegions-1:0] fcov_pmp_region_ichan2_priority;
    logic [PMPNumRegions-1:0] fcov_pmp_region_dchan_priority;

    logic unused_fcov_pmp_region_priority;

    assign unused_fcov_pmp_region_priority = ^{fcov_pmp_region_ichan_priority,
                                               fcov_pmp_region_ichan2_priority,
                                               fcov_pmp_region_dchan_priority};

    for (genvar i_region = 0; i_region < PMPNumRegions; i_region += 1) begin : g_pmp_region_fcov
      `DV_FCOV_SIGNAL(logic, pmp_region_ichan_access,
          g_pmp.pmp_i.region_match_all[PMP_I][i_region] & if_stage_i.if_id_pipe_reg_we)
      `DV_FCOV_SIGNAL(logic, pmp_region_ichan2_access,
          g_pmp.pmp_i.region_match_all[PMP_I2][i_region] & if_stage_i.if_id_pipe_reg_we)
      `DV_FCOV_SIGNAL(logic, pmp_region_dchan_access,
          g_pmp.pmp_i.region_match_all[PMP_D][i_region] & data_req_out)
      // pmp_cfg[5:6] is reserved and because of that the width of it inside cs_registers module
      // is 6-bit.
      `DV_FCOV_SIGNAL(logic, warl_check_pmpcfg,
          fcov_csr_write &&
          (cs_registers_i.g_pmp_registers.g_pmp_csrs[i_region].u_pmp_cfg_csr.wr_data_i !=
          {cs_registers_i.csr_wdata_int[(i_region%4)*PMP_CFG_W+:5],
           cs_registers_i.csr_wdata_int[(i_region%4)*PMP_CFG_W+7]}))

      if (i_region > 0) begin : g_region_priority
        assign fcov_pmp_region_ichan_priority[i_region] =
          g_pmp.pmp_i.region_match_all[PMP_I][i_region] &
          ~|g_pmp.pmp_i.region_match_all[PMP_I][i_region-1:0];

        assign fcov_pmp_region_ichan2_priority[i_region] =
          g_pmp.pmp_i.region_match_all[PMP_I2][i_region] &
          ~|g_pmp.pmp_i.region_match_all[PMP_I2][i_region-1:0];

        assign fcov_pmp_region_dchan_priority[i_region] =
          g_pmp.pmp_i.region_match_all[PMP_D][i_region] &
          ~|g_pmp.pmp_i.region_match_all[PMP_D][i_region-1:0];
      end else begin : g_region_highest_priority
        assign fcov_pmp_region_ichan_priority[i_region] =
          g_pmp.pmp_i.region_match_all[PMP_I][i_region];

        assign fcov_pmp_region_ichan2_priority[i_region] =
          g_pmp.pmp_i.region_match_all[PMP_I2][i_region];

        assign fcov_pmp_region_dchan_priority[i_region] =
          g_pmp.pmp_i.region_match_all[PMP_D][i_region];
      end
    end
  end
`endif

endmodule