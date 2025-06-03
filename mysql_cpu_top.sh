#/bin/bash
# auth:https://github.com/JiaTHui
# write: 2025/03/19
# update : 2025/05/28

log () {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
	local log="$2"
    echo -e "${msg}" >> "$log"

    if [[ ${VERBOSE} == true ]]; then
        echo -e "${msg}"
    fi
}

log_dir="/moni/log"
logfile=$log_dir/$(date +'%Y-%m-%d')-CPU-QPS.log
active_session_logfile=$log_dir/$(date +'%Y-%m-%d')-active-session.log
cpu_top=$log_dir/$(date +'%Y-%m-%d')-cpu-top.log
#计算 24 小时后的结束时间 (24 * 60 * 60=86400)
start_time=$(date +%s)
end_time=$((start_time + 86400 ))
VERBOSE=false
USER="dbros"
PSWD="123456"
PORT="3306"
HOST="192.168.58.60"
cores=$(nproc)
moni_interval=3
max_cpu=0

while true; do
	current_time=$(date +%s)
	
	if [ $current_time -ge $end_time ]; then
	    log "已运行 24 小时，即将退出..." "$logfile"
	    break
	fi
	TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
	QPS_V1=$(mysql -u"${USER}" -p"${PSWD}" -h"${HOST}" -P"${PORT}" -A -NB -c -e"show global status like 'Com_select';" 2>/dev/null |awk 'NR==1{print $2}')
    sleep $moni_interval
	QPS_V2=$(mysql -u"${USER}" -p"${PSWD}" -h"${HOST}" -P"${PORT}" -A -NB -c -e"show global status like 'Com_select';" 2>/dev/null |awk 'NR==1{print $2}')
    QPS=$(( QPS_V2 - QPS_V1 - 1))

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
done
