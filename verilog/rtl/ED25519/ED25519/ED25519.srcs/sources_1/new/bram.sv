module firmware_bram #(
    parameter INIT_FILE = "firmware.mem",
    parameter ADDR_WIDTH = 16,     // 64K words = 256KB total capacity
    parameter DATA_WIDTH = 32
)(
    input  logic                  clk,
    input  logic [ADDR_WIDTH-1:0] addr,
    output logic [DATA_WIDTH-1:0] dout
);

    // BRAM array
    (* ram_style = "block" *) logic [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

    // Load Hex File for FPGA Demo
    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    // Synchronous Read
    always_ff @(posedge clk) begin
        dout <= mem[addr];
    end

endmodule