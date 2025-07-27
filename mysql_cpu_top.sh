#/bin/bash

# DN monitoring script

# Note:
# Since this script has many detection items, in addition to Com_select, there are also top, processlist, and memory
# This will cause show Com_select to not be strictly continuous, and may miss a period of time, so the final statistics will be about 8% smaller
# For example, the script data: the total QPS between 2025-07-01 15:10:00 and 2025-07-01 15:20:00 is: 798205, and the total QPS [2025-07-01 15:20:07] QPS: 864756 is queried separately, but because insight monitoring will send some queries regularly, the missed ones offset these

# [Important] Configuration instructions:

# Configuration items to be configured:
# 1. log_dir: log directory, it is recommended to create a CPU directory under the DN user's home directory to store logs such as /data/goldendb/zxdb1/CPU, and the script can also be placed here
# 2. USER, PSWD, PORT, HOST are the connection strings for connecting to the DN
# 3. client: the absolute path of the mysql client

# The script should use the scheduled task crontab to configure the script to start at 0:00 every day, and the script will automatically exit after running for 24 hours
# Scheduled task command: 0 0 * * * /usr/bin/bash /data/db1/log/CPU/cpu_qps_moni_zxdb1.sh >/dev/null 2>&1 &
# Start the script bash /data/goldendb/zxdb1/log/cpu_qps_moni_zxdb1.sh separately

# To avoid monitoring the wrong CPU value after DN switching, the script needs to be configured for each DN
# Script naming rule: cpu_qps_moni_<DN user name>.sh

# Minimum monitoring permissions: grant process on *.* to db_moni;

# Generate 5 files after enabling. The first 4 files will generate a file corresponding to a date every day:
# 1. 2025-07-07-CPU-QPS.log: Regularly monitor the CPU usage of DN, QPS
# 2. 2025-07-07-active-session.log: When the CPU reaches 60, pull the content of performance_schema.processlist. At this time, the log information is the SQL that causes the CPU to surge
# 3. 2025-07-07-mem-monitor.log: The script starts with a multiple of 10 to monitor memory. If it is greater than 80, it will output /proc/meminfo
# 4. 2025-07-07-cpu-top.log: When the CPU reaches 60, pull the value of the top command. At this time, the log information can be used to view the specific process usage
# 5. delete-log.log : Every time the script is started, it searches for logs from 60 days ago and cleans them up, and outputs the cleaned logs. The regular expression matches '.*(CPU-QPS|active-session|cpu-top|mem-monitor)\.log$'

# Monitoring indicator explanation:
# CPU usage: ${CPU_USAGE}% Current CPU value
# Number of active sessions: ${ACTIVE_SESSIONS} Current active sessions
# QPS: ${QPS} Number of SELECTs in a monitoring cycle
# TPS: ${TPS} Number of transactions in a monitoring cycle
# RPS: ${RPS} Number of rollbacks in a monitoring cycle
# XA_TPS: ${XA_TPS} Number of XA transactions in a monitoring cycle
# XA_RPS: ${XA_RPS} Number of XA transaction rollbacks in a monitoring cycle
# DT: ${DT}, ${T} Number of DROP TABLE/TRUNCATE TABLE in a monitoring cycle
# 占用最高：user:${proc_user} comm:${proc_cmd} CPU:${proc_cpu}%  The process with the highest current CPU value. If it is not the mysqld process name of the current DN user, check 2025-07-07-cpu-top.log log to obtain the process with the highest usage

# auth:Liu Huiming https://github.com/JiaTHui
# 
# write: 2025/03/19
# update : 2025/07/07

# Counter, records the number of seconds that have passed
SECONDS=0

cleanup() {
   if [[ "$1" != "exit_clean" ]]; then
       echo "捕获到信号，正在清理资源..."
       rm -rf $temp_dir 2>/dev/null
       echo "清理完成，脚本退出"
   fi
   exit 0
}

trap 'cleanup' SIGTERM SIGINT
trap 'cleanup exit_clean' EXIT

log () {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
	local log="$2"
    echo -e "${msg}" >> "$log"

    if [[ ${VERBOSE} == true ]]; then
        echo -e "${msg}"
    fi
}

log_dir="/test/cpu/c"
logfile=$log_dir/$(date +'%Y-%m-%d')-CPU-QPS.log
active_session_logfile=$log_dir/$(date +'%Y-%m-%d')-active-session.log
cpu_top=$log_dir/$(date +'%Y-%m-%d')-cpu-top.log
memory_logfile=$log_dir/$(date +'%Y-%m-%d')-mem-monitor.log
DELETE_LOG=$log_dir/delete-log.log

