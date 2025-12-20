#!/bin/bash

# 系统监控面板 - 单文件安装脚本
# 功能：自动安装依赖、systemctl运行、日志管理、端口冲突处理

set -e

PORT=8888
INSTALL_DIR="/opt/system-monitor"
LOG_FILE="/var/log/system-monitor.log"
MAX_LOG_SIZE=10485760  # 10MB

# 检查root权限
if [ "$EUID" -ne 0 ]; then 
    echo "请使用root权限运行此脚本"
    exit 1
fi

echo "========================================="
echo "  系统监控面板 - 自动安装"
echo "========================================="

# 日志轮转函数 - 防止日志挤爆磁盘
rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$LOG_SIZE" -gt "$MAX_LOG_SIZE" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 日志文件过大，执行轮转..." >> "$LOG_FILE"
            tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 日志轮转完成" >> "$LOG_FILE"
        fi
    fi
}

# 清理8888端口占用
cleanup_port() {
    echo "检查端口 $PORT 占用情况..."
    PID=$(lsof -ti:$PORT 2>/dev/null || true)
    if [ ! -z "$PID" ]; then
        echo "端口 $PORT 被进程 $PID 占用，强制清除..."
        kill -9 $PID 2>/dev/null || true
        sleep 1
    fi
}

# 安装依赖函数
install_dependencies() {
    echo "检查并安装依赖..."
    rotate_log
    
    # 安装lsof
    if ! command -v lsof &> /dev/null; then
        echo "安装 lsof..."
        apt-get update -qq >> "$LOG_FILE" 2>&1 || true
        apt-get install -y lsof >> "$LOG_FILE" 2>&1 || yum install -y lsof >> "$LOG_FILE" 2>&1 || true
    fi
    
    # 安装netcat
    if ! command -v nc &> /dev/null; then
        echo "安装 netcat..."
        apt-get install -y netcat >> "$LOG_FILE" 2>&1 || yum install -y nc >> "$LOG_FILE" 2>&1 || true
    fi
    
    # 安装smartmontools
    if ! command -v smartctl &> /dev/null; then
        echo "安装 smartmontools..."
        for i in 1 2 3; do
            if command -v apt-get &> /dev/null; then
                apt-get install -y smartmontools >> "$LOG_FILE" 2>&1 && break
            elif command -v yum &> /dev/null; then
                yum install -y smartmontools >> "$LOG_FILE" 2>&1 && break
            elif command -v dnf &> /dev/null; then
                dnf install -y smartmontools >> "$LOG_FILE" 2>&1 && break
            fi
            sleep 2
        done
    fi
    
    echo "依赖检查完成"
}

# 创建监控脚本
create_monitor_script() {
    echo "创建监控脚本..."
    mkdir -p "$INSTALL_DIR"
    
    cat > "$INSTALL_DIR/monitor.sh" << 'MONITOR_EOF'
#!/bin/bash

PORT=8888
LOG_FILE="/var/log/system-monitor.log"
MAX_LOG_SIZE=10485760

# 日志轮转
rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$LOG_SIZE" -gt "$MAX_LOG_SIZE" ]; then
            tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
}

# 每30分钟检查并安装依赖
check_dependencies() {
    if ! command -v smartctl &> /dev/null; then
        for i in 1 2 3; do
            if command -v apt-get &> /dev/null; then
                apt-get install -y smartmontools >> "$LOG_FILE" 2>&1 && break
            elif command -v yum &> /dev/null; then
                yum install -y smartmontools >> "$LOG_FILE" 2>&1 && break
            fi
            sleep 2
        done
    fi
}

# 后台定时检查依赖
(
    while true; do
        sleep 1800  # 30分钟
        check_dependencies
        rotate_log
    done
) &

