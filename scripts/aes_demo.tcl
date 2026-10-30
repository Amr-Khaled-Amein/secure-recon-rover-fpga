# ============================================================================
# aes_demo.tcl : type a message in the simulator's Tcl console and get the
#                AES-128 ciphertext back from the simulated hardware.
#
# Use while demo_aes128 is the running simulation (see docs/how_to_test.md):
#   source {<project folder>/scripts/aes_demo.tcl}   ;# braces if the path has spaces
#   aes_encrypt "hello world"
#   aes_key "my secret key 16"     ;# 16 characters, or 32 hex digits
#   aes_selftest                   ;# FIPS-197 check
#
# The text is UTF-8 encoded and padded to a multiple of 16 bytes with PKCS#7,
# then each 16-byte block is encrypted on its own (ECB). That is for this
# demo only: equal blocks give equal ciphertext, which is why the rover will
# use AES-GCM.
# ============================================================================
set ::aes_top     /demo_aes128
set ::aes_key_hex 000102030405060708090a0b0c0d0e0f   ;# FIPS-197 C.1 key

proc aes_pad32 {hex} {
    set hex [string tolower $hex]
    return "[string repeat 0 [expr {32 - [string length $hex]}]]$hex"
}

# Set the key: exactly 16 characters of text, or 32 hex digits.
proc aes_key {k} {
    if {[regexp {^[0-9a-fA-F]{32}$} $k]} {
        set ::aes_key_hex [string tolower $k]
    } else {
        set b [encoding convertto utf-8 $k]
        if {[string length $b] != 16} {
            error "key must be exactly 16 characters (or 32 hex digits); got [string length $b] bytes"
        }
        binary scan $b H* ::aes_key_hex
    }
    puts "key = $::aes_key_hex"
}

# Encrypt one block (32 hex digits) on the simulated core; returns 32 hex digits.
proc aes_block {pt_hex} {
    set top $::aes_top
    set_value $top/go 0
    run 20 ns
    set_value -radix hex $top/key      $::aes_key_hex
    set_value -radix hex $top/block_in $pt_hex
    set_value $top/go 1
    run 200 ns                          ;# core needs 11 cycles = 110 ns
    set_value $top/go 0
    if {[get_value $top/ready] != 1} {
        error "AES core did not finish"
    }
    return [aes_pad32 [get_value -radix hex $top/block_out]]
}

# Encrypt a text message; prints the steps and returns the ciphertext in hex.
proc aes_encrypt {msg} {
    set b   [encoding convertto utf-8 $msg]
    set pad [expr {16 - [string length $b] % 16}]
    append b [string repeat [binary format c $pad] $pad]
    binary scan $b H* pt

    puts ""
    puts "message    : \"$msg\""
    puts "key        : $::aes_key_hex"
    set ct ""
    set n  [expr {[string length $pt] / 32}]
    for {set i 0} {$i < $n} {incr i} {
        set blk [string range $pt [expr {32 * $i}] [expr {32 * $i + 31}]]
        set c   [aes_block $blk]
        puts [format "block %-4d : plaintext  %s" $i $blk]
        puts [format "             ciphertext %s" $c]
        append ct $c
    }
    puts "ciphertext : $ct"
    puts ""
    return $ct
}

# Known-answer check (FIPS-197 C.1) on the simulated core.
proc aes_selftest {} {
    set saved $::aes_key_hex
    set ::aes_key_hex 000102030405060708090a0b0c0d0e0f
    set c [aes_block 00112233445566778899aabbccddeeff]
    set ::aes_key_hex $saved
    if {$c eq "69c4e0d86a7b0430d8cdb78070b4c55a"} {
        puts "SELFTEST PASSED: FIPS-197 C.1 -> $c"
    } else {
        puts "SELFTEST FAILED: got $c, expected 69c4e0d86a7b0430d8cdb78070b4c55a"
    }
}

puts "AES demo loaded. Try:  aes_encrypt \"hello world\""
