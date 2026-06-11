// =============================================================================
// sha_ed25519_obi_wrapper.sv
//
// OBI subordinate — exposes SHA+ED25519 subsystem status to Ibex.
// Base address: 0x0005_0000  (4KB window, addr[11:0] decoded)
//
// Register map:
//   0x000 — CRYPTO_STATUS (RO)
//             [0] verify_done      : ED25519 verification complete
//             [1] signature_valid  : signature verified OK
//
// All other addresses return 0. No writes needed — CPU only polls status.
//
// OBI handshake:
//   gnt  : combinational, always-ready
//   rvalid: registered, one cycle after granted read
//   err  : permanently 0
// =============================================================================

module sha_ed25519_obi_wrapper (
  input  logic        clk_i,
  input  logic        rst_ni,

  // OBI subordinate interface
  input  logic        req_i,
  input  logic        we_i,
  input  logic [ 3:0] be_i,
  input  logic [31:0] addr_i,
  input  logic [31:0] wdata_i,
  output logic        gnt_o,
  output logic        rvalid_o,
  output logic [31:0] rdata_o,
  output logic        err_o,

  // Status inputs from sha_ed25519_subsystem
  input  logic        verify_done_i,
  input  logic        signature_valid_i
);

  localparam logic [11:0] CRYPTO_STATUS_OFF = 12'h000;

  // --------------------------------------------------------------------------
  // OBI handshake — always ready
  // --------------------------------------------------------------------------
  assign gnt_o = req_i;
  assign err_o = 1'b0;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) rvalid_o <= 1'b0;
    else         rvalid_o <= req_i & ~we_i;
  end

  // --------------------------------------------------------------------------
  // Read data — registered
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rdata_o <= 32'h0;
    end else begin
      if (req_i && ~we_i) begin
        case (addr_i[11:0])
          CRYPTO_STATUS_OFF:
            rdata_o <= {30'h0, signature_valid_i, verify_done_i};
          default:
            rdata_o <= 32'h0;
        endcase
      end
    end
  end

endmodule