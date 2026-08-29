#!/bin/bash
set -e

SERVICE1="hw-monitor"
SERVICE2="tty-banner"
INSTALL_DIR="/opt/hw-monitor"
PORT=8889
PYTHON_BIN=$(command -v python3 || true)

echo "============================================"
echo "  Hardware Monitor + TTY Kiosk - Install"
echo "  Dir: ${INSTALL_DIR}"
echo "  Port: ${PORT}"
echo "============================================"

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Run as root (sudo)"
  exit 1
fi

for REQUIRED_CMD in python3 lspci dmidecode ip lsof systemctl; do
  if ! command -v "$REQUIRED_CMD" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: ${REQUIRED_CMD}"
    exit 1
  fi
done

echo "[*] Stop existing services..."
SERVICE_WAS_ACTIVE=0
GETTY_WAS_ACTIVE=0
systemctl is-active --quiet ${SERVICE1} && SERVICE_WAS_ACTIVE=1 || true
systemctl is-active --quiet getty@tty1 && GETTY_WAS_ACTIVE=1 || true
systemctl stop ${SERVICE1} 2>/dev/null || true
systemctl stop ${SERVICE2} 2>/dev/null || true
systemctl disable ${SERVICE2} 2>/dev/null || true

echo "[*] Check port ${PORT}..."
PID=$(lsof -ti:${PORT} 2>/dev/null || true)
if [ -n "$PID" ]; then
  echo "[ERROR] Port ${PORT} is still owned by an unknown process:"
  ps -fp $PID 2>/dev/null || true
  echo "[ERROR] Refusing to terminate an unrelated process."
  [ "$SERVICE_WAS_ACTIVE" = "1" ] && systemctl start ${SERVICE1} 2>/dev/null || true
  exit 1
fi

echo "[*] Create install dir..."
mkdir -p ${INSTALL_DIR}
STAGE_DIR=$(mktemp -d "${INSTALL_DIR}/.install-stage.XXXXXX")
ROLLBACK_DIR=$(mktemp -d "/tmp/hw-monitor-rollback.XXXXXX")
DEPLOYED=0
for APP_FILE in server.py tty-banner.sh gpu_health.py gpu-health.py; do
  [ -e "${INSTALL_DIR}/${APP_FILE}" ] && cp -a "${INSTALL_DIR}/${APP_FILE}" "${ROLLBACK_DIR}/${APP_FILE}"
done

cleanup_install() {
  RESULT=$?
  if [ "$RESULT" -ne 0 ]; then
    echo "[ERROR] Installation failed; restoring the previous monitor files."
    if [ "$DEPLOYED" = "1" ]; then
      for APP_FILE in server.py tty-banner.sh gpu_health.py gpu-health.py; do
        if [ -e "${ROLLBACK_DIR}/${APP_FILE}" ]; then
          rm -f "${INSTALL_DIR}/${APP_FILE}"
          cp -a "${ROLLBACK_DIR}/${APP_FILE}" "${INSTALL_DIR}/${APP_FILE}"
        else
          rm -f "${INSTALL_DIR}/${APP_FILE}"
        fi
      done
      systemctl daemon-reload 2>/dev/null || true
    fi
    [ "$SERVICE_WAS_ACTIVE" = "1" ] && systemctl start ${SERVICE1} 2>/dev/null || true
    [ "$GETTY_WAS_ACTIVE" = "1" ] && systemctl restart getty@tty1 2>/dev/null || true
  fi
  rm -rf -- "$STAGE_DIR" "$ROLLBACK_DIR"
  exit "$RESULT"
}
trap cleanup_install EXIT

echo "[*] Deploy GPU health module..."
cat > ${STAGE_DIR}/gpu_health.py << 'GPU_HEALTH_EOF'
#!/usr/bin/env python3
"""Shared NVIDIA GPU inventory, slot mapping, baseline, and health checks."""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


INSTALL_DIR = Path(__file__).resolve().parent
DEFAULT_BASELINE = INSTALL_DIR / "gpu-baseline.json"
GPU_CLASS_RE = re.compile(
    r"NVIDIA.*(?:VGA compatible controller|3D controller|Display controller)|"
    r"(?:VGA compatible controller|3D controller|Display controller).*NVIDIA",
    re.IGNORECASE,
)
BDF_RE = re.compile(r"[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]")
SPEED_TO_GEN = {
    "2.5": "Gen1.0",
    "5": "Gen2.0",
    "5.0": "Gen2.0",
    "8": "Gen3.0",
    "8.0": "Gen3.0",
    "16": "Gen4.0",
    "16.0": "Gen4.0",
    "32": "Gen5.0",
    "32.0": "Gen5.0",
    "64": "Gen6.0",
    "64.0": "Gen6.0",
}
ISSUE_MESSAGES = {
    "BASELINE_MISSING": "GPU baseline is missing",
    "BASELINE_INVALID": "GPU baseline is invalid",
    "DRIVER_UNAVAILABLE": "NVIDIA driver is unavailable",
    "DRIVER_MISSING": "GPU is visible on PCIe but missing from the driver",
    "PCI_MISSING": "GPU from the baseline is missing from the PCIe bus",
    "TOPOLOGY_CHANGED": "GPU is not present in the saved baseline",
}
ISSUE_MESSAGES_ZH = {
    "BASELINE_MISSING": "尚未建立显卡物理基线",
    "BASELINE_INVALID": "显卡物理基线文件损坏",
    "DRIVER_UNAVAILABLE": "NVIDIA 驱动不可用",
    "DRIVER_MISSING": "PCIe 可见，但驱动未识别该显卡",
    "PCI_MISSING": "基线中的显卡已从 PCIe 总线消失",
    "TOPOLOGY_CHANGED": "检测到基线之外的显卡，请确认后刷新基线",
}


def run_command(args, timeout=8):
    try:
        proc = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
            env={**os.environ, "LC_ALL": "C", "LANG": "C"},
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, "", str(exc)


def normalize_bus_id(value):
    value = str(value or "").strip().lower()
    match = re.search(r"(?:[0-9a-f]{4,8}:)?([0-9a-f]{2}:[0-9a-f]{2}\.[0-7])$", value)
    if not match:
        return value
    domain = value[: value.rfind(match.group(1))].rstrip(":")
    if not domain:
        domain = "0000"
    else:
        domain = domain[-4:].zfill(4)
    return f"{domain}:{match.group(1)}"


def normalize_slot_name(value):
    slot = re.sub(r"\s+", " ", str(value or "")).strip()
    slot = re.sub(
        r"\s+PCI(?:[\s-]*E)?\s*(?:GEN\s*)?[1-6](?:\.0)?\s*X\s*\d+\s*$",
        "",
        slot,
        flags=re.IGNORECASE,
    ).strip()
    return slot


def short_bus_id(value):
    normalized = normalize_bus_id(value)
    return normalized[5:] if re.fullmatch(r"[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]", normalized) else normalized


def clean_model(description):
    model = re.sub(r"^[^:]+:\s*", "", description.strip())
    model = re.sub(r"^NVIDIA Corporation\s+", "", model, flags=re.IGNORECASE)
    model = re.sub(r"\s+\(rev\s+[^)]+\)\s*$", "", model, flags=re.IGNORECASE)
    return model.strip() or "Unknown NVIDIA GPU"


def parse_lspci(text):
    gpus = []
    for line in text.splitlines():
        line = line.strip()
        if not line or not GPU_CLASS_RE.search(line):
            continue
        match = re.match(r"(\S+)\s+(.+)$", line)
        if not match:
            continue
        bus_id = normalize_bus_id(match.group(1))
        if not re.fullmatch(r"[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]", bus_id):
            continue
        gpus.append({"bus_id": bus_id, "model": clean_model(match.group(2))})
    return sorted(gpus, key=lambda item: item["bus_id"])


def parse_dmi_slots(text):
    slot_map = {}
    designation = ""
    in_slot = False
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line == "System Slot Information":
            in_slot = True
            designation = ""
            continue
        if not in_slot:
            continue
        if line.startswith("Designation:"):
            designation = normalize_slot_name(line.split(":", 1)[1])
        elif line.startswith("Bus Address:"):
            bus_id = normalize_bus_id(line.split(":", 1)[1].strip())
            if designation and bus_id:
                slot_map[bus_id] = designation
            in_slot = False
    return slot_map


def resolve_slot(bus_id, slot_map, sysfs_path=None):
    bus_id = normalize_bus_id(bus_id)
    if sysfs_path is None:
        sysfs_path = os.path.realpath(f"/sys/bus/pci/devices/{bus_id}")
    chain = [normalize_bus_id(item) for item in BDF_RE.findall(sysfs_path or "")]
    if bus_id not in chain:
        chain.append(bus_id)
    for address in reversed(chain):
        if address in slot_map:
            return slot_map[address]
        base = address.rsplit(".", 1)[0] + "."
        for mapped, designation in slot_map.items():
            if mapped.startswith(base):
                return designation
    return "UNMATCHED"


def speed_to_gen(value):
    match = re.search(r"([0-9.]+)", str(value or ""))
    return SPEED_TO_GEN.get(match.group(1), "N/A") if match else "N/A"


def read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""


def get_link_info(bus_id):
    root = Path("/sys/bus/pci/devices") / normalize_bus_id(bus_id)
    max_speed = speed_to_gen(read_text(root / "max_link_speed"))
    max_width_raw = read_text(root / "max_link_width")
    current_speed = speed_to_gen(read_text(root / "current_link_speed"))
    current_width_raw = read_text(root / "current_link_width")

    def display(speed, width):
        if speed == "N/A" or not width or width in {"0", "63", "255"}:
            return "BAD"
        return f"{speed}x{width}"

    return {
        "max_link": display(max_speed, max_width_raw),
        "current_link": display(current_speed, current_width_raw),
    }


def collect_physical_gpus():
    _, lspci_out, _ = run_command(["lspci", "-D"], timeout=8)
    _, dmi_out, _ = run_command(["dmidecode", "-t", "slot"], timeout=12)
    slot_map = parse_dmi_slots(dmi_out)
    physical = parse_lspci(lspci_out)
    for gpu in physical:
        gpu["slot"] = resolve_slot(gpu["bus_id"], slot_map)
        gpu.update(get_link_info(gpu["bus_id"]))
    return physical


def collect_driver_gpus():
    query = (
        "index,name,pci.bus_id,power.draw,temperature.gpu"
    )
    rc, output, error = run_command(
        ["nvidia-smi", f"--query-gpu={query}", "--format=csv,noheader,nounits"],
        timeout=10,
    )
    if rc != 0:
        return False, [], error or output or "nvidia-smi failed"
    gpus = []
    for line in output.splitlines():
        parts = [part.strip() for part in line.split(",")]
        if len(parts) < 5:
            continue
        try:
            index = int(parts[0])
        except ValueError:
            index = len(gpus)
        gpus.append(
            {
                "index": index,
                "name": parts[1] or "Unknown NVIDIA GPU",
                "bus_id": normalize_bus_id(parts[2]),
                "power": parts[3] if parts[3] not in {"[N/A]", "N/A"} else "N/A",
                "temp": parts[4] if parts[4] not in {"[N/A]", "N/A"} else "N/A",
            }
        )
    return True, sorted(gpus, key=lambda item: item["index"]), ""


def baseline_payload(physical):
    return {
        "version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "gpus": [
            {
                "model": gpu.get("model", "Unknown NVIDIA GPU"),
                "bus_id": normalize_bus_id(gpu.get("bus_id")),
                "slot": normalize_slot_name(gpu.get("slot")) or "UNMATCHED",
            }
            for gpu in physical
        ],
    }


def save_baseline(path, physical):
    if not physical:
        raise RuntimeError("No physical NVIDIA GPU was found; baseline was not changed")
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = baseline_payload(physical)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)
    return payload


def load_baseline(path):
    path = Path(path)
    if not path.exists():
        return None, "BASELINE_MISSING"
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if payload.get("version") != 1 or not isinstance(payload.get("gpus"), list):
            raise ValueError("unsupported baseline")
        normalized = []
        for gpu in payload["gpus"]:
            if not isinstance(gpu, dict) or not gpu.get("bus_id"):
                raise ValueError("invalid GPU entry")
            normalized.append(
                {
                    "model": str(gpu.get("model") or "Unknown NVIDIA GPU"),
                    "bus_id": normalize_bus_id(gpu["bus_id"]),
                    "slot": normalize_slot_name(gpu.get("slot")) or "UNMATCHED",
                }
            )
        payload["gpus"] = normalized
        return payload, ""
    except (OSError, ValueError, json.JSONDecodeError):
        return None, "BASELINE_INVALID"


def make_issue(code, gpu=None):
    gpu = gpu or {}
    return {
        "code": code,
        "model": gpu.get("model") or gpu.get("name") or "NVIDIA GPU",
        "bus_id": normalize_bus_id(gpu.get("bus_id")) if gpu.get("bus_id") else "-",
        "slot": normalize_slot_name(gpu.get("slot")) or "-",
        "message": ISSUE_MESSAGES_ZH[code],
        "message_ascii": ISSUE_MESSAGES[code],
    }


def evaluate_health(baseline, baseline_error, physical, driver_available, driver):
    expected = baseline.get("gpus", []) if baseline else []
    physical_map = {normalize_bus_id(gpu["bus_id"]): gpu for gpu in physical}
    driver_map = {normalize_bus_id(gpu["bus_id"]): gpu for gpu in driver}
    issues = []

    if baseline_error:
        issues.append(make_issue(baseline_error))
    if not driver_available:
        issues.append(make_issue("DRIVER_UNAVAILABLE"))

    for gpu in expected:
        bus_id = normalize_bus_id(gpu["bus_id"])
        current = physical_map.get(bus_id)
        if current is None:
            issues.append(make_issue("PCI_MISSING", gpu))
        elif driver_available and bus_id not in driver_map:
            merged = dict(gpu)
            merged.update(current)
            issues.append(make_issue("DRIVER_MISSING", merged))

    expected_buses = {normalize_bus_id(gpu["bus_id"]) for gpu in expected}
    if baseline:
        for bus_id, gpu in physical_map.items():
            if bus_id not in expected_buses:
                issues.append(make_issue("TOPOLOGY_CHANGED", gpu))

    if not driver_available and expected:
        missing_count = len(expected)
    else:
        missing_count = sum(
            item["code"] in {"DRIVER_MISSING", "PCI_MISSING"}
            for item in issues
        )

    return {
        "status": "pass" if not issues else "fail",
        "expected_count": len(expected),
        "pci_count": len(physical),
        "driver_count": len(driver) if driver_available else 0,
        "missing_count": missing_count,
        "driver_available": driver_available,
        "issues": issues,
        "physical_gpus": physical,
        "driver_gpus": driver,
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }


def collect_health(baseline_path=DEFAULT_BASELINE):
    baseline, baseline_error = load_baseline(baseline_path)
    physical = collect_physical_gpus()
    driver_available, driver, _ = collect_driver_gpus()
    return evaluate_health(
        baseline,
        baseline_error,
        physical,
        driver_available,
        driver,
    )


def ensure_baseline(path):
    baseline, error = load_baseline(path)
    if baseline and not error:
        print(f"[OK] GPU baseline preserved: {len(baseline['gpus'])} GPU(s)")
        return 0
    if error == "BASELINE_INVALID":
        print("[WARN] Invalid GPU baseline was preserved; refresh it manually after inspection", file=sys.stderr)
        return 0
    physical = collect_physical_gpus()
    if not physical:
        print("[WARN] No physical NVIDIA GPU found; baseline was not created", file=sys.stderr)
        return 0
    save_baseline(path, physical)
    print(f"[OK] GPU baseline created: {len(physical)} GPU(s)")
    return 0


