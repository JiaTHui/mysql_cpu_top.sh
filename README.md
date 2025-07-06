# mysql_cpu_top.sh
This script monitors system usage and outputs CPU usage, QPS, and the number of active sessions. When the value is greater than the specified value, it outputs a list of active sessions that cause the CPU to surge. It exits when the running time is greater than 1 day.

Minimum privilege monitoring user

```sql
create user dbros@'%' identified with mysql_native_password by '123456';
grant process on *.* to dbros;
```

Usage:

```sql
/usr/bin/bash mysql_cpu_top.sh
```
You need to configure:

- USER="dbros" : mysql connection user
- PSWD="123456" : mysql connection password
- PORT="3306" : mysql connection port
- HOST="192.168.10.1" : mysql connection IP
- moni_interval=3 : interval QPS, CPU, active session monitoring interval
- max_cpu=60 : output active session information when it is greater than this value
Scheduled task configuration. If you configure a scheduled task, please check whether there is a mysql client under the corresponding user environment variable

```sql
0 0 * * * /usr/bin/bash /monitor/mysql_cpu_top.sh >/dev/null 2>&1 &
```

Output 4 files:

1. 2025-06-03-CPU-QPS.log: `CPU 使用率：${CPU_USAGE}%  活跃会话数:${ACTIVE_SESSIONS} QPS:${QPS} 占用最高：user:${proc_user} comm:${proc_cmd} CPU:${proc_cpu}%`
2. When it is greater than the variable specified by max_cpu:
   1. 2025-06-03-active-session.log:`CPU 使用率：${CPU_USAGE}%  活跃会话数:${ACTIVE_SESSIONS} QPS:${QPS} 占用最高：user:${proc_user} comm:${proc_cmd} CPU:${proc_cpu}% 活跃会话信息：\n$ACTIVE_SESSIONS_QUERY\n"`
   2. 2025-06-03-cpu-top.log: `CPU 使用率：${CPU_USAGE}%  活跃会话数:${ACTIVE_SESSIONS} QPS:${QPS} 占用最高：user:${proc_user} comm:${proc_cmd} CPU:${proc_cpu}% top 20 信息：\n$top_first20\n`
3. Monitor the memory output file and output the memory of the /proc/meminfo file when the memory is greater than 80%
   1. 2025-06-03-mem-monitor.log:`总内存:${MemTotal_GB}GB 已使用:${MemUsed}GB  缓存+缓冲:${CacheBuffers}GB Dirty:${Dirty} Writeback:${Writeback} CommitLimit:${CommitLimit_GB}GB Committed_AS:${Committed_AS_GB}GB`

2025-06-03-CPU-QPS.log output

```sql
[2025-06-03 19:53:41] CPU 使用率：97.10%  活跃会话数:2 QPS:3 占用最高：user:root comm:sshd CPU:3.10%
[2025-06-03 19:53:45] CPU 使用率：44.10%  活跃会话数:2 QPS:7 占用最高：user:root comm:rcu_sched CPU:2.95%
[2025-06-03 19:53:49] CPU 使用率：45.50%  活跃会话数:2 QPS:2 占用最高：user:root comm:top CPU:3.10%
```

2025-06-03-active-session.log output

```sql
[2025-06-03 19:53:49] CPU 使用率：45.50%  活跃会话数:2 QPS:2 占用最高：user:root comm:top CPU:3.10% 活跃会话信息：
*************************** 1. row ***************************
      ID: 147
    user: dbros
      DB: NULL
 Command: Query
    Time: 0
   STATE: executing
    INFO: select /*+ SET_VAR(sql_mode='STRICT_TRANS_TABLES')  */ group_concat(ID) 'ID',user,DB,Command, group_concat(TIME) 'Time',STATE,INFO,count(*) from performance_schema.processlist where COMMAND<>'Sleep' and user<>'repl' group by user,DB,Command,STATE,substring(INFO,1,30) order by count(*) asc
count(*): 1
*************************** 2. row ***************************
      ID: 5
    user: event_scheduler
      DB: NULL
 Command: Daemon
    Time: 2662364
   STATE: Waiting on empty queue
    INFO: NULL
count(*): 1

```

