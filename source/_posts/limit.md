title: linux下资源设置
date: 2016-02-16 11:07:49
tags:
- linux
categories:
- linux
toc: true

---

# linux下ulimit和sysctl设置原理和区别

在linux下网络编程开发过程中，如果服务器用户量很大，就会开启很多连接，这时可能就会导致服务器进程文件描述符不够的情况。经常，我们会关闭服务器进程，然后在进程中调用setrlimit函数或者ulimit来设置服务器进程描述符的数量。那么ulimit设置原理是怎么样的了？以及sysctl设置原理了？这票文章主要分析下二者的设置原理以及区别。

# ulimit设置

在linux下面，每个进程都有一个进程描述符struct\_task，该结构体含有大量的属性用来描述一个进程的各个属性，其中有一个属性为struct rlimit rlim[RLIM\_NLIMITS];用于描述该进程资源的限定值，其中struct rlimit定义如下：
```
struct rlimit {
	rlim_t rlim_cur;//软限制，即某项资源的最大值
	rlim_t rlim_max;//硬限制，即软限制的最大值
};
```
所以当我们调用setrlimit和ulimit时，主要是设置进程描述符的struct rlimit资源数组。当我们读取资源时，主要是读取/proc/<oid>/limits文件，/proc文件夹为进程或系统的虚拟文件系统，只存在于内存中，是不占用磁盘空间的，可以通过命令ll /来检验，反应系统或进程的属性。/proc/<pid>/limits文件内容如下
```
//资源名称                //软限制             //硬限制             //单位
Limit                     Soft Limit           Hard Limit           Units     
Max cpu time              unlimited            unlimited            seconds   
Max file size             unlimited            unlimited            bytes     
Max data size             unlimited            unlimited            bytes     
Max stack size            8388608              unlimited            bytes     
Max core file size        0                    unlimited            bytes     
Max resident set          unlimited            unlimited            bytes     
Max processes             23235                23235                processes
Max open files            1048                 1048                 files     
Max locked memory         65536                65536                bytes     
Max address space         unlimited            unlimited            bytes     
Max file locks            unlimited            unlimited            locks     
Max pending signals       23235                23235                signals   
Max msgqueue size         819200               819200               bytes     
Max nice priority         0                    0                    
Max realtime priority     0                    0                    
Max realtime timeout      unlimited            unlimited            us        
```

这和我们运行ulimit -a命令显示出的资源列表大部分是一样的。
```
charles@charles-Aspire-4741:/proc/2584$ ulimit -a
core file size          (blocks, -c) 0
data seg size           (kbytes, -d) unlimited
scheduling priority             (-e) 0
file size               (blocks, -f) unlimited
pending signals                 (-i) 23235
max locked memory       (kbytes, -l) 64
max memory size         (kbytes, -m) unlimited
open files                      (-n) 2048
pipe size            (512 bytes, -p) 8
POSIX message queues     (bytes, -q) 819200
real-time priority              (-r) 0
stack size              (kbytes, -s) 8192
cpu time               (seconds, -t) unlimited
max user processes              (-u) 23235
virtual memory          (kbytes, -v) unlimited
file locks                      (-x) unlimited
```
所以ulimit设置只是对当前进程有效。那么通过setlimit设置很好解释，因为直接操作进程描述符资源数组即可。但是ulimint命令怎么也会生效了？bash也是一个进程，那么在bash中调用ulimit设置的是bash的资源。那是因为在bash中执行的任何进程都是通过bash->fork->exec启动，所以ulimit设置了bash的资源，然后通过继承，传递给了bash中的子进程。所以ulimit对bash会话内的进程有效。

# sysctl设置

## sysctl读取属性

对于系统级别的资源，或者说想影响所有进程而不是单个进程时，只能通过sysctl函数或命令来读取设置。我们可以通过sysctl -a读取所有系统级别的资源限制。而sysctl读取的属性主要来自/proc/sys文件下的所有文件:
```
charles@charles-Aspire-4741:/proc/sys$ ll
总用量 0
dr-xr-xr-x   1 root root 0  2月  3  2016 ./
dr-xr-xr-x 217 root root 0  2月  3  2016 ../
dr-xr-xr-x   1 root root 0  2月  2 20:09 abi/
dr-xr-xr-x   1 root root 0  2月  2 20:09 debug/
dr-xr-xr-x   1 root root 0  2月  2 20:09 dev/
dr-xr-xr-x   1 root root 0  2月  2 19:32 fs/
dr-xr-xr-x   1 root root 0  2月  3  2016 kernel/
dr-xr-xr-x   1 root root 0  2月  2 19:32 net/
dr-xr-xr-x   1 root root 0  2月  2 19:32 vm/
```
注意看，该文件是不占用磁盘空间的。在这文件下下，经常使用的是fs,net,vm文件夹下的文件：
1. fs中的文件主要是文件系统的一些属性，例如打开文件的最大数量，管道数量的最大值以及epoll的一些设置；
2. net是网络的一些属性。例如网络接口wlan0,eth,lo的属性设置，还有tcp选项的设置，例如keepalive
3. vm是对虚拟内存的设置，例如redis有设置vm.overcommit_memory属性。

这个属性设置原理如下：
vm.overcommit_memory 默认值为0，可以设置为0,1,2，分别代表意思为：
* 0:当用户空间请求更多的的内存时，内核尝试估算出剩余可用的内存。如果内存不够，进程可能会崩溃。
* 1:当设这个参数值为1时，内核允许超量使用内存直到用完为止，主要用于科学计算;
* 2:当设这个参数值为2时，内核会使用一个决不过量使用内存的算法，即系统整个内存地址空间不能超过swap+50%的RAM值，50%参数的设定是在overcommit_ratio中设定。

