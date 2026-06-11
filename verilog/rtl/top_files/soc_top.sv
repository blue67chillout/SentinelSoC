// =============================================================================
// soc_top.sv
// Top-level SoC wrapper
// Core:       Ibex RV32IMC, no ICache, no SecureIbex, no PMP
// Boot addr:  0x0000_0000 (BootROM)
// Reset:      Active-low, synchronous
// Clock:      Single domain — PLL/clock gen to be added later
// =============================================================================

`include "obi/typedef.svh"
`include "obi/assign.svh"
`include "apb/typedef.svh"

module soc_top (
  // Clock and reset — raw pins for now, PLL stub to be added
  input  logic clk_i,
  input  logic rst_ni,

  // QSPI — external flash
  output logic       qspi_csn_o,
  output logic       qspi_clk_o,
  inout  logic [3:0] qspi_io_io,   // IO0-IO3 bidirectional

  // SPI
  output logic spi_csn_o,
  output logic spi_clk_o,
  output logic spi_mosi_o,
  input  logic spi_miso_i,

  // UART
  output logic uart_tx_o,
  input  logic uart_rx_i,

  // GPIO — 32 pins bidirectional
  inout  logic [31:0] gpio_io,

  // JTAG debug
  input  logic jtag_tck_i,
  input  logic jtag_tms_i,
  input  logic jtag_tdi_i,
  output logic jtag_tdo_o,
  input  logic jtag_trst_ni
);

  // ---------------------------------------------------------------------------
  // Local parameters
  // ---------------------------------------------------------------------------
  localparam logic [31:0] BOOT_ADDR  = 32'h0000_0000;
  localparam logic [31:0] HART_ID    = 32'h0000_0000;

  // Memory sizes (parameterised — change here to resize)
  localparam int unsigned BOOTROM_SIZE_WORDS = 1024; // 4KB
  localparam int unsigned ISRAM_SIZE_WORDS   = 1024; // 4KB
  localparam int unsigned DSRAM_SIZE_WORDS   = 1024; // 4KB

  // ---------------------------------------------------------------------------
  // OBI and APB type definitions for bridge
  // ---------------------------------------------------------------------------
  // OBI types — using default config (no optional fields)
  `OBI_TYPEDEF_DEFAULT_ALL(obi_apb, obi_pkg::ObiDefaultConfig)

  // APB types
  typedef logic [31:0] apb_addr_t;
  typedef logic [31:0] apb_data_t;
  typedef logic [ 3:0] apb_strb_t;
  `APB_TYPEDEF_ALL(apb, apb_addr_t, apb_data_t, apb_strb_t)

  // Struct instances
  obi_apb_req_t  apb_obi_req;
  obi_apb_rsp_t  apb_obi_rsp;
  apb_req_t      apb_req;
  apb_resp_t     apb_rsp;

  // PLIC register bus interface — simple valid/ready/addr/data/write
typedef struct packed {
  logic        valid;
  logic        write;
  logic [31:0] addr;
  logic [31:0] wdata;
  logic [ 3:0] wstrb;
} plic_reg_req_t;

typedef struct packed {
  logic        ready;
  logic        error;
  logic [31:0] rdata;
} plic_reg_rsp_t;

  // ---------------------------------------------------------------------------
  // Ibex ↔ decoder flat signals
  // ---------------------------------------------------------------------------

  // Instruction interface
  logic        instr_req;
  logic        instr_gnt;
  logic        instr_rvalid;
  logic [31:0] instr_addr;
  logic [31:0] instr_rdata;
  logic [ 6:0] instr_rdata_intg; // tied 0 — no ECC
  logic        instr_err;

  // Data interface
  logic        data_req;
  logic        data_gnt;
  logic        data_rvalid;
  logic        data_we;
  logic [ 3:0] data_be;
  logic [31:0] data_addr;
  logic [31:0] data_wdata;
  logic [ 6:0] data_wdata_intg; // tied 0 — no ECC
  logic [31:0] data_rdata;
  logic [ 6:0] data_rdata_intg; // tied 0
  logic        data_err;

  // Interrupt signals
  logic        irq_software;
  logic        irq_timer;
  logic        irq_external;
  logic        irq_nm;

  // PLIC OBI slave signals
  logic        plic_req;
  logic        plic_gnt;
  logic        plic_rvalid;
  logic [31:0] plic_addr;
  logic        plic_we;
  logic [ 3:0] plic_be;
  logic [31:0] plic_wdata;
  logic [31:0] plic_rdata;
  logic        plic_err;

  // PLIC register bus
  plic_reg_req_t plic_reg_req;
  plic_reg_rsp_t plic_reg_rsp;

  // Debug — stubbed until riscv_dbg is integrated
    // Debug target interface (addr_decode → dm_top)
  logic        dbg_req;
  logic [31:0] dbg_addr;
  logic        dbg_we;
  logic [ 3:0] dbg_be;
  logic [31:0] dbg_wdata;
  logic        dbg_rvalid;
  logic [31:0] dbg_rdata;
  // Debugger Signals 
  logic        debug_req_raw;
  logic        debug_req_gated;
  logic        debug_disable;
  logic        ndmreset; // Non-debug module reset (optional system reset)

  // DMI (Debug Module Interface)
  logic        dmi_req_valid, dmi_req_ready;
  logic [40:0] dmi_req_data;
  logic        dmi_resp_valid, dmi_resp_ready;
  logic [33:0] dmi_resp_data;

  // Security Gating: Tie to 0 for development. 
  // Later, tie to SHA valid signal to block debug on boot.
  assign debug_disable = 1'b0;
  assign debug_req_gated = debug_req_raw & ~debug_disable;
  
  // ---------------------------------------------------------------------------
  // Decoder ↔ slave flat signals
  // ---------------------------------------------------------------------------

  // BootROM
  logic        bootrom_req;
  logic        bootrom_gnt;
  logic        bootrom_rvalid;
  logic [31:0] bootrom_addr;
  logic        bootrom_we;
  logic [ 3:0] bootrom_be;
  logic [31:0] bootrom_wdata;
  logic [31:0] bootrom_rdata;
  logic        bootrom_err;

  // ISRAM
  logic        isram_req;
  logic        isram_gnt;
  logic        isram_rvalid;
  logic [31:0] isram_addr;
  logic        isram_we;
  logic [ 3:0] isram_be;
  logic [31:0] isram_wdata;
  logic [31:0] isram_rdata;
  logic        isram_err;

  // DSRAM
  logic        dsram_req;
  logic        dsram_gnt;
  logic        dsram_rvalid;
  logic [31:0] dsram_addr;
  logic        dsram_we;
  logic [ 3:0] dsram_be;
  logic [31:0] dsram_wdata;
  logic [31:0] dsram_rdata;
  logic        dsram_err;

  // Control registers
  logic        ctrl_req;
  logic        ctrl_gnt;
  logic        ctrl_rvalid;
  logic [31:0] ctrl_addr;
  logic        ctrl_we;
  logic [ 3:0] ctrl_be;
  logic [31:0] ctrl_wdata;
  logic [31:0] ctrl_rdata;
  logic        ctrl_err;

  // Buffer CSR
  logic        buf_req;
  logic        buf_gnt;
  logic        buf_rvalid;
  logic [31:0] buf_addr;
  logic        buf_we;
  logic [ 3:0] buf_be;
  logic [31:0] buf_wdata;
  logic [31:0] buf_rdata;
  logic        buf_err;

  // SHA + ED25519 CSR
  logic        sha_req;
  logic        sha_gnt;
  logic        sha_rvalid;
  logic [31:0] sha_addr;
  logic        sha_we;
  logic [ 3:0] sha_be;
  logic [31:0] sha_wdata;
  logic [31:0] sha_rdata;
  logic        sha_err;
  //interconnect
  logic [31:0] accel_data;
  logic [ 5:0] accel_addr;
  logic        accel_valid;

  logic        sha_verify_done;
  logic        sha_signature_valid;
  logic        sha_start;

  // APB bridge OBI side
  logic        apb_bridge_req;
  logic        apb_bridge_gnt;
  logic        apb_bridge_rvalid;
  logic [31:0] apb_bridge_addr;
  logic        apb_bridge_we;
  logic [ 3:0] apb_bridge_be;
  logic [31:0] apb_bridge_wdata;
  logic [31:0] apb_bridge_rdata;
  logic        apb_bridge_err;

  // ISRAM write lock from control registers
  logic        ctrl_isram_lock;

  // ---------------------------------------------------------------------------
  // IRQ lines from peripherals to PLIC
  // (PLIC → irq_external, CLINT → irq_timer + irq_software)
  // Peripheral IRQ lines — to be connected when PLIC is instantiated
  // ---------------------------------------------------------------------------
  logic        irq_uart;
  logic        irq_spi;
  logic        irq_qspi;
  logic        irq_gpio;
  logic        irq_timer_periph;
  logic        irq_buf;          // buffer full / stream done
  logic        irq_sha;          // crypto done / error

  // ---------------------------------------------------------------------------
  // Tie-offs for unused Ibex inputs
  // ---------------------------------------------------------------------------
  assign instr_rdata_intg = 7'h0;
  assign data_rdata_intg  = 7'h0;
  assign irq_nm           = 1'b0;

  // ---------------------------------------------------------------------------
  // Ibex RV32IMC instantiation
  // ---------------------------------------------------------------------------
  ibex_top #(
    .PMPEnable        ( 1'b0          ),
    .RV32E            ( 1'b0          ),
    .RV32M            ( ibex_pkg::RV32MFast ),
    .RV32B            ( ibex_pkg::RV32BNone ),
    .RegFile          ( ibex_pkg::RegFileFF ),
    .BranchTargetALU  ( 1'b0          ),
    .WritebackStage   ( 1'b1          ),
    .ICache           ( 1'b0          ),
    .BranchPredictor  ( 1'b0          ),
    .DbgTriggerEn     ( 1'b0          ),
    .SecureIbex       ( 1'b0          ),
    .DmHaltAddr       ( 32'h1A110800  ), // standard DM halt addr — update with riscv_dbg base
    .DmExceptionAddr  ( 32'h1A110808  )
  ) u_ibex_top (
    .clk_i                      ( clk_i            ),
    .rst_ni                     ( rst_ni            ),

    .test_en_i                  ( 1'b0              ),
    .ram_cfg_icache_tag_i       ( '0                ),
    .ram_cfg_icache_data_i      ( '0                ),
    .ram_cfg_rsp_icache_tag_o   (                   ),
    .ram_cfg_rsp_icache_data_o  (                   ),

    .hart_id_i                  ( HART_ID           ),
    .boot_addr_i                ( BOOT_ADDR         ),

    // Instruction interface
    .instr_req_o                ( instr_req         ),
    .instr_gnt_i                ( instr_gnt         ),
    .instr_rvalid_i             ( instr_rvalid      ),
    .instr_addr_o               ( instr_addr        ),
    .instr_rdata_i              ( instr_rdata       ),
    .instr_rdata_intg_i         ( instr_rdata_intg  ),
    .instr_err_i                ( instr_err         ),

    // Data interface
    .data_req_o                 ( data_req          ),
    .data_gnt_i                 ( data_gnt          ),
    .data_rvalid_i              ( data_rvalid       ),
    .data_we_o                  ( data_we           ),
    .data_be_o                  ( data_be           ),
    .data_addr_o                ( data_addr         ),
    .data_wdata_o               ( data_wdata        ),
    .data_wdata_intg_o          ( data_wdata_intg   ),
    .data_rdata_i               ( data_rdata        ),
    .data_rdata_intg_i          ( data_rdata_intg   ),
    .data_err_i                 ( data_err          ),

    // Interrupts
    .irq_software_i             ( irq_software      ),
    .irq_timer_i                ( irq_timer         ),
    .irq_external_i             ( irq_external      ),
    .irq_fast_i                 ( 15'h0             ),
    .irq_nm_i                   ( irq_nm            ),

    // Scrambling — unused
    .scramble_key_valid_i       ( 1'b0              ),
    .scramble_key_i             ( '0                ),
    .scramble_nonce_i           ( '0                ),
    .scramble_req_o             (                   ),

    // Debug
    .debug_req_i                (debug_req_gated),
    .crash_dump_o               (                   ),
    .double_fault_seen_o        (                   ),

    // CPU control
    .fetch_enable_i             ( ibex_pkg::IbexMuBiOn ),
    .alert_minor_o              (                   ),
    .alert_major_internal_o     (                   ),
    .alert_major_bus_o          (                   ),
    .core_sleep_o               (                   ),

    // DFT
    .scan_rst_ni                ( 1'b1              ),

    // Lockstep — disabled
    .lockstep_cmp_en_o          (                   ),
    .data_req_shadow_o          (                   ),
    .data_we_shadow_o           (                   ),
    .data_be_shadow_o           (                   ),
    .data_addr_shadow_o         (                   ),
    .data_wdata_shadow_o        (                   ),
    .data_wdata_intg_shadow_o   (                   ),
    .instr_req_shadow_o         (                   ),
    .instr_addr_shadow_o        (                   )
  );

  // ---------------------------------------------------------------------------
  // Address decoder + fetch demux
  // ---------------------------------------------------------------------------
  soc_addr_decode u_addr_decode (
    .clk_i              ( clk_i              ),
    .rst_ni             ( rst_ni             ),

    // Ibex instruction fetch
    .instr_req_i        ( instr_req          ),
    .instr_gnt_o        ( instr_gnt          ),
    .instr_rvalid_o     ( instr_rvalid       ),
    .instr_addr_i       ( instr_addr         ),
    .instr_rdata_o      ( instr_rdata        ),
    .instr_err_o        ( instr_err          ),

    // Ibex data
    .data_req_i         ( data_req           ),
    .data_gnt_o         ( data_gnt           ),
    .data_rvalid_o      ( data_rvalid        ),
    .data_we_i          ( data_we            ),
    .data_be_i          ( data_be            ),
    .data_addr_i        ( data_addr          ),
    .data_wdata_i       ( data_wdata         ),
    .data_rdata_o       ( data_rdata         ),
    .data_err_o         ( data_err           ),

    // ISRAM lock
    .ctrl_isram_lock_i  ( ctrl_isram_lock    ),

    // Slaves
    .bootrom_req_o      ( bootrom_req        ),
    .bootrom_gnt_i      ( bootrom_gnt        ),
    .bootrom_rvalid_i   ( bootrom_rvalid     ),
    .bootrom_addr_o     ( bootrom_addr       ),
    .bootrom_we_o       ( bootrom_we         ),
    .bootrom_be_o       ( bootrom_be         ),
    .bootrom_wdata_o    ( bootrom_wdata      ),
    .bootrom_rdata_i    ( bootrom_rdata      ),
    .bootrom_err_i      ( bootrom_err        ),

    .isram_req_o        ( isram_req          ),
    .isram_gnt_i        ( isram_gnt          ),
    .isram_rvalid_i     ( isram_rvalid       ),
    .isram_addr_o       ( isram_addr         ),
    .isram_we_o         ( isram_we           ),
    .isram_be_o         ( isram_be           ),
    .isram_wdata_o      ( isram_wdata        ),
    .isram_rdata_i      ( isram_rdata        ),
    .isram_err_i        ( isram_err          ),

    .dsram_req_o        ( dsram_req          ),
    .dsram_gnt_i        ( dsram_gnt          ),
    .dsram_rvalid_i     ( dsram_rvalid       ),
    .dsram_addr_o       ( dsram_addr         ),
    .dsram_we_o         ( dsram_we           ),
    .dsram_be_o         ( dsram_be           ),
    .dsram_wdata_o      ( dsram_wdata        ),
    .dsram_rdata_i      ( dsram_rdata        ),
    .dsram_err_i        ( dsram_err          ),

    .ctrl_req_o         ( ctrl_req           ),
    .ctrl_gnt_i         ( ctrl_gnt           ),
    .ctrl_rvalid_i      ( ctrl_rvalid        ),
    .ctrl_addr_o        ( ctrl_addr          ),
    .ctrl_we_o          ( ctrl_we            ),
    .ctrl_be_o          ( ctrl_be            ),
    .ctrl_wdata_o       ( ctrl_wdata         ),
    .ctrl_rdata_i       ( ctrl_rdata         ),
    .ctrl_err_i         ( ctrl_err           ),

    .buf_req_o          ( buf_req            ),
    .buf_gnt_i          ( buf_gnt            ),
    .buf_rvalid_i       ( buf_rvalid         ),
    .buf_addr_o         ( buf_addr           ),
    .buf_we_o           ( buf_we             ),
    .buf_be_o           ( buf_be             ),
    .buf_wdata_o        ( buf_wdata          ),
    .buf_rdata_i        ( buf_rdata          ),
    .buf_err_i          ( buf_err            ),

    .sha_req_o          ( sha_req            ),
    .sha_gnt_i          ( sha_gnt            ),
    .sha_rvalid_i       ( sha_rvalid         ),
    .sha_addr_o         ( sha_addr           ),
    .sha_we_o           ( sha_we             ),
    .sha_be_o           ( sha_be             ),
    .sha_wdata_o        ( sha_wdata          ),
    .sha_rdata_i        ( sha_rdata          ),
    .sha_err_i          ( sha_err            ),

    .apb_req_o          ( apb_bridge_req     ),
    .apb_gnt_i          ( apb_bridge_gnt     ),
    .apb_rvalid_i       ( apb_bridge_rvalid  ),
    .apb_addr_o         ( apb_bridge_addr    ),
    .apb_we_o           ( apb_bridge_we      ),
    .apb_be_o           ( apb_bridge_be      ),
    .apb_wdata_o        ( apb_bridge_wdata   ),
    .apb_rdata_i        ( apb_bridge_rdata   ),
    .apb_err_i          ( apb_bridge_err     ),

    .dbg_req_o    ( dbg_req    ),
    .dbg_addr_o   ( dbg_addr   ),
    .dbg_we_o     ( dbg_we     ),
    .dbg_be_o     ( dbg_be     ),
    .dbg_wdata_o  ( dbg_wdata  ),
    .dbg_rvalid_i ( dbg_rvalid ),
    .dbg_rdata_i  ( dbg_rdata  )
  );

  // ---------------------------------------------------------------------------
  // BootROM — read-only, initialised from bootrom.hex at synthesis
  // ---------------------------------------------------------------------------
  // TODO: replace with foundry SRAM macro when available
  soc_bootrom #(
    .NumWords ( BOOTROM_SIZE_WORDS )
  ) u_bootrom (
    .clk_i    ( clk_i         ),
    .rst_ni   ( rst_ni        ),
    .req_i    ( bootrom_req   ),
    .addr_i   ( bootrom_addr  ),
    .rdata_o  ( bootrom_rdata ),
    .rvalid_o ( bootrom_rvalid),
    .gnt_o    ( bootrom_gnt   ),
    .err_o    ( bootrom_err   )
  );

  // BootROM is read-only — write signals intentionally unconnected
  // bootrom_we and bootrom_wdata are decoder outputs that go nowhere here

  // ---------------------------------------------------------------------------
  // ISRAM — instruction SRAM, write port gated by decoder
  // ---------------------------------------------------------------------------
  // TODO: replace with foundry SRAM macro when available
  soc_sram #(
    .NumWords  ( ISRAM_SIZE_WORDS )
  ) u_isram (
    .clk_i    ( clk_i        ),
    .rst_ni   ( rst_ni       ),
    .req_i    ( isram_req    ),
    .we_i     ( isram_we     ),
    .be_i     ( isram_be     ),
    .addr_i   ( isram_addr   ),
    .wdata_i  ( isram_wdata  ),
    .rdata_o  ( isram_rdata  ),
    .rvalid_o ( isram_rvalid ),
    .gnt_o    ( isram_gnt    ),
    .err_o    ( isram_err    )
  );

  // ---------------------------------------------------------------------------
  // DSRAM — data SRAM
  // ---------------------------------------------------------------------------
  // TODO: replace with foundry SRAM macro when available
  soc_sram #(
    .NumWords  ( DSRAM_SIZE_WORDS )
  ) u_dsram (
    .clk_i    ( clk_i        ),
    .rst_ni   ( rst_ni       ),
    .req_i    ( dsram_req    ),
    .we_i     ( dsram_we     ),
    .be_i     ( dsram_be     ),
    .addr_i   ( dsram_addr   ),
    .wdata_i  ( dsram_wdata  ),
    .rdata_o  ( dsram_rdata  ),
    .rvalid_o ( dsram_rvalid ),
    .gnt_o    ( dsram_gnt    ),
    .err_o    ( dsram_err    )
  );

  // ---------------------------------------------------------------------------
  // Control Registers block
  // ---------------------------------------------------------------------------
  soc_ctrl_regs u_ctrl_regs (
    .clk_i          ( clk_i           ),
    .rst_ni         ( rst_ni          ),

    // OBI slave port
    .req_i          ( ctrl_req        ),
    .we_i           ( ctrl_we         ),
    .be_i           ( ctrl_be         ),
    .addr_i         ( ctrl_addr       ),
    .wdata_i        ( ctrl_wdata      ),
    .gnt_o          ( ctrl_gnt        ),
    .rvalid_o       ( ctrl_rvalid     ),
    .rdata_o        ( ctrl_rdata      ),
    .err_o          ( ctrl_err        ),
    .crypto_verified_i ( sha_signature_valid ),
    // Control outputs
    .isram_lock_o   ( ctrl_isram_lock )
  );

  // ---------------------------------------------------------------------------
  // Buffer block (OBI slave + AXI-Stream master)
  // ---------------------------------------------------------------------------
  soc_buffer u_buffer (
    .clk_i          ( clk_i       ),
    .rst_ni         ( rst_ni      ),

    // OBI slave — CSR + data write port
    .req_i          ( buf_req     ),
    .we_i           ( buf_we      ),
    .be_i           ( buf_be      ),
    .addr_i         ( buf_addr    ),
    .wdata_i        ( buf_wdata   ),
    .gnt_o          ( buf_gnt     ),
    .rvalid_o       ( buf_rvalid  ),
    .rdata_o        ( buf_rdata   ),
    .err_o          ( buf_err     ),

    .accel_data_o  ( accel_data        ),
    .accel_addr_o  ( accel_addr        ),
    .accel_valid_o ( accel_valid       ),
    .accel_data_i  ( 32'h0             ),
    .accel_done_i  ( sha_verify_done   ),
    // IRQ → PLIC
    .irq_o          ( irq_buf     )
  );

  top_most u_crypto (
    .clk(clk_i),
    .rst_n(rst_ni),
    .accel_data_i(accel_data),
    .accel_addr_i(accel_addr),
    .accel_valid_i(accel_valid),
    .start_verify_i(sha_start),
    .verify_done_o(sha_verify_done),
    .signature_valid(sha_signature_valid)
);

sha_ed25519_obi_wrapper u_sha_ctrl (

    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    // OBI slave interface
    .req_i              (sha_req),
    .we_i               (sha_we),
    .be_i               (sha_be),
    .addr_i             (sha_addr),
    .wdata_i            (sha_wdata),
    .gnt_o              (sha_gnt),
    .rvalid_o           (sha_rvalid),
    .rdata_o            (sha_rdata),
    .err_o              (sha_err),
    // Crypto control/status
    .start_verify_o     (sha_start),
    .verify_done_i      (sha_verify_done),
    .signature_valid_i  (sha_signature_valid)
);

  // ---------------------------------------------------------------------------
  // OBI → APB bridge
  // ---------------------------------------------------------------------------
  // TODO: instantiate obi_to_apb here with correct apb_req_t / apb_rsp_t types
  // and connect to APB peripheral mux below
  // Stubbed for now — returns error on all accesses
  // Pack flat apb_bridge_* signals into OBI request struct
  assign apb_obi_req.req     = apb_bridge_req;
  assign apb_obi_req.a.addr  = apb_bridge_addr;
  assign apb_obi_req.a.we    = apb_bridge_we;
  assign apb_obi_req.a.be    = apb_bridge_be;
  assign apb_obi_req.a.wdata = apb_bridge_wdata;
  assign apb_obi_req.a.aid   = '0;

  // Unpack OBI response struct into flat signals
  assign apb_bridge_gnt    = apb_obi_rsp.gnt;
  assign apb_bridge_rvalid = apb_obi_rsp.rvalid;
  assign apb_bridge_rdata  = apb_obi_rsp.r.rdata;
  assign apb_bridge_err    = apb_obi_rsp.r.err;

  // OBI to APB bridge — converts OBI requests to APB transactions
  obi_to_apb #(
    .ObiCfg            (obi_pkg::ObiDefaultConfig),
    .obi_req_t         (obi_apb_req_t),
    .obi_rsp_t         (obi_apb_rsp_t),
    .apb_req_t         (apb_req_t),
    .apb_rsp_t         (apb_resp_t),
    .EnableSameCycleRsp(1'b0)
  ) u_obi_to_apb (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .obi_req_i  (apb_obi_req),
    .obi_rsp_o  (apb_obi_rsp),
    .apb_req_o  (apb_req),
    .apb_rsp_i  (apb_rsp)
  );

  // ---------------------------------------------------------------------------
  // APB Address Decoder & Peripheral Response Mux
  // ---------------------------------------------------------------------------
  logic psel_uart, psel_timer, psel_spi, psel_qspi, psel_gpio;
  logic [31:0] prdata_uart, prdata_timer, prdata_spi, prdata_qspi, prdata_gpio;
  logic pready_uart, pready_timer, pready_spi, pready_qspi, pready_gpio;
  logic pslverr_uart, pslverr_timer, pslverr_spi, pslverr_qspi, pslverr_gpio;

  // APB peripheral select decoding
  assign psel_uart  = apb_req.psel && (apb_req.paddr >= 32'h1050_3000 && apb_req.paddr < 32'h1050_4000);
  assign psel_timer = apb_req.psel && (apb_req.paddr >= 32'h1050_1000 && apb_req.paddr < 32'h1050_2000);
  assign psel_qspi  = apb_req.psel && (apb_req.paddr >= 32'h1050_0000 && apb_req.paddr < 32'h1050_1000);
  assign psel_spi   = apb_req.psel && (apb_req.paddr >= 32'h1050_2000 && apb_req.paddr < 32'h1050_3000);
  assign psel_gpio  = apb_req.psel && (apb_req.paddr >= 32'h1060_0000 && apb_req.paddr < 32'h1060_1000);

  // APB response mux — combine responses from all peripherals
  always_comb begin
    apb_rsp.prdata  = 32'h0;
    apb_rsp.pready  = 1'b1;
    apb_rsp.pslverr = 1'b0;
    if (psel_uart) begin
      apb_rsp.prdata  = prdata_uart;
      apb_rsp.pready  = pready_uart;
      apb_rsp.pslverr = pslverr_uart;
    end
    if (psel_timer) begin
      apb_rsp.prdata  = prdata_timer;
      apb_rsp.pready  = pready_timer;
      apb_rsp.pslverr = pslverr_timer;
    end
    if (psel_qspi) begin
      apb_rsp.prdata  = prdata_qspi;
      apb_rsp.pready  = pready_qspi;
      apb_rsp.pslverr = pslverr_qspi;
    end
    if (psel_spi) begin
      apb_rsp.prdata  = prdata_spi;
      apb_rsp.pready  = pready_spi;
      apb_rsp.pslverr = pslverr_spi;
    end
    if (psel_gpio) begin
      apb_rsp.prdata  = prdata_gpio;
      apb_rsp.pready  = pready_gpio;
      apb_rsp.pslverr = pslverr_gpio;
    end
  end

  // ---------------------------------------------------------------------------
  // APB peripheral stubs
  // TODO: replace each with actual CrocSoC IP instantiation
  // ---------------------------------------------------------------------------

  // UART
  // u_apb_uart : apb_uart #(...) (...)
// UART
  apb_uart_sv #(
    .APB_ADDR_WIDTH ( 12 )
  ) u_apb_uart (
    .CLK (clk_i),
    .RSTN (rst_ni),
    .PADDR (apb_req.paddr[11:0]),
    .PWDATA (apb_req.pwdata),
    .PWRITE (apb_req.pwrite),
    .PSEL (psel_uart),
    .PENABLE (apb_req.penable),
    .PRDATA (prdata_uart),
    .PREADY (pready_uart),
    .PSLVERR (pslverr_uart),
    .rx_i (uart_rx_i),
    .tx_o (uart_tx_o),
    .event_o (irq_uart)
  );

  // SPI
  // u_apb_spi : apb_spi_master #(...) (...)
  assign spi_csn_o   = 1'b1;
  assign spi_clk_o   = 1'b0;
  assign spi_mosi_o  = 1'b0;
  assign irq_spi     = 1'b0;

  // QSPI
  // u_apb_qspi : apb_spi_master #(...) (...)
  assign qspi_csn_o  = 1'b1;
  assign qspi_clk_o  = 1'b0;
  assign irq_qspi    = 1'b0;

  // GPIO
  // u_gpio : gpio #(...) (...)
  assign irq_gpio    = 1'b0;

  // Timer
  // u_apb_timer : apb_timer #(...) (...)
  assign irq_timer_periph = 1'b0;

  // OBI -> PLIC reg adapter
  // OBI is req/gnt/rvalid, reg bus is valid/ready/rdata
  // Grant immediately, rvalid one cycle later
  assign plic_gnt            = plic_req;
  assign plic_reg_req.valid  = plic_req;
  assign plic_reg_req.write  = plic_we;
  assign plic_reg_req.addr   = plic_addr;
  assign plic_reg_req.wdata  = plic_wdata;
  assign plic_reg_req.wstrb  = plic_be;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) plic_rvalid <= 1'b0;
    else         plic_rvalid <= plic_req & plic_gnt;
  end

  assign plic_rdata = plic_reg_rsp.rdata;
  assign plic_err   = plic_reg_rsp.error;

  plic_top #(
    .N_SOURCE (12),
    .N_TARGET (1),
    .MAX_PRIO (7),
    .reg_req_t (plic_reg_req_t),
    .reg_rsp_t (plic_reg_rsp_t)
  ) u_plic (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .req_i(plic_reg_req),
    .resp_o(plic_reg_rsp),
    .le_i(12'h0), // all level-triggered
    .irq_sources_i({5'h0, irq_sha, irq_buf, irq_timer_periph, irq_gpio, irq_qspi, irq_spi, irq_uart} ),
    .eip_targets_o(irq_external)  // Ibex irq_external_i
  );

  // ---------------------------------------------------------------------------
  // CLINT stub
  // TODO: instantiate CLINT and connect mtime/mtimecmp registers
  // CLINT outputs → irq_timer, irq_software
  // ---------------------------------------------------------------------------
  assign irq_timer    = 1'b0;
  assign irq_software = 1'b0;

  // ---------------------------------------------------------------------------
  // JTAG debug stub
  // TODO: instantiate riscv_dbg and connect to:
  //   - jtag_tck_i, jtag_tms_i, jtag_tdi_i, jtag_tdo_o, jtag_trst_ni
  //   - Ibex debug_req_i
  //   - dm_* OBI/memory interface for debug module access
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // JTAG DTM (Debug Transport Module)
  // ---------------------------------------------------------------------------
  dmi_jtag u_dmi_jtag (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .testmode_i       (1'b0),
    
    // JTAG pins
    .tck_i            (jtag_tck_i),
    .tms_i            (jtag_tms_i),
    .trst_ni          (jtag_trst_ni),
    .td_i             (jtag_tdi_i),
    .td_o             (jtag_tdo_o),
    .tdo_oe_o         (), // Leave disconnected if using simple inout/output
    
    // DMI Interface
    .dmi_req_o        (dmi_req_data),
    .dmi_req_valid_o  (dmi_req_valid),
    .dmi_req_ready_i  (dmi_req_ready),
    .dmi_resp_i       (dmi_resp_data),
    .dmi_resp_valid_i (dmi_resp_valid),
    .dmi_resp_ready_o (dmi_resp_ready)
  );

  // ---------------------------------------------------------------------------
  // RISC-V Debug Module (DM)
  // ---------------------------------------------------------------------------
  dm_top #(
    .NrHarts(1),
    .BusWidth(32)
  ) u_dm_top (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .testmode_i       (1'b0),
    .ndmreset_o       (ndmreset),
    .dmactive_o       (),
    .debug_req_o      (debug_req_raw),
    .unavailable_i    (1'b0),
    
    // DMI Interface
    .dmi_req_i        (dmi_req_data),
    .dmi_req_valid_i  (dmi_req_valid),
    .dmi_req_ready_o  (dmi_req_ready),
    .dmi_resp_o       (dmi_resp_data),
    .dmi_resp_valid_o (dmi_resp_valid),
    .dmi_resp_ready_i (dmi_resp_ready),
    
    // Target Memory Interface (Ibex reads from this when halted)
    // TODO: Connect these to your soc_addr_decode for address 0x1A11_0000
    .slave_req_i    ( dbg_req    ),
    .slave_we_i     ( dbg_we     ),
    .slave_addr_i   ( dbg_addr   ),
    .slave_wdata_i  ( dbg_wdata  ),
    .slave_be_i     ( dbg_be     ),
    .slave_rvalid_o ( dbg_rvalid ),
    .slave_rdata_o  ( dbg_rdata  ),
    
    // SBA Master Interface (TIED OFF for simple configuration!)
    .master_req_o     (),
    .master_add_o     (),
    .master_we_o      (),
    .master_wdata_o   (),
    .master_be_o      (),
    .master_gnt_i     (1'b0),
    .master_r_valid_i (1'b0),
    .master_r_rdata_i (32'h0)
  );

endmodule