2025-06-03-cpu-top.log output

```sql
[2025-06-03 19:53:49] CPU 使用率：45.50%  活跃会话数:2 QPS:2 占用最高：user:root comm:top CPU:3.10% top 20 信息：
top - 19:53:49 up 2 days,  9:24,  6 users,  load average: 1.25, 1.38, 1.04
Tasks: 215 total,   4 running, 211 sleeping,   0 stopped,   0 zombie
%Cpu(s): 35.3 us, 32.4 sy,  0.0 ni, 29.4 id,  0.0 wa,  0.0 hi,  2.9 si,  0.0 st
KiB Mem :  2860040 total,   170728 free,  1336016 used,  1353296 buff/cache
KiB Swap:  2097148 total,  2094580 free,     2568 used.  1217928 avail Mem 

   PID USER      PR  NI    VIRT    RES    SHR S  %CPU %MEM     TIME+ COMMAND
 17580 root      20   0  161360   6236   4480 S  12.5  0.2   1:03.75 sshd
 17742 root      20   0  162760   2964   1588 S  12.5  0.1   0:13.50 top
  8307 root      16  -4   55616   1672   1212 S   6.2  0.1   9:42.87 sedispatch
 59211 root      20   0  161268   6204   4480 R   6.2  0.2   0:14.03 sshd
 96008 root      20   0  115344   1584   1328 S   6.2  0.1   0:00.01 bash
     1 root      20   0  128428   7124   4212 S   0.0  0.2   3:05.51 systemd
     2 root      20   0       0      0      0 S   0.0  0.0   0:02.47 kthreadd
     3 root      20   0       0      0      0 S   0.0  0.0   4:30.78 ksoftirqd/0
     5 root       0 -20       0      0      0 S   0.0  0.0   0:00.00 kworker/0:0H
     7 root      rt   0       0      0      0 S   0.0  0.0   3:14.53 migration/0
     8 root      20   0       0      0      0 S   0.0  0.0   0:00.00 rcu_bh
     9 root      20   0       0      0      0 R   0.0  0.0  28:06.31 rcu_sched
    10 root       0 -20       0      0      0 S   0.0  0.0   0:00.00 lru-add-drain

```

2025-06-03-mem-monitor.log output

```sql
[2025-06-30 18:36:44] 总内存:2GB 已使用:1GB  缓存+缓冲:1GB Dirty:40 Writeback:0 CommitLimit:3GB Committed_AS:2GB
[2025-06-30 18:36:44] 已使用内存比例:50
MemTotal:        2860040 kB
MemFree:          214956 kB
MemAvailable:    1029424 kB
Buffers:               0 kB
Cached:           735896 kB
SwapCached:          104 kB
Active:           892112 kB
Inactive:         726372 kB
Active(anon):     458812 kB
Inactive(anon):   470260 kB
Active(file):     433300 kB
Inactive(file):   256112 kB
Unevictable:           0 kB
Mlocked:               0 kB
SwapTotal:       2097148 kB
SwapFree:        2093556 kB
Dirty:                40 kB
Writeback:             0 kB
AnonPages:        882548 kB
Mapped:           121700 kB
Shmem:             46484 kB
Slab:             544124 kB
SReclaimable:     406588 kB
SUnreclaim:       137536 kB
KernelStack:        8832 kB
PageTables:        23892 kB
NFS_Unstable:          0 kB
Bounce:                0 kB
WritebackTmp:          0 kB
CommitLimit:     3461632 kB
Committed_AS:    2899060 kB
VmallocTotal:   34359738367 kB
VmallocUsed:      185244 kB
VmallocChunk:   34359310332 kB
HardwareCorrupted:     0 kB
AnonHugePages:    468992 kB
CmaTotal:              0 kB
CmaFree:               0 kB
HugePages_Total:      64
HugePages_Free:       50
HugePages_Rsvd:       19
HugePages_Surp:        0
Hugepagesize:       2048 kB
DirectMap4k:      143168 kB
DirectMap2M:     3035136 kB
DirectMap1G:           0 kB

```