def format_tty(health):
    physical_map = {gpu["bus_id"]: gpu for gpu in health["physical_gpus"]}
    lines = [
        "  --------------------------------------------",
        "  GPU",
        "  --------------------------------------------",
        "  " + f"{'ID':<5}{'MODEL':<27}{'BUS':<14}{'SLOT':<16}{'CURRENT':<12}{'POWER':<10}{'TEMP':<7}",
    ]
    for driver in health["driver_gpus"]:
        physical = physical_map.get(driver["bus_id"], {})
        slot = physical.get("slot", "UNMATCHED")
        current_link = physical.get("current_link", "N/A")
        power = f"{driver['power']} W" if driver["power"] != "N/A" else "N/A"
        temp = f"{driver['temp']} C" if driver["temp"] != "N/A" else "N/A"
        lines.append(
            "  "
            + f"{driver['index']:<5}{driver['name'][:25]:<27}{driver['bus_id']:<14}"
            + f"{slot[:14]:<16}{current_link:<12}{power:<10}{temp:<7}"
        )

    summary = (
        f"  GPU HEALTH: {health['status'].upper()}  "
        f"EXPECTED={health['expected_count']}  PCI={health['pci_count']}  "
        f"DRIVER={health['driver_count']}"
    )
    if health["issues"]:
        lines.extend([
            "",
            "  " + f"{'STATUS':<8}{'MODEL':<31}{'BUS':<14}{'SLOT':<16}{'REASON'}",
        ])
        for issue in health["issues"]:
            lines.append(
                "  "
                + f"{'FAIL':<8}{issue['model'][:29]:<31}{issue['bus_id']:<14}"
                + f"{issue['slot'][:14]:<16}{issue['code']}"
            )
    else:
        lines.extend(["", summary])
    return "\n".join(lines)


def self_test():
    assert normalize_bus_id("00000000:04:00.0") == "0000:04:00.0"
    assert normalize_bus_id("04:00.0") == "0000:04:00.0"
    assert normalize_slot_name("CPU SLOT6 PCI-E 4.0 X16") == "CPU SLOT6"
    assert normalize_slot_name("CPU SLOT7 PCIe 5.0 x 16") == "CPU SLOT7"
    assert normalize_slot_name("CPU1 SLOT8") == "CPU1 SLOT8"
    sample_lspci = """
0000:04:00.0 VGA compatible controller: NVIDIA Corporation GA102 [GeForce RTX 3090] (rev ff)
0000:05:00.0 VGA compatible controller: NVIDIA Corporation GA102 [GeForce RTX 3090] (rev a1)
0000:06:00.0 Ethernet controller: Intel Corporation Device
"""
    physical = parse_lspci(sample_lspci)
    assert len(physical) == 2
    assert physical[0]["model"] == "GA102 [GeForce RTX 3090]"
    sample_dmi = """
System Slot Information
        Designation: CPU2 SLOT5
        Bus Address: 0000:02:00.0
System Slot Information
        Designation: CPU1 SLOT8
        Bus Address: 0000:04:00.0
System Slot Information
        Designation: CPU1 SLOT9 PCI-E 4.0 X16
        Bus Address: 0000:05:00.0
"""
    slot_map = parse_dmi_slots(sample_dmi)
    path0 = "/sys/devices/pci0000:00/0000:00:02.0/0000:02:00.0/0000:03:08.0/0000:04:00.0"
    path1 = "/sys/devices/pci0000:00/0000:00:02.0/0000:02:00.0/0000:03:10.0/0000:05:00.0"
    assert resolve_slot("0000:04:00.0", slot_map, path0) == "CPU1 SLOT8"
    assert resolve_slot("0000:05:00.0", slot_map, path1) == "CPU1 SLOT9"

    expected = baseline_payload(
        [
            {"model": "RTX 3090", "bus_id": "0000:04:00.0", "slot": "CPU1 SLOT8"},
            {"model": "RTX 3090", "bus_id": "0000:05:00.0", "slot": "CPU1 SLOT9"},
        ]
    )
    current = [dict(item, max_link="Gen4.0x16", current_link="Gen1.0x16") for item in expected["gpus"]]
    driver = [{"bus_id": "0000:05:00.0", "index": 1, "name": "RTX 3090", "power": "20", "temp": "35"}]
    health = evaluate_health(expected, "", current, True, driver)
    assert health["status"] == "fail"
    assert health["missing_count"] == 1
    assert health["issues"][0]["code"] == "DRIVER_MISSING"
    assert health["issues"][0]["slot"] == "CPU1 SLOT8"
    failed_tty = format_tty(health)
    assert "GPU HEALTH:" not in failed_tty
    assert "CPU1 SLOT8" in failed_tty and "DRIVER_MISSING" in failed_tty
    assert "MAX" not in failed_tty and "CURRENT" in failed_tty

    pci_missing = evaluate_health(expected, "", current[1:], True, driver)
    assert pci_missing["issues"][0]["code"] == "PCI_MISSING"
    pci_all_missing = evaluate_health(expected, "", [], True, [])
    assert [item["code"] for item in pci_all_missing["issues"]] == ["PCI_MISSING", "PCI_MISSING"]
    assert pci_all_missing["missing_count"] == 2
    all_driver = [
        {"bus_id": item["bus_id"], "index": i, "name": item["model"], "power": "20", "temp": "35"}
        for i, item in enumerate(expected["gpus"])
    ]
    passing = evaluate_health(expected, "", current, True, all_driver)
    assert passing["status"] == "pass"
    assert not passing["issues"]
    assert "GPU HEALTH: PASS" in format_tty(passing)
    unavailable = evaluate_health(expected, "", current, False, [])
    assert any(item["code"] == "DRIVER_UNAVAILABLE" for item in unavailable["issues"])
    assert unavailable["missing_count"] == 2
    extra = {"model": "RTX 4090", "bus_id": "0000:06:00.0", "slot": "CPU1 SLOT10"}
    topology = evaluate_health(expected, "", current + [extra], True, all_driver + [extra])
    assert [item["code"] for item in topology["issues"]] == ["TOPOLOGY_CHANGED"]
    assert topology["missing_count"] == 0
    no_baseline = evaluate_health(None, "BASELINE_MISSING", current, True, all_driver)
    assert [item["code"] for item in no_baseline["issues"]] == ["BASELINE_MISSING"]
    assert no_baseline["expected_count"] == 0
    print("gpu-health self-test: PASS")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default=str(DEFAULT_BASELINE))
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--json", action="store_true", help="print health JSON")
    group.add_argument("--tty", action="store_true", help="print ASCII TTY block")
    group.add_argument("--ensure-baseline", action="store_true")
    group.add_argument("--refresh-baseline", action="store_true")
    group.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    baseline_path = Path(args.baseline)

    if args.self_test:
        return self_test()
    if args.ensure_baseline:
        return ensure_baseline(baseline_path)
    if args.refresh_baseline:
        physical = collect_physical_gpus()
        try:
            save_baseline(baseline_path, physical)
        except RuntimeError as exc:
            print(f"[ERROR] {exc}", file=sys.stderr)
            return 2
        print(json.dumps(baseline_payload(physical), ensure_ascii=False, indent=2))
        return 0

    health = collect_health(baseline_path)
    if args.tty:
        print(format_tty(health))
    else:
        print(json.dumps(health, ensure_ascii=False, indent=2))
    return 0 if health["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
GPU_HEALTH_EOF
chmod 0755 ${STAGE_DIR}/gpu_health.py

echo "[*] Deploy web monitor..."
cat > ${STAGE_DIR}/server.py << 'SERVER_EOF'
#!/usr/bin/env python3
"""Hardware Monitor - Enterprise Edition"""

import http.server
import json
import subprocess
import re
import os
import time
import socket
import threading
import signal
import uuid
import ipaddress
import sys
from datetime import datetime, timedelta, timezone

from gpu_health import collect_health, normalize_bus_id

PORT = 8889
DISCOVERY_PORT = 8890
DISCOVERY_INTERVAL = 5
PEER_TIMEOUT = 20
DISCOVERY_PROTOCOL = "hw-monitor-discovery"
DISCOVERY_VERSION = 1
NODE_ID_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "node-id")
BEIJING_TZ = timezone(timedelta(hours=8), name="Asia/Shanghai")

# Track burn test processes: {gpu_index: {"proc": Popen, "start": timestamp}}
burn_processes = {}
burn_lock = threading.Lock()

# LAN discovery state: {node_id: node_info}
discovered_nodes = {}
discovery_lock = threading.Lock()
node_id_lock = threading.Lock()
local_node_id = None

def run_cmd(cmd, timeout=5):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except subprocess.TimeoutExpired:
        return ""
    except:
        return ""

def has_nvidia():
    """Check if nvidia-smi exists and is responsive"""
    try:
        r = subprocess.run("nvidia-smi --query-gpu=count --format=csv,noheader",
                           shell=True, capture_output=True, text=True, timeout=8)
        return r.returncode == 0 and len(r.stdout.strip()) > 0
    except:
        return False

