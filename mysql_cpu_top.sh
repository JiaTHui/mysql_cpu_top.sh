#/bin/bash
# crontab needs to be configured to start the script at 0:00 every day, and the script will automatically exit after running for 24 hours
# 0 0 * * * /usr/bin/bash /data/goldendb/zxdb1/log/cpu >/dev/null 2>&1 &
# Minimum permission: grant process on *.* to dbros;
# Note:
# Since this script has many detection items, in addition to Com_select, there are also top, processlist, and memory
# This will cause show Com_select to not be strictly continuous, and may miss a period of time, so the final statistics will be about 8% smaller
# For example, the script data: the total QPS between 2025-07-01 15:10:00 and 2025-07-01 15:20:00 is: 798205, query the total QPS separately [2025-07-01 15:20:07] QPS: 864756, but because insight monitoring will send some queries regularly, the missed ones will offset these

# Configuration instructions:
# Need to configure the log directory: log_dir
# USER, PSWD, PORT, HOST are the connection strings of the connection DN
# To avoid switching monitoring errors CPU values, you need to configure this script for each DN
# Please check whether there is a mysql client under root

# auth:Liu Huiming https://github.com/JiaTHui
# 
# write: 2025/03/19
# update : 2025/06/30

log () {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
	local log="$2"
    echo -e "${msg}" >> "$log"

    if [[ ${VERBOSE} == true ]]; then
        echo -e "${msg}"
    fi
}

log_dir="/test/cpu/log"
logfile=$log_dir/$(date +'%Y-%m-%d')-CPU-QPS.log
active_session_logfile=$log_dir/$(date +'%Y-%m-%d')-active-session.log
cpu_top=$log_dir/$(date +'%Y-%m-%d')-cpu-top.log
memory_logfile=$log_dir/$(date +'%Y-%m-%d')-mem-monitor.log

#Calculate the end time after 24 hours (24 * 60 * 60=86400)
start_time=$(date +%s)
end_time=$((start_time + 86400 ))
VERBOSE=false
USER="dbros"
PSWD="123456"
PORT="3306"
HOST="192.168.58.60"
cores=$(nproc)
moni_interval=3
max_cpu=60
# Counter, record the number of seconds that have passed
SECONDS=0 

memory_monitor(){
	MemTotal=0; Memfree=0; MemAvailable=0
	Buffers=0; Cached=0; SReclaimable=0; Shmem=0
	Active=0; Inactive=0; SwapTotal=0; SwapFree=0
	Dirty=0; Writeback=0; CommitLimit=0; Committed_AS=0

	# Read /proc/meminfo line by line to view the resource information used by this process. Use /proc/self/status
	while read -r key value _; do
		case "$key" in
			MemTotal:)	MemTotal=$value ;;			# 总内存
			MemFree:)	MemFree=$value ;;			# 空闲内存
			MemAvailable:)	MemAvailable=$value ;;	# 可用内存 （包含可回收的缓冲）
			Buffers:)	Buffers=$value ;;			# 用于缓冲区的内存
			Cached:)	Cached=$value ;;			# 用于页缓冲的内存
			SReclaimable:)	SReclaimable=$value ;;	# 可回收 Slab (内核) 缓存
			Shmem:)	Shmem=$value;;					# 共享内存使用量
			Active:)	Active=$value ;;			# 活跃内存页
			Inactive:)	Inactive=$value ;;			# 不活跃内存页
			SwapTotal:)	SwapTotal=$value ;;			# 总 Swap 交换区
			SwapFree:)	SwapFree=$value ;;			# 空闲 Swap 交换区
			Dirty:)	Dirty=$value ;;					# 已修改但未写回磁盘的页数
			Writeback:)	Writeback=$value ;;			# 正在写回磁盘的页数
			CommitLimit:) CommitLimit=$value ;;		# 可分配给进程的虚拟内存总量上限 (RAM + swap * overcommit_ratio)
			Committed_AS:) Committed_AS=$value ;;	# 当前已分配 （承诺）的虚拟内存总量
			*) ;; #其他字段忽略
		esac
	done < /proc/meminfo
	
	#计算已用、缓存 + 缓冲
	MemTotal_GB=$(( MemTotal/1024/1024 ))
	MemUsed=$(( (MemTotal - MemAvailable)/1024/1024 ))
	CacheBuffers=$(( (Buffers + Cached + SReclaimable )/1024/1024 ))
	CommitLimit_GB=$(( CommitLimit/1024/1024 ))
	Committed_AS_GB=$(( Committed_AS/1024/1024 ))
	
	log "总内存:${MemTotal_GB}GB 已使用:${MemUsed}GB  缓存+缓冲:${CacheBuffers}GB Dirty:${Dirty} Writeback:${Writeback} CommitLimit:${CommitLimit_GB}GB Committed_AS:${Committed_AS_GB}GB" "$memory_logfile"
	Ratio=$(( MemUsed*100/MemTotal_GB ))
	if (( Ratio > 80 )); then
		log "已使用内存比例:${Ratio}" "$memory_logfile"
		cat /proc/meminfo >> $memory_logfile
		
	fi
}

