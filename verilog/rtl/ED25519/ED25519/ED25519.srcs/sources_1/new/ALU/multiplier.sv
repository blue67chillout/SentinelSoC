// -----------------------------------------------------------------------------
// Module: mult
// Description: 256x256 unsigned multiplier heavily optimized for area.
// Architecture: Iterative 64x64 schoolbook method.
// Latency: 18 cycles fixed (1 cycle setup + 16 multiply cycles + 1 flush cycle)
// 
// Protocol: 
// - Assert 'start' to begin. 
// - 'done' will assert when calculation is complete and hold HIGH.
// - Output 'p' is fully registered and valid while 'done' is HIGH.
// - Asserting 'start' at any time (even mid-calculation) will abort and restart.
// - Holding 'start' high for multiple cycles will continuously re-initiate 
//   the operation; computation begins on the first cycle 'start' is low.
// -----------------------------------------------------------------------------

module mult (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic [255:0] a,
    input  logic [255:0] b,
    output logic         done,
    output logic [511:0] p
);

    typedef enum logic [1:0] {
        IDLE,
        CALC,
        DONE
    } state_t;

    state_t       state;
    logic [255:0] a_reg, b_reg;
    logic [511:0] p_reg;
    logic [4:0]   count; 

    // --- Datapath signals ---
    logic [63:0]  op_a, op_b;
    logic [127:0] prod;
    logic [2:0]   shift_amt;
    logic [511:0] shifted_prod;
    logic [511:0] shifted_prod_r;  // Pipeline register

    // ---------------------------------------------------------
    // Combinational Datapath: Selection & Power Gating
    // ---------------------------------------------------------
    
    // 64-bit word select with power gating. 
    always_comb begin
        op_a = '0;
        op_b = '0;
        
        if (state == CALC && count < 5'd16) begin
            case (count[3:2])
                2'd0: op_a = a_reg[63:0];
                2'd1: op_a = a_reg[127:64];
                2'd2: op_a = a_reg[191:128];
                2'd3: op_a = a_reg[255:192];
                default: op_a = '0;
            endcase
            
            case (count[1:0])
                2'd0: op_b = b_reg[63:0];
                2'd1: op_b = b_reg[127:64];
                2'd2: op_b = b_reg[191:128];
                2'd3: op_b = b_reg[255:192];
                default: op_b = '0;
            endcase
        end
    end

    // Single 64x64 multiplier instance
    assign prod = op_a * op_b;

    // Lane alignment: shift_amt = i + j, range [0,6]
    assign shift_amt = {1'b0, count[3:2]} + {1'b0, count[1:0]};

    // Mux-based placement (avoids barrel shifter). 
    always_comb begin
        shifted_prod = '0;
        unique case (shift_amt)
            3'd0: shifted_prod[127:0]   = prod;
            3'd1: shifted_prod[191:64]  = prod;
            3'd2: shifted_prod[255:128] = prod;
            3'd3: shifted_prod[319:192] = prod;
            3'd4: shifted_prod[383:256] = prod;
            3'd5: shifted_prod[447:320] = prod;
            3'd6: shifted_prod[511:384] = prod;
            default: shifted_prod = '0;
        endcase
    end

    // ---------------------------------------------------------
    // Sequential Datapath: Pipelining
    // ---------------------------------------------------------
    
    // Pipeline register: breaks critical path between multiplier and adder.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shifted_prod_r <= '0;
        end else if (start) begin
            // Clear on start (abort/restart/initial) 
            shifted_prod_r <= '0;
        end else if (state == CALC) begin
            // Implicitly holds value in IDLE/DONE, allowing synthesis to insert ICG
            shifted_prod_r <= shifted_prod;
        end
    end

    // ---------------------------------------------------------
    // Control FSM & Accumulator
    // ---------------------------------------------------------
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            count <= '0;
            a_reg <= '0;
            b_reg <= '0;
            p_reg <= '0;
            done  <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    if (start) begin
                        a_reg <= a;
                        b_reg <= b;
                        p_reg <= '0;
                        count <= '0;
                        done  <= 1'b0;
                        state <= CALC;
                    end
                end

                CALC: begin
                    if (start) begin
                        // Abort and restart
                        a_reg <= a;
                        b_reg <= b;
                        p_reg <= '0;
                        count <= '0;
                        done  <= 1'b0;
                    end else begin
                        // Accumulate pipelined product
                        // Synthesis Hint: Tool should map this to a CLA/Fast adder 
                        p_reg <= p_reg + shifted_prod_r;  
                        count <= count + 5'd1;
                        
                        // Exit on count == 16. The final shifted_prod_r (prod15) 
                        // is concurrently accumulated into p_reg on this exact clock edge.
                        if (count == 5'd16) begin
                            state <= DONE;
                            done  <= 1'b1;
                            count <= '0;  // Clear to avoid lint hazards on shift_amt
                        end
                    end
                end

                DONE: begin
                    if (start) begin
                        // Immediate restart from DONE state
                        a_reg <= a;
                        b_reg <= b;
                        p_reg <= '0;
                        count <= '0;
                        done  <= 1'b0;
                        state <= CALC;
                    end
                    // 'done' remains high until 'start' is asserted
                end

                default: state <= IDLE;
            endcase
        end
    end

    // Output assignment (p_reg is a flip-flop output, so p is fully registered)
    assign p = p_reg;

endmodule