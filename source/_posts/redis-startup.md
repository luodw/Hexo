title: redis源码分析之启动过程
date: 2016-02-01 10:52:23
tags:
- redis
categories:
- redis

---

今天这篇文章主要是分析下redis的启动流程，作为一个完整的软件，分析开启过程主要是分析main函数，当然，这主要还是在对redis有一定的了解，否则很难读懂redis的各个函数。

redis服务器所有属性都保存在struct redisServer这个结构体中，所以服务器一开始时，首先是先初始化服务器属性，然后在建立事件驱动，将listenfd可读事件添加进EventLoop事件驱动中，等待客户端连接，然后服务器处于事件驱动的无限循环中。

在main函数中，首先做的就是为改服务器进程标题做好初始化操作。首先调用 spt_init(argc, argv);再调用 redisSetProcTitle(argv[0]);修改标题。我们都知道argv[0]就是进程的名称，是否可以直接修改了？

首先需要说明一点就是linux进程栈上面还有main函数参数和环境变量指针，都为字符数组指针，以NULL结尾，而且argv[]参数和environ参数是在连续内存中，这样一来，如果新的进程名称长度大于旧的argv[0]，那么就会改变argv[1]的值。所以redis采用的方法是先将[argv[1],argv[argc-1]]参数和environ的值移到另一块内存块，然后再对argv[0]进行赋值，此时argv[0]拥有原argv和environ所有内存。

接下来分析下重要的几个设置。

# initServerConfig函数

这个函数主要就是初始化server结构体，这个结构体有大量的属性，这里说下几个重要属性。
1. server.lruclock=getLRUClock();这个为redis运行时钟，主要是用于判断键值队是否到期，代码如下:
```
//mstime()函数返回unix时间毫秒数
//#define REDIS_LRU_BITS 24
//#define REDIS_LRU_CLOCK_MAX ((1<<REDIS_LRU_BITS)-1) /* Max value of obj->lru */
//#define REDIS_LRU_CLOCK_RESOLUTION 1000 /* LRU clock resolution in ms */
unsigned int getLRUClock(void) {
    return (mstime()/REDIS_LRU_CLOCK_RESOLUTION) & REDIS_LRU_CLOCK_MAX;
}
```
这个REDIS_LRU_CLOCK\_RESOLUTION常量主要是unix运行时钟精度，这里值为1000ms，所以 (mstime()/REDIS\_LRU\_CLOCK\_RESOLUTION)所得值最后三位为0，即精度为秒。即server.lruclock为unix某个时间点的秒数。

2. 将命令列表挂到server属性中。
```
server.commands = dictCreate(&commandTableDictType,NULL);
server.orig_commands = dictCreate(&commandTableDictType,NULL);
populateCommandTable();
```
populateCommandTable()函数将命令数组redisCommandTable中的所有命令添加到server.commands和server.orig_commands。因为在redis.conf可能被rename命令改变，所以需要在server.orig_commands再保存一份命令表。

# 从命令行和redis.conf读取配置项

初始化好server之后，接下来redis读取用户设置选项，然后对server属性重新赋值。代码如下:
```
if (argc >= 2) {
        int j = 1; /* argv第一个选项 */
        sds options = sdsempty();
        char *configfile = NULL;//配置文件路径

        /* H处理特殊选项 --help 和 --version */
        if (strcmp(argv[1], "-v") == 0 ||
            strcmp(argv[1], "--version") == 0) version();
        if (strcmp(argv[1], "--help") == 0 ||
            strcmp(argv[1], "-h") == 0) usage();
        if (strcmp(argv[1], "--test-memory") == 0) {
            if (argc == 3) {
                memtest(atoi(argv[2]),50);
                exit(0);
            } else {
                fprintf(stderr,"Please specify the amount of memory to test in megabytes.\n");
                fprintf(stderr,"Example: ./redis-server --test-memory 4096\n\n");
                exit(1);
            }
        }
```
这段代码先是处理一些特殊的选项，例如版本，帮助和内存测试。而且这些选项函数执行之后，redis服务器就退出。而且我也发现，在linux下面，完整选项必须加'--'，而缩写选项加'-'。

接下来就是读取真正的配置项。

