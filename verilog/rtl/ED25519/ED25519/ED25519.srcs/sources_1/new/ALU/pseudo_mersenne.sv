`timescale 1ns / 1ps

module pseudo_mersenne (
    input  logic [511:0] data_in,
    output logic [255:0] data_out
);

    // Ed25519 Prime: p = 2^255 - 19
    localparam logic [255:0] PRIME_P = 
        256'h7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFED;
 
    // ==========================================
    // STAGE 1: 512-bit to ~263-bit Reduction
    // Slice at 256 bits, weight is 38
    // ==========================================
    logic [255:0] H1;
    logic [255:0] L1;
    logic [261:0] H1_times_38; // 256 bits * 38 (requires 262 bits max)
    logic [262:0] stage1_sum;  // 262 bits + 256 bits (requires 263 bits max)

    assign H1 = data_in[511:256];
    assign L1 = data_in[255:0];

    // Explicit casting to prevent silent carry-bit truncation
    assign H1_times_38 = 262'(H1) * 262'd38;
    assign stage1_sum  = 263'(L1) + 263'(H1_times_38);


    // ==========================================
    // STAGE 2: 263-bit to ~255-bit Reduction
    // Slice at 255 bits, weight is 19
    // ==========================================
    logic [7:0]   H2;
    logic [254:0] L2;
    logic [12:0]  H2_times_19; // 8 bits * 19 (requires 13 bits max)
    logic [255:0] stage2_sum;  // 255 bits + 13 bits (requires 256 bits max)

    assign H2 = stage1_sum[262:255];
    assign L2 = stage1_sum[254:0];

    // Explicit casting for the second reduction
    assign H2_times_19 = 13'(H2) * 13'd19;
    assign stage2_sum  = 256'(L2) + 256'(H2_times_19);


    // ==========================================
    // STAGE 3: Final Correction    
    // ==========================================
    logic [255:0] final_reduced_value;

    always_comb begin
        if (stage2_sum >= PRIME_P) begin
            final_reduced_value = stage2_sum - PRIME_P;
        end else begin
            final_reduced_value = stage2_sum;
        end
    end

    assign data_out = final_reduced_value;

endmodule