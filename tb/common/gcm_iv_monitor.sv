// ============================================================================
// gcm_iv_monitor : simulation-only checker for GCM IV reuse (project brief §5.2).
//
// Watches one aes_gcm instance. Every accepted ENCRYPT start records the
// (key, iv) pair; seeing the same pair twice is an IV reuse, which breaks
// GCM confidentiality and authentication.
//   FATAL = 1 : stop the simulation with $fatal (use in system testbenches)
//   FATAL = 0 : only count in reuse_count (lets a testbench prove the
//               monitor works by reusing an IV on purpose)
// Decryptions and single-block ECB calls (ecb = 1, no IV) are not recorded:
// decrypting the same packet twice is harmless.
// Call clear() to forget the history (e.g. between unrelated KAT vectors that
// share key and IV by design).
// ============================================================================
module gcm_iv_monitor #(
    parameter bit    FATAL = 1,
    parameter string NAME  = "gcm"
) (
    input logic         clk,
    input logic         start,
    input logic         ready,
    input logic         decrypt,
    input logic         ecb,
    input logic [127:0] key,
    input logic [95:0]  iv
);
    bit seen [bit [223:0]];
    int reuse_count = 0;
    int enc_count   = 0;

    function automatic void clear();
        seen.delete();
    endfunction

    always @(posedge clk) begin
        if (start && ready && !decrypt && !ecb) begin
            enc_count++;
            if (seen.exists({key, iv})) begin
                reuse_count++;
                if (FATAL)
                    $fatal(1, "[%s] GCM IV REUSE: key %h iv %h", NAME, key, iv);
                else
                    $display("[%s] (expected) IV reuse detected: iv %h", NAME, iv);
            end
            seen[{key, iv}] = 1'b1;
        end
    end
endmodule