```
   /* 判断第一个参数是否为配置文件 */
        if (argv[j][0] != '-' || argv[j][1] != '-')
            configfile = argv[j++];//如果是，赋值给configfile，并将j+1，开始解析第二个参数
   while(j != argc) {
            if (argv[j][0] == '-' && argv[j][1] == '-') {
                /* (1)选项的名称 */
                if (sdslen(options)) options = sdscat(options,"\n");
                options = sdscat(options,argv[j]+2);
                options = sdscat(options," ");
            } else {
                /* (2)选项的值 */
                options = sdscatrepr(options,argv[j],strlen(argv[j]));
                options = sdscat(options," ");
            }
            j++;
        }
```
根据源码，配置文件只能在第二个参数(第一个为程序名称)，然后跟着配置文件后面可以是各个配置选项，都存储在option字符串中。加入有一个配置项是--port 6380，那么在option字符串会添加"port 6380\n"。然后调用函数 loadServerConfig(configfile,options);将文件读进内存，并给server赋值:
```
void loadServerConfig(char *filename, char *options) {
    sds config = sdsempty();
    char buf[REDIS_CONFIGLINE_MAX+1];

    /* 读取配置文件的内容 */
    if (filename) {
        FILE *fp;

        if (filename[0] == '-' && filename[1] == '\0') {
            fp = stdin;//配置文件为空，则从标准输入读取
        } else {
            if ((fp = fopen(filename,"r")) == NULL) {
                redisLog(REDIS_WARNING,
                    "Fatal error, can't open config file '%s'", filename);
                exit(1);
            }
        }
        while(fgets(buf,REDIS_CONFIGLINE_MAX+1,fp) != NULL)
            config = sdscat(config,buf);//将配置文件的每一行读取进config字符串
        if (fp != stdin) fclose(fp);
    }
    /* Append the additional options */
    if (options) {
        config = sdscat(config,"\n");
        config = sdscat(config,options);//将options接着配置文件字符串后面
    }
　　//最后读取config字符串，将配置项赋值给server
    loadServerConfigFromString(config);
    sdsfree(config);
}
```
从这段代码即可得知，命令行参数配置选项是跟在配置文件之后的，所以如果命令行参数配置选项和配置文件有同样的配置，则命令行参数选项会覆盖配置文件中的配置选项。 loadServerConfigFromString(config);这个函数代码比较长，主要就是比较配置选项名称，给server属性赋值。

接下来主要就是分析initServer()函数

# initServer函数

这个函数非常重要，主要就是在服务器进入事件循环之前，做的一些工作，例如忽略SIGHUP,SIGPIPE信号，监听listenfd并加入Eventloop,以及监听unix域并加入Eventloop等等。
1. 创建EventLoop实例 事件监听的文件描述符个数为客户端数量的最大值+预留值。
```
server.el = aeCreateEventLoop(server.maxclients+REDIS_EVENTLOOP_FDSET_INCR);

```

2. 获取监听的ip数组以及个数
```
 if (server.port != 0 &&
        listenToPort(server.port,server.ipfd,&server.ipfd_count) == REDIS_ERR)
        exit(1);
```
这个函数主要做的就是先判断用户是否有提供监听地址，如果没有，则监听0,0,0,0地址，即INADDR_ANY，也就是所有地址。并监听0,0,0,0的ipv4和ipv6地址，并设置为非阻塞；如果有设置监听地址，可以是一个地址队列，则只监听用户自己设置的ip地址队列。最后server.ipfd为监听套接字数组，server.ipfd_count为套接字数组个数。

3. 设置unix域套接字监听
```
 if (server.unixsocket != NULL) {
        unlink(server.unixsocket); /* 防止unix套接字文件存在 */
        server.sofd = anetUnixServer(server.neterr,server.unixsocket,
            server.unixsocketperm, server.tcp_backlog);
        if (server.sofd == ANET_ERR) {
            redisLog(REDIS_WARNING, "Opening Unix socket: %s", server.neterr);
            exit(1);
        }
        anetNonBlock(NULL,server.sofd);
    }

```
anetUnixServer函数主要工作就是创建unix域套接字，并返回文件描述符sofd。因为在创建域套接字时，会创建文件，所以需要先unlink这个文件，防止已经存在了。

4. 更新unix缓存时间
```
void updateCachedTime(void) {
    server.unixtime = time(NULL);//以秒数为单位
    server.mstime = mstime();//以毫秒为单位
}
```

5. 创建时间事件和网络事件
```
//时间事件
  if(aeCreateTimeEvent(server.el, 1, serverCron, NULL, NULL) == AE_ERR) {
        redisPanic("Can't create the serverCron time event.");
        exit(1);
    }
//文件描述符事件
  for (j = 0; j < server.ipfd_count; j++) {
        if (aeCreateFileEvent(server.el, server.ipfd[j], AE_READABLE,
            acceptTcpHandler,NULL) == AE_ERR)
            {
                redisPanic(
                    "Unrecoverable error creating server.ipfd file event.");
            }
    }
//域套接字文件描述符事件
if (server.sofd > 0 && aeCreateFileEvent(server.el,server.sofd,AE_READABLE,
        acceptUnixHandler,NULL) == AE_ERR) redisPanic("Unrecoverable error creating server.sofd file event.");
```
这个没啥好说的，因为之前有介绍过Mainae模块，就是调用相应函数，但是要关注下回调函数，这个等后面分析。还有一个就是时间事件的回调函数，非常重要，在redis运行期间，每一秒执行一次，后面再分析。

