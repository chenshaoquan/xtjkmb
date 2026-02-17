#!/bin/bash
set -e

SERVICE1="hw-monitor"
SERVICE2="tty-banner"
INSTALL_DIR="/opt/hw-monitor"
PORT=8889
PYTHON_BIN=$(which python3)

echo "============================================"
echo "  Hardware Monitor + TTY Kiosk - Install"
echo "  Dir: ${INSTALL_DIR}"
echo "  Port: ${PORT}"
echo "============================================"

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Run as root (sudo)"
  exit 1
fi

echo "[*] Check port ${PORT}..."
PID=$(lsof -ti:${PORT} 2>/dev/null || true)
if [ -n "$PID" ]; then
  echo "[*] Kill process on port (PID: ${PID})"
  kill -9 $PID 2>/dev/null || true
  sleep 1
fi

echo "[*] Stop existing services..."
systemctl stop ${SERVICE1} 2>/dev/null || true
systemctl disable ${SERVICE1} 2>/dev/null || true
systemctl stop ${SERVICE2} 2>/dev/null || true
systemctl disable ${SERVICE2} 2>/dev/null || true

echo "[*] Create install dir..."
mkdir -p ${INSTALL_DIR}

echo "[*] Deploy web monitor..."
cat > ${INSTALL_DIR}/server.py << 'SERVER_EOF'
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
from datetime import datetime

PORT = 8889

# Track burn test processes: {gpu_index: {"proc": Popen, "start": timestamp}}
burn_processes = {}
burn_lock = threading.Lock()

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

def get_gpu_info():
    gpus = []
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
                bus_id_full = parts[9]
                bus_short = bus_id_full.replace("00000000:", "").strip()
                pcie = get_pcie_info(bus_short)
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
                    "bus_id": bus_short,
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
    gpus = get_gpu_info()
    net = get_network_info()
    driver = get_driver_info()
    burn_status = get_burn_status()
    return {
        "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
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
        "burn_status": {str(k): v for k, v in burn_status.items()},
        "network": [{"name": n["name"], "rx": fmt_bytes(n["rx"]), "tx": fmt_bytes(n["tx"]), "ip": n["ip"], "speed": n["speed"], "mac": n["mac"]} for n in net],
    }

