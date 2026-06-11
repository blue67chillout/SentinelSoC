`timescale 1ns/1ps

module ibex_dift_mem
  #(
    parameter ADDR_WIDTH = 11,  
    parameter DATA_WIDTH = 32,
    parameter NUM_WORDS  = 1024
  )(
    input  logic                   clk,
    input  logic                   rstn_i,
    input  logic                   en_i,
    input  logic [ADDR_WIDTH-1:0]  addr_i,
    input  logic                   wdata_i, // The 1-bit taint bit
    output logic                   rdata_o, // The 1-bit tag for the word
    input  logic                   we_i,
    input  logic [DATA_WIDTH/8-1:0] be_i    // Byte enables
  );

  logic mem [0:NUM_WORDS-1];

  // Address logic: If addr_i is a byte address, we shift it to word address
  // For a 32-bit system, we typically ignore the lower 2 bits (addr_i[1:0])
  logic [ADDR_WIDTH-1:0] word_addr;
  assign word_addr = addr_i; 

  always @(posedge clk)
  begin
    if (~rstn_i)
    begin
      // Clear all tags on reset
      for (int i = 0; i < NUM_WORDS; i++) begin
        mem[i] <= 1'b0;
      end
      rdata_o <= 1'b0;
    end
    else if (en_i && we_i)
    begin
      // If ANY byte in the 32-bit word is written (ORing all be_i bits), 
      // we update the single tag for this word.
      if (|be_i) begin
        mem[word_addr] <= wdata_i;
      end
    end

    // Synchronous Read
    rdata_o <= mem[word_addr];
  end

endmodule