6. 一些初始化

例如如果有必要打开aof文件，lua脚本环境初始化，慢日志初始化等待。

initServer函数结束之后，调用aeMain()函数进入事件驱动循环，到此为止，redis服务器就运行起来了，等客户端的连接。接下来要分析redis时间事件回调函数serverCron，每秒执行一次，非常重要，很多都基于这个回调函数更新。

# serverCron

像memecache的时间事件主要是更新时间戳，而且是每秒执行一次，所以秒数就一秒一秒更新，因为需要用当前时间来判断键值对item是否过期。而redis的时间事件第一次是1毫秒执行，后面就是100毫秒执行一次。serverCron除了更新时间外，还做了很多工作:
1. 更新时间缓存
```
 /* Update the time cache. */
    updateCachedTime();
//***********************************
void updateCachedTime(void) {
    server.unixtime = time(NULL);
    server.mstime = mstime();
}
```
主要是因为后期有大量需要获取时间的情况，如果每次都调用time(NULL)，那么将降低系统的性能，所以在server全局变量中缓存时间，这样以后每次就可以从这获取时间了。

2. 跟新LRU时钟
```
 server.lruclock = getLRUClock();
 
```
更新时钟缓存，减少time系统调用.

3. 更新内存使用的最大值
```
 /* Record the max memory used since the server was started. */
    if (zmalloc_used_memory() > server.stat_peak_memory)
        server.stat_peak_memory = zmalloc_used_memory();

```

4. 更新常驻内存的大小
```
/* Sample the RSS here since this is a relatively slow call. */
    server.resident_set_size = zmalloc_get_rss();
```
这个函数其实取出/proc/<pid>/stat文件第23个选项，然后乘以内存页的大小即为常驻内存的大小。

5. 优雅执行shutdown
```
 if (server.shutdown_asap) {
        if (prepareForShutdown(0) == REDIS_OK) exit(0);
        redisLog(REDIS_WARNING,"SIGTERM received but errors trying to shut down the server, check the logs for more information");
        server.shutdown_asap = 0;
    }
```
当执行shutdown命令时或者产生SIGINT或者SIGTERM信号，不是直接exit退出程序，而是设置server.shutdown_asap=1，然后在时间事件中，调用prepareForShutdown函数，先准一些关闭前的操作，例如刷新aof和rdb文件，关闭监听描述符等等,最后再关闭。

6. 展示一些非空数据库信息

7. 如果是sentinel模式，展示客户端连接信息

8. 处理客户端信息
```
  /* We need to do a few operations on clients asynchronously. */
    clientsCron();
```
主要就是判断是否有客户端空闲时间超过一定值，即keepalive设置的，有的话，删除。

9. 更新数据库信息
```
 /* Handle background operations on Redis databases. */
    databasesCron();
```
主要就是哈希表扩容

10. 调度aof或者rdb读写子进程

11. 复制同步，集群同步，sentinel定时器

定时事件做的事情很多，可以说redis充分利用了定时器，这样就少了很多线程，因为memcache很多事都交给了线程，所以时间事件只是更新时间戳。

# 分析redis开启过程的一些收获

## 服务器如何监听ipv6地址

现在ipv6越来越普及，服务器也必须支持ipv6，当初getaddrinfo函数就是为了ipv6而出的。那如何监听ipv6地址了？
1. 创建ipv6套接字
```
int s=socket(AF_INET6,SOCK_STREAM,0)
```

2. 设置套接字选项IPV6_V6ONLY
```
int yes = 1;
setsockopt(s,IPPROTO_IPV6,IPV6_V6ONLY,&yes,sizeof(yes))
```

3. 当绑定或者accept地址时时，需要使用sockaddr_in6

## RSS和VSZ的区别

今天在看redis时，有看到进程获取rss的大小；在调用ps命令时，也经常看到rss和vsz这两个选项，那么这两个选项是什么意思了？

RSS(Resident Set Size)是进程常驻内存的大小,用来表示进程在RAM中分配了多少内存。RSS不包括被swapped out出去的swap内存部分，RSS包括在内存中的共享库部分，在内存中代码部分，堆，栈。

VSZ(Virtual Memory Size)是虚拟内存部分，也就是进程可以操控的内存部分。包括进程所有内存，包括在内存中或者swap out在交换空间中。

举个例子，如果一个进程有500k的二进制代码，2500k的共享库，200k的堆栈；其中100k堆栈在内存中（其他被swapped），400k的二进制代码和1000k共享库在实际内存中(其他被swapped)。
> RSS:400k+1000k+100k = 1500k
> VSZ:500k+2500k+200k = 3200k

参考stackoverflow一个帖子[What is RSS and VSZ in Linux memory management](http://stackoverflow.com/questions/7880784/what-is-rss-and-vsz-in-linux-memory-management "")