HTML_PAGE = '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>硬件监控面板</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#0b1120;--card:#0f1729;--card-hover:#131d35;--border:#1b2a4a;--text:#e8edf5;--text-secondary:#8899bb;--text-dim:#4a5a7a;--accent:#38bdf8;--accent2:#818cf8;--green:#34d399;--yellow:#fbbf24;--red:#f87171;--glow:rgba(56,189,248,.08)}
body{background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','PingFang SC','Hiragino Sans GB','Microsoft YaHei',sans-serif;font-size:13px;line-height:1.6;min-height:100vh}
.container{max-width:1800px;margin:0 auto;padding:24px}
.header{display:flex;justify-content:space-between;align-items:center;padding:20px 0;border-bottom:1px solid var(--border);margin-bottom:28px}
.header h1{font-size:20px;font-weight:700;letter-spacing:3px;color:var(--accent);display:flex;align-items:center;gap:12px}
.header h1::before{content:'';width:10px;height:10px;background:var(--green);border-radius:50%;box-shadow:0 0 12px rgba(52,211,153,.5);animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1;box-shadow:0 0 6px rgba(52,211,153,.5)}50%{opacity:.7;box-shadow:0 0 16px rgba(52,211,153,.3)}}
.header .meta{font-size:12px;color:var(--text-secondary);text-align:right;line-height:1.8}
.status-bar{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;padding:18px 24px;background:var(--card);border:1px solid var(--border);border-radius:10px;margin-bottom:28px;box-shadow:0 2px 20px rgba(0,0,0,.3)}
.status-item{text-align:center;padding:8px 0}
.status-item .label{font-size:10px;text-transform:uppercase;letter-spacing:1.5px;color:var(--text-dim);margin-bottom:6px}
.status-item .value{font-size:13px;font-weight:600;color:var(--text)}
.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:20px;margin-bottom:20px}
.grid-3{grid-template-columns:repeat(3,1fr)}
.card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:20px;transition:all .25s ease;box-shadow:0 2px 12px rgba(0,0,0,.2)}
.card:hover{background:var(--card-hover);border-color:#2a3d6a;box-shadow:0 4px 24px rgba(0,0,0,.3)}
.card-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;padding-bottom:12px;border-bottom:1px solid var(--border)}
.card-title{font-size:12px;font-weight:600;text-transform:uppercase;letter-spacing:2px;color:var(--text-secondary)}
.card-badge{font-size:10px;padding:4px 12px;background:rgba(56,189,248,.08);border:1px solid rgba(56,189,248,.2);border-radius:4px;color:var(--accent);font-weight:600}
.full-width{grid-column:1/-1}
.gpu-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:20px;margin-bottom:20px}
.gpu-card{border-left:3px solid var(--accent);background:linear-gradient(135deg,var(--card) 0%,#0d1525 100%)}
.gpu-header{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:16px}
.gpu-name{font-size:16px;font-weight:700;color:var(--text);margin-bottom:4px}
.gpu-bus{font-size:13px;color:var(--text);font-weight:500}
.gpu-index{font-size:11px;font-weight:700;color:var(--accent);background:rgba(56,189,248,.1);padding:5px 14px;border-radius:5px;border:1px solid rgba(56,189,248,.2)}
.stats-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}
.stat-box{padding:14px 10px;background:rgba(0,0,0,.3);border-radius:8px;border:1px solid rgba(255,255,255,.04);text-align:center}
.stat-box .stat-label{font-size:9px;text-transform:uppercase;letter-spacing:1px;color:var(--text-dim);margin-bottom:6px}
.stat-box .stat-value{font-size:20px;font-weight:700;color:var(--text)}
.stat-box .stat-sub{font-size:10px;color:var(--text-dim);margin-top:3px}
.pcie-section{margin-top:16px;padding-top:16px;border-top:1px solid var(--border);display:flex;gap:12px;flex-wrap:wrap}
.pcie-tag{display:inline-flex;align-items:center;gap:10px;padding:10px 18px;background:rgba(56,189,248,.06);border:1px solid rgba(56,189,248,.18);border-radius:8px}
.pcie-tag .pcie-label{color:var(--text-dim);font-size:10px;text-transform:uppercase;letter-spacing:1.5px;font-weight:500}
.pcie-tag .pcie-value{color:var(--accent);font-weight:700;font-size:15px;letter-spacing:.5px}
.progress{height:4px;background:rgba(255,255,255,.06);border-radius:3px;overflow:hidden;margin-top:8px}
.progress-fill{height:100%;border-radius:3px;transition:width .5s ease}
.fill-green{background:linear-gradient(90deg,#059669,var(--green))}
.fill-yellow{background:linear-gradient(90deg,#d97706,var(--yellow))}
.fill-red{background:linear-gradient(90deg,#dc2626,var(--red))}
.fill-accent{background:linear-gradient(90deg,#2563eb,var(--accent))}
table{width:100%;border-collapse:collapse}
th{text-align:left;padding:12px 14px;font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:1.5px;color:var(--text-dim);border-bottom:1px solid var(--border)}
td{padding:12px 14px;font-size:13px;color:var(--text);border-bottom:1px solid rgba(255,255,255,.04)}
tr:hover td{background:rgba(56,189,248,.03)}
.tag{display:inline-block;padding:4px 10px;border-radius:5px;font-size:11px;font-weight:600}
.tag-green{background:rgba(52,211,153,.12);color:var(--green)}
.tag-yellow{background:rgba(251,191,36,.12);color:var(--yellow)}
.tag-red{background:rgba(248,113,113,.12);color:var(--red)}
.no-gpu{text-align:center;padding:40px;color:var(--text-dim);font-size:14px}
.burn-btn{padding:6px 16px;border-radius:6px;border:1px solid rgba(248,113,113,.5);background:rgba(248,113,113,.15);color:var(--red);font-size:11px;font-weight:600;cursor:pointer;transition:all .2s;letter-spacing:1px}
.burn-btn:hover{background:rgba(248,113,113,.3);border-color:rgba(248,113,113,.7)}
.burn-btn.burning{background:rgba(248,113,113,.35);border-color:rgba(248,113,113,.6);color:#fff;animation:burnPulse 1.5s infinite}
.burn-btn.burning:hover{background:rgba(248,113,113,.45)}
@keyframes burnPulse{0%,100%{opacity:1}50%{opacity:.7}}
.footer{text-align:center;padding:20px 0;color:var(--text-dim);font-size:10px;letter-spacing:2px;border-top:1px solid var(--border);margin-top:28px}
.temp-green{color:var(--green)}
.temp-yellow{color:var(--yellow)}
.temp-red{color:var(--red)}
@media(max-width:1400px){.gpu-grid{grid-template-columns:1fr}}
@media(max-width:1200px){.grid{grid-template-columns:1fr}.grid-3{grid-template-columns:1fr}}
@media(max-width:768px){.stats-grid{grid-template-columns:repeat(2,1fr)}.status-bar{grid-template-columns:repeat(2,1fr)}.container{padding:12px}.header{flex-direction:column;gap:12px;text-align:center}.header .meta{text-align:center}.header h1{font-size:16px}.gpu-header{flex-direction:column;gap:10px}.gpu-name{font-size:14px}.pcie-section{flex-direction:column}.pcie-tag{width:100%;justify-content:space-between}.card{padding:14px}.stat-box .stat-value{font-size:16px}}
@media(max-width:480px){.stats-grid{grid-template-columns:1fr}.status-bar{grid-template-columns:1fr}.burn-btn{width:100%;padding:10px}}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1 id="pageTitle">硬件监控面板</h1>
    <div class="meta"><span id="hostname">-</span><br><span id="timestamp">-</span></div>
  </div>
  <div class="status-bar" id="statusBar"></div>
  <div class="grid grid-3" id="systemSection"></div>
  <div class="gpu-grid" id="gpuSection"></div>
  <div class="grid" id="storageSection"></div>
</div>
<script>
function pctClass(v){return v>90?'red':v>70?'yellow':'green'}
function pctTag(v){return '<span class="tag tag-'+pctClass(v)+'">'+v.toFixed(1)+'%</span>'}
function progress(v,c){return '<div class="progress"><div class="progress-fill fill-'+(c||pctClass(v))+'" style="width:'+Math.min(v,100)+'%"></div></div>'}
function tempClass(t){return t>85?'temp-red':t>70?'temp-yellow':'temp-green'}
function pcieWarn(s){return s.indexOf('\u26a0')>=0?'color:var(--yellow)':'color:var(--accent)'}

function renderStatus(d){
  document.getElementById('hostname').textContent=d.hostname;
  document.getElementById('timestamp').textContent=d.timestamp;
  var title=d.hostname;
  if(d.has_gpu){title+=' · '+d.gpus[0].name+' x'+d.gpus.length}
  document.getElementById('pageTitle').textContent=title;
  document.title=title;
  var html='<div class="status-item"><div class="label">主机名</div><div class="value">'+d.hostname+'</div></div>'+
    '<div class="status-item"><div class="label">运行时间</div><div class="value">'+d.uptime+'</div></div>';
  if(d.has_gpu){
    var totalPower=0;d.gpus.forEach(function(g){totalPower+=g.power});
    html+='<div class="status-item"><div class="label">CUDA版本</div><div class="value">'+d.driver.cuda+'</div></div>';
    html+='<div class="status-item"><div class="label">GPU总功耗</div><div class="value">'+totalPower.toFixed(1)+' W</div></div>';
  }
  document.getElementById('statusBar').innerHTML=html;
}

function renderSystem(d){
  var cpu=d.cpu,mem=d.memory,mf=d.memory_fmt;
  document.getElementById('systemSection').innerHTML=
    '<div class="card"><div class="card-header"><span class="card-title">处理器</span><span class="card-badge">CPU</span></div>'+
    '<div style="font-size:14px;font-weight:600;color:var(--text);margin-bottom:16px">'+cpu.model+'</div>'+
    '<div class="stats-grid" style="grid-template-columns:repeat(2,1fr)">'+
    '<div class="stat-box"><div class="stat-label">核心/线程</div><div class="stat-value">'+cpu.cores+'/'+cpu.threads+'</div></div>'+
    '<div class="stat-box"><div class="stat-label">频率</div><div class="stat-value" style="font-size:14px">'+cpu.freq+'</div></div>'+
    '</div></div>'+
    '<div class="card"><div class="card-header"><span class="card-title">内存</span><span class="card-badge">RAM</span></div>'+
    '<div class="stats-grid" style="grid-template-columns:repeat(2,1fr)">'+
    '<div class="stat-box"><div class="stat-label">已用/总量</div><div class="stat-value" style="font-size:14px">'+mf.used+'</div><div class="stat-sub">共 '+mf.total+'</div>'+progress(mem.percent)+'</div>'+
    '<div class="stat-box"><div class="stat-label">可用</div><div class="stat-value" style="font-size:14px">'+mf.available+'</div><div class="stat-sub">使用率 '+mem.percent+'%</div></div>'+
    '</div></div>'+
    '<div class="card"><div class="card-header"><span class="card-title">物理网卡</span><span class="card-badge">NET</span></div>'+
    '<table><thead><tr><th>接口</th><th>IP地址</th><th>速率</th><th>接收</th><th>发送</th></tr></thead><tbody>'+
    d.network.map(function(n){return '<tr><td>'+n.name+'</td><td>'+n.ip+'</td><td>'+n.speed+'</td><td>'+n.rx+'</td><td>'+n.tx+'</td></tr>'}).join('')+
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
    var burnLabel=isBurning?'\u26a0 压测中 (剩余'+Math.floor(bs.remaining/60)+'分'+bs.remaining%60+'秒) 点击停止':'压测';
    var burnClass=isBurning?'burn-btn burning':'burn-btn';
    return '<div class="card gpu-card">'+
      '<div class="gpu-header"><div><div class="gpu-name">'+g.name+'</div><div class="gpu-bus">总线: '+g.bus_id+'</div></div><div style="display:flex;gap:8px;align-items:center"><button class="'+burnClass+'" onclick="toggleBurn('+g.index+','+!!isBurning+')">'+burnLabel+'</button><div class="gpu-index">GPU '+g.index+'</div></div></div>'+
      '<div class="stats-grid">'+
      '<div class="stat-box"><div class="stat-label">温度</div><div class="stat-value '+tempClass(g.temp)+'">'+g.temp+'\u00b0C</div></div>'+
      '<div class="stat-box"><div class="stat-label">利用率</div><div class="stat-value">'+g.util+'%</div>'+progress(g.util)+'</div>'+
      '<div class="stat-box"><div class="stat-label">显存</div><div class="stat-value" style="font-size:14px">'+g.mem_used+'</div><div class="stat-sub">/ '+g.mem_total+' MiB</div>'+progress(memPct)+'</div>'+
      '<div class="stat-box"><div class="stat-label">功耗</div><div class="stat-value" style="font-size:14px">'+g.power+'W</div><div class="stat-sub">上限 '+g.power_limit+'W</div>'+progress(pwrPct)+'</div>'+
      '</div>'+
      '<div class="pcie-section">'+
      '<div class="pcie-tag"><span class="pcie-label">PCIe 支持</span><span class="pcie-value">'+p.cap_gen_display+'</span></div>'+
      '<div class="pcie-tag"><span class="pcie-label">当前链路</span><span class="pcie-value" style="'+pcieWarn(p.sta_gen_display)+'">'+p.sta_gen_display+'</span></div>'+
      '<div class="pcie-tag"><span class="pcie-label">链路带宽</span><span class="pcie-value">'+p.bandwidth+'</span></div>'+
      '</div></div>';
  }).join('');
}

function renderStorage(d){
  document.getElementById('storageSection').innerHTML=
    '<div class="card full-width"><div class="card-header"><span class="card-title">存储设备</span><span class="card-badge">'+d.disks.length+' 个分区</span></div>'+
    '<table><thead><tr><th>设备</th><th>挂载点</th><th>已用</th><th>总量</th><th>使用率</th><th style="width:150px"></th></tr></thead><tbody>'+
    d.disks.map(function(dk){return '<tr><td>'+dk.device+'</td><td>'+dk.mount+'</td><td>'+dk.used+'</td><td>'+dk.total+'</td><td>'+pctTag(dk.percent)+'</td><td>'+progress(dk.percent)+'</td></tr>'}).join('')+
    '</tbody></table></div>';
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
  try{var r=await fetch('/api/data');var d=await r.json();renderStatus(d);renderSystem(d);renderGPUs(d);renderStorage(d);}catch(e){console.error(e)}
}
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
    server = http.server.HTTPServer(('0.0.0.0', PORT), Handler)
    print(f"Hardware Monitor running on http://0.0.0.0:{PORT}")
    server.serve_forever()

SERVER_EOF

echo "[*] Deploy TTY kiosk script..."
cat > ${INSTALL_DIR}/tty-banner.sh << 'TTY_EOF'
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

  GPU_LINES=""
  GPU_COUNT=0
  if command -v nvidia-smi &>/dev/null; then
  GPU_LINES=""
  GPU_COUNT=0
  if command -v nvidia-smi &>/dev/null; then
    # 获取GPU信息：索引、名称、总线ID、功耗、温度
    GPU_DATA=$(nvidia-smi --query-gpu=index,name,pci.bus_id,power.draw,temperature.gpu --format=csv,noheader,nounits 2>/dev/null)
    if [ -n "$GPU_DATA" ]; then
      while IFS=',' read -r IDX NAME BUS_ID POWER TEMP; do
        IDX=$(echo "$IDX" | xargs)
        NAME=$(echo "$NAME" | xargs)
        BUS_ID=$(echo "$BUS_ID" | xargs | sed "s/00000000://")
        POWER=$(echo "$POWER" | xargs)
        TEMP=$(echo "$TEMP" | xargs)
        
        LSPCI_OUT=$(lspci -vvv -s "$BUS_ID" 2>/dev/null)
        CAP_SPEED="" ; CAP_WIDTH="" ; STA_SPEED="" ; STA_WIDTH=""
        if [ -n "$LSPCI_OUT" ]; then
          CAP_LINE=$(echo "$LSPCI_OUT" | grep -m1 "LnkCap:" | sed "s/.*LnkCap://")
          STA_LINE=$(echo "$LSPCI_OUT" | grep -m1 "LnkSta:" | sed "s/.*LnkSta://")
          CAP_SPEED=$(echo "$CAP_LINE" | grep -o "Speed [0-9.]\+GT/s" | sed "s/Speed //")
          CAP_WIDTH=$(echo "$CAP_LINE" | grep -o "Width x[0-9]\+" | sed "s/Width x//")
        STA_SPEED_NUM=$(echo "$STA_LINE" | grep -o "Speed [0-9.]\+GT/s" | sed "s/Speed //; s/GT\/s//")
        # Convert speed to PCIe generation
        case "$STA_SPEED_NUM" in
          2.5) PCIE_GEN="1" ;;
          5)   PCIE_GEN="2" ;;
          8)   PCIE_GEN="3" ;;
          16)  PCIE_GEN="4" ;;
          32)  PCIE_GEN="5" ;;
          *)   PCIE_GEN="4" ;;
        esac
        STA_SPEED="$PCIE_GEN"
        # Convert speed to PCIe generation
        case "$STA_SPEED_NUM" in
          2.5) PCIE_GEN="1" ;;
          5)   PCIE_GEN="2" ;;
          8)   PCIE_GEN="3" ;;
          16)  PCIE_GEN="4" ;;
          32)  PCIE_GEN="5" ;;
          *)   PCIE_GEN="4" ;;
        esac
        STA_SPEED="$PCIE_GEN"
          STA_WIDTH=$(echo "$STA_LINE" | grep -o "Width x[0-9]\+" | sed "s/Width x//")
        fi
        
        # 格式化功耗和温度
        POWER_FMT="$POWER W"
        TEMP_FMT="${TEMP}°C"
        
        GPU_LINES="${GPU_LINES}$(printf "    %-4s %-25s %-10s %-10s %-14s %-10s %-8s" "$IDX" "$NAME" "$BUS_ID" "Gen5 x${CAP_WIDTH:-16}" "Gen${STA_SPEED}  x${STA_WIDTH}" "$POWER_FMT" "$TEMP_FMT")
