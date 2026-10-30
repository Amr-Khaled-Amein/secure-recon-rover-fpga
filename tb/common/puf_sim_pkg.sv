// ============================================================================
// puf_sim_pkg : settings and helpers for the ring-oscillator model
//               (tb/common/ro_cell_sim.sv). Simulation only.
//
// A testbench changes these between "power-ups":
//   chip       which FPGA: sets every RO's process variation (fingerprint)
//   run        power-up number: seeds the measurement noise
//   sigma_ppm  process variation of RO periods, sigma in ppm (10000 = 1%)
//   bias_ppm   systematic slow-down of even-index ROs, ppm (0 = unbiased);
//              positive values make pair bits more often 0
//   env_ppm    per-measurement frequency offset, sigma in ppm
//              (supply / temperature noise; makes marginal bits flip)
//   jit_ppm    per-half-period jitter, sigma in ppm
// ============================================================================
package puf_sim_pkg;
    int chip      = 1;
    int run       = 1;
    int sigma_ppm = 10000;
    int bias_ppm  = 0;
    int env_ppm   = 1500;
    int jit_ppm   = 2000;

    // deterministic 32-bit hash, simulator independent
    function automatic int unsigned mix(input int unsigned x);
        x ^= x >> 16; x *= 32'h7feb352d;
        x ^= x >> 15; x *= 32'h846ca68b;
        x ^= x >> 16;
        return x;
    endfunction

    // approximately standard normal (sum of 12 uniforms)
    function automatic real gauss(inout int unsigned st);
        real s = 0.0;
        for (int i = 0; i < 12; i++) begin
            st = mix(st + 32'h9e3779b9);
            s += real'(st) / 4294967296.0;
        end
        return s - 6.0;
    endfunction

    // nominal period of RO idx on the current chip
    function automatic real ro_period_ps(input int idx, input real nom_ps);
        int unsigned st = mix(mix(chip * 32'h01000193) ^ idx);
        return nom_ps * (1.0 + gauss(st) * sigma_ppm / 1.0e6
                             + ((idx % 2 == 0) ? bias_ppm / 1.0e6 : 0.0));
    endfunction

    function automatic int unsigned noise_seed(input int idx);
        return mix(mix(run * 32'h2545f491) ^ (idx * 32'h9e3779b1) ^ chip);
    endfunction
endpackage