get_json_data() {
    # CPU
    CPU_MODEL=$(grep 'model name' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
    CPU_CORES=$(nproc)
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    
    # 内存
    MEM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
    MEM_USED=$(free -h | awk '/^Mem:/ {print $3}')
    MEM_FREE=$(free -h | awk '/^Mem:/ {print $4}')
    MEM_PERCENT=$(free | awk '/^Mem:/ {printf "%.0f", $3/$2*100}')
    
    # 磁盘分区信息
    PARTITIONS_DATA=""
    while read -r line; do
        DEV=$(echo "$line" | awk '{print $1}')
        SIZE=$(echo "$line" | awk '{print $2}')
        USED=$(echo "$line" | awk '{print $3}')
        AVAIL=$(echo "$line" | awk '{print $4}')
        PCT=$(echo "$line" | awk '{print $5}' | tr -d '%')
        MOUNT=$(echo "$line" | awk '{print $6}')
        [ ! -z "$PARTITIONS_DATA" ] && PARTITIONS_DATA="$PARTITIONS_DATA,"
        PARTITIONS_DATA="${PARTITIONS_DATA}{\"dev\":\"$DEV\",\"size\":\"$SIZE\",\"used\":\"$USED\",\"avail\":\"$AVAIL\",\"pct\":\"$PCT\",\"mount\":\"$MOUNT\"}"
    done < <(df -h | grep -E "^/dev/" | grep -v "/boot")
    
    # 物理磁盘健康状态
    DISKS_HEALTH=""
    if command -v smartctl >/dev/null 2>&1; then
        for disk in $(lsblk -d -n -o NAME,TYPE | awk '$2=="disk" {print $1}'); do
            HEALTH=$(smartctl -H /dev/$disk 2>/dev/null | grep -i "SMART overall-health" | awk -F': ' '{print $2}' || echo "N/A")
            [ -z "$HEALTH" ] && HEALTH="N/A"
            MODEL=$(smartctl -i /dev/$disk 2>/dev/null | grep -E "Device Model|Model Number" | awk -F': ' '{print $2}' | xargs || echo "Unknown")
            HOURS=$(smartctl -a /dev/$disk 2>/dev/null | grep "Power On Hours:" | awk '{print $4}' | tr -d ',' | head -1)
            if [ -z "$HOURS" ]; then
                HOURS=$(smartctl -A /dev/$disk 2>/dev/null | awk '/Power_On_Hours/ {print $10}' | head -1)
            fi
            [ -z "$HOURS" ] && HOURS="0"
            TEMP=$(smartctl -A /dev/$disk 2>/dev/null | awk '/Temperature_Celsius/ {print $10}' | head -1)
            if [ -z "$TEMP" ]; then
                TEMP=$(smartctl -a /dev/$disk 2>/dev/null | grep "Temperature:" | head -1 | awk '{print $2}')
            fi
            [ -z "$TEMP" ] && TEMP="N/A"
            HEALTH_PCT=$(smartctl -a /dev/$disk 2>/dev/null | grep "Available Spare:" | awk '{print $3}' | tr -d '%' | head -1)
            if [ -z "$HEALTH_PCT" ]; then
                HEALTH_PCT=$(smartctl -A /dev/$disk 2>/dev/null | awk '/Wear_Leveling_Count|Media_Wearout_Indicator/ {print $4}' | head -1)
            fi
            if [ -z "$HEALTH_PCT" ]; then
                USED_PCT=$(smartctl -a /dev/$disk 2>/dev/null | grep "Percentage Used:" | awk '{print $3}' | tr -d '%' | head -1)
                if [ ! -z "$USED_PCT" ]; then
                    HEALTH_PCT=$((100 - USED_PCT))
                fi
            fi
            [ -z "$HEALTH_PCT" ] && HEALTH_PCT="100"
            [ ! -z "$DISKS_HEALTH" ] && DISKS_HEALTH="$DISKS_HEALTH,"
            DISKS_HEALTH="${DISKS_HEALTH}{\"disk\":\"$disk\",\"model\":\"$MODEL\",\"health\":\"$HEALTH\",\"healthPct\":\"$HEALTH_PCT\",\"hours\":\"$HOURS\",\"temp\":\"$TEMP\"}"
        done
    fi
    
    # 系统
    OS_NAME=$(cat /etc/os-release 2>/dev/null | grep "^PRETTY_NAME" | cut -d'"' -f2 || uname -s)
    KERNEL=$(uname -r)
    UPTIME=$(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    
    # GPU
    GPU_DATA=""
    if command -v nvidia-smi >/dev/null 2>&1; then
        declare -A PCIE_INFO
        while IFS=',' read -r IDX BUS GEN_CUR GEN_MAX WIDTH_CUR WIDTH_MAX; do
            IDX=$(echo "$IDX" | xargs)
            BUS=$(echo "$BUS" | xargs)
            GEN_CUR=$(echo "$GEN_CUR" | xargs)
            GEN_MAX=$(echo "$GEN_MAX" | xargs)
            WIDTH_CUR=$(echo "$WIDTH_CUR" | xargs)
            WIDTH_MAX=$(echo "$WIDTH_MAX" | xargs)
            PCIE_INFO[$IDX]="$BUS|$GEN_CUR|$GEN_MAX|$WIDTH_CUR|$WIDTH_MAX"
        done < <(nvidia-smi --query-gpu=index,pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv,noheader 2>/dev/null)
        
        while IFS=',' read -r IDX NAME DRIVER TEMP UTIL MEM_USED_G MEM_TOTAL_G POWER; do
            [ -z "$IDX" ] && continue
            IDX=$(echo "$IDX" | xargs)
            NAME=$(echo "$NAME" | xargs)
            DRIVER=$(echo "$DRIVER" | xargs)
            TEMP=$(echo "$TEMP" | xargs)
            UTIL=$(echo "$UTIL" | xargs)
            MEM_USED_G=$(echo "$MEM_USED_G" | xargs)
            MEM_TOTAL_G=$(echo "$MEM_TOTAL_G" | xargs)
            POWER=$(echo "$POWER" | xargs)
            MEM_PCT=$(awk "BEGIN {printf \"%.0f\", ($MEM_USED_G/$MEM_TOTAL_G)*100}" 2>/dev/null || echo "0")
            PCIE="${PCIE_INFO[$IDX]}"
            if [ ! -z "$PCIE" ]; then
                IFS='|' read -r BUS GEN_CUR GEN_MAX WIDTH_CUR WIDTH_MAX <<< "$PCIE"
            else
                BUS="N/A"; GEN_CUR="0"; GEN_MAX="0"; WIDTH_CUR="0"; WIDTH_MAX="0"
            fi
            [ ! -z "$GPU_DATA" ] && GPU_DATA="$GPU_DATA,"
            GPU_DATA="${GPU_DATA}{\"idx\":$IDX,\"name\":\"$NAME\",\"driver\":\"$DRIVER\",\"temp\":$TEMP,\"util\":$UTIL,\"memUsed\":$MEM_USED_G,\"memTotal\":$MEM_TOTAL_G,\"memPct\":$MEM_PCT,\"power\":\"$POWER\",\"pciBus\":\"$BUS\",\"pciGenCur\":\"$GEN_CUR\",\"pciGenMax\":\"$GEN_MAX\",\"pciWidthCur\":\"$WIDTH_CUR\",\"pciWidthMax\":\"$WIDTH_MAX\"}"
        done < <(nvidia-smi --query-gpu=index,name,driver_version,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw --format=csv,noheader,nounits 2>/dev/null)
    fi
    
    echo "{\"cpu\":{\"model\":\"$CPU_MODEL\",\"cores\":\"$CPU_CORES\",\"usage\":\"$CPU_USAGE\"},\"mem\":{\"total\":\"$MEM_TOTAL\",\"used\":\"$MEM_USED\",\"free\":\"$MEM_FREE\",\"pct\":\"$MEM_PERCENT\"},\"sys\":{\"os\":\"$OS_NAME\",\"kernel\":\"$KERNEL\",\"uptime\":\"$UPTIME\",\"time\":\"$CURRENT_TIME\"},\"disks\":[${DISKS_HEALTH}],\"partitions\":[${PARTITIONS_DATA}],\"gpus\":[$GPU_DATA]}"
}

generate_page() {
    DATA=$(get_json_data)
    
    echo "HTTP/1.1 200 OK"
    echo "Content-Type: text/html; charset=UTF-8"
    echo "Cache-Control: no-cache"
    echo "Connection: close"
    echo ""
    
    cat << 'HTMLSTART'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width,initial-scale=1.0">
    <title>系统监控中心</title>
    <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;background:#0a0a0f;color:#e2e8f0;min-height:100vh;position:relative}
        .bg{position:fixed;top:0;left:0;width:100%;height:100%;background:radial-gradient(ellipse at 20% 50%,rgba(59,130,246,.15) 0%,transparent 50%),radial-gradient(ellipse at 80% 20%,rgba(147,51,234,.15) 0%,transparent 50%),radial-gradient(ellipse at 40% 80%,rgba(6,182,212,.1) 0%,transparent 50%);z-index:-1}
        .grid-bg{position:fixed;top:0;left:0;width:100%;height:100%;background-image:linear-gradient(rgba(59,130,246,.03) 1px,transparent 1px),linear-gradient(90deg,rgba(59,130,246,.03) 1px,transparent 1px);background-size:50px 50px;z-index:-1}
        .container{max-width:1400px;margin:0 auto;padding:20px}
        header{text-align:center;padding:30px 0;margin-bottom:30px}
        h1{font-size:2.5em;font-weight:700;background:linear-gradient(135deg,#3b82f6,#8b5cf6,#06b6d4);-webkit-background-clip:text;-webkit-text-fill-color:transparent;animation:glow 3s ease-in-out infinite}
        @keyframes glow{0%,100%{filter:drop-shadow(0 0 20px rgba(59,130,246,.5))}50%{filter:drop-shadow(0 0 30px rgba(139,92,246,.7))}}
        .subtitle{color:#64748b;font-size:.9em;letter-spacing:3px;text-transform:uppercase}
        .system-overview{margin-bottom:25px}
        .disk-overview{margin-bottom:25px;max-height:400px}
        .disk-overview .overview-grid{max-height:320px;overflow-y:auto}
        .disk-overview .overview-grid::-webkit-scrollbar{width:8px}
        .disk-overview .overview-grid::-webkit-scrollbar-track{background:rgba(255,255,255,.05);border-radius:4px}
        .disk-overview .overview-grid::-webkit-scrollbar-thumb{background:rgba(59,130,246,.3);border-radius:4px}
        .disk-overview .overview-grid::-webkit-scrollbar-thumb:hover{background:rgba(59,130,246,.5)}
        .overview-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:25px}
        .overview-section{background:rgba(255,255,255,.02);border-radius:12px;padding:18px}
        .section-header{display:flex;align-items:center;gap:10px;font-size:1em;font-weight:600;color:#4fd1c5;margin-bottom:15px}
        .section-header .card-icon{margin-bottom:0;width:32px;height:32px;font-size:1em}
        .gpu-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(350px,1fr));gap:20px}
        .card{background:rgba(15,23,42,.8);border:1px solid rgba(59,130,246,.2);border-radius:16px;padding:24px;backdrop-filter:blur(10px);position:relative;overflow:hidden;transition:all .3s ease}
        .card::before{content:'';position:absolute;top:0;left:0;right:0;height:2px;background:linear-gradient(90deg,#3b82f6,#8b5cf6,#06b6d4)}
        .card:hover{transform:translateY(-4px);border-color:rgba(59,130,246,.4);box-shadow:0 20px 40px rgba(59,130,246,.15)}
        .card-icon{width:40px;height:40px;border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:1.2em;margin-bottom:15px}
        .card-icon.cpu{background:linear-gradient(135deg,#3b82f6,#1d4ed8)}
        .card-icon.mem{background:linear-gradient(135deg,#8b5cf6,#6d28d9)}
        .card-icon.disk{background:linear-gradient(135deg,#06b6d4,#0891b2)}
        .card-icon.sys{background:linear-gradient(135deg,#10b981,#059669)}
        .card-icon.gpu{background:linear-gradient(135deg,#f59e0b,#d97706)}
        .card-title{font-size:1.1em;font-weight:600;color:#f1f5f9;margin-bottom:20px;display:flex;align-items:center;gap:12px}
        .row{display:flex;justify-content:space-between;align-items:center;padding:10px 0;border-bottom:1px solid rgba(255,255,255,.05)}
        .row:last-of-type{border-bottom:none}
        .label{color:#94a3b8;font-size:.9em}
        .value{color:#f1f5f9;font-weight:500}
        .prog-section{margin-top:15px}
        .prog-header{display:flex;justify-content:space-between;margin-bottom:8px;font-size:.85em}
        .prog-bar{width:100%;height:6px;background:rgba(255,255,255,.1);border-radius:3px;overflow:hidden}
        .prog-fill{height:100%;border-radius:3px;background:linear-gradient(90deg,#3b82f6,#8b5cf6);transition:width .5s ease}
        .prog-fill.warn{background:linear-gradient(90deg,#f59e0b,#d97706)}
        .prog-fill.danger{background:linear-gradient(90deg,#ef4444,#dc2626)}
        @media(max-width:768px){.container{padding:15px}h1{font-size:1.8em}.overview-grid,.gpu-grid{grid-template-columns:1fr;gap:15px}.card{padding:20px}}
        @media(max-width:480px){h1{font-size:1.5em}.subtitle{font-size:.8em}.card{padding:16px}}
    </style>
</head>
<body>
<div class="bg"></div>
<div class="grid-bg"></div>
<div class="container">
    <header>
        <h1>⚡ 系统监控中心</h1>
        <div class="subtitle">System Monitor Dashboard</div>
    </header>
    <div class="system-overview card">
        <div class="card-title" style="margin-bottom:25px">📊 系统概览</div>
        <div class="overview-grid">
            <div class="overview-section">
                <div class="section-header"><div class="card-icon cpu">💻</div>CPU 信息</div>
                <div id="cpu"></div>
            </div>
            <div class="overview-section">
                <div class="section-header"><div class="card-icon mem">🧠</div>内存信息</div>
                <div id="mem"></div>
            </div>
            <div class="overview-section">
                <div class="section-header"><div class="card-icon sys">🖥️</div>系统信息</div>
                <div id="sys"></div>
            </div>
        </div>
    </div>
    <div class="disk-overview card">
        <div class="card-title" style="margin-bottom:25px">💾 磁盘信息</div>
        <div class="overview-grid">
            <div class="overview-section">
                <div class="section-header">🔍 物理磁盘健康度</div>
                <div id="diskHealth"></div>
            </div>
            <div class="overview-section">
                <div class="section-header">📂 磁盘分区使用情况</div>
                <div id="diskPartitions"></div>
            </div>
        </div>
    </div>
    <div class="gpu-grid" id="gpuGrid"></div>
</div>
<script>
var DATA=
HTMLSTART
    
    echo "$DATA"
    
    cat << 'HTMLEND'
;
function pc(v){v=parseFloat(v);return v>80?'danger':v>60?'warn':'';}
var gpuCards=[];
function render(d){
    document.getElementById('cpu').innerHTML='<div class="row"><span class="label">处理器</span><span class="value">'+d.cpu.model+'</span></div><div class="row"><span class="label">核心数</span><span class="value">'+d.cpu.cores+' 核</span></div><div class="prog-section"><div class="prog-header"><span class="label">使用率</span><span class="value">'+d.cpu.usage+'%</span></div><div class="prog-bar"><div class="prog-fill '+pc(d.cpu.usage)+'" style="width:'+d.cpu.usage+'%"></div></div></div>';
    document.getElementById('mem').innerHTML='<div class="row"><span class="label">总容量</span><span class="value">'+d.mem.total+'</span></div><div class="row"><span class="label">已使用</span><span class="value">'+d.mem.used+'</span></div><div class="row"><span class="label">可用</span><span class="value">'+d.mem.free+'</span></div><div class="prog-section"><div class="prog-header"><span class="label">使用率</span><span class="value">'+d.mem.pct+'%</span></div><div class="prog-bar"><div class="prog-fill '+pc(d.mem.pct)+'" style="width:'+d.mem.pct+'%"></div></div></div>';
    var uptimeStr=d.sys.uptime;
    var uptimeMatch=uptimeStr.match(/(\d+)\s*hour[s]?,\s*(\d+)\s*minute[s]?/);
    if(!uptimeMatch){uptimeMatch=uptimeStr.match(/up\s+(\d+)\s*hour[s]?,\s*(\d+)\s*minute[s]?/);}
    var days=0,hours=0,minutes=0;
    if(uptimeMatch){
        hours=parseInt(uptimeMatch[1])||0;
        minutes=parseInt(uptimeMatch[2])||0;
        days=Math.floor(hours/24);
        hours=hours%24;
    }else{
        var dayMatch=uptimeStr.match(/(\d+)\s*day[s]?/);
        var hourMatch=uptimeStr.match(/(\d+)\s*hour[s]?/);
        var minMatch=uptimeStr.match(/(\d+)\s*minute[s]?/);
        if(dayMatch)days=parseInt(dayMatch[1])||0;
        if(hourMatch)hours=parseInt(hourMatch[1])||0;
        if(minMatch)minutes=parseInt(minMatch[1])||0;
    }
    var uptimeFormatted=days+'天'+hours+'时'+minutes+'分';
    document.getElementById('sys').innerHTML='<div class="row"><span class="label">操作系统</span><span class="value">'+d.sys.os+'</span></div><div class="row"><span class="label">运行时间</span><span class="value">'+uptimeFormatted+'</span></div>';
    var healthHtml='';
    if(d.disks&&d.disks.length>0){
        d.disks.forEach(function(disk){
            var healthColor=disk.health==='PASSED'?'#10b981':'#ef4444';
            var healthIcon=disk.health==='PASSED'?'✓':'✗';
            var pctColor=disk.healthPct>=80?'#10b981':disk.healthPct>=60?'#f59e0b':'#ef4444';
            var hours=parseInt(disk.hours);
            var years=Math.floor(hours/24/365);
            var months=Math.floor((hours-years*365*24)/24/30);
            var days=Math.floor((hours-years*365*24-months*30*24)/24);
            var runtimeStr=years+'年'+months+'月'+days+'天';
            healthHtml+='<div style="margin-bottom:20px;padding-bottom:15px;border-bottom:1px solid rgba(255,255,255,.05)"><div class="row"><span class="label" style="font-weight:600;color:#4fd1c5">/dev/'+disk.disk+'</span><span class="value" style="color:'+healthColor+'">'+healthIcon+' '+disk.health+'</span></div><div class="row"><span class="label">型号</span><span class="value">'+disk.model+'</span></div><div class="row"><span class="label">健康度</span><span class="value" style="color:'+pctColor+'">'+disk.healthPct+'%</span></div><div class="row"><span class="label">运行时间</span><span class="value">'+disk.hours+' 小时 ('+runtimeStr+')</span></div><div class="row"><span class="label">温度</span><span class="value">'+(disk.temp!=='N/A'?disk.temp+'°C':disk.temp)+'</span></div></div>';
        });
    }else{
        healthHtml='<div class="row"><span class="value" style="color:#64748b">暂无数据</span></div>';
    }
    document.getElementById('diskHealth').innerHTML=healthHtml;
    var partHtml='';
    if(d.partitions&&d.partitions.length>0){
        d.partitions.forEach(function(p){
            partHtml+='<div style="margin-bottom:15px"><div class="row"><span class="label">'+p.mount+'</span><span class="value">'+p.dev+'</span></div><div class="row"><span class="label">容量</span><span class="value">'+p.size+' (已用 '+p.used+')</span></div><div class="prog-section"><div class="prog-header"><span class="label">使用率</span><span class="value">'+p.pct+'%</span></div><div class="prog-bar"><div class="prog-fill '+pc(p.pct)+'" style="width:'+p.pct+'%"></div></div></div></div>';
        });
    }else{
        partHtml='<div class="row"><span class="value" style="color:#64748b">暂无数据</span></div>';
    }
    document.getElementById('diskPartitions').innerHTML=partHtml;
    if(d.gpus&&d.gpus.length>0){
        var grid=document.getElementById('gpuGrid');
        if(gpuCards.length===0){
            d.gpus.forEach(function(g,i){
                var card=document.createElement('div');
                card.className='card';
                card.id='gpuCard'+i;
                card.innerHTML='<div class="card-title"><div class="card-icon gpu">🎮</div>GPU '+g.idx+': '+g.name+'</div><div id="gpuContent'+i+'"></div>';
                grid.appendChild(card);
                gpuCards.push(card);
            });
        }
        d.gpus.forEach(function(g,i){
            var pciSpeed='PCIe '+g.pciGenCur+'.0 x'+g.pciWidthCur;
            var pciMax='PCIe '+g.pciGenMax+'.0 x'+g.pciWidthMax;
            document.getElementById('gpuContent'+i).innerHTML='<div class="row"><span class="label">PCIe 地址</span><span class="value">'+g.pciBus+'</span></div><div class="row"><span class="label">当前速率</span><span class="value">'+pciSpeed+'</span></div><div class="row"><span class="label">最大速率</span><span class="value">'+pciMax+'</span></div><div class="row"><span class="label">驱动版本</span><span class="value">'+g.driver+'</span></div><div class="row"><span class="label">温度</span><span class="value">'+g.temp+'°C</span></div><div class="row"><span class="label">功耗</span><span class="value">'+g.power+' W</span></div><div class="prog-section"><div class="prog-header"><span class="label">GPU 使用率</span><span class="value">'+g.util+'%</span></div><div class="prog-bar"><div class="prog-fill '+pc(g.util)+'" style="width:'+g.util+'%"></div></div></div><div class="prog-section"><div class="prog-header"><span class="label">显存 ('+g.memUsed+'M / '+g.memTotal+'M)</span><span class="value">'+g.memPct+'%</span></div><div class="prog-bar"><div class="prog-fill '+pc(g.memPct)+'" style="width:'+g.memPct+'%"></div></div></div>';
        });
    }
}
render(DATA);
</script>
</body>
</html>
HTMLEND
}

while true; do
    generate_page | nc -l -p $PORT -q 1 > /dev/null 2>&1
done
MONITOR_EOF

    chmod +x "$INSTALL_DIR/monitor.sh"
}

# 创建systemd服务
create_service() {
    echo "创建systemd服务..."
    
    cat > /etc/systemd/system/system-monitor.service << EOF
[Unit]
Description=System Monitor Web Dashboard
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash $INSTALL_DIR/monitor.sh
Restart=always
RestartSec=5
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

# 主安装流程
main() {
    # 1. 清理端口占用
    cleanup_port
    
    # 2. 安装依赖
    install_dependencies
    
    # 3. 停止旧服务
    echo "停止旧服务..."
    systemctl is-active --quiet system-monitor && systemctl stop system-monitor 2>/dev/null || true
    
    # 4. 创建监控脚本
    create_monitor_script
    
    # 5. 创建systemd服务
    create_service
    
    # 6. 启动服务
    echo "启动系统监控服务..."
    systemctl enable system-monitor
    systemctl start system-monitor
    
    # 7. 等待服务启动
    sleep 2
    
    # 8. 检查服务状态
    if systemctl is-active --quiet system-monitor; then
        echo ""
        echo "========================================="
        echo "  ✅ 安装成功！"
        echo "========================================="
        echo ""
        echo "访问地址: http://$(hostname -I | awk '{print $1}'):8888"
        echo ""
        echo "常用命令:"
        echo "  查看状态: systemctl status system-monitor"
        echo "  查看日志: tail -f $LOG_FILE"
        echo "  重启服务: systemctl restart system-monitor"
        echo "  停止服务: systemctl stop system-monitor"
        echo ""
        echo "特性:"
        echo "  - 每30分钟自动检查并安装依赖"
        echo "  - 日志自动轮转（限制10MB）"
        echo "  - 端口冲突自动清理"
        echo ""
    else
        echo ""
        echo "❌ 服务启动失败，请查看日志: tail -f $LOG_FILE"
        exit 1
    fi
}

# 执行安装
main