"
        GPU_COUNT=$((GPU_COUNT + 1))
      done <<< "$GPU_DATA"
    fi
  fi
  fi

  LAN_IP=$(ip -4 route get 1.0.0.0 2>/dev/null | grep -oP 'src \K[\d.]+' | head -1)

  UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
  UPTIME_D=$((UPTIME_SEC / 86400))
  UPTIME_H=$(( (UPTIME_SEC % 86400) / 3600 ))
  UPTIME_M=$(( (UPTIME_SEC % 3600) / 60 ))
  UPTIME_STR="${UPTIME_D}d ${UPTIME_H}h ${UPTIME_M}m"
}

show_info() {
  clear
  echo ""
  echo "  Hostname: ${HOSTNAME}    Uptime: ${UPTIME_STR}"
  echo ""
  echo "  CPU:    ${CPU_MODEL} (${CPU_CORES} cores)"
  echo "  RAM:    ${MEM_GB} GB"
  echo "  DISK:"
  echo "$(printf "    %-20s %s" "DEVICE" "SIZE")"
  echo -e "$DISK_LINES"
  echo "  --------------------------------------------"
  echo "  NETWORK"
  echo "  --------------------------------------------"
  echo "$(printf "    %-20s %-18s %-12s %s" "INTERFACE" "IP" "SPEED" "MAC")"
  echo -e "$NET_LINES"
  if [ "$GPU_COUNT" -gt 0 ]; then
    echo "  --------------------------------------------"
    echo "  GPU"
    echo "  --------------------------------------------"
    echo "$(printf "    %-4s %-25s %-10s %-10s %-14s %-10s %-8s" "ID" "MODEL" "BUS" "SLOT" "CURRENT" "POWER" "TEMP")"
    echo -e "$GPU_LINES"
  fi
  echo "  --------------------------------------------"
  echo "  WEB DASHBOARD"
  echo "  --------------------------------------------"
  [ -n "$LAN_IP" ] && echo "    http://${LAN_IP}:8889"
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
chmod +x ${INSTALL_DIR}/tty-banner.sh

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
LAN_IP=$(ip -4 route get 1.0.0.0 2>/dev/null | grep -oP 'src \K[\d.]+' | head -1)
[ -n "$LAN_IP" ] && echo "  URL: http://${LAN_IP}:${PORT}"
echo "============================================"
