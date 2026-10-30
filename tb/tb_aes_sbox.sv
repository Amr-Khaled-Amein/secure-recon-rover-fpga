// ============================================================================
// tb_aes_sbox : exhaustive self-checking testbench for aes_sbox
// ----------------------------------------------------------------------------
// Checks all 256 inputs against the S-box computed from its definition
// (FIPS-197 5.1.1): multiplicative inverse in GF(2^8), then the affine map.
// Also checks that the S-box is a permutation (every output appears once).
// ============================================================================
`timescale 1ns/1ps

module tb_aes_sbox;

    logic [7:0] x;
    wire  [7:0] y;

    aes_sbox dut (.x(x), .y(y));

    function automatic logic [7:0] gmul(logic [7:0] a, logic [7:0] b);
        logic [7:0] p = 8'h00;
        for (int k = 0; k < 8; k++) begin
            if (b[0]) p ^= a;
            a = {a[6:0], 1'b0} ^ (a[7] ? 8'h1b : 8'h00);
            b = b >> 1;
        end
        return p;
    endfunction

    function automatic logic [7:0] ref_sbox(logic [7:0] v);
        logic [7:0] inv = 8'h00;
        logic [7:0] s;
        if (v != 8'h00)
            for (int k = 1; k < 256; k++)
                if (gmul(v, k[7:0]) == 8'h01) inv = k[7:0];
        s = inv ^ {inv[6:0], inv[7]} ^ {inv[5:0], inv[7:6]}
                ^ {inv[4:0], inv[7:5]} ^ {inv[3:0], inv[7:4]} ^ 8'h63;
        return s;
    endfunction

    bit seen [256];

    initial begin
        for (int v = 0; v < 256; v++) begin
            x = v[7:0];
            #1;
            if (y !== ref_sbox(v[7:0]))
                $fatal(1, "S(%02h) = %02h, expected %02h", v[7:0], y, ref_sbox(v[7:0]));
            if (seen[y]) $fatal(1, "output %02h appears twice", y);
            seen[y] = 1'b1;
        end
        $display("PASS: all 256 entries match, S-box is a permutation");
        $display("TEST PASSED");
        $finish;
    end

endmodule
