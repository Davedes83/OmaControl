#!/bin/sh
# GPU parsing tests. collect.sh's nvidia-smi probe is pointed at a stub via
# OMC_NVIDIA_SMI so the harness never touches a real driver, and the collector
# still runs end-to-end against a throwaway data directory. Covers:
#   * valid CSV + XML dump -> every GPU field parsed into JSON + metrics
#   * empty/failed nvidia-smi -> clean fallback to zeros (no garbage)
#   * absent nvidia-smi binary -> probe skipped, zeros
#
# Run via tests/run-tests.sh, or directly: ./tests/gpu-tests.sh

set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$DIR/.." && pwd)
. "$DIR/lib.sh"

T=$(mktemp -d "${TMPDIR:-/tmp}/omc-gpu.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM

run_collect() {
  # usage: run_collect STUB LABEL
  STUB="$1"
  LABEL="$2"
  D="$T/$LABEL"
  mkdir -p "$D"
  if [ -n "$STUB" ]; then
    OMC_NVIDIA_SMI="$STUB"
  else
    OMC_NVIDIA_SMI="$T/no-such-nvidia-smi"
  fi
  export OMCONTROL_DATA_DIR="$D" OMCONTROL_DB="$D/history.db" OMC_NVIDIA_SMI
  run_interp "$ROOT/backend/collect.sh" >"$D/out.json" 2>"$D/out.err"
  rc=$?
  check_eq "gpu ($LABEL): collect exits 0" "0" "$rc"
  if [ "$rc" -ne 0 ]; then
    sed 's/^/  # /' "$D/out.err"
  fi
}

q() { sqlite3 -cmd ".timeout 1500" "$1" "$2" 2>/dev/null; }

# --- stub factory: nvidia-smi with injectable CSV + XML ---------------------
make_stub() {
  # usage: make_stub NAME CSV_BODY XML_BODY
  BIN="$T/bin-$1"
  cat >"$BIN" <<STUB
#!/bin/sh
case "\$1" in
  --query-gpu*)
    printf '%b' '$2'
    ;;
  -q*)
    printf '%b' '$3'
    ;;
  *) exit 99 ;;
esac
STUB
  chmod +x "$BIN"
  echo "$BIN"
}

CSV_VALID=' 95, 2048, 8192, 68, 45.3, 60, 1500, 2, 1
'
XML_VALID='<nvidia_smi_log>
  <driver_version>535.154.05</driver_version>
  <gpu id="00000000:01:00.0">
    <product_name>NVIDIA GeForce GTX 1650</product_name>
    <pci_bus_id>00000000:01:00.0</pci_bus_id>
    <max_power_limit>75.00</max_power_limit>
    <link_info>
      <pcie_gen><current_link_gen>3</current_link_gen><max_link_gen>3</max_link_gen></pcie_gen>
      <link_widths><current_link_width>8x</current_link_width><max_link_width>16x</max_link_width></link_widths>
    </link_info>
    <clocks>
      <graphics_clock>1500</graphics_clock>
      <mem_clock>3503</mem_clock>
    </clocks>
    <max_clocks>
      <graphics_clock>1875</graphics_clock>
      <mem_clock>3504</mem_clock>
    </max_clocks>
    <min_clocks>
      <graphics_clock>300</graphics_clock>
      <mem_clock>405</mem_clock>
    </min_clocks>
  </gpu>
</nvidia_smi_log>
'
CSV_EMPTY=''

STUB_VALID=$(make_stub valid "$CSV_VALID" "$XML_VALID")
STUB_EMPTY=$(make_stub empty "$CSV_EMPTY" "")

# --- scenario 1: valid CSV + XML --------------------------------------------
run_collect "$STUB_VALID" valid
python3 - "$T/valid/out.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
exp = {"gpu_pct": 95.0, "gpu_mem_mb": 2048.0, "gpu_mem_total_mb": 8192.0,
       "gpu_temp": 68.0, "gpu_power_w": 45.3, "gpu_fan_pct": 60.0,
       "gpu_clock_mhz": 1500.0, "gpu_enc_pct": 2.0, "gpu_dec_pct": 1.0}
for k, v in exp.items():
    assert d[k] == v, "%s: got %r" % (k, d[k])
assert d["gpu_name"] == "NVIDIA GeForce GTX 1650", d["gpu_name"]
assert d["gpu_driver"] == "535.154.05", d["gpu_driver"]
assert d["gpu_power_max_w"] == 75.0, d["gpu_power_max_w"]
assert d["gpu_link_gen"] == "3" and d["gpu_link_gen_max"] == "3", d
assert d["gpu_link_width"] == "8" and d["gpu_link_width_max"] == "16", d
assert d["gpu_mem_clock_mhz"] == 3503, d["gpu_mem_clock_mhz"]
assert d["gpu_mem_clock_max_mhz"] == 3504, d["gpu_mem_clock_max_mhz"]
assert d["gpu_graphics_max_mhz"] == 1875, d["gpu_graphics_max_mhz"]
PY
check_eq "gpu (valid): all fields parsed from CSV + XML" "0" "$?"
check_eq "gpu (valid): gpu_pct persisted into metrics" "95.0" "$(q "$T/valid/history.db" "SELECT gpu_pct FROM metrics;")"
check_eq "gpu (valid): gpu_temp persisted into metrics" "68" "$(q "$T/valid/history.db" "SELECT gpu_temp FROM metrics;")"

# --- scenario 2: nvidia-smi present but silent/empty -------------------------
run_collect "$STUB_EMPTY" empty
python3 - "$T/empty/out.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["gpu_pct"] == 0.0, d["gpu_pct"]
assert d["gpu_mem_mb"] == 0.0, d["gpu_mem_mb"]
assert d["gpu_temp"] == 0.0, d["gpu_temp"]
assert d["gpu_name"] == "" or d["gpu_name"] == "AMD GPU", d["gpu_name"]
PY
check_eq "gpu (empty): probe output falls back to zeros" "0" "$?"

# --- scenario 3: nvidia-smi binary absent -------------------------------------
run_collect "" missing
python3 - "$T/missing/out.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["gpu_pct"] == 0.0, d["gpu_pct"]
assert d["gpu_mem_mb"] == 0.0, d["gpu_mem_mb"]
assert d["gpu_mem_total_mb"] == 0.0, d["gpu_mem_total_mb"]
PY
check_eq "gpu (missing): absent binary is skipped cleanly" "0" "$?"

finish
