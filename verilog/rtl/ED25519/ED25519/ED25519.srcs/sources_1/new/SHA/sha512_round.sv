import sha512_pkg::*;

// this module does the state transformations
module sha512_round (
    input  word_t a, b, c, d, e, f, g, h, // Current state variables (a-h)
    input  word_t k_i, // round constant (cube root of prime)
    input  word_t w_i, // crrent word under operation
    output word_t a_n, b_n, c_n, d_n, e_n, f_n, g_n, h_n // Next state variables
);

    word_t t1, t2;
    word_t SIGMA1_e, SIGMA0_a;
    word_t ch_val, maj_val;

    assign SIGMA1_e   = upper_sigma1(e);
    assign SIGMA0_a   = upper_sigma0(a);
    assign ch_val  = Ch(e, f, g);
    assign maj_val = Maj(a, b, c);

    // t1 = h + Sigma1(e) + Ch(e, f, g) + Kt + Wt 
    csa_t r1, r2, r3;
    always_comb begin
        r1 = csa64(h, SIGMA1_e, ch_val);
        r2 = csa64(r1.sum, {r1.carry[62:0], 1'b0}, k_i);
        r3 = csa64(r2.sum, {r2.carry[62:0], 1'b0}, w_i);
        t1 = r3.sum + {r3.carry[62:0], 1'b0};
    end

    // T2 = Sigma0(a) + Maj(a, b, c)
    assign t2 = SIGMA0_a + maj_val;

    // State Change
    assign a_n = t1 + t2;    // New 'a' is T1 + T2
    assign b_n = a;          // b shifts from old a
    assign c_n = b;          // c shifts from old b
    assign d_n = c;          // d shifts from old c
    assign e_n = d + t1;     // New 'e' is d + T1
    assign f_n = e;          // f shifts from old e
    assign g_n = f;          // g shifts from old f
    assign h_n = g;          // h shifts from old g

endmodule