vm.overcommit_ratio默认值为50,这个参数值只有在vm.overcommit_memory=2的情况下，这个参数才会生效。

当我们需要读取某个资源限制时，可以通过如下两个命令进行读取:
```
sysctl -a | grep file-max
sysctl fs.file-max
```
但是我推荐第二种，因为第一种要先读取/proc/sys下所有文件，然后一个一个过滤，效率很低，而且有些文件是没有权限的，还会报提示。

第二种写法，其实就是文件夹.属性的形式。例如：
```
//如果要读取文件最大描述符
sysctl fs.file-max ---->  文件/proc/sys/fs/file-max
//读取overcommit_memory值
sysctl vm.overcommit_memory  ----->  文件/proc/sys/vm/overcommit_memory
//读取keepalive_time值
sysctl net.ipv4.tcp_keepalive_time  ----->  文件/proc/sys/net/ipv4/tcp_keepalive_time
```
## sysctl设置属性

如果要设置系统级别的属性，有两种方法：
1. 设置/proc/sys文件夹下，属性文件的值。这种方法只能在当前系统生效，系统重启，则还原为默认值。
2. 通过修改/etc/sysctl.conf文件，这样可以永久改变属性值，因为每次开机系统启动后, init 会执行 /etc/rc.d/rc.sysinit,便会使用 /etc/sysctl.conf 的预设值去执行 sysctl

先来谈谈如何通过修改/proc/sys来设置属性值。
```
//通过重定向输出到属性文件中，覆盖原有的值
echo '1' > /proc/sys/net/ipv4/ip_forward
//用sysctl命令-w属性，直接对变量写入值
sysctl -w net.ipv4.ip_forward=1
```
net.ipv4.ip_forward用于设置主机是否支持转发数据包，0为不转发，1转发。以上两种方法都可以达到修改属性值的目的，但是重定向的方式需要root权限，因为操作的都是系统文件，以下是结果
```
root@charles-Aspire-4741:/proc/sys# sysctl net.ipv4.ip_forward
net.ipv4.ip_forward = 0
root@charles-Aspire-4741:/proc/sys# echo '1' > /proc/sys/net/ipv4/ip_forward
root@charles-Aspire-4741:/proc/sys# sysctl net.ipv4.ip_forward
net.ipv4.ip_forward = 1
root@charles-Aspire-4741:/proc/sys# echo '0' > /proc/sys/net/ipv4/ip_forward
root@charles-Aspire-4741:/proc/sys# sysctl net.ipv4.ip_forward
net.ipv4.ip_forward = 0
root@charles-Aspire-4741:/proc/sys# sysctl -w net.ipv4.ip_forward=1
net.ipv4.ip_forward = 1
```

如果想让系统重启之后，配置还生效，则必须通过修改/etc/sysctl.conf文件，打开/etc/sysctl.conf文件，在文件末尾添加
```
net.ipv4.ip_forward=1
```
然后调用sysctl -p命令使/etc/sysctl.conf文件生效，以下是结果
```
root@charles-Aspire-4741:/proc/sys# sysctl net.ipv4.ip_forward
net.ipv4.ip_forward = 0
root@charles-Aspire-4741:/proc/sys# vim /etc/sysctl.conf
root@charles-Aspire-4741:/proc/sys# sysctl -p
net.ipv4.ip_forward = 1
```

# /etc/security/limits.conf设置

之前也有说道，ulimit设置是在当前会话有效，如果bash重启之后，则ulimit设置失效。如果要下次重启bash之后设置仍然有效，则需要把设置写进当前用户文件夹下的.profile文件中。但是这也是对当前用户有效，如果要对系统所有用户有效，则需要把ulimit命令写进/etc/profile文件中。但是如果设置了～/.profile文件之后，则/etc/profile文件设置对当前用户为无效。

linux还提供了对某一用户设置权限，即为/etc/security/limits.conf文件。要使用该文件，则必须保证/etc/pam.d/login中有下面:
session    required   pam_limits.so

/etc/security/limits.conf文件格式为:
```
username|@groupname   type  item  limit
```
1. username|@groupname 设置需要被限制的用户名，组名前加@与用户名区分开来,*表示所有用户。
2. type 类型有soft，hard 和 -，其中soft 指的是当前系统生效的设置值。hard 表明系统中所能设定的最大值。soft 的限制不能比har 限制高。用 - 就表明同时设置了soft 和hard的值
3. item 表示要限制的资源,有core,data,nofile等待，具体如文件注释所说:
```
<item> can be one of the following:
#        - core - limits the core file size (KB)
#        - data - max data size (KB)
#        - fsize - maximum filesize (KB)
#        - memlock - max locked-in-memory address space (KB)
#        - nofile - max number of open files
#        - rss - max resident set size (KB)
#        - stack - max stack size (KB)
#        - cpu - max CPU time (MIN)
#        - nproc - max number of processes
#        - as - address space limit (KB)
#        - maxlogins - max number of logins for this user
#        - maxsyslogins - max number of logins on the system
#        - priority - the priority to run user process with
#        - locks - max number of file locks the user can hold
#        - sigpending - max number of pending signals
#        - msgqueue - max memory used by POSIX message queues (bytes)
#        - nice - max nice priority allowed to raise to values: [-20, 19]
#        - rtprio - max realtime priority
#        - chroot - change root to directory (Debian-specific)
```

所以要设置所有用户最大文件描述符，则需要在文件中添加一行
```
*   soft   nofile   4096
```

linux下资源的设置，常用大概就这几个。最关键的还是ulimit命令和sysctl命令，需要好好掌握。