while true; do
	current_time=$(date +%s)
	
	if [ $current_time -ge $end_time ]; then
	    log "已运行 24 小时，即将退出..." "$logfile"
	    break
	fi
	QPS_V1=$(mysql -u"${USER}" -p"${PSWD}" -h"${HOST}" -P"${PORT}" -A -NB -c -e"show global status like 'Com_select';" 2>/dev/null |awk 'NR==1{print $2}')
    sleep $moni_interval
	QPS_V2=$(mysql -u"${USER}" -p"${PSWD}" -h"${HOST}" -P"${PORT}" -A -NB -c -e"show global status like 'Com_select';" 2>/dev/null |awk 'NR==1{print $2}')
    QPS=$(( QPS_V2 - QPS_V1 - 2))
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
	
    ACTIVE_SESSIONS=$(mysql -u"${USER}" -p"${PSWD}" -h"${HOST}" -P"${PORT}" -A -NB -c -e"select count(*) from performance_schema.processlist where COMMAND <>'Sleep';" 2>/dev/null)
	log "CPU 使用率：${CPU_USAGE}%  活跃会话数:${ACTIVE_SESSIONS} QPS:${QPS} 占用最高：user:${proc_user} comm:${proc_cmd} CPU:${proc_cpu}%" "$logfile"
	
	if awk "BEGIN { exit !($CPU_USAGE > $max_cpu) }"; then
	    ACTIVE_SESSIONS_QUERY=$(mysql -u"${USER}" -p"${PSWD}" -h"${HOST}" -P"${PORT}" -A -c -t -e"select /*+ SET_VAR(sql_mode='STRICT_TRANS_TABLES')  */ group_concat(ID) 'ID',user,DB,Command, group_concat(TIME) 'Time',STATE,INFO,count(*) from performance_schema.processlist where COMMAND<>'Sleep' and user<>'repl' group by user,DB,Command,STATE,substring(INFO,1,30) order by count(*) asc\G" 2>/dev/null)
		top_first20=$(top -bn1|head -20)
	    log "CPU 使用率：${CPU_USAGE}%  活跃会话数:${ACTIVE_SESSIONS} QPS:${QPS} 占用最高：user:${proc_user} comm:${proc_cmd} CPU:${proc_cpu}% 活跃会话信息：\n$ACTIVE_SESSIONS_QUERY\n" "$active_session_logfile"
		log "CPU 使用率：${CPU_USAGE}%  活跃会话数:${ACTIVE_SESSIONS} QPS:${QPS} 占用最高：user:${proc_user} comm:${proc_cmd} CPU:${proc_cpu}% top 20 信息：\n$top_first20\n" "$cpu_top"
		
	fi

	# 判断如果过了 10 的倍数秒就监控一次内存
	if (( SECONDS % 10 == 0 )); then
		memory_monitor
	fi

	
done
