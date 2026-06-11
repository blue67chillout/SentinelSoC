module alu (
    input  logic [255:0] src_a,
    input  logic [255:0] src_b,
    input  logic [511:0] mult_product, 
    input  logic [2:0]   alu_op,
    input  logic         sel_hi,
    input  logic         mod_p_en,     // modulo p enable
    input  logic         target_sign,
    
    output logic [255:0] alu_result,
    output logic         cmp_flag,
    output logic         cmp_eq,
    output logic         sign_bit_out
    
);

    // Ed25519 Prime: p = 2^255 - 19
    localparam logic [255:0] PRIME_P = 
        256'h7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFED;

    // Derived Constant for Two's Complement Subtraction Fix
    // TWO_256_MINUS_P = 2^256 - p = 2^255 + 19
    localparam logic [255:0] TWO_256_MINUS_P = 
        256'h8000000000000000000000000000000000000000000000000000000000000013;

    // Internal flags & wires
    logic [256:0] sum_full;
    logic [256:0] sub_full;
    logic         isolated_cmp_flag;
    logic [255:0] mod_mult_result; 
    logic [511:0] pm_input; // Power gating wire
    logic         carry;    // Extracted carry bit for comparator optimization

    typedef enum logic [2:0] { 
        OP_ADD     = 3'b000, 
        OP_SUB_CND = 3'b001, 
        OP_MULT    = 3'b010, 
        OP_CMP     = 3'b011, 
        OP_PASS    = 3'b100,
        OP_SUB_RAW = 3'b101,
        OP_LOAD_COMPRESSED = 3'b110,
        OP_COND_NEGATE     = 3'b111 
    } alu_op_t;
    
    assign isolated_cmp_flag = (src_a >= src_b);
    assign carry = sum_full[256];
    assign cmp_eq = (src_a == src_b);

    // --- POWER GATING: The Pseudo Mersenne Reducer ---
    // Only toggle the massive combinatorial tree if we are actually doing a Mod-P Multiply
    assign pm_input = (mod_p_en && (alu_op == OP_MULT)) ? mult_product : '0;

    pseudo_mersenne u_pm_reducer (
        .data_in  (pm_input),
        .data_out (mod_mult_result)
    );   

    
    always_comb begin
        alu_result = 256'd0;
        sum_full   = 257'd0;
        sub_full   = 257'd0;
        cmp_flag   = 1'b0;
        sign_bit_out = 1'b0;
        

                
        case (alu_op)
            OP_ADD: begin 
                sum_full = {1'b0, src_a} + {1'b0, src_b};
                if (mod_p_en) begin                 
                    alu_result = (carry || sum_full[255:0] >= PRIME_P) ? 
                                 (sum_full[255:0] - PRIME_P) : sum_full[255:0];
                end else begin                    
                    alu_result = sum_full[255:0];
                end
            end
            
            OP_SUB_CND: begin 
                // NOTE: mod_p_en has no effect here. A conditional subtraction by p 
                // is exactly what field arithmetic reduction requires anyway.
                cmp_flag   = isolated_cmp_flag;
                alu_result = isolated_cmp_flag ? (src_a - src_b) : src_a;         
            end
            
            OP_MULT: begin 
                
                if (mod_p_en) begin
                    // Point Math: Route through Pseudo Mersenne Reducer
                    alu_result = mod_mult_result; 
                end else begin
                    // Barrett Math: Use sel_hi to grab raw halves
                    alu_result = sel_hi ? mult_product[511:256] : mult_product[255:0];
                end
            end
            
            OP_CMP: begin 
                // NOTE: mod_p_en has no effect here. Comparison behaves identically.
                cmp_flag   = isolated_cmp_flag; 
                alu_result = src_a; 
            end
            
            OP_PASS: begin 
                alu_result = src_a;
            end

            OP_SUB_RAW: begin 
                sub_full = {1'b0, src_a} - {1'b0, src_b};
                if (mod_p_en) begin
                    // Field Subtraction (Safe Two's Complement Underflow Fix)
                    alu_result = sub_full[256] ? (sub_full[255:0] - TWO_256_MINUS_P) : sub_full[255:0];
                end else begin
                    // Standard Wrap-around Subtraction (For Barrett)
                    alu_result = sub_full[255:0]; 
                    cmp_flag   = ~sub_full[256];
                end
            end

            OP_LOAD_COMPRESSED: begin 
                // 1. Mask out bit 255 (force it to 0), pass the remaining 255 bits
                alu_result = {1'b0, src_a[254:0]}; 
                
                // 2. Output the stripped top bit on the dedicated wire
                sign_bit_out = src_a[255];
            end

            OP_COND_NEGATE: begin
                // Check if the calculated parity (bit 0) matches the target parity
                if (src_a[0] != target_sign) begin
                    // Parity mismatch! Calculate (p - x) mod p to negate it.
                    // Because x is guaranteed to be less than p at this stage, 
                    // simple subtraction is mathematically safe.
                    alu_result = PRIME_P - src_a; 
                end else begin
                    // Parity matches! Pass x through unharmed.
                    alu_result = src_a;
                end
            end

            default: alu_result = 256'd0;
        endcase
    end
endmodule