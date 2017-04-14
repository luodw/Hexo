title: linux内存分配与回收
date: 2016-08-13 19:32:11
tags:
- linux
- memory
categories:
- linux
toc: true

---

之前在实习时，听了OOM的分享之后，就对linux内核内存管理充满兴趣；但是这块知识非常庞大，没有一定积累，不敢写下，担心误人子弟；所以经过一个一段时间的积累，对内核内存有一定了解之后，今天才写下这篇博客，记录以及分享；

之前也有写过linux内存管理，那篇文章主要是[linux内存管理](http://luodw.cc/2016/02/17/linux-memory/ "")，这篇文章主要是分析了单个进程空间的内存布局与分配，今天这篇博客主要是从全局的视角分析下内核对内存的管理;
![厦大白城](http://7xjnip.com1.z0.glb.clouddn.com/29381f30e924b899045823b46e061d950b7bf6d2.jpg "")

下面主要从以下方面介绍linux内存管理:
* 进程的内存申请与分配
* 内存耗尽之后OOM
* 申请的内存都在哪？
* 系统回收内存

【版权声明】博客内容由罗道文的私房菜拥有版权，允许转载，但请标明原文链接[http://luodw.cc/2016/08/13/linux-cache/](http://luodw.cc/2016/08/13/linux-cache/ "")

# 进程的内存申请与分配

----

之前有篇文章介绍hello world程序是如何载入内存以及是如何申请内存的；我在这，再次说明下；同样，还是先给出进程的地址空间，我觉得对于任何开发人员这张图是必须记住的，还有一张就是操作disk,memory以及cpu cache的时间图；
![进程的地址空间](http://7xjnip.com1.z0.glb.clouddn.com/ldw-%E9%80%89%E5%8C%BA_015.png "")

当我们在终端启动一个程序时，终端进程调用exec函数将可执行文件载入内存，此时代码段，数据段，bbs段，stack段都通过mmap函数映射到内存空间，堆则要根据是否有在堆上申请内存来决定是否映射；exec执行之后，此时并未真正开始执行进程，而是将cpu控制权交给了动态链接库装载器，由它来将该进程需要的动态链接库装载进内存；之后才开始进程的执行；这个过程可以通过strace命令跟踪进程调用的系统函数来分析，
```bash
charles@charles-Aspire-4741:~$ strace ./toUpper
execve("./toUpper", ["./toUpper"], [/* 72 vars */]) = 0
brk(NULL)                               = 0x1bef000
access("/etc/ld.so.nohwcap", F_OK)      = -1 ENOENT (No such file or directory)
mmap(NULL, 8192, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0) = 0x7f30be5d8000
access("/etc/ld.so.preload", R_OK)      = -1 ENOENT (No such file or directory)
open("/etc/ld.so.cache", O_RDONLY|O_CLOEXEC) = 3
fstat(3, {st_mode=S_IFREG|0644, st_size=116232, ...}) = 0
mmap(NULL, 116232, PROT_READ, MAP_PRIVATE, 3, 0) = 0x7f30be5bb000
close(3)                                = 0
access("/etc/ld.so.nohwcap", F_OK)      = -1 ENOENT (No such file or directory)
open("/lib/x86_64-linux-gnu/libc.so.6", O_RDONLY|O_CLOEXEC) = 3
read(3, "\177ELF\2\1\1\3\0\0\0\0\0\0\0\0\3\0>\0\1\0\0\0P\t\2\0\0\0\0\0"..., 832) = 832
fstat(3, {st_mode=S_IFREG|0755, st_size=1864888, ...}) =: 0
mmap(NULL, 3967488, PROT_READ|PROT_EXEC, MAP_PRIVATE|MAP_DENYWRITE, 3, 0) = 0x7f30bdfec000
mprotect(0x7f30be1ac000, 2093056, PROT_NONE) = 0
mmap(0x7f30be3ab000, 24576, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_FIXED|MAP_DENYWRITE, 3, 0x1bf000) = 0x7f30be3ab000
mmap(0x7f30be3b1000, 14848, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_FIXED|MAP_ANONYMOUS, -1, 0) = 0x7f30be3b1000

......

```
这是我上篇博客认识pipe中的程序，从这个输出过程，可以看出和我上述描述的一致；

当第一次调用malloc申请内存时，通过系统调用brk嵌入到内核，首先会进行一次判断，是否有关于堆的vma，如果没有，则通过mmap匿名映射一块内存给堆，并建立vma结构，挂到mm_struct描述符上的红黑树和链表上；然后回到用户态，通过内存分配器(ptmaloc,tcmalloc,jemalloc)算法将分配到的内存进行管理，返回给用户所需要的内存；

如果用户态申请大内存时，是直接调用mmap分配内存，此时返回给用户态的内存还是虚拟内存，直到第一次访问返回的内存时，才真正进行内存的分配；其实通过brk返回的也是虚拟内存，但是经过内存分配器进行切割分配之后(切割就必须访问内存)，全都分配到了物理内存

当进程在用户态通过调用free释放内存时，如果这块内存是通过mmap分配，则调用munmap直接返回给系统；否则内存是先返回给内存分配器，然后由内存分配器统一返还给系统，这就是为什么当我们调用free回收内存之后，再次访问这块内存时，可能不会报错的原因；

当然，当整个进程退出之后，这个进程占用的内存都会归还给系统；

# 内存耗尽之后OOM

----

在实习期间，有一台测试机上的mysql实例经常被oom杀死；oom(out of memory)即为系统在内存耗尽时的自我拯救措施，他会选择一个进程，将其杀死，释放出内存；很明显，哪个进程占用的内存最多，即最可能被杀死，但事实是这样的吗？

今天早上去上班，刚好碰到了一起OOM，突然发现，oom一次，世界都安静下来了，哈哈；测试机上的redis被杀死了；
```
Out of memory: Kill process 12312 (redis-server) score 9 or sacrifice child
Killed process 12312, UID 501, (redis-server) total-vm:186660kB, anon-rss:9388kB, file-rss:4kB
```
OOM关键文件oom_kill.c，里面介绍了当内存不够时，系统如何选择最应该被杀死的进程；选择因素有挺多的，除了进程占用的内存外，还有进程运行的时间，进程的优先级，是否为root用户进程，子进程个数和占用内存以及用户控制参数oom_adj都相关；

当产生oom之后，函数select_bad_process会遍历所有进程，通过之前提到的那些因素，每个进程都会得到一个oom_score分数，分数最高，则被选为杀死的进程；

我们可以通过设置/proc/<pid>/oom_adj分数来干预系统选择杀死的进程；
```c++
/*
 * /proc/<pid>/oom_adj set to -17 protects from the oom killer for legacy
 * purposes.
 */
#define OOM_DISABLE (-17)
/* inclusive */
#define OOM_ADJUST_MIN (-16)
#define OOM_ADJUST_MAX 15

```
这是内核关于这个oom_adj调整值的定义；最大可以调整为15,最小为-16，如果为-17，则该进程就像买了vip会员一样，不会被系统驱逐杀死了；因此，如果在一台机器上有跑很多服务器，且你不希望自己的服务被杀死的话，就可以设置自己服务的oom_adj为-17；

当然，说到这，就必须提到另一个参数/proc/sys/vm/overcommit_memory，man proc说明如下:
```
 0: heuristic overcommit (this is the default)
 1: always overcommit, never check
 2: always check, never overcommit
```
意思就是当overcommit_memory为0时，则为启发式oom，即当申请的虚拟内存不是很夸张的大于物理内存，则系统允许申请；但是当进程申请的虚拟内存很夸张的大于物理内存，则就会产生OOM，例如只有8g的物理内存，然后redis虚拟内存占用了24G，物理内存占用3g,如果这时执行bgsave，子进程和父进程共享物理内存，但是虚拟内存是自己的，即子进程会申请24g的虚拟内存，这很夸张大于物理内存，就会产生一次OOM；

当overcommit_memory为1时，则永远都允许overmemory内存申请；即不管你多大的虚拟内存申请都允许，但是当系统内存耗尽时，这时就会产生oom；即上述的redis例子，在overcommit_memory=1时，是不会产生oom的，因为物理内存足够；

当overcommit_memory为2时，永远都不能超出某个限定额的内存申请，这个限定额为swap+RAM*系数（/proc/sys/vm/overcmmit_ratio，默认50%，可以自己调整），如果这么多资源已经用光，那么后面任何尝试申请内存的行为都会返回错误，这通常意味着此时没法运行任何新程序

以上就是oom的内容，了解原理，以及如何根据自己的应用，合理的设置OOM；

# 系统申请的内存都在哪？

---

我们了解了一个进程的地址空间之后，是否会好奇，申请到的物理内存都存在哪了？可能很多人觉得，不就是物理内存吗？我这里说申请的内存在哪，是因为物理内存有分为cache和普通物理内存，可以通过free命令查看；而且物理内存还有分DMA,NORMAL,HIGH三个区，这里主要分析cache和普通内存；

通过第一部分，我们知道一个进程的地址空间几乎都是mmap函数申请，有文件映射和匿名映射两种；

## 共享文件映射


我们先来看下代码段和动态链接库映射段，这两个都是属于共享文件映射，也就是说由同一个可执行文件启动的两个进程是共享这两个段，都是映射到同一块物理内存；那么这块内存在哪了？我写了个程序测试如下：
```c
#include<stdio.h>
#include<sys/mman.h>
#include<unistd.h>
#include<fcntl.h>
#include<sys/stat.h>
#include<stdlib.h>
#include<string.h>

#define SIZE  1024*1024*1024

int main(int argc,char* argv[]) {
    int fd;
    struct stat sb;  
    char *p;
  	if ((fd = open(argv[1], O_RDWR)) < 0) {
    	perror("open");
	}  
    if ((fstat(fd, &sb)) == -1) {  
        perror("fstat");  
    }
    if ((p = (char *)mmap(NULL,sb.st_size, PROT_READ |   
                PROT_WRITE, MAP_SHARED , fd, 0)) == (void *)-1) {  
    	perror("mmap");  
	 }
	//必须执行下面memset函数，否则系统不会分配真实内存
	memset(p,'c',sb.st_size);
	sleep(100);
	return 0;
}
```

我们先看下当前系统的内存使用情况:
```bash
charles@charles-Aspire-4741:~$ free -m
              total        used        free      shared  buff/cache   available
Mem:           5828        1596        3612          47         620        3913
Swap:          3904           4        3900

```
当我在本地新建一个1G的文件
> dd if=/dev/zero of=fileblock bs=M count=1024

然后调用上述程序，进行共享文件映射,此时内存使用情况为：
```
 ./hello fileblock
/*---------------------*/
charles@charles-Aspire-4741:~$ free -m
              total        used        free      shared  buff/cache   available
Mem:           5828        1679        2491          47        1656        3824
Swap:          3904           4        3900

```
我们可以发现，buff/cache增长了大概1G，因此我们可以得出结论，代码段和动态链接库段是映射到内核cache中，也就是说当执行共享文件映射时，文件是先被读取到cache中，然后再映射到用户进程空间中；

## 私有文件映射段

对于进程空间中的数据段，其必须是私有文件映射；因为如果是共享文件映射，那么同一个可执行文件启动的两个进程，任何一个进程修改数据段，都将影响另一个进程了；我将上述测试程序改写成匿名文件映射：
```
#include<stdio.h>
#include<sys/mman.h>
#include<unistd.h>
#include<fcntl.h>
#include<sys/stat.h>
#include<stdlib.h>
#include<string.h>

#define SIZE  1024*1024*1024

int main(int argc,char* argv[]) {
    int fd;
    struct stat sb;  
    char *p;
        if ((fd = open(argv[1], O_RDWR)) < 0) {
        perror("open");
        }  
    if ((fstat(fd, &sb)) == -1) {  
        perror("fstat");  
    }
    if ((p = (char *)mmap(NULL,sb.st_size, PROT_READ |   
                PROT_WRITE, MAP_PRIVATE , fd, 0)) == (void *)-1) {  
        perror("mmap");  
         }
        //必须执行下面memset函数，否则系统不会分配真实内存
        memset(p,'c',sb.st_size);
        sleep(100);
        return 0;
}
```
在执行程序执行，需要先将之前的cache释放掉，否则会影响结果
>  echo 1 >> /proc/sys/vm/drop_caches

接着执行程序，看下内存使用情况:
```
//没执行程序之前的内存使用情况
charles@charles-Aspire-4741:~$ free -m
              total        used        free      shared  buff/cache   available
Mem:           5828        1679        3681          47         467        3840
Swap:          3904           4        3900
/*------------------------------------------*/
./hello fileblock
/*-----------------------------------------*/
//调用程序之后内存使用情况
charles@charles-Aspire-4741:~$ free -m
              total        used        free      shared  buff/cache   available
Mem:           5828        2713        1584          47        1530        2806
Swap:          3904           4        3900
```
从使用前和使用后对比，可以发现used和buff/cache分别增长了1G，说明当进行私有文件映射时，首先是将文件映射到cache中，然后如果某个文件对这个文件进行修改，则会从其他内存中分配一块内存先将文件数据拷贝至新分配的内存，然后再在新分配的内存上进行修改，这也就是写时复制；

这也很好理解，因为如果同一个可执行文件开启多个实例，那么内核先将这个可执行的数据段映射到cache，然后每个实例如果有修改数据段，则都将分配一个一块内存存储数据段，毕竟数据段也是一个进程私有的；

通过上述分析，可以得出结论，如果是文件映射，则都是将文件映射到cache中，然后根据共享还是私有进行不同的操作；

## 私有匿名映射

像bbs段，堆，栈这些都是匿名映射，因为可执行文件中没有相应的段；而且必须是私有映射，否则如果当前进程fork出一个子进程，那么父子进程将会共享这些段，一个修改都会影响到彼此，这是不合理的;

ok，现在我把上述测试程序改成私有匿名映射
```
#include<stdio.h>
#include<sys/mman.h>
#include<unistd.h>
#include<stdlib.h>
#include<string.h>

#define SIZE  1024*1024*1024

int main(int argc,char* argv[]) {  
    char *p;
    if ((p = (char *)mmap(NULL,SIZE, PROT_READ |   
                PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)) == (void *)-1) {  
    	perror("mmap");  
	 }
	memset(p,'c',SIZE);
	sleep(100);
	return 0;
}

```
这时再来看下内存的使用情况
```
//程序执行前
charles@charles-Aspire-4741:~$ free -m
              total        used        free      shared  buff/cache   available
Mem:           5828        1698        3646          47         483        3821
Swap:          3904           4        3900
/*------------------------------------------*/
./hello
/*------------------------------------------*/
//测试程序执行之后
charles@charles-Aspire-4741:~$ free -m
              total        used        free      shared  buff/cache   available
Mem:           5828        2749        2582          47         496        2771
Swap:          3904           4        3900

```

我们可以看到，只有used增加了1G，而buff/cache并没有增长；说明，在进行匿名私有映射时，并没有占用cache，其实这也是有道理，因为就只有当前进程在使用这块这块内存，没有必要占用宝贵的cache;

## 共享匿名映射

当我们需要在父子进程共享内存时，就可以用到mmap共享匿名映射；那么共享匿名映射的内存是存放在哪了？我继续改写上述测试程序为共享匿名映射
```
#include<stdio.h>
#include<sys/mman.h>
#include<unistd.h>
#include<stdlib.h>
#include<string.h>

#define SIZE  1024*1024*1024

int main(int argc,char* argv[]) {  
    char *p;
    if ((p = (char *)mmap(NULL,SIZE, PROT_READ |   
                PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0)) == (void *)-1) {  
        perror("mmap");  
         }
        memset(p,'c',SIZE);
        sleep(100);
        return 0;
}

```
这时来看下内存的使用情况：
```bash
/测试程序执行前：
charles@charles-Aspire-4741:~$ free -m
              total        used        free      shared  buff/cache   available
Mem:           5828        1667        3661          47         499        3852
Swap:          3904           4        3900
/*-----------------------------------------*/
./hello
/*-----------------------------------------*/
charles@charles-Aspire-4741:~$ free -m
              total        used        free      shared  buff/cache   available
Mem:           5828        1694        2602        1071        1531        2801
Swap:          3904           4        3900

```
从上述结果，我们可以看出，只有buff/cache增长了1G，即当进行共享匿名映射时，这时是从cache中申请内存；道理也很明显，因为父子进程共享这块内存，共享匿名映射存在于cache，然后每个进程再映射到彼此的虚存空间，这样即可操作的是同一块内存，
# 系统回收内存

----

当系统内存不足时，有两种方式进行内存释放，一种是手动的方式，另一种是系统自己触发的内存回收；先来看下手动触发方式；

## 手动回收内存

手动回收内存，之前也有演示过，即
> echo 1 >> /proc/sys/vm/drop_caches

我们可以在man proc下面看到关于这个的简介
```
To free pagecache, use:
	echo 1 > /proc/sys/vm/drop_caches

To free dentries and inodes, use:

	echo 2 > /proc/sys/vm/drop_caches

To free pagecache, dentries and inodes, use:

	echo 3 > /proc/sys/vm/drop_caches
 Because writing to this file is a nondestructive  operation  and  
dirty  objects  are  not  freeable,  the user should run sync(1) first.

```
从这个介绍可以看出，当drop_caches文件为1时，这时将释放pagecache中可释放的部分(有些cache是不能通过这个释放的)；当drop_caches为2时，这时将释放dentries和inodes缓存；当drop_caches为3时，这同时释放上述两项；

关键还有最后一句，意思是说如果pagecache中有脏数据时，操作drop_caches是不能释放的，必须通过sync命令将脏数据刷新到磁盘，才能通过操作drop_caches释放pagecache；

ok，之前有提到有些pagecache是不能通过drop_caches释放的，那么除了上述提文件映射和共享匿名映射外，还有有哪些东西是存在pagecache了？

### tmpfs

我们先来看下tmpfs; tmpfs和procfs,sysfs以及ramfs一样，都是基于内存的文件系统；tmpfs和ramfs的区别就是ramfs的文件基于纯内存的，和tmpfs除了纯内存外，还会使用swap交换空间，以及ramfs可能会把内存耗尽，而tmpfs可以限定使用内存大小；可以用命令df -T -h查看系统一些文件系统，其中就有一些是tmpfs，比较出名的是目录/dev/shm

tmpfs文件系统源文件在内核源码mm/shmem.c，tmpfs实现很复杂，之前有介绍虚拟文件系统，基于tmpfs文件系统创建文件和其他基于磁盘的文件系统一样，也会有inode,super_block,identry,file等结构，区别主要是在读写上，因为读写才涉及到文件的载体是内存还是磁盘；

而tmpfs文件的读函数shmem_file_read，过程主要为通过inode结构找到address_space地址空间，其实就是磁盘文件的pagecache；然后通过读偏移定位cache页以及页内偏移，这时就可以直接从这个pagecache通过函数__copy_to_user将缓存页内数据拷贝到用户空间；当我们要读物的数据不pagecache中时，这时要判断是否在swap中，如果在则先将内存页swap in，再读取；

tmpfs文件的写函数shmem_file_write，过程主要为先判断要写的页是否在内存中，如果在，则直接将用户态数据通过函数__copy_from_user拷贝至内核pagecache中覆盖老数据，并标为dirty；如果要写的数据不再内存中，则判断是否在swap中，如果在，则先读取出来，用新数据覆盖老数据并标为脏；如果即不在内存也不在磁盘，则新生成一个pagecache存储用户数据；

由上面分析，我们知道基于tmpfs的文件也是使用cache的，我们可以在/dev/shm上创建一个文件来检测下:
```
//没有创建文件前内存使用情况
charles@charles-Aspire-4741:/dev/shm$ free -m
              total        used        free      shared  buff/cache   available
Mem:           5828        1401        2223          42        2204        4058
Swap:          3904           0        3904
/*-----------------------------------------*/
dd if=/dev/zero of=fileblock bs=1G count=1
/*-----------------------------------------*/
//在/dev/shm上创建一个1G的文件
charles@charles-Aspire-4741:/dev/shm$ free -m
              total        used        free      shared  buff/cache   available
Mem:           5828        1400        1197        1066        3229        3035
Swap:          3904           0        3904

```
看到了吧，cache增长了1G，验证了tmpfs的确使用的cache内存；

其实mmap匿名映射原理也是用了tmpfs，在mm/mmap.c->do_mmap_pgoff函数内部，有判断如果file结构为空以及为SHARED映射，则调用shmem_zero_setup(vma)函数在tmpfs上用新建一个文件
```
int shmem_zero_setup(struct vm_area_struct *vma)
{
	struct file *file;
	loff_t size = vma->vm_end - vma->vm_start;

	file = shmem_file_setup("dev/zero", size, vma->vm_flags);
	if (IS_ERR(file))
		return PTR_ERR(file);

	if (vma->vm_file)
		fput(vma->vm_file);
	vma->vm_file = file;
	vma->vm_ops = &shmem_vm_ops;
	return 0;
}

```
这里就解释了为什么共享匿名映射内存初始化为0了；但是我们知道用mmap分配的内存初始化为0，就是说mmap私有匿名映射也为0,那么体现在哪了？

这个在do_mmap_pgoff函数内部可没有体现出来，而是在缺页异常，然后分配一种特殊的初始化为0的页；

那么这个tmpfs占有的内存页可以回收吗？
```
//创建文件前
free -m
              total        used        free      shared  buff/cache   available
Mem:           5828        1240        4040          41         547        4245
Swap:          3904           0        3904
//创建文件之后
root@charles-Aspire-4741:/dev/shm# free -m
              total        used        free      shared  buff/cache   available
Mem:           5828        1243        3011        1065        1573        3217
Swap:          3904           0        3904
/*------------------------------------------*/
root@charles-Aspire-4741:/dev/shm# echo 1 >> /proc/sys/vm/drop_caches
/*-------------------------------------------*/
 free -m
              total        used        free      shared  buff/cache   available
Mem:           5828        1243        3012        1065        1572        3217
Swap:          3904           0        3904

```
也就是说tmpfs文件占有的pagecache是不能回收的；道理也很明显，因为有文件引用这些页，就不能回收；

### 共享内存

posix共享内存其实和mmap共享映射是同一个道理，都是利用在tmpfs文件系统上新建一个文件，然后再映射到用户态；最后两个进程操作同一个物理内存；那么System V共享内存是否也是利用tmpfs文件系统了？

我们可以跟踪到下述函数
```
static int newseg(struct ipc_namespace *ns, struct ipc_params *params)
{
//........
sprintf(name, "SYSV%08x", key);
if  ((shmflg & SHM_NORESERVE) &&sysctl_overcommit_memory != OVERCOMMIT_NEVER)
	acctflag = VM_NORESERVE;
file = shmem_kernel_file_setup(name, size, acctflag);
//........
```
这个函数就是新建一个共享内存段，其中函数
> shmem_kernel_file_setup

就是在tmpfs文件系统上创建一个文件；然后通过这个内存文件实现进程通信；这我就不写测试程序了；而且这也是不能回收的，因为共享内存ipc机制生命周期是随内核的，也就是说你创建共享内存之后，如果不显示删除的话，进程退出之后，共享内存还是存在的；

之前看了一些技术博客，说到Poxic和System V两套ipc机制(消息队列，信号量以及共享内存)都是使用tmpfs文件系统，也就是说最终内存使用的都是pagecache，但是我在源码中看出了两个共享内存是基于tmpfs文件系统，其他信号量和消息队列还没看出来(有待后续考究)；

posix消息队列的实现有点类似与pipe的实现，也是自己一套mqueue文件系统，然后在inode上的i_private上挂上关于消息队列属性mqueue_inode_info，在这个属性上，内核2.6时，是用一个数组存储消息，而到了4.6则用红黑树了存储消息(我下载了这两个版本，具体什么时候开始用红黑树，没深究)；然后两个进程每次操作都是操作这个mqueue_inode_info中的消息数组或者红黑树，实现进程通信；和这个mqueue_inode_info类似的还有tmpfs文件系统属性shmem_inode_info和为epoll服务的文件系统eventloop,也有一个特殊属性struct eventpoll，这个是挂在file结构的private_data等等；

> 说到这，可以小结下，进程空间中代码段，数据段，动态链接库(共享文件映射)，mmap共享匿名映射都存在于cache中，但是这些内存页都有被进程引用，所以是不能释放的；基于tmpfs的ipc进程间通信机制的生命周期是随内核，因此也是不能通过drop_caches释放；

虽然上述提及的cache不能释放，但是后面有提到，当内存不足时，这些内存是可以swap out的；

**因此drop_caches能释放的就是当从磁盘读取文件时的缓存页以及某个进程将某个文件映射到内存之后，进程退出，这时映射文件的的缓存页如果没有被引用，也是可以被释放的;**


## 内存自动释放方式

当系统内存不够时，操作系统有一套自我整理内存，并尽可能的释放内存机制；如果这套机制不能释放足够多的内存，那么只能OOM了；

之前在提及oom时，说道redis因为oom被杀死，如下:
```
Out of memory: Kill process 12312 (redis-server) score 9 or sacrifice child
Killed process 12312, UID 501, (redis-server) total-vm:186660kB, anon-rss:9388kB, file-rss:4kB
```
第二句后半部分，
> total-vm:186660kB, anon-rss:9388kB, file-rss:4kB

把一个进程内存使用情况，用三个属性进行了说明，即所有虚拟内存，常驻内存匿名映射页以及常驻内存文件映射页；

其实从上述的分析，我们也可以知道一个进程其实就是文件映射和匿名映射；
* 文件映射:代码段，数据段，动态链接库共享存储段以及用户程序的文件映射段；
* 匿名映射：bbs段，堆，以及当malloc用mmap分配的内存，还有mmap共享内存段；

其实内核回收内存就是根据文件映射和匿名映射来进行的；在mmzone.h有如下定义:
```
#define LRU_BASE 0
#define LRU_ACTIVE 1
#define LRU_FILE 2

enum lru_list {
	LRU_INACTIVE_ANON = LRU_BASE,//不活跃匿名映射页lru
	LRU_ACTIVE_ANON = LRU_BASE + LRU_ACTIVE,//活跃匿名映射页lru
	LRU_INACTIVE_FILE = LRU_BASE + LRU_FILE,//不活跃文件映射页lru
	LRU_ACTIVE_FILE = LRU_BASE + LRU_FILE + LRU_ACTIVE,//活跃文件映射页lru
	LRU_UNEVICTABLE,
	NR_LRU_LISTS
};
```
LRU_UNEVICTABLE即为不可驱逐页lru，我的理解就是当调用mlock锁住内存，不让系统swap out出去的页列表；

简单说下linux内核自动回收内存原理；内核有一个kswapd会周期性的检查内存使用情况，如果发现空闲内存定于pages_low，则kswapd会对lru_list前四个lru队列进行扫描，在活跃链表中查找不活跃的页，并添加不活跃链表；然后再遍历不活跃链表，逐个进行回收释放出32个页，知道free page数量达到pages_high；针对不同的页，回收方式也不一样；

当然，当内存水平低于某个极限阈值时，会直接发出内存回收，原理和kswapd一样，但是这次回收力度更大，需要回收更多的内存；

文件页：
1. 如果是脏页，则直接回写进磁盘，再回收内存；
2. 如果不是脏页，则直接释放回收；因为如果是io读缓存，直接释放掉，下次读时，缺页异常，直接到磁盘读回来即可；如果是文件映射页，直接释放掉，下次访问时，也是产生两个缺页异常，一次将文件内容读取进磁盘，另一次与进程虚拟内存关联；

匿名页：
因为匿名页没有回写的地方，如果释放掉，那么就找不到数据了，所以匿名页的回收是采取swap out到磁盘；并在页表项做个标记，下次缺页异常在从磁盘swap in进内存；

swap换进换出其实是很占用系统IO的，如果系统内存需求突然间迅速增长，那么cpu将被io占用，系统会卡死，导致不能对外提供服务；因此系统提供一个参数，用于设置当进行内存回收时，执行回收cache和swap匿名页的，这个参数为:
```
 /proc/sys/vm/swappiness
      The value in this file controls how aggressively the kernel will
      swap memory pages.  Higher values increase aggressiveness, lower
      values decrease aggressiveness.  The default value is 60.
```
意思就是说这个值越高，越可能使用swap的方式回收内存；最大值为100；如果设为0，则尽可能使用回收cache的方式释放内存；



# 总结

这篇博客主要是写了linux内存管理相关的东西；首先是回顾了进程地址空间；其次当进程消耗大量内存而导致内存不足时，我们可以有两种方式，第一是手动回收cache；另一种是系统后台线程swapd执行内存回收工作；最后当申请的内存大于系统剩余的内存时，这时就只会产生oom，杀死进程，释放内存；从这个过程，可以看出系统为了腾出足够的内存，是多么的努力啊！！！

后记
> 一开始决定在写最后一部分内存回收时，打算列出源码进行分析，但是发现linux内存回收比文件系统难看多了；所以暂时以分析原理为主，后面有时间，慢慢再看这块代码；

> 我一直很支持学计算机的朋友学习linux和c/c++，因为现在服务器几乎都是linux系统，而且经典高性能服务器软件大部分是c/c++(nginx,redis,mysql,redis,leveldb等等)写的，且跑在linux系统上；其次就是，linux暴露给外界进入的入口就是系统调用，其他语言如果想嵌入内核，就必须封装系统调用接口；而C++主要是锻炼oop思想还有泛型思想；因此，学好了linux和c/c++，再学其他软件或语言，都会轻松很多；**这也就是我一直喜欢linux和c/c++的原因**

> 像这次实习接触golang语言；如果有c/c++基础，golang语法层面是很快熟悉的；然后如果了解linux系统系统调用以及内核原理，那么golang执行与系统相关的函数也会很好理解；像平时使用的网络编程，golang没有提供epoll接口，但是其实内部是有用这个epoll进行轮询的；后面要好好写写博客，聊聊golang

还是那句话，如果有什么出错的地方，希望大家能指出来，感谢～