#Calculate the end time after 24 hours (24 * 60 * 60=86400)
start_time=$(date +%s)
end_time=$((start_time + 86400 ))
VERBOSE=false
USER="dbros"
PSWD="123456"
PORT="3306"
HOST="192.168.58.60"
# Client path
client="/application/mysql_8_3306/bin/mysql"
cores=$(nproc)
# Monitoring interval, based on 3 seconds, no need to change if there is no special requirement
moni_interval=3
# When the CPU value is greater than 60, output the value of SQL and top commands
max_cpu=60
# When the memory value is greater than 80, output the /proc/meminfo
max_mem=80
# Check the log directory and clean up the logs 60 days ago when running the script every day
DELETE_DAYS=60

Ratio=0

memory_monitor(){
	MemTotal=0; Memfree=0; MemAvailable=0
	Buffers=0; Cached=0; SReclaimable=0; Shmem=0
	Active=0; Inactive=0; SwapTotal=0; SwapFree=0
	Dirty=0; Writeback=0; CommitLimit=0; Committed_AS=0

	# Read /proc/meminfo line by line to view the resource information used by this process. Use /proc/self/status
	while read -r key value _; do
		case "$key" in
			MemTotal:)	MemTotal=$value ;;			
			MemFree:)	MemFree=$value ;;			
			MemAvailable:)	MemAvailable=$value ;;	
			Buffers:)	Buffers=$value ;;			
			Cached:)	Cached=$value ;;			
			SReclaimable:)	SReclaimable=$value ;;	
			Shmem:)	Shmem=$value;;					
			Active:)	Active=$value ;;			
			Inactive:)	Inactive=$value ;;			
			SwapTotal:)	SwapTotal=$value ;;			
			SwapFree:)	SwapFree=$value ;;			
			Dirty:)	Dirty=$value ;;					
			Writeback:)	Writeback=$value ;;			
			CommitLimit:) CommitLimit=$value ;;		
			Committed_AS:) Committed_AS=$value ;;	
			*) ;; # Other fields are ignored
		esac
	done < /proc/meminfo
	
	#Calculate used, cache + buffer
	MemTotal_GB=$(( MemTotal/1024/1024 ))
	MemUsed=$(( (MemTotal - MemAvailable)/1024/1024 ))
	CacheBuffers=$(( (Buffers + Cached + SReclaimable )/1024/1024 ))
	CommitLimit_GB=$(( CommitLimit/1024/1024 ))
	Committed_AS_GB=$(( Committed_AS/1024/1024 ))
	
	log "总内存:${MemTotal_GB}GB 已使用:${MemUsed}GB  缓存+缓冲:${CacheBuffers}GB Dirty:${Dirty} Writeback:${Writeback} CommitLimit:${CommitLimit_GB}GB Committed_AS:${Committed_AS_GB}GB" "$memory_logfile"
	Ratio=$(( MemUsed*100/MemTotal_GB ))
	if (( Ratio > $max_mem )); then
		log "已使用内存比例:${Ratio}" "$memory_logfile"
		cat /proc/meminfo >> $memory_logfile
		
	fi
}

log "查找 ${DELETE_DAYS} 天前的日志进行删除..." "$DELETE_LOG"
DELETE_FILES=$(find ${log_dir} -type f -mtime +${DELETE_DAYS} \
-regextype posix-extended \
-regex '.*(CPU-QPS|active-session|cpu-top|mem-monitor)\.log$' \
-print
)
if [ -n "$DELETE_FILES" ]; then
	log "找到以下文件，将开始删除：" "$DELETE_LOG"
	# 打印列表
	for f in $DELETE_FILES; do 
		echo "  $f" >> "$DELETE_LOG"
	done
	
	# Clear the deletion record log
	> "$DELETE_LOG"
	
	for filename in ${DELETE_FILES}; do
		log "Rotation: deleting ${filename}" "$DELETE_LOG"
		rm -f "${filename}" && \
			log "已删除: ${filename}" "$DELETE_LOG" || \
			log "删除失败: ${filename}" "$DELETE_LOG"
	done
else
	log "没有符合条件的文件，无需删除。" "$DELETE_LOG"
fi

# Create a temporary directory and configuration file
temp_dir=$(mktemp -d -p "$log_dir")
mkdir -p "$temp_dir/procps"

