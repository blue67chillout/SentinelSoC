/* =============================================================================       
 DISCIPLINED REGISTER MAP:

 --- Persistent Storage Zone (24-31) ---
   REG[24]    = Constant 0
   REG[25]    = Constant 1
   REG[26]    = Constant d
   REG[27]    = Constant 2d
   REG[28]    = constant root i
   REG[29:31] = G (X,Y,Z)         


 --- Active Execution Zone (0-23) ---

    STAGE 1 (Barrett Reduction)

   REG[0:3]   = Accumulator (X, Y, Z, T)   -> Actively mutating during loops
   REG[4:7]   = Operand (X, Y, Z, T)       -> Actively read during Additions
   REG[8]     = Hash_low    //Can be overwritten once used
   REG[9]     = Hash_hi     //Can be overwritten once used
   REG[10]    = mu_hi       //Can be overwritten once used
   REG[11]    = q           //Can be overwritten once used
   REG[12]    = mu_lo       //Can be overwritten once used
   REG[13:15] = Free for calc
   REG[16]    = Datascalar h   
   REG[17-19] = P1 storage (s * G)
   REG[20]    = R compressed
   REG[21]    = pubKey compressed
   REG[22]    = Empty for now
   REG[23]    = s

   Final thing ends with h in REG[16], REG[8:15] can be overwritten


   STAGE 2 (P1 = s*G)

   REG[0:3]   = Accumulator (X, Y, Z, T)   -> Actively mutating during loops
   REG[4:7]   = Operand (X, Y, Z, T)       -> Actively read during Additions
   REG[8:15]  = ALU Scratchpads (A-H)      -> Violently overwritten every cycle
   REG[16]    = Datascalar h   
   REG[17:19] = P1 storage (s * G)
   REG[20]    = R compressed
   REG[21]    = pubKey compressed
   REG[22]    = Empty for now
   REG[23]    = s

   Ends with P1 in REG[17:19], REG[4:7] and REG[23] can be used for other purposes

   STAGE 3a (h*pubKey)

   REG[0:3]   = Accumulator (X, Y, Z, T)   -> Actively mutating during loops
   REG[4:7]   = Decompressed pubKey
   REG[8:15]  = ALU Scratchpads (A-H)      -> Violently overwritten every cycle
   REG[16]    = Datascalar h   
   REG[17:19] = P1 storage (s * G)
   REG[20]    = R compressed
   REG[21]    = pubKey compressed
   REG[22]    = Empty for now
   REG[23]    = s

   Decompress pubkey from the previous step to REG[4:7], 
   Once the math is done, store h*pubKey in REG[4:7] itself or in the REG[8:15] Scratchpads

   STAGE 3b (R + stage 3a)

   REG[0:3]   = Accumulator (X, Y, Z, T)   -> Actively mutating during loops
   REG[4:7]   = h*pubKey
   REG[8:15]  = ALU Scratchpads (A-H)      -> Violently overwritten every cycle
   REG[16]    = Datascalar h   
   REG[17:19] = P1 storage (s * G)
   REG[20]    = R compressed
   REG[21]    = pubKey compressed
   REG[22]    = Empty for now
   REG[23]    = s

   Decompress R to [20:23], do the final math.

 We can always change the register mapping. 
 ============================================================================= */

module reg_file #(
    parameter WIDTH = 256,
    parameter DEPTH = 32,
    parameter ADDR_W = $clog2(DEPTH)
)(
    input logic clk,  
    
    //Write
    input logic wr_enable,
    input logic [ADDR_W-1:0] wr_addr,
    input logic [WIDTH-1:0] data_in,
    
    //Read port A
    input logic [ADDR_W-1:0] A_select,
    output logic [WIDTH-1:0] A_out,
    
    //Read port B
    input logic [ADDR_W-1:0] B_select,
    output logic [WIDTH-1:0] B_out  
    );
    
    //storage 
    logic [WIDTH-1:0] mem[0:DEPTH-1];
      
    always_ff @(posedge clk) begin
        if (wr_enable)
            mem[wr_addr] <= data_in;
    end    
      
    assign A_out = mem[A_select];    
    assign B_out = mem[B_select];
    
       
endmodule