def get_uptime():
    try:
        with open('/proc/uptime', 'r') as f:
            secs = float(f.read().split()[0])
        d = int(secs // 86400)
        h = int((secs % 86400) // 3600)
        m = int((secs % 3600) // 60)
        return f"{d}天 {h}时 {m}分"
    except:
        return "N/A"

def get_cpu_info():
    info = {"model": "N/A", "cores": 0, "threads": 0, "usage": 0.0, "freq": "N/A"}
    try:
        with open('/proc/cpuinfo', 'r') as f:
            cpuinfo = f.read()
        models = re.findall(r'model name\s*:\s*(.*)', cpuinfo)
        if models:
            info["model"] = models[0].strip()
        info["threads"] = len(models)
        cores = re.findall(r'cpu cores\s*:\s*(\d+)', cpuinfo)
        if cores:
            info["cores"] = int(cores[0])
        freqs = re.findall(r'cpu MHz\s*:\s*([\d.]+)', cpuinfo)
        if freqs:
            avg = sum(float(f) for f in freqs) / len(freqs)
            info["freq"] = f"{avg:.0f} MHz"
    except:
        pass
    return info

def get_memory_info():
    info = {"total": 0, "used": 0, "available": 0, "percent": 0, "swap_total": 0, "swap_used": 0}
    try:
        with open('/proc/meminfo', 'r') as f:
            meminfo = f.read()
        def extract(key):
            m = re.search(rf'{key}:\s+(\d+)', meminfo)
            return int(m.group(1)) * 1024 if m else 0
        info["total"] = extract("MemTotal")
        info["available"] = extract("MemAvailable")
        info["used"] = info["total"] - info["available"]
        info["percent"] = round(info["used"] / info["total"] * 100, 1) if info["total"] > 0 else 0
        info["swap_total"] = extract("SwapTotal")
        swap_free = extract("SwapFree")
        info["swap_used"] = info["swap_total"] - swap_free
    except:
        pass
    return info

def fmt_bytes(b):
    for u in ['B', 'KB', 'MB', 'GB', 'TB']:
        if b < 1024:
            return f"{b:.1f} {u}"
        b /= 1024
    return f"{b:.1f} PB"

def get_disk_info():
    disks = []
    try:
        out = run_cmd("df -B1 -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null")
        for line in out.split('\n')[1:]:
            parts = line.split()
            if len(parts) >= 6 and parts[0].startswith('/dev/') and not parts[0].startswith('/dev/loop'):
                total = int(parts[1])
                used = int(parts[2])
                mount = parts[5]
                pct = round(used / total * 100, 1) if total > 0 else 0
                disks.append({"device": parts[0], "mount": mount, "total": total, "used": used, "percent": pct})
    except:
        pass
    return disks

def get_pcie_info(bus_id):
    info = {"cap_speed": "N/A", "cap_width": "N/A", "sta_speed": "N/A", "sta_width": "N/A", "gen": "N/A", "bandwidth": "N/A"}
    try:
        out = run_cmd(f"lspci -vvv -s {bus_id} 2>/dev/null")
        cap = re.search(r'LnkCap:.*?Speed\s+([\d.]+GT/s).*?Width\s+(x\d+)', out)
        sta = re.search(r'LnkSta:.*?Speed\s+([\d.]+GT/s).*?Width\s+(x\d+)', out)
        speed_map = {"2.5GT/s": "1.0", "5GT/s": "2.0", "8GT/s": "3.0", "16GT/s": "4.0", "32GT/s": "5.0", "64GT/s": "6.0"}
        
        if cap:
            info["cap_speed"] = cap.group(1)
            info["cap_width"] = cap.group(2)
            gen = speed_map.get(cap.group(1), "?")
            info["gen"] = gen
            info["cap_gen_display"] = f"Gen{gen} {cap.group(2)}"
        else:
            info["cap_gen_display"] = "N/A"
            
        if sta:
            info["sta_speed"] = sta.group(1)
            info["sta_width"] = sta.group(2)
            sta_gen = speed_map.get(sta.group(1), "?")
            info["sta_gen_display"] = f"Gen{sta_gen} {sta.group(2)}"
            
            # 计算实际链路带宽
            # PCIe每lane每代的带宽（GB/s，双向）
            # Gen1: 0.25 GB/s per lane (2.5 GT/s)
            # Gen2: 0.5 GB/s per lane (5 GT/s)
            # Gen3: 0.985 GB/s per lane (8 GT/s)
            # Gen4: 1.969 GB/s per lane (16 GT/s)
            # Gen5: 3.938 GB/s per lane (32 GT/s)
            # Gen6: 7.876 GB/s per lane (64 GT/s)
            
            speed_gt = float(sta.group(1).replace("GT/s", ""))
            width = int(sta.group(2).replace("x", ""))
            
            # 计算理论带宽（GB/s，双向）
            if speed_gt == 2.5:  # Gen1
                bandwidth_per_lane = 0.25
            elif speed_gt == 5.0:  # Gen2
                bandwidth_per_lane = 0.5
            elif speed_gt == 8.0:  # Gen3
                bandwidth_per_lane = 0.985
            elif speed_gt == 16.0:  # Gen4
                bandwidth_per_lane = 1.969
            elif speed_gt == 32.0:  # Gen5
                bandwidth_per_lane = 3.938
            elif speed_gt == 64.0:  # Gen6
                bandwidth_per_lane = 7.876
            else:
                bandwidth_per_lane = 0
            
            total_bandwidth = bandwidth_per_lane * width
            if total_bandwidth >= 1:
                info["bandwidth"] = f"{total_bandwidth:.1f} GB/s"
            else:
                info["bandwidth"] = f"{total_bandwidth*1024:.0f} MB/s"
            
            # Store raw for comparison (warn logic moved to GPU level)
            info["downgraded"] = bool(cap and sta.group(1) != cap.group(1))
        else:
            info["sta_gen_display"] = "N/A"
            info["downgraded"] = False
    except:
        pass
    return info

def apply_physical_pcie_info(info, physical):
    """Prefer the shared sysfs collector over lspci's sometimes stale LnkCap."""
    def parse_link(value):
        match = re.fullmatch(r'Gen([0-9.]+)x([0-9]+)', str(value or ''))
        return (match.group(1), int(match.group(2))) if match else None

    speed_by_gen = {
        "1.0": "2.5GT/s", "2.0": "5GT/s", "3.0": "8GT/s",
        "4.0": "16GT/s", "5.0": "32GT/s", "6.0": "64GT/s",
    }
    bandwidth_per_lane = {
        "1.0": 0.25, "2.0": 0.5, "3.0": 0.985,
        "4.0": 1.969, "5.0": 3.938, "6.0": 7.876,
    }
    cap = parse_link(physical.get("max_link"))
    current = parse_link(physical.get("current_link"))
    if cap:
        cap_gen, cap_width = cap
        info.update({
            "cap_speed": speed_by_gen.get(cap_gen, "N/A"),
            "cap_width": f"x{cap_width}",
            "gen": cap_gen,
            "cap_gen_display": f"Gen{cap_gen} x{cap_width}",
        })
    if current:
        current_gen, current_width = current
        total_bandwidth = bandwidth_per_lane.get(current_gen, 0) * current_width
        info.update({
            "sta_speed": speed_by_gen.get(current_gen, "N/A"),
            "sta_width": f"x{current_width}",
            "sta_gen_display": f"Gen{current_gen} x{current_width}",
            "bandwidth": (f"{total_bandwidth:.1f} GB/s" if total_bandwidth >= 1
                          else f"{total_bandwidth * 1024:.0f} MB/s"),
        })
    if cap and current:
        info["downgraded"] = cap != current
    return info

def get_gpu_info(gpu_health=None):
    gpus = []
    physical_by_bus = {
        normalize_bus_id(item.get("bus_id")): item
        for item in (gpu_health or {}).get("physical_gpus", [])
    }
    if not has_nvidia():
        return gpus
    try:
        out = run_cmd("nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,power.limit,fan.speed,pci.bus_id --format=csv,noheader,nounits", timeout=8)
        if not out:
            return gpus
        for line in out.split('\n'):
            if not line.strip():
                continue
            try:
                parts = [p.strip() for p in line.split(',')]
                if len(parts) < 10:
                    continue
                bus_id = normalize_bus_id(parts[9])
                pcie = get_pcie_info(bus_id)
                physical = physical_by_bus.get(bus_id, {})
                pcie = apply_physical_pcie_info(pcie, physical)
                def safe_int(v, default=0):
                    try:
                        return int(v)
                    except:
                        return default
                def safe_float(v, default=0.0):
                    try:
                        return float(v)
                    except:
                        return default
                util = safe_int(parts[3])
                # Only show PCIe downgrade warning when GPU is under load (util > 5%)
                if pcie.get("downgraded") and util > 5:
                    pcie["sta_gen_display"] += " \u26a0"
                gpus.append({
                    "index": safe_int(parts[0]),
                    "name": parts[1],
                    "temp": safe_int(parts[2]),
                    "util": util,
                    "mem_used": safe_int(parts[4]),
                    "mem_total": safe_int(parts[5]),
                    "power": safe_float(parts[6]),
                    "power_limit": safe_float(parts[7]),
                    "fan": safe_int(parts[8]),
                    "bus_id": bus_id,
                    "slot": physical.get("slot", "UNMATCHED"),
                    "pcie": pcie
                })
            except:
                continue
    except:
        pass
    return gpus

def get_network_info():
    interfaces = []
    try:
        net_dir = '/sys/class/net'
        for iface in os.listdir(net_dir):
            if not os.path.isdir(os.path.join(net_dir, iface, 'device')):
                continue
            with open(f'/sys/class/net/{iface}/statistics/rx_bytes', 'r') as f:
                rx = int(f.read().strip())
            with open(f'/sys/class/net/{iface}/statistics/tx_bytes', 'r') as f:
                tx = int(f.read().strip())
            ip = run_cmd(f"ip -4 addr show {iface} 2>/dev/null | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){{3}}'")
            speed = run_cmd(f"cat /sys/class/net/{iface}/speed 2>/dev/null")
            speed_str = f"{speed} Mbps" if speed and speed != "-1" else "N/A"
            with open(f'/sys/class/net/{iface}/address', 'r') as f:
                mac = f.read().strip().upper()
            interfaces.append({"name": iface, "rx": rx, "tx": tx, "ip": ip or "-", "speed": speed_str, "mac": mac})
    except:
        pass
    return interfaces

def get_hostname():
    return socket.gethostname()

def get_node_id():
    """Return a stable UUID for this monitor installation."""
    global local_node_id
    with node_id_lock:
        if local_node_id:
            return local_node_id
        try:
            value = open(NODE_ID_FILE, 'r', encoding='utf-8').read().strip()
            local_node_id = str(uuid.UUID(value))
            return local_node_id
        except:
            pass

        value = str(uuid.uuid4())
        try:
            with open(NODE_ID_FILE, 'w', encoding='utf-8') as f:
                f.write(value + '\n')
            os.chmod(NODE_ID_FILE, 0o600)
        except:
            pass
        local_node_id = value
        return local_node_id

def is_usable_ipv4(value):
    try:
        addr = ipaddress.ip_address(str(value))
        return (addr.version == 4 and not addr.is_loopback and
                not addr.is_link_local and not addr.is_multicast and
                not addr.is_unspecified)
    except:
        return False

def is_container_interface(name):
    return name.startswith(('docker', 'veth', 'br-', 'virbr', 'cni', 'flannel'))

def get_discovery_network():
    """Return access addresses, physical-LAN broadcast targets and MACs."""
    addresses = []
    broadcasts = []
    macs = []
    seen_addresses = set()
    seen_broadcasts = set()
    seen_macs = set()

    try:
        result = subprocess.run(
            ['ip', '-j', '-4', 'addr', 'show'], capture_output=True,
            text=True, timeout=5
        )
        ip_data = json.loads(result.stdout) if result.returncode == 0 else []
        for item in ip_data:
            iface = str(item.get('ifname', ''))[:64]
            device_dir = os.path.join('/sys/class/net', iface, 'device')
            is_physical = os.path.isdir(device_dir)
            is_tailscale = iface.startswith('tailscale')
            if (not iface or iface == 'lo' or is_container_interface(iface) or
                    (not is_physical and not is_tailscale)):
                continue
            for addr_info in item.get('addr_info', []):
                if addr_info.get('family') != 'inet':
                    continue
                local_ip = str(addr_info.get('local', ''))
                if is_usable_ipv4(local_ip) and local_ip not in seen_addresses:
                    addresses.append({
                        "interface": iface,
                        "ip": local_ip,
                        "physical": is_physical,
                    })
                    seen_addresses.add(local_ip)
                broadcast = str(addr_info.get('broadcast', ''))
                if (is_physical and is_usable_ipv4(broadcast) and
                        broadcast not in seen_broadcasts):
                    broadcasts.append(broadcast)
                    seen_broadcasts.add(broadcast)
    except:
        pass

    try:
        for iface in sorted(os.listdir('/sys/class/net')):
            device_dir = os.path.join('/sys/class/net', iface, 'device')
            address_file = os.path.join('/sys/class/net', iface, 'address')
            if not os.path.isdir(device_dir) or not os.path.isfile(address_file):
                continue
            mac = open(address_file, 'r', encoding='utf-8').read().strip().upper()
            if (re.fullmatch(r'(?:[0-9A-F]{2}:){5}[0-9A-F]{2}', mac) and
                    mac != '00:00:00:00:00:00' and mac not in seen_macs):
                macs.append({"interface": iface[:64], "mac": mac})
                seen_macs.add(mac)
    except:
        pass

    return addresses, broadcasts, macs

def get_gpu_count_quick():
    out = run_cmd('nvidia-smi --query-gpu=index --format=csv,noheader,nounits', timeout=8)
    return len([line for line in out.splitlines() if line.strip()]) if out else 0

def get_gpu_power_summary_quick():
    """Return compact GPU model/power data for LAN overview broadcasts."""
    summary = []
    out = run_cmd(
        'nvidia-smi --query-gpu=index,name,power.draw --format=csv,noheader,nounits',
        timeout=8
    )
    if not out:
        return summary
    for line in out.splitlines()[:64]:
        try:
            parts = [part.strip() for part in line.split(',', 2)]
            if len(parts) != 3:
                continue
            summary.append({
                "index": max(0, min(127, int(parts[0]))),
                "name": parts[1][:96],
                "power": round(max(0.0, min(5000.0, float(parts[2]))), 2),
            })
        except:
            continue
    return summary

def build_discovery_announcement():
    addresses, broadcasts, macs = get_discovery_network()
    gpu_summary = get_gpu_power_summary_quick()
    gpu_health = collect_health()
    payload = {
        "protocol": DISCOVERY_PROTOCOL,
        "version": DISCOVERY_VERSION,
        "node_id": get_node_id(),
        "hostname": get_hostname()[:64],
        "port": PORT,
        "addresses": [item["ip"] for item in addresses],
        "macs": macs,
        "gpu_count": gpu_health.get("expected_count") or len(gpu_summary),
        "gpu_summary": gpu_summary,
        "gpu_health_status": gpu_health.get("status", "fail"),
        "gpu_expected_count": gpu_health.get("expected_count", 0),
        "gpu_pci_count": gpu_health.get("pci_count", 0),
        "gpu_driver_count": gpu_health.get("driver_count", 0),
        "gpu_issue_count": len(gpu_health.get("issues", [])),
        "gpu_missing_count": gpu_health.get("missing_count", 0),
        "timestamp": int(time.time()),
    }
    return json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode('utf-8'), broadcasts

def sanitize_discovery_packet(payload, source_ip):
    if payload.get('protocol') != DISCOVERY_PROTOCOL or payload.get('version') != DISCOVERY_VERSION:
        return None
    try:
        node_id = str(uuid.UUID(str(payload.get('node_id', ''))))
    except:
        return None
    if node_id == get_node_id() or not is_usable_ipv4(source_ip):
        return None

    raw_hostname = str(payload.get('hostname', 'unknown'))[:64]
    blocked = {"<", ">", "&", '"', "'"}
    hostname = ''.join(ch for ch in raw_hostname if ch.isprintable() and ch not in blocked).strip()
    hostname = hostname or 'unknown'

    try:
        port = int(payload.get('port', PORT))
        if port < 1 or port > 65535:
            raise ValueError()
    except:
        port = PORT

    addresses = [source_ip]
    for value in payload.get('addresses', [])[:16]:
        value = str(value)
        if is_usable_ipv4(value) and value not in addresses:
            addresses.append(value)

    macs = []
    for item in payload.get('macs', [])[:16]:
        if not isinstance(item, dict):
            continue
        mac = str(item.get('mac', '')).upper()
        iface = str(item.get('interface', ''))[:64]
        if re.fullmatch(r'(?:[0-9A-F]{2}:){5}[0-9A-F]{2}', mac):
            macs.append({"interface": iface, "mac": mac})

    try:
        gpu_count = max(0, min(128, int(payload.get('gpu_count', 0))))
    except:
        gpu_count = 0

    gpu_summary = []
    for item in payload.get('gpu_summary', [])[:64]:
        if not isinstance(item, dict):
            continue
        try:
            index = max(0, min(127, int(item.get('index', len(gpu_summary)))))
            power = round(max(0.0, min(5000.0, float(item.get('power', 0)))), 2)
        except:
            continue
        raw_name = str(item.get('name', 'Unknown GPU'))[:96]
        name = ''.join(
            ch for ch in raw_name
            if ch.isprintable() and ch not in blocked
        ).strip() or 'Unknown GPU'
        gpu_summary.append({"index": index, "name": name, "power": power})
    if gpu_summary:
        gpu_count = max(gpu_count, len(gpu_summary))

    gpu_health_status = str(payload.get("gpu_health_status", "unknown")).lower()
    if gpu_health_status not in {"pass", "fail", "unknown"}:
        gpu_health_status = "unknown"

    def bounded_count(key):
        try:
            return max(0, min(128, int(payload.get(key, 0))))
        except:
            return 0

    return {
        "node_id": node_id,
        "hostname": hostname,
        "port": port,
        "addresses": addresses,
        "source_ip": source_ip,
        "macs": macs,
        "primary_mac": macs[0]["mac"] if macs else "-",
        "gpu_count": gpu_count,
        "gpu_summary": gpu_summary,
        "gpu_health_status": gpu_health_status,
        "gpu_expected_count": bounded_count("gpu_expected_count"),
        "gpu_pci_count": bounded_count("gpu_pci_count"),
        "gpu_driver_count": bounded_count("gpu_driver_count"),
        "gpu_issue_count": bounded_count("gpu_issue_count"),
        "gpu_missing_count": bounded_count("gpu_missing_count"),
        "_last_seen": time.monotonic(),
    }

def expire_discovered_nodes():
    cutoff = time.monotonic() - PEER_TIMEOUT
    with discovery_lock:
        for node_id, node in list(discovered_nodes.items()):
            if node.get('_last_seen', 0) < cutoff:
                del discovered_nodes[node_id]

def discovery_loop():
    """Broadcast this node and listen for other monitors on the LAN."""
    while True:
        sock = None
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            sock.bind(('', DISCOVERY_PORT))
            next_broadcast = 0.0

            while True:
                now = time.monotonic()
                if now >= next_broadcast:
                    packet, broadcasts = build_discovery_announcement()
                    for broadcast in broadcasts:
                        try:
                            sock.sendto(packet, (broadcast, DISCOVERY_PORT))
                        except:
                            pass
                    next_broadcast = now + DISCOVERY_INTERVAL

                sock.settimeout(max(0.2, min(1.0, next_broadcast - time.monotonic())))
                try:
                    raw, sender = sock.recvfrom(8192)
                    payload = json.loads(raw.decode('utf-8'))
                    if isinstance(payload, dict):
                        node = sanitize_discovery_packet(payload, sender[0])
                        if node:
                            with discovery_lock:
                                discovered_nodes[node["node_id"]] = node
                except socket.timeout:
                    pass
                except:
                    pass
                expire_discovered_nodes()
        except Exception as exc:
            print(f"LAN discovery error: {exc}", file=sys.stderr, flush=True)
            time.sleep(3)
        finally:
            if sock:
                try:
                    sock.close()
                except:
                    pass

def get_node_directory(gpus, gpu_health):
    addresses, _, macs = get_discovery_network()
    physical_ip = next(
        (item["ip"] for item in addresses if item.get("physical")), ""
    )
    now = time.monotonic()
    current = {
        "node_id": get_node_id(),
        "hostname": get_hostname(),
        "port": PORT,
        "addresses": [item["ip"] for item in addresses],
        "source_ip": physical_ip,
        "macs": macs,
        "primary_mac": macs[0]["mac"] if macs else "-",
        "gpu_count": gpu_health.get("expected_count") or len(gpus),
        "gpu_summary": [
            {
                "index": int(gpu.get("index", index)),
                "name": str(gpu.get("name", "Unknown GPU"))[:96],
                "power": round(float(gpu.get("power", 0) or 0), 2),
            }
            for index, gpu in enumerate(gpus[:64])
        ],
        "gpu_health_status": gpu_health.get("status", "fail"),
        "gpu_expected_count": gpu_health.get("expected_count", 0),
        "gpu_pci_count": gpu_health.get("pci_count", 0),
        "gpu_driver_count": gpu_health.get("driver_count", 0),
        "gpu_issue_count": len(gpu_health.get("issues", [])),
        "gpu_missing_count": gpu_health.get("missing_count", 0),
        "age": 0,
        "current": True,
    }

    nodes = [current]
    with discovery_lock:
        for node_id, node in list(discovered_nodes.items()):
            age = now - node.get('_last_seen', 0)
            if age > PEER_TIMEOUT:
                del discovered_nodes[node_id]
                continue
            public_node = {key: value for key, value in node.items() if not key.startswith('_')}
            public_node["age"] = round(age, 1)
            public_node["current"] = False
            nodes.append(public_node)
    nodes[1:] = sorted(nodes[1:], key=lambda item: (item["hostname"].lower(), item["source_ip"]))
    return nodes

def get_driver_info():
    if not has_nvidia():
        return {"driver": "N/A", "cuda": "N/A"}
    try:
        out = run_cmd("nvidia-smi --query-gpu=driver_version --format=csv,noheader", timeout=8)
        driver = out.split('\n')[0].strip() if out else "N/A"
        smi_out = run_cmd("nvidia-smi", timeout=8)
        m = re.search(r'CUDA Version:\s+([\d.]+)', smi_out)
        cuda_ver = m.group(1) if m else "N/A"
        return {"driver": driver, "cuda": cuda_ver}
    except:
        return {"driver": "N/A", "cuda": "N/A"}

def get_burn_status():
    """Get burn test status for all GPUs"""
    status = {}
    with burn_lock:
        for idx, info in list(burn_processes.items()):
            proc = info["proc"]
            if proc.poll() is None:
                elapsed = int(time.time() - info["start"])
                remaining = max(0, info["duration"] - elapsed)
                status[idx] = {"running": True, "elapsed": elapsed, "remaining": remaining}
            else:
                del burn_processes[idx]
    return status

def start_burn(gpu_index, duration=600):
    """Start gpu-burn on a specific GPU"""
    with burn_lock:
        if gpu_index in burn_processes:
            proc = burn_processes[gpu_index]["proc"]
            if proc.poll() is None:
                return {"ok": False, "msg": "该显卡正在压测中"}
    
    try:
        env = os.environ.copy()
        env["CUDA_VISIBLE_DEVICES"] = str(gpu_index)
        proc = subprocess.Popen(
            f"/snap/bin/gpu-burn -i 0 {duration}",
            shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            preexec_fn=os.setsid, env=env
        )
        time.sleep(2)
        if proc.poll() is None:
            with burn_lock:
                burn_processes[gpu_index] = {"proc": proc, "start": time.time(), "duration": duration}
            return {"ok": True, "msg": f"GPU {gpu_index} 压测已启动 ({duration}秒)"}
        else:
            return {"ok": False, "msg": f"gpu-burn 启动失败，退出码: {proc.poll()}"}
    except Exception as e:
        return {"ok": False, "msg": str(e)}

def stop_burn(gpu_index):
    """Stop gpu-burn on a specific GPU, reset GPU if stuck"""
    with burn_lock:
        if gpu_index in burn_processes:
            proc = burn_processes[gpu_index]["proc"]
            if proc.poll() is None:
                try:
                    pgid = os.getpgid(proc.pid)
                    os.killpg(pgid, signal.SIGTERM)
                except:
                    try:
                        proc.terminate()
                    except:
                        pass
                try:
                    proc.wait(timeout=5)
                except:
                    try:
                        pgid = os.getpgid(proc.pid)
                        os.killpg(pgid, signal.SIGKILL)
                    except:
                        try:
                            proc.kill()
                        except:
                            pass
                    try:
                        proc.wait(timeout=3)
                    except:
                        pass
            del burn_processes[gpu_index]
    # pkill any remaining gpu-burn if no other GPUs are burning
    with burn_lock:
        still_running = any(p["proc"].poll() is None for p in burn_processes.values())
    if not still_running:
        try:
            subprocess.run("pkill -9 -f gpu-burn", shell=True, timeout=3)
        except:
            pass
    return {"ok": True, "msg": f"GPU {gpu_index} 压测已停止"}

def collect_all():
    cpu = get_cpu_info()
    mem = get_memory_info()
    disks = get_disk_info()
    gpu_health = collect_health()
    gpus = get_gpu_info(gpu_health)
    net = get_network_info()
    driver = get_driver_info()
    burn_status = get_burn_status()
    return {
        "timestamp": datetime.now(BEIJING_TZ).strftime("%Y-%m-%d %H:%M:%S"),
        "hostname": get_hostname(),
        "uptime": get_uptime(),
        "driver": driver,
        "cpu": cpu,
        "memory": mem,
        "memory_fmt": {
            "total": fmt_bytes(mem["total"]),
            "used": fmt_bytes(mem["used"]),
            "available": fmt_bytes(mem["available"]),
            "swap_total": fmt_bytes(mem["swap_total"]),
            "swap_used": fmt_bytes(mem["swap_used"]),
        },
        "disks": [{"device": d["device"], "mount": d["mount"], "total": fmt_bytes(d["total"]), "used": fmt_bytes(d["used"]), "percent": d["percent"]} for d in disks],
        "gpus": gpus,
        "has_gpu": len(gpus) > 0,
        "gpu_health": gpu_health,
        "burn_status": {str(k): v for k, v in burn_status.items()},
        "network": [{"name": n["name"], "rx": fmt_bytes(n["rx"]), "tx": fmt_bytes(n["tx"]), "ip": n["ip"], "speed": n["speed"], "mac": n["mac"]} for n in net],
        "nodes": get_node_directory(gpus, gpu_health),
    }

HTML_PAGE = '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>硬件监控面板</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600;700&family=Outfit:wght@300;400;500;600;700&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#0b1120;
  --bg-2:#080d18;
  --card:#0f172a;
  --card-hover:#141e33;
  --card-2:#0a1020;
  --border:#1b2a4a;
  --border-2:#243552;
  --text:#e8edf5;
  --text-secondary:#8899bb;
  --text-dim:#4a5a7a;
  --accent:#38bdf8;
  --accent-glow:rgba(56,189,248,0.15);
  --accent2:#818cf8;
  --green:#34d399;
  --green-glow:rgba(52,211,153,0.12);
  --yellow:#fbbf24;
  --yellow-glow:rgba(251,191,36,0.12);
  --red:#f87171;
  --red-glow:rgba(248,113,113,0.12);
}
body{
  background:var(--bg);
  background-image:
    radial-gradient(ellipse 80% 50% at 50% -20%, rgba(56,189,248,0.08), transparent),
    radial-gradient(ellipse 60% 40% at 100% 100%, rgba(129,140,248,0.05), transparent);
  color:var(--text);
  font-family:'Outfit',-apple-system,BlinkMacSystemFont,'Segoe UI','PingFang SC','Hiragino Sans GB','Microsoft YaHei',sans-serif;
  font-size:13px;
  line-height:1.6;
  min-height:100vh;
  -webkit-font-smoothing:antialiased;
}
.app-shell{min-height:100vh}
.node-sidebar{
  position:fixed;
  inset:0 auto 0 0;
  width:232px;
  padding:22px 16px;
  background:rgba(8,13,24,0.97);
  border-right:1px solid var(--border);
  box-shadow:12px 0 36px rgba(0,0,0,0.2);
  overflow-y:auto;
  z-index:20;
}
.node-brand{padding:4px 8px 20px;border-bottom:1px solid var(--border);margin-bottom:14px}
.node-brand-title{font-size:15px;font-weight:700;letter-spacing:0.6px;color:var(--text)}
.node-brand-meta{display:flex;align-items:center;justify-content:space-between;margin-top:6px;color:var(--text-secondary);font-size:10px}
.node-count{color:var(--accent);font-family:'JetBrains Mono',monospace}
.node-list{display:flex;flex-direction:column;gap:8px}
.node-item{
  width:100%;
  display:block;
  padding:12px;
  color:var(--text);
  font:inherit;
  text-align:left;
  text-decoration:none;
  background:rgba(15,23,42,0.72);
  border:1px solid transparent;
  border-radius:11px;
  transition:background 0.2s ease,border-color 0.2s ease,transform 0.2s ease;
}
.node-item:is(a,button){cursor:pointer}
.node-item:is(a,button):hover{background:var(--card-hover);border-color:var(--border-2);transform:translateX(2px)}
.node-item.active{background:var(--accent-glow);border-color:rgba(56,189,248,0.28)}
.node-item.fault{background:rgba(127,29,29,.12);border-color:rgba(248,113,113,.68);animation:node-fault-pulse 1.4s ease-in-out infinite}
.node-item.fault .node-dot{background:var(--red);box-shadow:0 0 11px rgba(248,113,113,.72)}
.node-item.fault:is(a,button):hover{background:rgba(127,29,29,.2);border-color:var(--red)}
@keyframes node-fault-pulse{0%,100%{border-color:rgba(248,113,113,.42);box-shadow:0 0 0 rgba(248,113,113,0)}50%{border-color:var(--red);box-shadow:0 0 16px rgba(248,113,113,.28)}}
.node-title-row{display:flex;align-items:center;gap:8px;min-width:0}
.node-dot{width:7px;height:7px;border-radius:50%;background:var(--green);box-shadow:0 0 10px rgba(52,211,153,0.6);flex:0 0 auto}
.node-dot.stale{background:var(--yellow);box-shadow:0 0 10px rgba(251,191,36,0.5)}
.node-name{font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.node-current{margin-left:auto;color:var(--accent);font-size:8px;letter-spacing:1px}
.node-ip{margin-top:7px;color:#fff;font:10px 'JetBrains Mono',monospace}
.node-detail{margin-top:4px;color:#fff;font:9px 'JetBrains Mono',monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.node-empty{padding:18px 10px;color:var(--text-dim);font-size:11px;text-align:center}
.overview-nav{display:flex;align-items:center;gap:10px;width:100%;padding:11px 12px;color:var(--text-secondary);font:inherit;text-align:left;background:rgba(15,23,42,.72);border:1px solid transparent;border-radius:11px;cursor:pointer;transition:background .2s ease,border-color .2s ease,transform .2s ease}
.overview-nav:hover{color:var(--text);background:var(--card-hover);border-color:var(--border-2);transform:translateX(2px)}
.overview-nav.active{color:var(--text);background:linear-gradient(135deg,rgba(56,189,248,.16),rgba(15,23,42,.82));border-color:rgba(56,189,248,.3)}
.overview-nav-icon{display:grid;grid-template-columns:repeat(2,5px);gap:2px;flex:0 0 auto}
.overview-nav-icon i{width:5px;height:5px;border-radius:1px;background:var(--accent);box-shadow:0 0 7px rgba(56,189,248,.35)}
.overview-nav-copy{min-width:0;flex:1}
.overview-nav-title{display:block;color:inherit;font-size:12px;font-weight:600}
.overview-nav-meta{display:block;margin-top:2px;color:var(--text-dim);font:8px 'JetBrains Mono',monospace}
.overview-nav-arrow{color:var(--accent);font:14px 'JetBrains Mono',monospace}
.node-dashboard[hidden],.fleet-dashboard[hidden]{display:none!important}
.fleet-header{margin-bottom:24px}
.fleet-kpis{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:12px;margin-bottom:16px}
.fleet-kpi{position:relative;overflow:hidden;min-height:116px;padding:20px;background:var(--card);border:1px solid var(--border);border-radius:14px;box-shadow:0 4px 24px rgba(0,0,0,.28)}
.fleet-kpi::after{content:'';position:absolute;inset:auto -24px -34px auto;width:90px;height:90px;border-radius:50%;background:rgba(56,189,248,.055)}
.fleet-kpi.primary{background:linear-gradient(145deg,rgba(14,116,144,.22),rgba(15,23,42,.94));border-color:rgba(56,189,248,.24)}
.fleet-kpi.fault-link{width:100%;color:inherit;font:inherit;text-align:left;cursor:pointer;transition:transform .2s ease,border-color .2s ease,background .2s ease}
.fleet-kpi.fault-link:hover{transform:translateY(-2px);border-color:rgba(248,113,113,.45);background:var(--card-hover)}
.fleet-kpi.fault-link:focus-visible,.fleet-fault-row:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.fleet-kpi.fault-link.has-faults{background:linear-gradient(145deg,rgba(127,29,29,.2),rgba(15,23,42,.94));border-color:rgba(248,113,113,.3)}
.fleet-kpi.fault-link.has-faults .fleet-kpi-value{color:var(--red)}
.fleet-kpi.fault-link.no-faults .fleet-kpi-value{color:var(--green)}
.fleet-kpi-label{color:var(--text-dim);font-size:9px;letter-spacing:1.4px}
.fleet-kpi-value{margin-top:9px;color:var(--text);font:700 27px 'JetBrains Mono',monospace;letter-spacing:-1px}
.fleet-kpi-value small{margin-left:5px;color:var(--accent);font:600 11px 'Outfit','Microsoft YaHei',sans-serif;letter-spacing:0}
.fleet-kpi-note{margin-top:5px;color:var(--text-secondary);font-size:9px}
.fleet-panels{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px;margin-bottom:20px}
.fleet-panel{display:flex;min-width:0;flex-direction:column;padding:18px 20px;background:var(--card);border:1px solid var(--border);border-radius:14px;box-shadow:0 4px 24px rgba(0,0,0,.25)}
.fleet-panel-head{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:16px;padding-bottom:11px;border-bottom:1px solid var(--border)}
.fleet-panel-title{font-size:12px;font-weight:600;letter-spacing:.6px}
.fleet-panel-meta{color:var(--text-dim);font:9px 'JetBrains Mono',monospace}
.fleet-model-list,.fleet-device-list{display:flex;height:308px;min-height:308px;flex-direction:column;gap:12px;overflow-y:auto;overflow-x:hidden;padding-right:4px;scrollbar-width:thin;scrollbar-color:rgba(56,189,248,.34) rgba(2,6,23,.36)}
.fleet-model-list::-webkit-scrollbar,.fleet-device-list::-webkit-scrollbar{width:5px}
.fleet-model-list::-webkit-scrollbar-track,.fleet-device-list::-webkit-scrollbar-track{background:rgba(2,6,23,.36);border-radius:999px}
.fleet-model-list::-webkit-scrollbar-thumb,.fleet-device-list::-webkit-scrollbar-thumb{background:rgba(56,189,248,.34);border-radius:999px}
.fleet-model-row,.fleet-device-row{display:grid;height:28px;min-height:28px;grid-template-columns:minmax(0,1fr) auto;gap:7px;align-items:center}
.fleet-row-name{min-width:0;color:var(--text);font-size:10px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.fleet-row-value{color:var(--accent);font:700 10px 'JetBrains Mono',monospace}
.fleet-device-row{grid-template-columns:minmax(0,1fr) 72px}
.fleet-device-row .fleet-row-value{text-align:right}
.fleet-device-label{display:grid;min-width:0;grid-template-columns:minmax(0,1fr) 84px;align-items:center;gap:18px}
.fleet-device-model{min-width:0;overflow:hidden;color:var(--text);font-size:10px;white-space:nowrap;text-overflow:ellipsis}
.fleet-device-host{display:flex;min-width:0;align-items:center;gap:6px;overflow:hidden;color:var(--text-secondary);font:9px 'JetBrains Mono',monospace;white-space:nowrap;text-overflow:ellipsis}
.fleet-device-host .node-dot{width:6px;height:6px}
.fleet-bar{grid-column:1/-1;height:5px;overflow:hidden;background:rgba(2,6,23,.82);border-radius:999px}
.fleet-bar-fill{height:100%;background:linear-gradient(90deg,var(--accent),var(--green));border-radius:inherit;box-shadow:0 0 10px rgba(56,189,248,.22)}
.fleet-empty{padding:28px;color:var(--text-dim);font-size:11px;text-align:center}
.fleet-fault-panel{margin-bottom:20px;scroll-margin-top:18px}
.fleet-fault-list{display:flex;flex-direction:column;gap:8px}
.fleet-fault-row{display:grid;width:100%;grid-template-columns:minmax(0,1fr) auto;gap:16px;align-items:center;padding:12px 14px;color:var(--text);font:inherit;text-align:left;text-decoration:none;background:rgba(127,29,29,.1);border:1px solid rgba(248,113,113,.2);border-radius:10px;cursor:pointer;transition:background .2s ease,border-color .2s ease,transform .2s ease}
.fleet-fault-row:hover{background:rgba(127,29,29,.18);border-color:rgba(248,113,113,.4);transform:translateX(2px)}
.fleet-fault-main{min-width:0}
.fleet-fault-name{display:flex;align-items:center;gap:8px;font-size:12px;font-weight:600}
.fleet-fault-name .node-dot{background:var(--red);box-shadow:0 0 10px rgba(248,113,113,.55)}
.fleet-fault-detail{margin-top:4px;color:var(--text-secondary);font:9px 'JetBrains Mono',monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.fleet-fault-go{color:var(--red);font:600 10px 'JetBrains Mono',monospace;white-space:nowrap}
.dashboard-main{min-width:0;margin-left:232px}
.container{max-width:1800px;margin:0 auto;padding:28px 32px}
.header{display:flex;justify-content:space-between;align-items:center;padding:24px 0;border-bottom:1px solid var(--border);margin-bottom:32px;position:relative}
.header::after{content:'';position:absolute;bottom:-1px;left:0;right:0;height:1px;background:linear-gradient(90deg,transparent,var(--accent),transparent);opacity:0.3}
.header h1{font-size:22px;font-weight:600;letter-spacing:1px;color:var(--text);display:flex;align-items:center;gap:14px}
.header h1::before{content:'';width:8px;height:8px;background:var(--green);border-radius:50%;box-shadow:0 0 16px var(--green),0 0 32px rgba(52,211,153,0.4);animation:pulse 2.5s ease-in-out infinite}
@keyframes pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:0.7;transform:scale(0.92)}}
.header .meta{font-size:12px;color:var(--text-secondary);text-align:right;line-height:1.9;font-family:'JetBrains Mono',monospace}
.header .meta span{opacity:0.8}
.status-bar{
  display:grid;
  grid-template-columns:repeat(auto-fit,minmax(160px,1fr));
  gap:14px;
  padding:20px 24px;
  background:var(--card);
  border:1px solid var(--border);
  border-radius:14px;
  margin-bottom:28px;
  box-shadow:
    0 4px 24px rgba(0,0,0,0.4),
    inset 0 1px 0 rgba(255,255,255,0.03);
  position:relative;
  overflow:hidden
}
.status-bar::before{
  content:'';
  position:absolute;
  top:0;left:0;right:0;height:1px;
  background:linear-gradient(90deg,transparent,rgba(56,189,248,0.4),transparent);
}
.status-item{text-align:center;padding:10px 6px;position:relative}
.status-item:not(:last-child)::after{
  content:'';
  position:absolute;
  right:0;top:20%;bottom:20%;
  width:1px;
  background:linear-gradient(180deg,transparent,var(--border),transparent);
}
.status-item .label{
  font-size:9px;
  text-transform:uppercase;
  letter-spacing:2px;
  color:var(--text-dim);
  margin-bottom:8px;
  font-weight:500;
}
.status-item .value{
  font-size:14px;
  font-weight:600;
  color:var(--text);
  font-family:'JetBrains Mono',monospace;
}
.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:20px;margin-bottom:24px}
.grid-3{grid-template-columns:repeat(3,1fr)}
.card{
  background:var(--card);
  border:1px solid var(--border);
  border-radius:16px;
  padding:24px;
  transition:all 0.3s ease;
  box-shadow:0 4px 20px rgba(0,0,0,0.3);
  position:relative;
  overflow:hidden;
}
.card::before{
  content:'';
  position:absolute;
  top:0;left:0;right:0;height:2px;
  background:linear-gradient(90deg,var(--accent),var(--accent2));
  opacity:0;
  transition:opacity 0.3s ease;
}
.card:hover{
  background:var(--card-hover);
  border-color:var(--border-2);
  box-shadow:0 8px 40px rgba(0,0,0,0.4);
  transform:translateY(-2px);
}
.card:hover::before{opacity:1}
.card-header{
  display:flex;
  justify-content:space-between;
  align-items:center;
  margin-bottom:20px;
  padding-bottom:16px;
  border-bottom:1px solid rgba(255,255,255,0.05);
}
.card-title{
  font-size:11px;
  font-weight:600;
  text-transform:uppercase;
  letter-spacing:2.5px;
  color:var(--text-secondary);
}
.card-badge{
  font-size:9px;
  padding:5px 12px;
  background:var(--accent-glow);
  border:1px solid rgba(56,189,248,0.2);
  border-radius:20px;
  color:var(--accent);
  font-weight:600;
  letter-spacing:1px;
}
.full-width{grid-column:1/-1}
.gpu-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:20px;margin-bottom:24px}
.gpu-card{
  border:1px solid var(--border);
  border-radius:16px;
  padding:24px;
  background:linear-gradient(145deg,var(--card) 0%,var(--bg-2) 100%);
  box-shadow:0 4px 20px rgba(0,0,0,0.35);
  position:relative;
  overflow:hidden;
  transition:all 0.3s ease;
}
.gpu-card::before{
  content:'';
  position:absolute;
  top:0;left:0;width:3px;bottom:0;
  background:linear-gradient(180deg,var(--accent),var(--accent2));
  border-radius:3px 0 0 3px;
}
.gpu-card:hover{
  border-color:var(--border-2);
  box-shadow:0 8px 40px rgba(0,0,0,0.45);
  transform:translateY(-2px);
}
.gpu-header{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:20px}
.gpu-name{font-size:15px;font-weight:600;color:var(--text);margin-bottom:6px;letter-spacing:0.3px}
.gpu-bus{font-size:12px;color:var(--text-secondary);font-weight:400}
.gpu-index{
  font-size:10px;
  font-weight:700;
  color:var(--accent);
  background:var(--accent-glow);
  padding:6px 14px;
  border-radius:8px;
  border:1px solid rgba(56,189,248,0.15);
  letter-spacing:1px;
}
.stats-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}
.stat-box{
  padding:16px 12px;
  background:rgba(0,0,0,0.25);
  border-radius:12px;
  border:1px solid rgba(255,255,255,0.03);
  text-align:center;
  transition:all 0.2s ease;
}
.stat-box:hover{
  background:rgba(0,0,0,0.35);
  border-color:rgba(255,255,255,0.06);
}
.stat-box .stat-label{
  font-size:8px;
  text-transform:uppercase;
  letter-spacing:1.5px;
  color:var(--text-dim);
  margin-bottom:10px;
  font-weight:500;
}
.stat-box .stat-value{
  font-size:22px;
  font-weight:700;
  color:var(--text);
  font-family:'JetBrains Mono',monospace;
  line-height:1.2;
}
.stat-box .stat-sub{
  font-size:10px;
  color:var(--text-dim);
  margin-top:6px;
  font-weight:400;
}
.pcie-section{
  margin-top:20px;
  padding-top:20px;
  border-top:1px solid rgba(255,255,255,0.05);
  display:flex;
  gap:12px;
  flex-wrap:wrap;
}
.pcie-tag{
  display:inline-flex;
  align-items:center;
  gap:12px;
  padding:12px 18px;
  background:rgba(0,0,0,0.2);
  border:1px solid rgba(56,189,248,0.1);
  border-radius:10px;
  flex:1;
  min-width:140px;
  transition:all 0.2s ease;
}
.pcie-tag:hover{
  background:rgba(56,189,248,0.05);
  border-color:rgba(56,189,248,0.2);
}
.pcie-tag .pcie-label{
  color:var(--text-dim);
  font-size:9px;
  text-transform:uppercase;
  letter-spacing:1.5px;
  font-weight:500;
}
.pcie-tag .pcie-value{
  color:var(--accent);
  font-weight:700;
  font-size:14px;
  letter-spacing:0.5px;
  font-family:'JetBrains Mono',monospace;
}
.progress{
  height:5px;
  background:rgba(0,0,0,0.4);
  border-radius:4px;
  overflow:hidden;
  margin-top:10px;
  box-shadow:inset 0 1px 3px rgba(0,0,0,0.3);
}
.progress-fill{
  height:100%;
  border-radius:4px;
  transition:width 0.6s cubic-bezier(0.4,0,0.2,1);
  position:relative;
}
.progress-fill::after{
  content:'';
  position:absolute;
  top:0;left:0;right:0;height:50%;
  background:linear-gradient(180deg,rgba(255,255,255,0.2),transparent);
  border-radius:4px 4px 0 0;
}
.fill-green{background:linear-gradient(90deg,#059669,var(--green),#10b981)}
.fill-yellow{background:linear-gradient(90deg,#d97706,var(--yellow),#f59e0b)}
.fill-red{background:linear-gradient(90deg,#dc2626,var(--red),#ef4444)}
.fill-accent{background:linear-gradient(90deg,#2563eb,var(--accent),#0ea5e9)}
table{width:100%;border-collapse:collapse}
th{
  text-align:left;
  padding:14px 16px;
  font-size:9px;
  font-weight:600;
  text-transform:uppercase;
  letter-spacing:2px;
  color:var(--text-dim);
  border-bottom:1px solid var(--border);
  background:rgba(0,0,0,0.2);
}
td{
  padding:14px 16px;
  font-size:13px;
  color:var(--text);
  border-bottom:1px solid rgba(255,255,255,0.03);
  font-family:'JetBrains Mono',monospace;
  font-size:12px;
}
tr{transition:all 0.15s ease}
tr:hover td{
  background:rgba(56,189,248,0.04);
}
tr:last-child td{border-bottom:none}
.tag{
  display:inline-block;
  padding:5px 12px;
  border-radius:6px;
  font-size:10px;
  font-weight:600;
  letter-spacing:0.5px;
}
.tag-green{background:var(--green-glow);color:var(--green);border:1px solid rgba(52,211,153,0.2)}
.tag-yellow{background:var(--yellow-glow);color:var(--yellow);border:1px solid rgba(251,191,36,0.2)}
.tag-red{background:var(--red-glow);color:var(--red);border:1px solid rgba(248,113,113,0.2)}
.no-gpu{
  text-align:center;
  padding:60px 40px;
  color:var(--text-dim);
  font-size:14px;
  position:relative;
}
.no-gpu::before{
  content:'';
  display:block;
  width:60px;
  height:60px;
  margin:0 auto 20px;
  border-radius:50%;
  background:rgba(248,113,113,0.1);
  border:1px dashed rgba(248,113,113,0.3);
}
.burn-btn{
  padding:8px 18px;
  border-radius:8px;
  border:1px solid rgba(248,113,113,0.4);
  background:rgba(248,113,113,0.1);
  color:var(--red);
  font-size:10px;
  font-weight:600;
  cursor:pointer;
  transition:all 0.25s ease;
  letter-spacing:1px;
  font-family:'Outfit',sans-serif;
}
.burn-btn:hover{
  background:rgba(248,113,113,0.2);
  border-color:rgba(248,113,113,0.6);
  box-shadow:0 0 20px rgba(248,113,113,0.2);
}
.burn-btn.burning{
  background:rgba(248,113,113,0.25);
  border-color:rgba(248,113,113,0.5);
  color:#fff;
  animation:burnPulse 1.8s ease-in-out infinite;
}
.burn-btn.burning:hover{
  background:rgba(248,113,113,0.35);
  animation:none;
}
@keyframes burnPulse{0%,100%{opacity:1;box-shadow:0 0 10px rgba(248,113,113,0.3)}50%{opacity:0.75;box-shadow:0 0 25px rgba(248,113,113,0.5)}}
.footer{
  text-align:center;
  padding:28px 0;
  color:var(--text-dim);
  font-size:9px;
  letter-spacing:3px;
  border-top:1px solid var(--border);
  margin-top:32px;
  text-transform:uppercase;
}
.temp-green{color:var(--green)}
.temp-yellow{color:var(--yellow)}
.temp-red{color:var(--red)}
@media(max-width:1400px){.gpu-grid{grid-template-columns:1fr}}
@media(max-width:1200px){.grid{grid-template-columns:1fr}.grid-3{grid-template-columns:1fr}}
@media(max-width:900px){
  .node-sidebar{position:sticky;inset:auto;top:0;width:100%;height:auto;padding:10px 12px;overflow:hidden}
  .node-brand{display:flex;align-items:center;justify-content:space-between;padding:2px 4px 9px;margin-bottom:9px}
  .node-brand-meta{gap:12px;margin-top:0}
  .node-list{flex-direction:row;overflow-x:auto;padding-bottom:2px}
  .node-item{min-width:190px}
  .dashboard-main{margin-left:0}
}
@media(max-width:768px){
  .stats-grid{grid-template-columns:repeat(2,1fr)}
  .status-bar{grid-template-columns:repeat(2,1fr)}
  .container{padding:16px}
  .header{flex-direction:column;gap:16px;text-align:center}
  .header .meta{text-align:center}
  .header h1{font-size:18px}
  .gpu-header{flex-direction:column;gap:12px}
  .gpu-name{font-size:14px}
  .pcie-section{flex-direction:column}
  .pcie-tag{width:100%;justify-content:space-between}
  .card{padding:18px;border-radius:12px}
  .stat-box .stat-value{font-size:18px}
}
@media(max-width:480px){
  .stats-grid{grid-template-columns:1fr}
  .status-bar{grid-template-columns:1fr}
  .burn-btn{width:100%;padding:12px}
}

/* Operations-first responsive layout */
.container{max-width:1720px;padding:20px 24px}
.header{padding:10px 0;margin-bottom:14px}
.header h1{font-size:20px}
.status-bar{
  grid-template-columns:repeat(4,minmax(0,1fr));
  gap:0;
  padding:10px 14px;
  margin-bottom:14px;
  border-radius:12px;
}
.status-item{padding:7px 6px;min-width:0}
.status-item .label{margin-bottom:4px}
.status-item .value{font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.system-overview{
  display:grid;
  grid-template-columns:minmax(170px,1fr) minmax(190px,1.1fr) minmax(320px,1.65fr) minmax(190px,1fr);
  gap:12px;
  margin-bottom:18px;
}
#systemSection,#storageSection{display:contents}
.system-overview .card{
  min-width:0;
  padding:16px;
  border-radius:12px;
  box-shadow:0 3px 16px rgba(0,0,0,0.26);
}
.system-overview .card.full-width{grid-column:auto}
.system-overview .card-header{margin-bottom:12px;padding-bottom:10px}
.system-overview .stats-grid{gap:8px}
.system-overview .stat-box{padding:10px 8px}
.system-overview .stat-box .stat-label{margin-bottom:6px}
.system-overview .stat-box .stat-value{font-size:16px!important}
.system-overview th{padding:8px 7px;font-size:8px;letter-spacing:1px}
.system-overview td{padding:9px 7px;font-size:10px;white-space:nowrap}
.system-overview table{table-layout:fixed}
.network-card td{overflow:hidden;text-overflow:ellipsis}
.storage-list{display:flex;flex-direction:column;gap:10px}
.storage-row{padding:2px 0 10px;border-bottom:1px solid rgba(255,255,255,0.05)}
.storage-row:last-child{padding-bottom:0;border-bottom:0}
.storage-row-top{display:flex;align-items:center;justify-content:space-between;gap:8px}
.storage-device{min-width:0;color:var(--text);font:11px 'JetBrains Mono',monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.storage-percent{color:var(--accent);font:700 12px 'JetBrains Mono',monospace}
.storage-usage{margin-top:5px;color:var(--text-secondary);font:10px 'JetBrains Mono',monospace}
.gpu-section-heading{display:flex;align-items:end;justify-content:space-between;gap:12px;margin:2px 0 10px;padding:0 2px 9px;border-bottom:1px solid var(--border)}
.gpu-section-heading h2{font-size:16px;letter-spacing:.5px}
.gpu-section-meta{color:var(--text-secondary);font:10px 'JetBrains Mono',monospace}
.gpu-section-meta.health-pass{color:var(--green)}
.gpu-section-meta.health-fail{color:var(--red)}
.gpu-health{margin:-9px 0 18px;padding:12px 14px;border-radius:10px;font-size:11px}
.gpu-health.pass{border:1px solid rgba(34,197,94,.28);background:rgba(34,197,94,.07);color:var(--green)}
.gpu-health.fail{border:1px solid rgba(239,68,68,.35);background:rgba(239,68,68,.08);color:var(--text)}
.gpu-health-summary{display:flex;align-items:center;justify-content:space-between;gap:12px;font:600 11px 'JetBrains Mono',monospace}
.gpu-health-summary strong{color:var(--red)}
.gpu-health.pass .gpu-health-summary strong{color:var(--green)}
.gpu-health-detail{margin-top:10px;width:100%;border-collapse:collapse}
.gpu-health-detail th,.gpu-health-detail td{padding:7px 8px;text-align:left;border-top:1px solid rgba(239,68,68,.16);font-size:10px}
.gpu-health-detail th{color:var(--text-dim);font-size:8px;letter-spacing:1px}
.gpu-health-code{color:var(--red);font-family:'JetBrains Mono',monospace;white-space:nowrap}
.gpu-column-head{
  display:grid;
  grid-template-columns:minmax(160px,1.15fr) repeat(4,minmax(0,.725fr)) repeat(4,minmax(0,.6875fr)) minmax(62px,.45fr);
  gap:0;
  padding:0 14px 7px;
  color:var(--text-dim);
  font-size:7px;
  text-transform:uppercase;
  letter-spacing:1px;
}
.gpu-column-head span{padding:0 9px;white-space:nowrap}
.gpu-column-head span:first-child{padding-left:0}
.gpu-grid{display:flex;flex-direction:column;gap:5px;margin-bottom:20px}
.gpu-card{
  display:grid;
  grid-template-columns:minmax(160px,1.15fr) minmax(360px,2.9fr) minmax(340px,2.75fr) minmax(62px,.45fr);
  align-items:center;
  gap:8px;
  padding:4px 12px;
  border-radius:10px;
}
.gpu-card::before{width:2px}
.gpu-header{display:flex;flex-direction:column;align-items:flex-start;justify-content:center;gap:1px;margin:0;min-width:0}
.gpu-name{width:100%;font-size:12px;margin:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.gpu-bus{font-size:9px}
.gpu-index{order:-1;padding:2px 7px;border-radius:6px;font-size:8px}
.gpu-card>.stats-grid{grid-template-columns:repeat(4,minmax(0,1fr));gap:0;min-width:0}
.gpu-card .stat-box{min-width:0;padding:3px 7px;background:transparent;border:0;border-left:1px solid rgba(255,255,255,0.055);border-radius:0;text-align:left}
.gpu-card .stat-box:first-child{border-left:0}
.gpu-card .stat-box .stat-label{display:none;margin-bottom:2px;font-size:7px;letter-spacing:1px}
.gpu-card .stat-box .stat-value{font-size:15px!important;white-space:nowrap}
.gpu-card .stat-box .stat-sub{margin-top:0;font-size:8px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.gpu-card .progress{height:3px;margin-top:3px}
.gpu-card>.pcie-section{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:0;margin:0;padding:0;border:0;min-width:0}
.gpu-card .pcie-tag{display:flex;flex-direction:column;align-items:flex-start;justify-content:center;gap:2px;min-width:0;padding:3px 7px;background:transparent;border:0;border-left:1px solid rgba(255,255,255,0.055);border-radius:0}
.gpu-card .pcie-label{display:none;font-size:7px;letter-spacing:1px;white-space:nowrap}
.gpu-card .pcie-value{font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}
.gpu-actions{display:flex;justify-content:flex-end;align-items:center}
.gpu-actions .burn-btn{width:auto;padding:7px 10px;border-radius:7px;font-size:9px;white-space:nowrap}
.node-item:focus-visible,.burn-btn:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.footer{padding:20px 0;margin-top:20px}

@media(max-width:1300px) and (min-width:901px){
  .system-overview{grid-template-columns:repeat(2,minmax(0,1fr))}
  .gpu-column-head{display:none}
  .gpu-card .stat-box .stat-label,.gpu-card .pcie-label{display:block}
  .gpu-card{grid-template-columns:160px minmax(0,1fr);align-items:start}
  .gpu-card>.stats-grid{grid-column:2;grid-row:1}
  .gpu-card>.pcie-section{grid-column:2;grid-row:2}
  .gpu-actions{grid-column:1;grid-row:2;justify-content:flex-start;align-self:end}
}

@media(max-width:900px){
  .node-sidebar{padding:10px 12px 9px;box-shadow:0 10px 28px rgba(0,0,0,.3)}
  .node-brand{padding:1px 3px 8px;margin-bottom:8px}
  .node-brand-title{font-size:14px}
  .node-list{gap:8px;scrollbar-width:none}
  .node-list::-webkit-scrollbar{display:none}
  .node-brand-meta{flex:0 0 auto}
  .overview-nav{flex:0 0 190px;min-width:190px;padding:9px 10px}
  .node-item{min-width:calc((100vw - 32px)/2);padding:9px 10px;border-radius:9px}
  .node-ip{margin-top:4px}
  .node-detail{margin-top:2px}
  .container{padding:12px}
  .header{align-items:flex-start;gap:4px;padding:10px 4px;margin-bottom:9px;text-align:left}
  .header h1{font-size:17px;line-height:1.35;letter-spacing:.3px}
  .header .meta{text-align:left;font-size:9px;line-height:1.4}
  .status-bar{padding:8px 5px;margin-bottom:10px}
  .status-item{padding:6px 3px}
  .status-item .label{font-size:7px;letter-spacing:1px}
  .status-item .value{font-size:10px}
  .system-overview{grid-template-columns:repeat(2,minmax(0,1fr));gap:8px;margin-bottom:14px}
  .system-overview .card{padding:11px;border-radius:10px}
  .system-overview .network-card,.system-overview .storage-card{grid-column:1/-1}
  .system-overview .card-header{margin-bottom:8px;padding-bottom:7px}
  .system-overview .card-title{font-size:9px;letter-spacing:1.4px}
  .system-overview .card-badge{padding:3px 8px;font-size:7px}
  .system-overview .stat-box{padding:7px 4px}
  .system-overview .stat-box .stat-value{font-size:14px!important}
  .system-overview .stat-box .stat-sub{font-size:8px}
  .system-overview th{padding:6px 5px;font-size:7px}
  .system-overview td{padding:7px 5px;font-size:9px}
  .system-overview .net-traffic{display:none}
  .storage-list{gap:7px}
  .storage-row{padding-bottom:7px}
  .storage-usage{margin-top:3px}
  .gpu-section-heading{margin-top:2px;padding-bottom:7px}
  .gpu-section-heading h2{font-size:14px}
  .gpu-column-head{display:none}
  .gpu-card .stat-box .stat-label,.gpu-card .pcie-label{display:block}
  .gpu-card{display:block;padding:11px 10px 10px;border-radius:11px}
  .gpu-header{display:flex;min-height:39px;padding-right:70px}
  .gpu-name{font-size:12px}
  .gpu-bus{font-size:9px}
  .gpu-card>.stats-grid{grid-template-columns:repeat(4,minmax(0,1fr));gap:0;margin-top:8px}
  .gpu-card .stat-box{padding:7px 4px;text-align:center}
  .gpu-card .stat-box .stat-value{font-size:14px!important}
  .gpu-card .stat-box .stat-sub{font-size:7px}
  .gpu-card>.pcie-section{grid-template-columns:repeat(4,minmax(0,1fr));margin-top:7px;padding-top:7px;border-top:1px solid rgba(255,255,255,0.05)}
  .gpu-card .pcie-tag{align-items:center;padding:5px 3px;text-align:center}
  .gpu-card .pcie-label{font-size:6px;letter-spacing:.5px}
  .gpu-card .pcie-value{font-size:9px}
  .gpu-actions{position:absolute;top:11px;right:10px}
  .gpu-actions .burn-btn{padding:6px 9px}
  .gpu-actions .burn-btn{min-width:52px;min-height:44px}
  .fleet-header{margin-bottom:12px}
  .fleet-kpis{grid-template-columns:repeat(2,minmax(0,1fr));gap:8px;margin-bottom:10px}
  .fleet-kpi{min-height:92px;padding:14px;border-radius:11px}
  .fleet-kpi-label{font-size:8px;letter-spacing:.8px}
  .fleet-kpi-value{margin-top:5px;font-size:21px}
  .fleet-kpi-note{font-size:8px}
  .fleet-panels{grid-template-columns:1fr;gap:9px;margin-bottom:14px}
  .fleet-panel{padding:13px;border-radius:11px}
  .fleet-panel-head{margin-bottom:11px;padding-bottom:8px}
  .fleet-device-row{grid-template-columns:minmax(0,1fr) 64px}
  .fleet-device-label{grid-template-columns:minmax(0,1fr) 68px;gap:10px}
  .footer{margin-top:14px;padding:16px 0}
}

@media(max-width:480px){
  .status-bar{grid-template-columns:repeat(4,minmax(0,1fr))}
  .system-overview .stats-grid{grid-template-columns:repeat(2,minmax(0,1fr))!important}
  .gpu-card>.stats-grid{grid-template-columns:repeat(4,minmax(0,1fr))}
  .gpu-actions .burn-btn{width:auto;padding:6px 9px}
}

@media(prefers-reduced-motion:reduce){
  *,*::before,*::after{animation-duration:.01ms!important;animation-iteration-count:1!important;transition-duration:.01ms!important}
}
</style>
</head>
<body>
<div class="app-shell">
<aside class="node-sidebar" aria-label="局域网节点">
  <div class="node-brand">
    <div class="node-brand-title">局域网节点</div>
    <div class="node-brand-meta"><span>自动发现</span><span class="node-count" id="nodeCount">0 台</span></div>
  </div>
  <nav class="node-list" id="nodeList"><div class="node-empty">正在搜索同网段面板...</div></nav>
</aside>
<main class="dashboard-main">
<div class="container">
  <section class="node-dashboard" id="nodeDashboard">
  <div class="header">
    <h1 id="pageTitle">硬件监控面板</h1>
    <div class="meta"><span id="hostname">-</span>&nbsp;&nbsp;<span id="timestamp">-</span></div>
  </div>
  <div class="status-bar" id="statusBar"></div>
  <div class="system-overview">
    <div id="systemSection"></div>
    <div id="storageSection"></div>
  </div>
  <div class="gpu-section-heading"><h2>GPU 监控</h2><span class="gpu-section-meta" id="gpuSectionMeta">实时状态</span></div>
  <div class="gpu-column-head" aria-hidden="true"><span>GPU</span><span>温度</span><span>利用率</span><span>显存</span><span>功耗</span><span>风扇转速</span><span>PCIe 支持</span><span>当前链路</span><span>链路带宽</span><span>操作</span></div>
  <div class="gpu-grid" id="gpuSection"></div>
  <div id="gpuHealthSection"></div>
  </section>
  <section class="fleet-dashboard" id="fleetDashboard" aria-label="局域网数据概览" hidden></section>
  <div class="footer">Hardware Monitor · Enterprise Edition</div>
</div>
</main>
</div>
<script>
function esc(v){
  return String(v==null?'':v).replace(/[&<>"']/g,function(ch){
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch];
  });
}
function ipv4Parts(value){
  var parts=String(value||'').split('.');
  if(parts.length!==4)return null;
  var nums=parts.map(Number);
  return nums.every(function(n){return Number.isInteger(n)&&n>=0&&n<=255})?nums:null;
}
function addressScore(ip){
  var current=ipv4Parts(location.hostname),target=ipv4Parts(ip);
  if(!target)return -1;
  if(!current)return 0;
  var weights=[16,8,4,2],score=0;
  for(var i=0;i<4;i++){
    if(current[i]!==target[i])break;
    score+=weights[i];
  }
  return score;
}
function pickNodeIp(node){
  var addresses=Array.isArray(node.addresses)?node.addresses.slice(0):[];
  if(node.source_ip&&addresses.indexOf(node.source_ip)<0)addresses.push(node.source_ip);
  var best='',bestScore=-1;
  addresses.forEach(function(ip){
    var score=addressScore(ip);
    if(score>bestScore){best=ip;bestScore=score}
  });
  return best;
}
var mainView='node',latestDashboardData=null;
function setMainView(view){
  var nodes=latestDashboardData&&Array.isArray(latestDashboardData.nodes)?latestDashboardData.nodes:[];
  if(view==='overview'&&nodes.length<2)view='node';
  mainView=view;
  var showOverview=view==='overview';
  document.getElementById('nodeDashboard').hidden=showOverview;
  document.getElementById('fleetDashboard').hidden=!showOverview;
  if(latestDashboardData){
    renderNodes(latestDashboardData);
    if(showOverview){
      document.title='局域网数据概览 · '+nodes.length+' 台设备';
    }else{
      renderStatus(latestDashboardData);
    }
  }
  window.scrollTo(0,0);
}
function formatPower(watts){
  watts=Number(watts||0);
  return watts>=1000?(watts/1000).toFixed(2)+' kW':watts.toFixed(1)+' W';
}
function powerMarkup(watts){
  var parts=formatPower(watts).split(' ');
  return esc(parts[0])+'<small>'+esc(parts[1]||'W')+'</small>';
}
function gpuModelSummary(node){
  var gpus=Array.isArray(node&&node.gpu_summary)?node.gpu_summary:[];
  var declared=Math.max(Number(node&&node.gpu_count||0),gpus.length);
  var counts={};
  gpus.forEach(function(gpu){
    var name=String(gpu&&gpu.name||'Unknown GPU');
    counts[name]=(counts[name]||0)+1;
  });
  var parts=Object.keys(counts).sort(function(a,b){return counts[b]-counts[a]||a.localeCompare(b)}).map(function(name){return name+' ×'+counts[name]});
  var missing=Math.max(0,declared-gpus.length);
  if(missing)parts.push('驱动不可见 ×'+missing);
  if(node&&node.gpu_health_status==='fail'){
    var missingCount=Number(node.gpu_missing_count||0);
    if(missingCount)parts.push('缺卡 ×'+missingCount);
    else parts.push('显卡异常 ×'+Number(node.gpu_issue_count||1));
  }
  return parts.length?parts.join(' + '):'未检测到 GPU';
}
function gpuPowerModelSummary(node){
  var gpus=Array.isArray(node&&node.gpu_summary)?node.gpu_summary:[];
  var counts={};
  gpus.forEach(function(gpu){
    var name=String(gpu&&gpu.name||'Unknown GPU');
    counts[name]=(counts[name]||0)+1;
  });
  var parts=Object.keys(counts).sort(function(a,b){return counts[b]-counts[a]||a.localeCompare(b)}).map(function(name){return name+' ×'+counts[name]});
  return parts.length?parts.join(' + '):'暂无功耗数据';
}
function renderOverview(d){
  var nodes=Array.isArray(d.nodes)?d.nodes:[];
  var dashboard=document.getElementById('fleetDashboard');
  var oldModelList=dashboard.querySelector('.fleet-model-list');
  var oldDeviceList=dashboard.querySelector('.fleet-device-list');
  var modelScrollTop=oldModelList?oldModelList.scrollTop:0;
  var deviceScrollTop=oldDeviceList?oldDeviceList.scrollTop:0;
  if(nodes.length<2){
    dashboard.innerHTML='';
    if(mainView==='overview')setMainView('node');
    return;
  }

  var totalPower=0,totalGpus=0,modelCounts={},machines=[];
  nodes.forEach(function(node){
    var gpus=Array.isArray(node.gpu_summary)?node.gpu_summary:[];
    var count=Math.max(Number(node.gpu_count||0),gpus.length);
    var machinePower=0;
    totalGpus+=count;
    gpus.forEach(function(gpu){
      var power=Math.max(0,Number(gpu.power||0));
      var name=String(gpu.name||'Unknown GPU');
      machinePower+=power;
      modelCounts[name]=(modelCounts[name]||0)+1;
    });
    totalPower+=machinePower;
    var missing=Math.max(0,count-gpus.length);
    if(missing){modelCounts['数据待同步']=(modelCounts['数据待同步']||0)+missing}
    machines.push({node:node,count:count,power:machinePower,gpuLabel:gpuPowerModelSummary(node)});
  });

  var models=Object.keys(modelCounts).sort(function(a,b){return modelCounts[b]-modelCounts[a]});
  var modelHtml=models.map(function(name){
    var count=modelCounts[name],percent=totalGpus?count/totalGpus*100:0;
    return '<div class="fleet-model-row"><span class="fleet-row-name" title="'+esc(name)+'">'+esc(name)+'</span><span class="fleet-row-value">×'+count+'</span><div class="fleet-bar"><div class="fleet-bar-fill" style="width:'+percent.toFixed(1)+'%"></div></div></div>';
  }).join('');
  var maxMachinePower=Math.max.apply(null,machines.map(function(machine){return machine.power}).concat([1]));
  var deviceHtml=machines.map(function(machine){
    var percent=machine.power/maxMachinePower*100;
    return '<div class="fleet-device-row"><span class="fleet-device-label"><span class="fleet-device-model" title="'+esc(machine.gpuLabel)+'">'+esc(machine.gpuLabel)+'</span><span class="fleet-device-host" title="'+esc(machine.node.hostname)+'"><span class="node-dot"></span>'+esc(machine.node.hostname)+'</span></span><span class="fleet-row-value">'+formatPower(machine.power)+'</span><div class="fleet-bar"><div class="fleet-bar-fill" style="width:'+percent.toFixed(1)+'%"></div></div></div>';
  }).join('');
  var faultMachines=machines.filter(function(machine){return machine.node.gpu_health_status==='fail'});
  var faultHtml=faultMachines.map(function(machine){
    var node=machine.node;
    var targetIp=node.current?location.hostname:pickNodeIp(node);
    var displayIp=node.source_ip||((Array.isArray(node.addresses)&&node.addresses.length)?node.addresses[0]:targetIp);
    var missingCount=Math.max(0,Number(node.gpu_missing_count||0));
    var issueCount=Math.max(1,Number(node.gpu_issue_count||0));
    var expected=Math.max(0,Number(node.gpu_expected_count||node.gpu_count||0));
    var driver=Math.max(0,Number(node.gpu_driver_count||0));
    var reason=missingCount?'缺卡 '+missingCount+' 张':'显卡异常 '+issueCount+' 项';
    if(expected)reason+=' · 驱动 '+driver+'/'+expected;
    var inner='<span class="fleet-fault-main"><span class="fleet-fault-name"><span class="node-dot"></span>'+esc(node.hostname)+'</span><span class="fleet-fault-detail">'+esc(displayIp||'无可用地址')+' · '+esc(reason)+'</span></span>';
    if(!targetIp)return '<div class="fleet-fault-row">'+inner+'<span class="fleet-fault-go">地址不可用</span></div>';
    var url=node.current?(location.protocol+'//'+location.host+'/'):('http://'+targetIp+':'+Number(node.port||8889)+'/');
    return '<a class="fleet-fault-row" href="'+esc(url)+'" aria-label="查看故障机器 '+esc(node.hostname)+'">'+inner+'<span class="fleet-fault-go">查看机器 ›</span></a>';
  }).join('');
  var averagePower=totalGpus?totalPower/totalGpus:0;
  dashboard.innerHTML='<div class="header fleet-header"><h1>局域网数据概览</h1><div class="meta"><span>'+nodes.length+' 台设备在线</span>&nbsp;&nbsp;<span>'+esc(d.timestamp)+'</span></div></div>'+
    '<div class="fleet-kpis">'+
      '<div class="fleet-kpi primary"><div class="fleet-kpi-label">GPU 实时总功耗</div><div class="fleet-kpi-value">'+powerMarkup(totalPower)+'</div><div class="fleet-kpi-note">全局每 5 秒自动刷新</div></div>'+
      '<div class="fleet-kpi"><div class="fleet-kpi-label">在线设备</div><div class="fleet-kpi-value">'+nodes.length+'<small>台</small></div><div class="fleet-kpi-note">局域网自动发现</div></div>'+
      '<div class="fleet-kpi"><div class="fleet-kpi-label">显卡总数</div><div class="fleet-kpi-value">'+totalGpus+'<small>张</small></div><div class="fleet-kpi-note">'+models.length+' 种 GPU 型号</div></div>'+
      '<div class="fleet-kpi"><div class="fleet-kpi-label">单卡平均功耗</div><div class="fleet-kpi-value">'+powerMarkup(averagePower)+'</div><div class="fleet-kpi-note">按当前实时功耗计算</div></div>'+
      '<button class="fleet-kpi fault-link '+(faultMachines.length?'has-faults':'no-faults')+'" type="button" data-fault-target="fleetFaultPanel"><div class="fleet-kpi-label">故障机器</div><div class="fleet-kpi-value">'+faultMachines.length+'<small>台</small></div><div class="fleet-kpi-note">'+(faultMachines.length?'点击查看并跳转':'当前未发现故障')+'</div></button>'+
    '</div>'+
    '<div class="fleet-panels"><section class="fleet-panel"><div class="fleet-panel-head"><span class="fleet-panel-title">显卡型号分布</span><span class="fleet-panel-meta">'+totalGpus+' 张</span></div><div class="fleet-model-list">'+(modelHtml||'<div class="fleet-empty">暂无显卡数据</div>')+'</div></section>'+
      '<section class="fleet-panel"><div class="fleet-panel-head"><span class="fleet-panel-title">设备功耗对比</span><span class="fleet-panel-meta">实时</span></div><div class="fleet-device-list">'+deviceHtml+'</div></section></div>'+
    '<section class="fleet-panel fleet-fault-panel" id="fleetFaultPanel"><div class="fleet-panel-head"><span class="fleet-panel-title">故障机器</span><span class="fleet-panel-meta">'+faultMachines.length+' 台</span></div><div class="fleet-fault-list">'+(faultHtml||'<div class="fleet-empty">当前未发现显卡故障机器</div>')+'</div></section>';
  var newModelList=dashboard.querySelector('.fleet-model-list');
  var newDeviceList=dashboard.querySelector('.fleet-device-list');
  if(newModelList)newModelList.scrollTop=Math.min(modelScrollTop,Math.max(0,newModelList.scrollHeight-newModelList.clientHeight));
  if(newDeviceList)newDeviceList.scrollTop=Math.min(deviceScrollTop,Math.max(0,newDeviceList.scrollHeight-newDeviceList.clientHeight));
}
function renderNodes(d){
  var nodes=Array.isArray(d.nodes)?d.nodes:[];
  document.getElementById('nodeCount').textContent=nodes.length+' 台';
  if(!nodes.length){
    document.getElementById('nodeList').innerHTML='<div class="node-empty">暂未发现节点</div>';
    return;
  }
  var overviewNav=nodes.length>=2?'<button class="overview-nav'+(mainView==='overview'?' active':'')+'" id="overviewNav" type="button" data-main-view="overview"'+(mainView==='overview'?' aria-current="page"':'')+'><span class="overview-nav-icon" aria-hidden="true"><i></i><i></i><i></i><i></i></span><span class="overview-nav-copy"><span class="overview-nav-title">数据概览</span><span class="overview-nav-meta">'+nodes.length+' 台设备 · 局域网汇总</span></span><span class="overview-nav-arrow">›</span></button>':'';
  document.getElementById('nodeList').innerHTML=overviewNav+nodes.map(function(node){
    var targetIp=node.current?location.hostname:pickNodeIp(node);
    var displayIp=node.source_ip||((Array.isArray(node.addresses)&&node.addresses.length)?node.addresses[0]:targetIp);
    var stale=!node.current&&Number(node.age||0)>10;
    var fault=node.gpu_health_status==='fail';
    var detail=gpuModelSummary(node);
    var inner='<div class="node-title-row"><span class="node-dot'+(stale?' stale':'')+'"></span>'+
      '<span class="node-name">'+esc(node.hostname)+'</span>'+
      (node.current?'<span class="node-current">当前</span>':'')+'</div>'+
      '<div class="node-ip">'+esc(displayIp||'无可用地址')+'</div>'+
      '<div class="node-detail">'+esc(detail)+'</div>';
    if(node.current)return '<button class="node-item'+(mainView==='node'?' active':'')+(fault?' fault':'')+'" id="currentNodeNav" type="button" data-main-view="node"'+(mainView==='node'?' aria-current="page"':'')+'>'+inner+'</button>';
    if(!targetIp)return '<div class="node-item'+(fault?' fault':'')+'">'+inner+'</div>';
    var url='http://'+targetIp+':'+Number(node.port||8889)+'/';
    return '<a class="node-item'+(fault?' fault':'')+'" href="'+esc(url)+'" aria-label="切换到 '+esc(node.hostname)+'">'+inner+'</a>';
  }).join('');
}
function pctClass(v){return v>90?'red':v>70?'yellow':'green'}
function pctTag(v){return '<span class="tag tag-'+pctClass(v)+'">'+v.toFixed(1)+'%</span>'}
function progress(v,c){return '<div class="progress"><div class="progress-fill fill-'+(c||pctClass(v))+'" style="width:'+Math.min(v,100)+'%"></div></div>'}
function tempClass(t){return t>85?'temp-red':t>70?'temp-yellow':'temp-green'}
function pcieWarn(s){return s.indexOf('\u26a0')>=0?'color:var(--yellow)':'color:var(--accent)'}

function renderStatus(d){
  document.getElementById('hostname').textContent=d.hostname;
  document.getElementById('timestamp').textContent=d.timestamp;
  var title=d.hostname;
  var health=d.gpu_health||{};
  var expected=Number(health.expected_count||d.gpus.length||0);
  var driverCount=Number(health.driver_count||d.gpus.length||0);
  if(d.has_gpu){title+=' · '+d.gpus[0].name+' x'+driverCount}
  document.getElementById('pageTitle').textContent=title;
  document.title=mainView==='overview'?'局域网数据概览 · '+(Array.isArray(d.nodes)?d.nodes.length:0)+' 台设备':title;
  var html='<div class="status-item"><div class="label">主机名</div><div class="value">'+d.hostname+'</div></div>'+
    '<div class="status-item"><div class="label">运行时间</div><div class="value">'+d.uptime+'</div></div>';
  var totalPower=0;d.gpus.forEach(function(g){totalPower+=g.power});
  var healthText=health.status==='pass'?'健康检查通过 '+driverCount+'/'+expected:'显卡健康异常 '+driverCount+'/'+expected;
  var healthColor=health.status==='pass'?'var(--green)':'var(--red)';
  html+='<div class="status-item"><div class="label">GPU健康</div><div class="value" style="color:'+healthColor+'">'+esc(healthText)+'</div></div>';
  html+='<div class="status-item"><div class="label">GPU总功耗</div><div class="value">'+totalPower.toFixed(1)+' W</div></div>';
  document.getElementById('statusBar').innerHTML=html;
}

function renderSystem(d){
  var cpu=d.cpu,mem=d.memory,mf=d.memory_fmt;
  document.getElementById('systemSection').innerHTML=
    '<div class="card system-card cpu-card"><div class="card-header"><span class="card-title">处理器</span><span class="card-badge">CPU</span></div>'+
    '<div class="stats-grid" style="grid-template-columns:repeat(2,1fr)">'+
    '<div class="stat-box"><div class="stat-label">核心 / 线程</div><div class="stat-value">'+cpu.cores+' / '+cpu.threads+'</div></div>'+
    '<div class="stat-box"><div class="stat-label">频率</div><div class="stat-value">'+cpu.freq+'</div></div>'+
    '</div></div>'+
    '<div class="card system-card memory-card"><div class="card-header"><span class="card-title">内存</span><span class="card-badge">RAM</span></div>'+
    '<div class="stats-grid" style="grid-template-columns:repeat(2,1fr)">'+
    '<div class="stat-box"><div class="stat-label">已用 / 总计</div><div class="stat-value" style="font-size:16px">'+mf.used+'</div><div class="stat-sub">'+mf.total+'</div>'+progress(mem.percent)+'</div>'+
    '<div class="stat-box"><div class="stat-label">可用</div><div class="stat-value" style="font-size:16px">'+mf.available+'</div><div class="stat-sub">'+mem.percent+'% 已用</div></div>'+
    '</div></div>'+
    '<div class="card system-card network-card"><div class="card-header"><span class="card-title">物理网卡</span><span class="card-badge">NET</span></div>'+
    '<table><thead><tr><th>接口</th><th>IP 地址</th><th>速率</th><th class="net-traffic">接收</th><th class="net-traffic">发送</th></tr></thead><tbody>'+
    d.network.map(function(n){return '<tr><td>'+n.name+'</td><td>'+n.ip+'</td><td>'+n.speed+'</td><td class="net-traffic">'+n.rx+'</td><td class="net-traffic">'+n.tx+'</td></tr>'}).join('')+
    '</tbody></table></div>';
}

function renderGPUs(d){
  var el=document.getElementById('gpuSection');
  if(!d.has_gpu){el.innerHTML='<div class="card full-width"><div class="no-gpu">未检测到 NVIDIA GPU 或驱动未就绪</div></div>';return}
  el.innerHTML=d.gpus.map(function(g){
    var memPct=g.mem_total>0?g.mem_used/g.mem_total*100:0;
    var pwrPct=g.power_limit>0?g.power/g.power_limit*100:0;
    var p=g.pcie;
    var bs=d.burn_status[String(g.index)];
    var isBurning=bs&&bs.running;
    var burnLabel=isBurning?'\u26a0 压测中 ('+Math.floor(bs.remaining/60)+'分'+bs.remaining%60+'秒)':'压测';
    var burnClass=isBurning?'burn-btn burning':'burn-btn';
    return '<div class="gpu-card">'+
      '<div class="gpu-header"><div class="gpu-index">GPU '+g.index+'</div><div class="gpu-name">'+esc(g.name)+'</div><div class="gpu-bus">Bus: '+esc(g.bus_id)+' · 插槽: '+esc(g.slot||'未匹配')+'</div></div>'+
      '<div class="stats-grid">'+
      '<div class="stat-box"><div class="stat-label">温度</div><div class="stat-value '+tempClass(g.temp)+'">'+g.temp+'\u00b0C</div></div>'+
      '<div class="stat-box"><div class="stat-label">利用率</div><div class="stat-value">'+g.util+'%</div>'+progress(g.util)+'</div>'+
      '<div class="stat-box"><div class="stat-label">显存</div><div class="stat-value" style="font-size:18px">'+g.mem_used+'</div><div class="stat-sub">/ '+g.mem_total+' MiB</div>'+progress(memPct)+'</div>'+
      '<div class="stat-box"><div class="stat-label">功耗</div><div class="stat-value" style="font-size:18px">'+g.power+'W</div><div class="stat-sub">上限 '+g.power_limit+'W</div>'+progress(pwrPct)+'</div>'+
      '</div>'+
      '<div class="pcie-section">'+
      '<div class="pcie-tag"><span class="pcie-label">风扇转速</span><span class="pcie-value">'+g.fan+'%</span></div>'+
      '<div class="pcie-tag"><span class="pcie-label">PCIe 支持</span><span class="pcie-value">'+p.cap_gen_display+'</span></div>'+
      '<div class="pcie-tag"><span class="pcie-label">当前链路</span><span class="pcie-value" style="'+pcieWarn(p.sta_gen_display)+'">'+p.sta_gen_display+'</span></div>'+
      '<div class="pcie-tag"><span class="pcie-label">链路带宽</span><span class="pcie-value">'+p.bandwidth+'</span></div>'+
      '</div><div class="gpu-actions"><button class="'+burnClass+'" onclick="toggleBurn('+g.index+','+!!isBurning+')">'+burnLabel+'</button></div></div>';
  }).join('');
}

function renderGPUHealth(d){
  var health=d.gpu_health||{status:'fail',expected_count:0,pci_count:0,driver_count:0,issues:[]};
  var issues=Array.isArray(health.issues)?health.issues:[];
  var passed=health.status==='pass';
  var meta=document.getElementById('gpuSectionMeta');
  meta.className='gpu-section-meta '+(passed?'health-pass':'health-fail');
  meta.textContent=passed?'健康检查通过 '+health.driver_count+'/'+health.expected_count+' · 5 秒刷新':'显卡健康异常 '+health.driver_count+'/'+health.expected_count+' · 5 秒刷新';
  var summary=(passed?'检查通过':'检查失败')+' · 基线 '+health.expected_count+' 张 · PCIe '+health.pci_count+' 张 · 驱动 '+health.driver_count+' 张';
  var html='<div class="gpu-health '+(passed?'pass':'fail')+'"><div class="gpu-health-summary"><strong>'+(passed?'正常':'异常')+'</strong><span>'+esc(summary)+'</span></div>';
  if(!passed&&issues.length){
    html+='<table class="gpu-health-detail"><thead><tr><th>状态</th><th>显卡型号</th><th>BusID</th><th>物理插槽</th><th>异常原因</th></tr></thead><tbody>';
    html+=issues.map(function(issue){return '<tr><td class="gpu-health-code">异常</td><td>'+esc(issue.model)+'</td><td>'+esc(issue.bus_id)+'</td><td>'+esc(issue.slot)+'</td><td>'+esc(issue.message)+'</td></tr>'}).join('');
    html+='</tbody></table>';
  }
  document.getElementById('gpuHealthSection').innerHTML=html+'</div>';
}

function renderStorage(d){
  document.getElementById('storageSection').innerHTML=
    '<div class="card system-card storage-card"><div class="card-header"><span class="card-title">存储</span><span class="card-badge">'+d.disks.length+' 分区</span></div>'+
    '<div class="storage-list">'+d.disks.map(function(dk){return '<div class="storage-row">'+
      '<div class="storage-row-top"><span class="storage-device">'+dk.device+' · '+dk.mount+'</span><span class="storage-percent">'+dk.percent.toFixed(1)+'%</span></div>'+
      '<div class="storage-usage">'+dk.used+' / '+dk.total+'</div>'+progress(dk.percent)+'</div>'}).join('')+
    '</div></div>';
}

async function toggleBurn(idx,running){
  var action=running?'stop':'start';
  if(action==='start'){
    if(!confirm('确定要对 GPU '+idx+' 进行压测吗？'))return;
    if(!confirm('再次确认：压测将持续10分钟，确定开始？'))return;
  }
  try{
    var r=await fetch('/api/burn',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({gpu:idx,action:action})});
    var d=await r.json();
    if(!d.ok)alert(d.msg);
    refresh();
  }catch(e){alert('操作失败: '+e)}
}

async function refresh(){
  try{var r=await fetch('/api/data');var d=await r.json();latestDashboardData=d;renderNodes(d);renderOverview(d);renderStatus(d);renderSystem(d);renderGPUs(d);renderGPUHealth(d);renderStorage(d);}catch(e){console.error(e)}
}
document.getElementById('nodeList').addEventListener('click',function(event){
  var button=event.target.closest('[data-main-view]');
  if(button)setMainView(button.getAttribute('data-main-view'));
});
document.getElementById('fleetDashboard').addEventListener('click',function(event){
  var button=event.target.closest('[data-fault-target]');
  if(!button)return;
  var panel=document.getElementById(button.getAttribute('data-fault-target'));
  if(panel)panel.scrollIntoView({behavior:'smooth',block:'start'});
});
refresh();setInterval(refresh,5000);
</script>
</body>
</html>'''


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path == '/api/data':
            data = collect_all()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())
        elif self.path == '/' or self.path == '/index.html':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(HTML_PAGE.encode())
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == '/api/burn':
            length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(length)) if length else {}
            gpu = body.get('gpu', 0)
            action = body.get('action', 'start')
            duration = body.get('duration', 600)
            if action == 'start':
                result = start_burn(int(gpu), int(duration))
            else:
                result = stop_burn(int(gpu))
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == '__main__':
    threading.Thread(target=discovery_loop, name='lan-discovery', daemon=True).start()
    server = http.server.ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
    print(f"Hardware Monitor running on http://0.0.0.0:{PORT}")
    server.serve_forever()
SERVER_EOF

echo "[*] Deploy TTY kiosk script..."
cat > ${STAGE_DIR}/tty-banner.sh << 'TTY_EOF'
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

collect_info() {
  HOSTNAME=$(hostname)
  CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //')
  CPU_CORES=$(grep -c '^processor' /proc/cpuinfo)
  MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  MEM_GB=$(( MEM_KB / 1024 / 1024 ))

  DISK_LINES=""
  while read -r line; do
    DEV=$(echo "$line" | awk '{print $1}')
    SIZE=$(echo "$line" | awk '{print $2}')
    SIZE_TB=$(awk "BEGIN {printf \"%.1f\", $SIZE / 1024 / 1024 / 1024 / 1024}")
    SIZE_GB=$(awk "BEGIN {printf \"%.0f\", $SIZE / 1024 / 1024 / 1024}")
    if [ "$(echo "$SIZE_TB" | awk '{print ($1 >= 1.0)}')" = "1" ]; then
      DISK_LINES="${DISK_LINES}$(printf "    %-20s %s" "$DEV" "${SIZE_TB} TB")\n"
    else
      DISK_LINES="${DISK_LINES}$(printf "    %-20s %s" "$DEV" "${SIZE_GB} GB")\n"
    fi
  done < <(lsblk -dbn -o NAME,SIZE 2>/dev/null | grep -E '^(sd|nvme|vd|hd)' | awk '{print "/dev/"$1, $2}')

  NET_LINES=""
  for iface in $(ls /sys/class/net/ 2>/dev/null); do
    [ -d "/sys/class/net/${iface}/device" ] || continue
    IP=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [ -z "$IP" ] && IP="-"
    SPEED=$(cat "/sys/class/net/${iface}/speed" 2>/dev/null)
    if [ -n "$SPEED" ] && [ "$SPEED" != "-1" ]; then
      SPEED_STR="${SPEED} Mbps"
    else
      SPEED_STR="N/A"
    fi
    MAC=$(cat "/sys/class/net/${iface}/address" 2>/dev/null | tr 'a-f' 'A-F')
    NET_LINES="${NET_LINES}$(printf "    %-20s %-18s %-12s %s" "$iface" "$IP" "$SPEED_STR" "$MAC")\n"
  done

  GPU_BLOCK=$(python3 /opt/hw-monitor/gpu-health.py --tty 2>/dev/null)
  [ -z "$GPU_BLOCK" ] && GPU_BLOCK="  GPU HEALTH: FAIL  COLLECTOR_ERROR"

  LAN_IP=$(ip -4 route get 1.0.0.0 2>/dev/null | grep -oP 'src \K[\d.]+' | head -1)

  UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
  UPTIME_D=$((UPTIME_SEC / 86400))
  UPTIME_H=$(( (UPTIME_SEC % 86400) / 3600 ))
  UPTIME_M=$(( (UPTIME_SEC % 3600) / 60 ))
  UPTIME_S=$((UPTIME_SEC % 60 ))
  UPTIME_STR="${UPTIME_D}d ${UPTIME_H}h ${UPTIME_M}m ${UPTIME_S}s"
}

show_info() {
  clear
  echo ""
  MACHINE_ID=$(awk 'NR==1{print $NF}' /opt/frp/machine_id.txt 2>/dev/null || echo "")
  echo "  Hostname: ${HOSTNAME}  ServerID: ${MACHINE_ID}  Uptime: ${UPTIME_STR}"
  echo ""
  echo "  CPU:    ${CPU_CORES} cores"
  echo "  RAM:    ${MEM_GB} GB"
  echo "  DISK:"
  echo "$(printf "    %-20s %s" "DEVICE" "SIZE")"
  echo -e "$DISK_LINES"
  echo "  --------------------------------------------"
  echo "  NETWORK"
  echo "  --------------------------------------------"
  echo "$(printf "    %-20s %-18s %-12s %s" "INTERFACE" "IP" "SPEED" "MAC")"
  echo -e "$NET_LINES"
  [ -n "$GPU_BLOCK" ] && printf "%s\n" "$GPU_BLOCK"
  [ -n "$LAN_IP" ] && echo "  WEB DASHBOARD: http://${LAN_IP}:8889"
  echo ""
  echo "  >>> Press ENTER for options <<<"
  echo ""
}

# === Main loop ===
while true; do
  collect_info
  show_info
  # Wait 10s, press Enter to show menu
  if read -t 10 -n 1 -s; then
    echo ""
    echo "  [1] Enter System Terminal (auto-return in 300s)"
    echo "  [2] Reboot"
    echo "  [3] Shutdown"
    echo ""
    read -t 10 -n 1 -s CHOICE
    case "$CHOICE" in
      1)
        chvt 2
        # Auto-return to monitor after 300 seconds
        sleep 300
        chvt 1
        ;;
      2)
        echo ""
        echo "  Rebooting in 10 seconds... Press any key to cancel"
        if ! read -t 10 -n 1 -s; then
          reboot
        fi
        ;;
      3)
        echo ""
        echo "  Shutting down in 10 seconds... Press any key to cancel"
        if ! read -t 10 -n 1 -s; then
          poweroff
        fi
        ;;
    esac
  fi
done


TTY_EOF
chmod 0755 ${STAGE_DIR}/tty-banner.sh

echo "[*] Validate generated monitor files..."
chmod 0755 ${STAGE_DIR}/gpu_health.py
chmod 0644 ${STAGE_DIR}/server.py
${PYTHON_BIN} -m py_compile ${STAGE_DIR}/gpu_health.py ${STAGE_DIR}/server.py
${PYTHON_BIN} ${STAGE_DIR}/gpu_health.py --self-test

echo "[*] Atomically deploy monitor files..."
mv -f ${STAGE_DIR}/gpu_health.py ${INSTALL_DIR}/gpu_health.py
mv -f ${STAGE_DIR}/server.py ${INSTALL_DIR}/server.py
mv -f ${STAGE_DIR}/tty-banner.sh ${INSTALL_DIR}/tty-banner.sh
ln -sfn gpu_health.py ${INSTALL_DIR}/gpu-health.py
DEPLOYED=1
${PYTHON_BIN} ${INSTALL_DIR}/gpu-health.py --ensure-baseline

echo "[*] Create hw-monitor service..."
cat > /etc/systemd/system/${SERVICE1}.service << EOF
[Unit]
Description=Hardware Monitor Web Dashboard
After=network.target

[Service]
Type=simple
ExecStart=${PYTHON_BIN} ${INSTALL_DIR}/server.py
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
Environment="CUDA_VISIBLE_DEVICES=all"
Environment="NVIDIA_VISIBLE_DEVICES=all"
Restart=always
RestartSec=5
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "[*] Setup TTY1 kiosk autologin..."
# Override getty@tty1 to auto-run our kiosk script
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --login-program /opt/hw-monitor/tty-banner.sh %I $TERM
Type=idle
Restart=no
EOF

# Stop the old tty-banner service if it exists
systemctl stop ${SERVICE2} 2>/dev/null || true
systemctl disable ${SERVICE2} 2>/dev/null || true
rm -f /etc/systemd/system/${SERVICE2}.service

# Clear /etc/issue since we no longer use it
echo "" > /etc/issue

echo "[*] Configure journal limit..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/hw-monitor.conf << EOF
[Journal]
SystemMaxUse=50M
EOF

echo "[*] Start services..."
systemctl daemon-reload
systemctl enable ${SERVICE1}
systemctl start ${SERVICE1}
systemctl restart getty@tty1

sleep 2

echo ""
echo "============================================"
S1=$(systemctl is-active ${SERVICE1} 2>/dev/null)
G1=$(systemctl is-active getty@tty1 2>/dev/null)
[ "$S1" = "active" ] && echo "  [OK] hw-monitor   - running" || echo "  [!!] hw-monitor   - stopped"
[ "$G1" = "active" ] && echo "  [OK] tty1-kiosk   - running" || echo "  [!!] tty1-kiosk   - stopped"
if [ "$S1" != "active" ] || [ "$G1" != "active" ]; then
  echo "[ERROR] Service validation failed."
  exit 1
fi
${PYTHON_BIN} - <<'PY_CHECK'
import json
import urllib.request

with urllib.request.urlopen("http://127.0.0.1:8889/api/data", timeout=8) as response:
    payload = json.load(response)
health = payload.get("gpu_health")
if not isinstance(health, dict) or health.get("status") not in {"pass", "fail"}:
    raise SystemExit("gpu_health is missing from /api/data")
print(
    "  [OK] gpu-health   - "
    f"{health['status'].upper()} expected={health.get('expected_count', 0)} "
    f"pci={health.get('pci_count', 0)} driver={health.get('driver_count', 0)}"
)
PY_CHECK
LAN_IP=$(ip -4 route get 1.0.0.0 2>/dev/null | grep -oP 'src \K[\d.]+' | head -1)
[ -n "$LAN_IP" ] && echo "  URL: http://${LAN_IP}:${PORT}"
echo "  Baseline refresh: sudo ${INSTALL_DIR}/gpu-health.py --refresh-baseline"
echo "============================================"