# top Configuration
cat << 'EOF' | base64 -d > "$temp_dir/procps/toprc"
dG9wJ3MgQ29uZmlnIEZpbGUgKExpbnV4IHByb2Nlc3NlcyB3aXRoIHdpbmRvd3MpCklkOmksIE1v
ZGVfYWx0c2NyPTAsIE1vZGVfaXJpeHBzPTEsIERlbGF5X3RpbWU9My4wLCBDdXJ3aW49MApEZWYJ
ZmllbGRzY3VyPaWos7S7vcDEt7q5xaYnKSorLC0uLzAxMjU2uDw+P0FCQ0ZHSElKS8zNTk9Q0VJT
VFVWV1hZWtvcXV5fYGFiY2RlZmdoaWoKCXdpbmZsYWdzPTE5Mjc1Niwgc29ydGluZHg9MjEsIG1h
eHRhc2tzPTAsIGdyYXBoX2NwdXM9MCwgZ3JhcGhfbWVtcz0wCglzdW1tY2xyPTEsIG1zZ3NjbHI9
MSwgaGVhZGNscj0zLCB0YXNrY2xyPTEKSm9iCWZpZWxkc2N1cj2lprm3uiiztMS7vUA8p8UpKiss
LS4vMDEyNTY4Pj9BQkNGR0hJSktMTU5PUFFSU1RVVldYWVpbXF1eX2BhYmNkZWZnaGlqCgl3aW5m
bGFncz0xOTM4NDQsIHNvcnRpbmR4PTAsIG1heHRhc2tzPTAsIGdyYXBoX2NwdXM9MCwgZ3JhcGhf
bWVtcz0wCglzdW1tY2xyPTYsIG1zZ3NjbHI9NiwgaGVhZGNscj03LCB0YXNrY2xyPTYKTWVtCWZp
ZWxkc2N1cj2lurs8vb6/wMFNQk7DRDM0t8UmJygpKissLS4vMDEyNTY4OUZHSElKS0xPUFFSU1RV
VldYWVpbXF1eX2BhYmNkZWZnaGlqCgl3aW5mbGFncz0xOTM4NDQsIHNvcnRpbmR4PTIxLCBtYXh0
YXNrcz0wLCBncmFwaF9jcHVzPTAsIGdyYXBoX21lbXM9MAoJc3VtbWNscj01LCBtc2dzY2xyPTUs
IGhlYWRjbHI9NCwgdGFza2Nscj01ClVzcglmaWVsZHNjdXI9paanqKqwube6xMUpKywtLi8xMjM0
NTY4Ozw9Pj9AQUJDRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl9gYWJjZGVmZ2hpagoJd2luZmxh
Z3M9MTkzODQ0LCBzb3J0aW5keD0zLCBtYXh0YXNrcz0wLCBncmFwaF9jcHVzPTAsIGdyYXBoX21l
bXM9MAoJc3VtbWNscj0zLCBtc2dzY2xyPTMsIGhlYWRjbHI9MiwgdGFza2Nscj0zCkZpeGVkX3dp
ZGVzdD0wLCBTdW1tX21zY2FsZT0yLCBUYXNrX21zY2FsZT0yLCBaZXJvX3N1cHByZXNzPTAKCg==
EOF


names_str="'Com_select','Com_commit','Com_rollback','Com_xa_commit','Com_xa_rollback','Com_drop_table','Com_truncate'"

get_stats(){
	${mysql_client} -u"${USER}" -p"${PSWD}" \
	-h"${HOST}" -P"${PORT}" -A -NB -c \
	-e"SHOW GLOBAL STATUS WHERE Variable_name IN (${names_str});" 2>/dev/null \
	|awk '
		$1=="Com_select" 		{s=$2}
		$1=="Com_commit" 		{c=$2}
		$1=="Com_rollback" 		{r=$2}
		$1=="Com_xa_commit" 	{xc=$2}
		$1=="Com_xa_rollback" 	{xr=$2}
		$1=="Com_drop_table" 	{dt=$2}
		$1=="Com_truncate" 		{t=$2}
		END {print s, c, r, xc, xr, dt, t}
		'
}

