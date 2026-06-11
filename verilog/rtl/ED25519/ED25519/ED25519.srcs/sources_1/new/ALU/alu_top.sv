module alu_top (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [255:0] src_a,
    input  logic [255:0] src_b,
    input  logic [2:0]   alu_op,
    input  logic         sel_hi,
    input  logic         mult_kick,
    input  logic         mod_p_en,
    
    output logic [255:0] alu_result,
    output logic         cmp_flag,
    output logic         cmp_eq,
    output logic         mult_done,
    output logic         x_sign
);
    localparam logic [2:0] OP_LOAD_COMPRESSED = 3'b110;

    // Internal routing wires
    logic [511:0] mult_product;
    logic         alu_sign_out;

    // --- The Combinational Math Engine ---
    alu u_comb_alu (
        .src_a        (src_a),
        .src_b        (src_b),
        .mult_product (mult_product),
        .alu_op       (alu_op),
        .sel_hi       (sel_hi),
        .mod_p_en     (mod_p_en),
        .target_sign  (x_sign),
        .alu_result   (alu_result),
        .cmp_flag     (cmp_flag),
        .cmp_eq       (cmp_eq),
        .sign_bit_out (alu_sign_out)     
        
        
    );

    // --- The Sign Bit Status Register ---
    // <-- NEW: Dedicated flip-flop to hold the sign bit across multiple cycles
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_sign <= 1'b0;
        end else if (alu_op == OP_LOAD_COMPRESSED) begin
            // Only update the flip-flop when the FSM explicitly commands a Load
            x_sign <= alu_sign_out;
        end
    end
        
    
    // --- The 18-Cycle Iterative Multiplier ---
    mult u_booth_mult (
        .clk   (clk),
        .rst_n (rst_n),
        .start (mult_kick), 
        .a     (src_a),
        .b     (src_b),
        .done  (mult_done), // Routes back to the Micro-Sequencer
        .p     (mult_product)
    );

endmodule