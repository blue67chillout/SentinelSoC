package sha512_pkg;
 
    // Standard SHA-512 Word Type
    typedef logic [63:0] word_t;

    // Initial Hash Values (IV)
    // High-order 64 bits of the fractional parts of the square roots of the first 8 primes
    const word_t SHA512_IV [8] = '{
        64'h6a09e667f3bcc908, // sqrt(2)
        64'hbb67ae8584caa73b, // sqrt(3)
        64'h3c6ef372fe94f82b, // sqrt(5)
        64'ha54ff53a5f1d36f1, // sqrt(7)
        64'h510e527fade682d1, // sqrt(11)
        64'h9b05688c2b3e6c1f, // sqrt(13)
        64'h1f83d9abfb41bd6b, // sqrt(17)
        64'h5be0cd19137e2179  // sqrt(19)
    };

    // Round Constants (K)
    // High-order 64 bits of the fractional parts of the cube roots of the first 80 primes
    const word_t K [80] = '{
        64'h428a2f98d728ae22, 64'h7137449123ef65cd, 64'hb5c0fbcfec4d3b2f, 64'he9b5dba58189dbbc,
        64'h3956c25bf348b538, 64'h59f111f1b605d019, 64'h923f82a4af194f9b, 64'hab1c5ed5da6d8118,
        64'hd807aa98a3030242, 64'h12835b0145706fbe, 64'h243185be4ee4b28c, 64'h550c7dc3d5ffb4e2,
        64'h72be5d74f27b896f, 64'h80deb1fe3b1696b1, 64'h9bdc06a725c71235, 64'hc19bf174cf692694,
        64'he49b69c19ef14ad2, 64'hefbe4786384f25e3, 64'h0fc19dc68b8cd5b5, 64'h240ca1cc77ac9c65,
        64'h2de92c6f592b0275, 64'h4a7484aa6ea6e483, 64'h5cb0a9dcbd41fbd4, 64'h76f988da831153b5,
        64'h983e5152ee66dfab, 64'ha831c66d2db43210, 64'hb00327c898fb213f, 64'hbf597fc7beef0ee4,
        64'hc6e00bf33da88fc2, 64'hd5a79147930aa725, 64'h06ca6351e003826f, 64'h142929670a0e6e70,
        64'h27b70a8546d22ffc, 64'h2e1b21385c26c926, 64'h4d2c6dfc5ac42aed, 64'h53380d139d95b3df,
        64'h650a73548baf63de, 64'h766a0abb3c77b2a8, 64'h81c2c92e47edaee6, 64'h92722c851482353b,
        64'ha2bfe8a14cf10364, 64'ha81a664bbc423001, 64'hc24b8b70d0f89791, 64'hc76c51a30654be30,
        64'hd192e819d6ef5218, 64'hd69906245565a910, 64'hf40e35855771202a, 64'h106aa07032bbd1b8,
        64'h19a4c116b8d2d0c8, 64'h1e376c085141ab53, 64'h2748774cdf8eeb99, 64'h34b0bcb5e19b48a8,
        64'h391c0cb3c5c95a63, 64'h4ed8aa4ae3418acb, 64'h5b9cca4f7763e373, 64'h682e6ff3d6b2b8a3,
        64'h748f82ee5defb2fc, 64'h78a5636f43172f60, 64'h84c87814a1f0ab72, 64'h8cc702081a6439ec,
        64'h90befffa23631e28, 64'ha4506cebde82bde9, 64'hbef9a3f7b2c67915, 64'hc67178f2e372532b,
        64'hca273eceea26619c, 64'hd186b8c721c0c207, 64'heada7dd6cde0eb1e, 64'hf57d4f7fee6ed178,
        64'h06f067aa72176fba, 64'h0a637dc5a2c898a6, 64'h113f9804bef90dae, 64'h1b710b35131c471b,
        64'h28db77f523047d84, 64'h32caab7b40c72493, 64'h3c9ebe0a15c9bebc, 64'h431d67c49c100d4c,
        64'h4cc5d4becb3e42b6, 64'h597f299cfc657e2a, 64'h5fcb6fab3ad6faec, 64'h6c44198c4a475817
    };

    // Helper Functions ROTR and SHR
    function automatic word_t rotr(input word_t value,input int amt);
        return (value >> amt) | (value << (64 - amt));
    endfunction

    function automatic word_t shr(input word_t value, input int amt);
        return (value >> amt);
    endfunction

    // SHA-512 Logical Primitives
    function automatic word_t Ch(word_t x, word_t y, word_t z);
        return (x & y) ^ (~x & z);
    endfunction

    function automatic word_t Maj(word_t x, word_t y, word_t z);
        return (x & y) ^ (x & z) ^ (y & z);
    endfunction

    // SHA-512 Sigma Functions
    function automatic word_t upper_sigma0(word_t x);
        return rotr(x, 28) ^ rotr(x, 34) ^ rotr(x, 39);
    endfunction

    function automatic word_t upper_sigma1(word_t x);
        return rotr(x, 14) ^ rotr(x, 18) ^ rotr(x, 41);
    endfunction

    function automatic word_t lower_sigma0(word_t x);
        return rotr(x, 1) ^ rotr(x, 8) ^ shr(x, 7);
    endfunction

    function automatic word_t lower_sigma1(word_t x);
        return rotr(x, 19) ^ rotr(x, 61) ^ shr(x, 6);
    endfunction
    
    typedef struct {
        word_t sum;
        word_t carry;
    } csa_t;

    // Carry Save Adder
    function automatic csa_t csa64(word_t a, word_t b, word_t c);
        csa_t res;
        res.sum   = a ^ b ^ c;
        res.carry = (a & b) | (b & c) | (a & c);
        return res;
    endfunction
    
endpackage