while true; do
	current_time=$(date +%s)
	
	if [ $current_time -ge $end_time ]; then
	    log "已运行 24 小时，即将退出..." "$logfile"
	    break
	fi
	
	read QPS_V1 TPS_V1 RPS_V1 XA_TPS_V1 XA_RPS_V1 DT_V1 T_V1 < <( get_stats )
	sleep $moni_interval
	read QPS_V2 TPS_V2 RPS_V2 XA_TPS_V2 XA_RPS_V2 DT_V2 T_V2 < <( get_stats )
	
    QPS=$(( QPS_V2 - QPS_V1 - 2))
	TPS=$(( TPS_V2 - TPS_V1))
	RPS=$(( RPS_V2 - RPS_V1))
	XA_TPS=$(( XA_TPS_V2 - XA_TPS_V1))
	XA_RPS=$(( XA_RPS_V2 - XA_RPS_V1))
	DT=$(( DT_V2 - DT_V1))
	T=$(( T_V2 - T_V1))
	
	read CPU_USAGE proc_user proc_cmd proc_cpu < <(
		top -b -n1|awk -v c=$cores '
		/%Cpu\(s\)/	{ CPU_USAGE = 100 - $8}
		/^ *PID/	{ header = 1; next}
		header && !got {
		  proc_user = $2
		  proc_cmd = $12
		  proc_cpu = $9 / c
		  got = 1
		}
		END { printf("%.2f %s %s %.2f", CPU_USAGE, proc_user, proc_cmd, proc_cpu) }
		'
	)
	
    ACTIVE_SESSIONS=$(${mysql_client} -u"${USER}" -p"${PSWD}" -h"${HOST}" -P"${PORT}" -A -NB -c -e"select count(*) from performance_schema.processlist where COMMAND <>'Sleep';" 2>/dev/null)
	log "CPU 使用率：${CPU_USAGE}%  活跃会话数:${ACTIVE_SESSIONS} QPS:${QPS} TPS:${TPS} RPS:${RPS} XA_TPS:${XA_TPS} XA_RPS:${XA_RPS} DT:${DT},${T} 占用最高：user:${proc_user} comm:${proc_cmd} CPU:${proc_cpu}%" "$logfile"
	
	if awk "BEGIN { exit !($CPU_USAGE > $max_cpu ) }"; then
	    ACTIVE_SESSIONS_QUERY=$(${mysql_client} -u"${USER}" -p"${PSWD}" -h"${HOST}" -P"${PORT}" -A -c -t -e"select group_concat(ID) 'ID',user,DB,Command, group_concat(TIME) 'Time',STATE,INFO,count(*) from performance_schema.processlist where COMMAND<>'Sleep' and user<>'repl' group by user,DB,Command,STATE,substring(INFO,1,30) order by count(*) asc\G" 2>/dev/null)
		top_first20=$(top -bn1|head -20)
	    log "CPU 使用率：${CPU_USAGE}%  活跃会话数:${ACTIVE_SESSIONS} QPS:${QPS} TPS:${TPS} RPS:${RPS} XA_TPS:${XA_TPS} XA_RPS:${XA_RPS} DT:${DT},${T} 占用最高：user:${proc_user} comm:${proc_cmd} CPU:${proc_cpu}% 活跃会话信息：\n$ACTIVE_SESSIONS_QUERY\n" "$active_session_logfile"
		log "CPU 使用率：${CPU_USAGE}%  活跃会话数:${ACTIVE_SESSIONS} QPS:${QPS} TPS:${TPS} RPS:${RPS} XA_TPS:${XA_TPS} XA_RPS:${XA_RPS} DT:${DT},${T} 占用最高：user:${proc_user} comm:${proc_cmd} CPU:${proc_cpu}% top 20 信息：\n$top_first20\n" "$cpu_top"
		
	fi
	
	# If a multiple of 10 seconds has passed, monitor the memory once
	if (( SECONDS % 10 == 0 )); then
		memory_monitor
		if awk "BEGIN { exit !($Ratio > $max_mem ) }"; then
			# 指定 XDG_CONFIG_HOME
			mem_top_first20=$(XDG_CONFIG_HOME="$temp_dir" top -bn1 -w 200 -o %MEM|head -20)
			log "CPU 使用率：${CPU_USAGE}% 内存使用率：${Ratio}% 活跃会话数:${ACTIVE_SESSIONS} QPS:${QPS} TPS:${TPS} RPS:${RPS} XA_TPS:${XA_TPS} XA_RPS:${XA_RPS} DT:${DT},${T} 占用最高：user:${proc_user} comm:${proc_cmd} CPU:${proc_cpu}% top 20 信息：\n$mem_top_first20\n" "$cpu_top"
			
		fi
	fi

done

# Clean up toprc temporary files
rm -rf "$temp_dir" && \
    log "已删除 TOP 临时目录: ${temp_dir}" "$logfile" || \
    log "删除TOP 临时目录失败: ${temp_dir}" "$logfile"
