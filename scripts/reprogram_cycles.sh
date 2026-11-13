#!/usr/bin/env bash
# fpga-coord request 0005 acceptance: N cycles of {program the rx_stats bitstream, wait for
# the MAC to leave reset (MDIO link up), stream datagrams, read the UART counters}.
# A cycle passes when the RX FIFO high-water mark never exceeded its depth (a broken Gray
# pointer reads up to 4095) and nothing was lost: udp_ok = sent, seq_err = seq_lost =
# ovf_lost = crc_err = rx_err = 0.
#   scripts/reprogram_cycles.sh OUT.csv [N] [BIT]
# Per-cycle UART stream, programmer output and sender output go to OUT.d/ (LOGDIR).
# fresh = the first report after programming showed uptime 0 (the new design is running;
# 0 means the previous design was still up: programming did not take). SETTLE = seconds
# to wait after the MAC is up before sending (default 0).
# Needs: vivado-env in ~/.bashrc, the board's FTDI attached (usbipd), the host on the cable
# at IF_IP (default 192.168.10.1), build/host/udp_seq_send (make host). Programs with
# openFPGALoader (SRAM, seconds; PROG=vivado uses Vivado batch + PROG_TCL, ~2 min per cycle).
# PROG=dtr programs once, then restarts the running design each cycle by pulsing the UART's
# DTR low (the Arty's ck_rst): core reset with the PHY held in reset, so rx_clk stops while
# the MAC resets (fpga-coord 0005).
set -euo pipefail
out=$1 n=${2:-100} bit=${3:-build/rx_stats/rx_stats_top.bit}
if_ip=${IF_IP:-192.168.10.1} tty=${TTY:-/dev/ttyUSB1}
prog=${PROG:-ofl} prog_tcl=${PROG_TCL:-$HOME/OrderBook/syn/prog.tcl}
ofl=${OFL:-$HOME/.local/opt/oss-cad-suite/bin/openFPGALoader}
pps=${PPS:-8000} count=${COUNT:-8000} depth=${DEPTH:-2048} settle=${SETTLE:-0}
logdir=${LOGDIR:-${out%.csv}.d}
mkdir -p "$logdir"
[ -f "$bit" ] || { echo "no bitstream $bit" >&2; exit 2; }
eval "$(sed -n '/^vivado-env()/,/^}/p' ~/.bashrc)"
set +euo pipefail  # vivado-env: unmatched-glob ls, unset LD_LIBRARY_PATH
vivado-env >/dev/null
set -euo pipefail
stty -F "$tty" 115200 raw -echo -hupcl
tmp=$(mktemp -d)
rd=""
trap '[ -n "$rd" ] && kill "$rd" 2>/dev/null; rm -rf "$tmp"' EXIT
echo "cycle,fresh,mac_up_s,sent,send_retries,achieved_pps,uptime_s,eth_ok,crc_err,rx_err,ovf_lost,udp_ok,seq_err,seq_lost,fifo_hwm,pass" > "$out"
fails=0
dtr_pulse() {  # DTR low 50 ms, then high again
  python3 -c 'import fcntl, struct, sys, termios, time
f = open(sys.argv[1], "rb", buffering=0)
b = struct.pack("I", termios.TIOCM_DTR)
fcntl.ioctl(f, termios.TIOCMBIC, b); time.sleep(0.05); fcntl.ioctl(f, termios.TIOCMBIS, b)' "$tty"
}
if [ "$prog" = dtr ]; then  # load the design once; each cycle restarts it
  "$ofl" -b arty_a7_100t "$bit" > "$tmp/prog0.txt" 2>&1 || { cat "$tmp/prog0.txt" >&2; exit 3; }
  sleep 5
fi
for c in $(seq 1 "$n"); do
  if [ "$prog" = dtr ]; then
    dtr_pulse > "$tmp/prog.txt" 2>&1
  elif [ "$prog" = vivado ]; then
    vivado -mode batch -nojournal -nolog -source "$prog_tcl" -tclargs "$bit" > "$tmp/prog.txt" 2>&1
  else
    "$ofl" -b arty_a7_100t "$bit" > "$tmp/prog.txt" 2>&1
  fi || { echo "cycle $c: programming failed" >&2; cat "$tmp/prog.txt" >&2; exit 3; }
  cp "$tmp/prog.txt" "$logdir/$c.prog.txt"
  t0=$(date +%s.%N)
  : > "$tmp/uart.txt"
  cat "$tty" > "$tmp/uart.txt" & rd=$!
  mac_up="" fresh=""
  for _ in $(seq 300); do
    if [ -z "$fresh" ]; then
      first=$({ grep -a '^RX ' "$tmp/uart.txt" || true; } | head -1 | gawk '{print strtonum("0x"$2)}')
      [ -n "$first" ] && { [ "$first" -eq 0 ] && fresh=1 || fresh=0; }
    fi  # up to 30 s for link + MAC start
    up=$({ grep -a '^RX ' "$tmp/uart.txt" || true; } | tail -1 | gawk '{print strtonum("0x"$2)}')
    if [ -n "$up" ] && [ "$up" -ge 1 ]; then mac_up=$(echo "$(date +%s.%N) - $t0" | bc); break; fi
    sleep 0.1
  done
  if [ -z "$mac_up" ]; then
    kill $rd; rd=""; cp "$tmp/uart.txt" "$logdir/$c.uart.txt"; echo "$c,$fresh,,,,,,,,,,,,,,0" >> "$out"; fails=$((fails + 1))
    echo "cycle $c: MAC never left reset" >&2; continue
  fi
  sleep "$settle"
  build/host/udp_seq_send --dst 239.1.1.1 --port 26400 --if-ip "$if_ip" --size 1472 \
    --pps "$pps" --count "$count" > "$logdir/$c.send.txt" 2>/dev/null
  kv() { awk -F= -v k="$1" '$1==k{print $2}' "$logdir/$c.send.txt"; }
  sent=$(kv sent)
  sleep 2.5  # at least two report lines after the last datagram
  kill $rd; rd=""; cp "$tmp/uart.txt" "$logdir/$c.uart.txt"
  read -r -a f <<< "$({ grep -a '^RX ' "$tmp/uart.txt" || true; } | tail -1 | tr -d '\r')"
  v() { echo $((16#${f[$1 + 1]})); }
  hwm=$(v 14)
  ok=1
  [ "$fresh" = 1 ] && [ "$hwm" -le "$depth" ] && [ "$(v 7)" -eq "$sent" ] && [ "$(v 12)" -eq 0 ] && [ "$(v 13)" -eq 0 ] \
    && [ "$(v 6)" -eq 0 ] && [ "$(v 2)" -eq 0 ] && [ "$(v 3)" -eq 0 ] || ok=0
  [ $ok -eq 1 ] || fails=$((fails + 1))
  echo "$c,$fresh,$mac_up,$sent,$(kv send_retries),$(kv achieved_pps),$(v 0),$(v 1),$(v 2),$(v 3),$(v 6),$(v 7),$(v 12),$(v 13),$hwm,$ok" >> "$out"
  echo "cycle $c: fresh $fresh mac_up ${mac_up}s udp_ok $(v 7)/$sent hwm $hwm pass $ok"
done
echo "cycles=$n failed=$fails"
[ $fails -eq 0 ]
