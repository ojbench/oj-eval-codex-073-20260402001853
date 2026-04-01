// Simple RV32I CPU, multi-cycle, byte-wide memory interface
module cpu(
  input  wire                 clk_in,
  input  wire                 rst_in,
  input  wire                 rdy_in,

  input  wire [ 7:0]          mem_din,
  output wire [ 7:0]          mem_dout,
  output wire [31:0]          mem_a,
  output wire                 mem_wr,
  
  input  wire                 io_buffer_full,
  
  output wire [31:0]          dbgreg_dout
);

reg [31:0] pc;
reg [31:0] regs[31:0];
reg [31:0] ir;

reg [31:0] mem_a_r; assign mem_a = mem_a_r;
reg [7:0]  mem_dout_r; assign mem_dout = mem_dout_r;
reg        mem_wr_r; assign mem_wr = mem_wr_r;

assign dbgreg_dout = regs[10];

wire [6:0]  op  = ir[6:0];
wire [2:0]  f3  = ir[14:12];
wire [6:0]  f7  = ir[31:25];
wire [4:0]  rd  = ir[11:7];
wire [4:0]  rs1 = ir[19:15];
wire [4:0]  rs2 = ir[24:20];

wire [31:0] imm_i = {{20{ir[31]}}, ir[31:20]};
wire [31:0] imm_s = {{20{ir[31]}}, ir[31:25], ir[11:7]};
wire [31:0] imm_b = {{19{ir[31]}}, ir[31], ir[7], ir[30:25], ir[11:8], 1'b0};
wire [31:0] imm_u = {ir[31:12], 12'b0};
wire [31:0] imm_j = {{11{ir[31]}}, ir[31], ir[19:12], ir[20], ir[30:21], 1'b0};

localparam S_IF0=0,S_IF0D=1,S_IF1=2,S_IF1D=3,S_IF2=4,S_IF2D=5,S_IF3=6,S_IF3D=7;
localparam S_DEC=8,S_LOAD0=9,S_LOAD1=10,S_LOAD2=11,S_LOAD3=12,S_STORE0=13,S_STORE1=14,S_STORE2=15,S_STORE3=16,S_WB=17,S_NEXT=18;
reg [4:0] state;

reg [31:0] wb_data; reg [4:0] wb_rd; reg wb_en;
reg [31:0] addr; reg [31:0] ldata; reg [1:0] lsize; reg luns; reg [1:0] ssize;

function [31:0] sext8; input [7:0] v; begin sext8 = {{24{v[7]}},v}; end endfunction
function [31:0] zext8; input [7:0] v; begin zext8 = {24'b0,v}; end endfunction
function [31:0] sext16; input [15:0] v; begin sext16 = {{16{v[15]}},v}; end endfunction
function [31:0] zext16; input [15:0] v; begin zext16 = {16'b0,v}; end endfunction

integer i;
always @(posedge clk_in) begin
  if (rst_in) begin
    pc <= 32'h0; ir <= 32'h13; mem_a_r <= 32'h0; mem_dout_r <= 8'h0; mem_wr_r <= 1'b0; state <= S_IF0;
    for (i=0;i<32;i=i+1) regs[i] <= 32'h0;
  end else if (!rdy_in) begin
    mem_wr_r <= 1'b0;
  end else begin
    mem_wr_r <= 1'b0; regs[0] <= 32'h0;
    case (state)
      S_IF0:  begin mem_a_r <= pc + 0; state <= S_IF0D; end
      S_IF0D: begin ir[7:0] <= mem_din; state <= S_IF1; end
      S_IF1:  begin mem_a_r <= pc + 1; state <= S_IF1D; end
      S_IF1D: begin ir[15:8] <= mem_din; state <= S_IF2; end
      S_IF2:  begin mem_a_r <= pc + 2; state <= S_IF2D; end
      S_IF2D: begin ir[23:16] <= mem_din; state <= S_IF3; end
      S_IF3:  begin mem_a_r <= pc + 3; state <= S_IF3D; end
      S_IF3D: begin ir[31:24] <= mem_din; state <= S_DEC; end

      S_DEC: begin
        wb_en <= 1'b0; wb_rd <= rd;
        case (op)
          7'b0110111: begin wb_data <= imm_u; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // LUI
          7'b0010111: begin wb_data <= pc + imm_u; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // AUIPC
          7'b1101111: begin wb_data <= pc + 4; wb_en <= (rd!=0); state <= S_WB; pc <= pc + imm_j; end // JAL
          7'b1100111: begin if (f3==3'b000) begin wb_data <= pc + 4; wb_en <= (rd!=0); state <= S_WB; pc <= ((regs[rs1] + imm_i) & 32'hFFFF_FFFE); end else begin pc <= pc + 4; state <= S_NEXT; end end // JALR
          7'b1100011: begin // BRANCH
            pc <= ((f3==3'b000 && regs[rs1]==regs[rs2]) || (f3==3'b001 && regs[rs1]!=regs[rs2]) || (f3==3'b100 && (regs[rs1]) < (regs[rs2])) || (f3==3'b101 && (regs[rs1]) >= (regs[rs2])) || (f3==3'b110 && regs[rs1] < regs[rs2]) || (f3==3'b111 && regs[rs1] >= regs[rs2])) ? (pc + imm_b) : (pc + 4);
            state <= S_NEXT;
          end
          7'b0000011: begin // LOAD
            addr <= regs[rs1] + imm_i; luns <= (f3==3'b100 || f3==3'b101);
            case (f3)
              3'b000,3'b100: lsize <= 2'd0; // LB/LBU
              3'b001,3'b101: lsize <= 2'd1; // LH/LHU
              3'b010: lsize <= 2'd2; // LW
              default: lsize <= 2'd2;
            endcase
            wb_rd <= rd; mem_a_r <= addr + 0; state <= S_LOAD0;
          end
          7'b0100011: begin // STORE
            addr <= regs[rs1] + imm_s;
            case (f3)
              3'b000: ssize <= 2'd0; // SB
              3'b001: ssize <= 2'd1; // SH
              3'b010: ssize <= 2'd2; // SW
              default: ssize <= 2'd2;
            endcase
            state <= S_STORE0;
          end
          7'b0010011: begin // OP-IMM
            case (f3)
              3'b000: begin wb_data <= regs[rs1] + imm_i; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // ADDI
              3'b010: begin wb_data <= ((regs[rs1]) < (imm_i)) ? 32'd1:32'd0; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // SLTI
              3'b011: begin wb_data <= (regs[rs1] < imm_i) ? 32'd1:32'd0; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // SLTIU
              3'b100: begin wb_data <= regs[rs1] ^ imm_i; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // XORI
              3'b110: begin wb_data <= regs[rs1] | imm_i; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // ORI
              3'b111: begin wb_data <= regs[rs1] & imm_i; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // ANDI
              3'b001: begin wb_data <= regs[rs1] << ir[24:20]; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // SLLI
              3'b101: begin if (ir[30]) wb_data <= (regs[rs1]) >>> ir[24:20]; else wb_data <= regs[rs1] >> ir[24:20]; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // SRLI/SRAI
              default: begin pc <= pc + 4; state <= S_NEXT; end
            endcase
          end
          7'b0110011: begin // OP
            case ({f7,f3})
              {7'b0000000,3'b000}: begin wb_data <= regs[rs1] + regs[rs2]; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // ADD
              {7'b0100000,3'b000}: begin wb_data <= regs[rs1] - regs[rs2]; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // SUB
              {7'b0000000,3'b001}: begin wb_data <= regs[rs1] << regs[rs2][4:0]; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // SLL
              {7'b0000000,3'b010}: begin wb_data <= ((regs[rs1]) < (regs[rs2])) ? 32'd1:32'd0; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // SLT
              {7'b0000000,3'b011}: begin wb_data <= (regs[rs1] < regs[rs2]) ? 32'd1:32'd0; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // SLTU
              {7'b0000000,3'b100}: begin wb_data <= regs[rs1] ^ regs[rs2]; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // XOR
              {7'b0000000,3'b101}: begin wb_data <= regs[rs1] >> regs[rs2][4:0]; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // SRL
              {7'b0100000,3'b101}: begin wb_data <= (regs[rs1]) >>> regs[rs2][4:0]; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // SRA
              {7'b0000000,3'b110}: begin wb_data <= regs[rs1] | regs[rs2]; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // OR
              {7'b0000000,3'b111}: begin wb_data <= regs[rs1] & regs[rs2]; wb_en <= (rd!=0); state <= S_WB; pc <= pc + 4; end // AND
              default: begin pc <= pc + 4; state <= S_NEXT; end
            endcase
          end
          default: begin pc <= pc + 4; state <= S_NEXT; end
        endcase
      end

      // LOAD sequence
      S_LOAD0: begin ldata[7:0] <= mem_din; if (lsize==2'd0) begin wb_en <= (wb_rd!=0); wb_data <= luns ? zext8(mem_din) : sext8(mem_din); pc <= pc + 4; state <= S_WB; end else begin mem_a_r <= addr + 1; state <= S_LOAD1; end end
      S_LOAD1: begin ldata[15:8] <= mem_din; if (lsize==2'd1) begin wb_en <= (wb_rd!=0); wb_data <= luns ? zext16({mem_din, ldata[7:0]}) : sext16({mem_din, ldata[7:0]}); pc <= pc + 4; state <= S_WB; end else begin mem_a_r <= addr + 2; state <= S_LOAD2; end end
      S_LOAD2: begin ldata[23:16] <= mem_din; mem_a_r <= addr + 3; state <= S_LOAD3; end
      S_LOAD3: begin ldata[31:24] <= mem_din; wb_en <= (wb_rd!=0); wb_data <= {mem_din, ldata[23:16], ldata[15:8], ldata[7:0]}; pc <= pc + 4; state <= S_WB; end

      // STORE sequence
      S_STORE0: begin
        // If writing to UART TX at 0x30000 and buffer full, stall
        if ((addr[17:16]==2'b11) && (ssize==2'd0) && (addr[2:0]==3'b000) && io_buffer_full) begin
          state <= S_STORE0;
        end else begin
          mem_a_r   <= addr + 0;
          mem_dout_r<= regs[rs2][7:0];
          mem_wr_r  <= 1'b1;
          if (ssize==2'd0) begin
            pc    <= pc + 4;
            state <= S_NEXT;
          end else begin
            state <= S_STORE1;
          end
        end
      end
      S_STORE1: begin
        mem_a_r    <= addr + 1;
        mem_dout_r <= regs[rs2][15:8];
        mem_wr_r   <= 1'b1;
        if (ssize==2'd1) begin
          pc    <= pc + 4;
          state <= S_NEXT;
        end else begin
          state <= S_STORE2;
        end
      end
      S_STORE2: begin
        mem_a_r    <= addr + 2;
        mem_dout_r <= regs[rs2][23:16];
        mem_wr_r   <= 1'b1;
        state      <= S_STORE3;
      end
      S_STORE3: begin
        mem_a_r    <= addr + 3;
        mem_dout_r <= regs[rs2][31:24];
        mem_wr_r   <= 1'b1;
        pc         <= pc + 4;
        state      <= S_NEXT;
      end

      S_WB: begin if (wb_en && wb_rd!=0) regs[wb_rd] <= wb_data; state <= S_NEXT; end
      S_NEXT: begin state <= S_IF0; end
    endcase
  end
end

endmodule
