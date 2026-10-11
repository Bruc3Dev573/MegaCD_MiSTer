#!/usr/bin/env bash
# Behavioral regressions against the release RTL. No board, BIOS or game is needed.
set -euo pipefail
export MSYS_NO_PATHCONV=1
absdir() { (cd "$1" && (pwd -W 2>/dev/null || pwd)); }
ROOT="$(absdir "$(dirname "$0")/..")"

run_case() {
    case "$1" in
        freeze)
            docker run --rm --entrypoint sh -v "$ROOT":/src:ro verilator/verilator:latest -c '
                set -e
                cd /tmp
                verilator --binary --timing -j 2 -Wno-fatal -DSIM_FAST \
                    --top-module tb_load_freeze -o smoke \
                    /src/rtl/savestate.sv /src/sim/tb_ss_load_freeze/tb_load_freeze.sv
                ./obj_dir/smoke
            '
            ;;
        cpu)
            docker run --rm --entrypoint sh -v "$ROOT":/src:ro verilator/verilator:latest -c '
                set -e
                cd /tmp
                cp /src/rtl/FX68K/*.mem .
                # The ALU selector is undefined during power-up. Explicit testbench checks remain enabled.
                verilator --binary --timing -j 2 -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --no-assert-case \
                    --top-module tb_fx68k_pending -o smoke \
                    /src/rtl/FX68K/fx68k.sv /src/rtl/FX68K/fx68kAlu.sv \
                    /src/rtl/FX68K/uaddrPla.sv /src/sim/tb_fx68k_pending/tb_fx68k_pending.sv
                ./obj_dir/smoke
            '
            ;;
        cdc|asic)
            docker run --rm --entrypoint sh -v "$ROOT":/src:ro \
                ghdl/ghdl:6.0.0-mcode-ubuntu-22.04 -c '
                set -e
                cd /tmp
                if [ "$1" = cdc ]; then
                    top=tb_cdc_stale_valid
                    ghdl -a --std=08 /src/rtl/MCD/CDC.vhd \
                        /src/sim/tb_cdc_stale_valid/tb_cdc_stale_valid.vhd
                else
                    top=tb_h1_dma_byte
                    ghdl -a --std=08 /src/rtl/MCD/ASIC_PKG.vhd \
                        /src/rtl/MCD/CDC.vhd /src/rtl/MCD/ASIC.vhd \
                        /src/sim/tb_h1_ghdl/tb_h1_dma_byte.vhd
                fi
                ghdl -e --std=08 "$top"
                ghdl -r --std=08 "$top" --assert-level=error
            ' smoke "$1"
            ;;
        *) echo "Usage: bash sim/run_smoke.sh [all|freeze|cpu|cdc|asic]" >&2; exit 2 ;;
    esac
}

if [ "${1:-all}" = all ]; then
    for scenario in freeze cpu cdc asic; do run_case "$scenario"; done
else
    run_case "$1"
fi
