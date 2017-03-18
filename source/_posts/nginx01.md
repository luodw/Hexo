title: nginx是这么运行的
date: 2017-03-17 11:19:36
tags:
- nginx
categories:
- nginx

toc: true

---

很早之前就有看nginx的冲动，但是一直被一些事耽搁着，最近在繁忙之中，抽出点时间，看了下nginx代码，发现整体上并不是很难看懂，而且刚好想学习nginx+lua开发，因此，决定在今后一段时间内，对技术的时间投入都放在nginx+lua了。nginx在互联网公司使用很广，最重要的功能当属反向代理和负载均衡了吧，当然还有缓存；所以对nginx的熟悉使用和深入了解，对于一名后台开发人员，至关重要。

记得我之前在很多文章有提到，后台组件框架主要有三种：redis单进程单线程，memcache单进程多线程，nginx多进程；等看了nginx之后，我也算集齐了；nginx以模块化方式开发，比如核心模块，event模块，http模块，然后为了支持多平台，event模块下又有对各大平台的封装支持，例如linux平台epoll，mac平台kqueue等等；然后http模块也被拆分成了很多子模块。

这篇文章算是我自己做的笔记吧，把之前研究的东西记录下。也许是之前看过redis和golang以及python的http框架，nginx整体框架比较容易就看懂了，当然很多细节还需后面慢慢看；这篇文章主要介绍nginx是如何开启，以及请求是怎么执行的，所以这篇文章主要就是以下两点：
1. nginx开启流程;
2. 重要回调函数设置；
3. nginx处理http请求；
4. 总结

# 1. nginx开启流程

----

nginx体量很大，想要在较短时间内看完所有代码很难，而且我看得时间也不是很多，所以，这里主要站在宏观角度，对nginx做个整体剖析；其实如果直接从main函数直接开始看，其实也是可以看懂大部分，但是nginx回调函数太多了，看着看着，突然跑出一个回调函数，经常就懵逼了；因此，就需要用gdb来定点调试；

要使用gdb，首先需要在gcc编译时，加入-g选项，可以如下操作：
1. 打开nginx目录/auto/cc/conf文件，然后更改ngx\_compile\_opt="-c"选项，添加-g，即为ngx\_compile\_opt="-c -g";
2. 然后运行./configure和make即可编译生成可执行文件，在文件objs目录下;

生成可执行文件nginx之后，直接在终端运行即可，nginx会加载默认配置文件，以daemon形式运行;

nginx运行之后，即可通过gdb来调试;按如下命令开启gdb
```
gdb -q -tui
// -q 安静模式，即不输出多余信息，-tui提供一个窗口显示代码
```

然后，通过pidof命令获取nginx进程号，即可attach，如下：
```
shell pidof nginx 
```
nginx默认开启一个master进程和一个worker进程，因此上述命令会返回两个进程号，在我主机上8125和8126，较小是master进程，较大的是worker进程；接下来，先看下master进程，
```
attach 8125
```
这样就可以直接调试nginx的worker进程，用命令bt可以查看master进程的函数栈
```
(gdb) bt
#0  0x00007efd445d9f76 in do_sigsuspend (set=0x7ffe517ce5d0) at ../sysdeps/unix/sysv/linux/sigsuspend.c:31
#1  __GI___sigsuspend (set=set@entry=0x7ffe517ce5d0) at ../sysdeps/unix/sysv/linux/sigsuspend.c:41
#2  0x000000000042cc12 in ngx_master_process_cycle (cycle=cycle@entry=0x181f110) at src/os/unix/ngx_process_cycle.c:163
#3  0x000000000040c83d in main (argc=<optimized out>, argv=<optimized out>) at src/core/nginx.c:367
```
nginx开启之后，首先启动的就是master进程，从main函数开始，
1. main函数主要是做一些初始化操作，初始化启动参数，开启daemon，新建pid文件等等，然后调用ngx\_master\_process\_cycle函数；
2. 在ngx\_master\_process\_cycle函数中最重要就是开启子进程，然后调用sigsuspend函数，master进程则阻塞在在信号中；

因此，master进程任务就是开启子进程，然后管理子进程；怎么管理了？

信号，对，就是信号；当master进程收到一个信号之后，就把这个信号传递给worker进程，worker进程进而根据不同信号分别处理；那么问题又来了，master进程是如何把信号传递给worker进程的？

管道，对，就是管道；原理和memcache的master线程和worker线程通信机制一样；即每个worker进程有两个文件描述符fd[0]和fd[1]，一个读端，一个写端；worker进程将读端加入epoll事件监听，当master进程收到一个信号后，在每个worker进程写端写入一个flag，然后worker进程触发读事件，读取flag，并根据flag做相应操作。

因此nginx接收客户端请求以及处理客户端请求，主要是在worker进程，我们来看下，worker进程函数栈
```
(gdb) attach 8126
(gdb) bt
#0  0x00007efd4469d9f3 in __epoll_wait_nocancel () at ../sysdeps/unix/syscall-template.S:81
#1  0x000000000042dcae in ngx_epoll_process_events (cycle=0x181f110, timer=18446744073709551615, flags=1) at src/event/modules/ngx_epoll_module.c:717
#2  0x0000000000426225 in ngx_process_events_and_timers (cycle=cycle@entry=0x181f110) at src/event/ngx_event.c:242
#3  0x000000000042c15a in ngx_worker_process_cycle (cycle=0x181f110, data=<optimized out>) at src/os/unix/ngx_process_cycle.c:753
#4  0x000000000042ac46 in ngx_spawn_process (cycle=cycle@entry=0x181f110, proc=proc@entry=0x42c0d9 <ngx_worker_process_cycle>, data=data@entry=0x0, 
    name=name@entry=0x47a4cf "worker process", respawn=respawn@entry=-3) at src/os/unix/ngx_process.c:198
#5  0x000000000042c2b7 in ngx_start_worker_processes (cycle=cycle@entry=0x181f110, n=1, type=type@entry=-3) at src/os/unix/ngx_process_cycle.c:358
#6  0x000000000042cb13 in ngx_master_process_cycle (cycle=cycle@entry=0x181f110) at src/os/unix/ngx_process_cycle.c:130
#7  0x000000000040c83d in main (argc=<optimized out>, argv=<optimized out>) at src/core/nginx.c:367
```
因为worker进程是由master进程fork出来，因此worker进程包含master进程的函数栈；我们直接从#5函数开始看，
1. ngx\_start\_worker\_processes 函数调用ngx\_spawn\_process开启子进程，并且设置master进程和worker进程通信的管道；
2. ngx\_spawn\_process函数主要是设置master进程和worker进程间通信管道，例如非阻塞等等，然后通过fork函数正式开启子进程；子进程调用通过参数传递进来的回调函数ngx\_worker\_process\_cycle正式切入子进程部分，父进程则接着设置worker进程相关属性；
3. ngx\_worker\_process\_cycle一开始调用ngx\_worker\_process\_init函数对worker进程做些初始化设置，包括设置进程优先级，worker进程允许打开的最大文件描述符，对阻塞信号的设置，初始化所有模块，将master进程和worker进程间通信管道添加到监听可读事件等等；然后在一个无限循环中，函数ngx\_worker\_process\_cycle接着调用ngx\_process\_events\_and\_timers，开启事件监听循环；
4. 在ngx\_process\_events\_and\_timers函数中，先是获取锁，如果获取到锁，listenfd即可接收客户端，否则listenfd不可接收客户端事件；然后调用ngx\_process\_events函数，这个函数也就是ngx\_epoll\_process\_events函数，开启开启事件监听；

ok，worker进程此时已就绪，等待客户端连接以及请求数据；为了避免惊群现象以及实现worker进程负载均衡，每次有客户端连接时，所有worker进程会先争抢锁，如果某个worker进程获取到锁，即可执行接收客户端和客户端请求事件；如果worker进程没有争抢到锁，只执行客户端请求事件。


# 2. 重要回调函数设置

------

当nginx的master进程和worker进程开启之后，客户端即可发送请求；接下来，就看看nginx是如何处理请求的；

当客户端发送请求之后，首先是通过tcp三次握手建立连接；当连接建立成功之后，即执行listenfd的回调函数，但是listenfd的回调函数是哪个了？这对于新手来说，其实是很难发现listenfd回调函数；下面分析下；

> 像listenfd的回调函数以及模块间是如何拼凑在一起，这些几乎都是在模块初始化时完成的。对于listenfd的回调函数即是在event模块初始化时或者调用event模块一些设置函数时设置；客户端连接上服务器之后，服务器收到请求之后的回调函数也是在http模块初始化时或者调用模http模块一些设置函数时设置的。

在event模块初始化时，调用的是ngx\_event\_process\_init函数，下面列出这个函数最重要的代码:
```
static ngx_int_t
ngx_event_process_init(ngx_cycle_t *cycle)
{
    //.......
    for (m = 0; ngx_modules[m]; m++) {
        if (ngx_modules[m]->type != NGX_EVENT_MODULE) {
            continue;
        }

        if (ngx_modules[m]->ctx_index != ecf->use) {
            continue;
        }

        module = ngx_modules[m]->ctx;

        if (module->actions.init(cycle, ngx_timer_resolution) != NGX_OK) {
            /* fatal */
            exit(2);
        }

        break;
   　 }
    //..........
    for (i = 0; i < cycle->listening.nelts; i++) {
        rev->handler = ngx_event_accept;

            if (ngx_use_accept_mutex) {
                continue;
            }

            if (ngx_event_flags & NGX_USE_RTSIG_EVENT) {
                if (ngx_add_conn(c) == NGX_ERROR) {
                    return NGX_ERROR;
                }

            } else {
                if (ngx_add_event(rev, NGX_READ_EVENT, 0) == NGX_ERROR) {
                    return NGX_ERROR;
                }
            }
    }
```
在for循环中，迭代每个监听套接字，recv为listenfd连接对象的读事件，这里设置listenfd读事件的回调函数为ngx\_event\_accept函数，然后将每个listenfd添加到事件监听中，并设置为可读事件。

ok，当我们去看ngx\_add\_conn和ngx\_add\_event的定义时，如下：
```
#define ngx_add_event        ngx_event_actions.add
#define ngx_add_conn         ngx_event_actions.add_conn
```
说明ngx\_add\_conn和ngx\_add\_event都是结构体ngx\_event\_actions结构体中设置的函数指针；其实这个ngx\_event\_actions就是nginx跨平台的关键，因为不同平台使用的事件监听器是不一样的，导致ngx\_event\_actions也就不一样。例如linux使用的是epoll，因此ngx\_event\_actions结构体就是在epoll模块加载时设置，在上述代码前半部分。我们来看下epoll模块actions.init函数：
```
// ngx_epoll_module.c
static ngx_int_t
ngx_epoll_init(ngx_cycle_t *cycle, ngx_msec_t timer)
{
    //......
    nevents = epcf->events;
    ngx_io = ngx_os_io;
    ngx_event_actions = ngx_epoll_module_ctx.actions;
    //......
    return NGX_OK;
}
```
从代码可以看出，ngx\_event\_actions被设置为ngx\_epoll\_module_ctx.actions，接着看下这个结构体:
```
ngx_event_module_t  ngx_epoll_module_ctx = {
    &epoll_name,
    ngx_epoll_create_conf,               /* create configuration */
    ngx_epoll_init_conf,                 /* init configuration */

    {// actions
        ngx_epoll_add_event,             /* add an event */
        ngx_epoll_del_event,             /* delete an event */
        ngx_epoll_add_event,             /* enable an event */
        ngx_epoll_del_event,             /* disable an event */
        ngx_epoll_add_connection,        /* add an connection */
        ngx_epoll_del_connection,        /* delete an connection */
        NULL,                            /* process the changes */
        ngx_epoll_process_events,        /* process the events */
        ngx_epoll_init,                  /* init the events */
        ngx_epoll_done,                  /* done the events */
    }
};
```
因此，当调用ngx\_add\_conn和ngx\_add\_event时，分别调用的是ngx\_epoll\_add\_connection和ngx\_epoll\_add\_event;如此一来，如果此时是mac平台，那么使用的事件监听器是kqueue，那么当调用ngx\_add\_event时，调用的就是ngx\_kqueue\_add\_event。如果使用的poll监听器，那么调用将是ngx\_poll\_add\_event等等。

接下来，再分析一个很重要的回调函数，即客户端连上客户端之后，发送请求时的回调函数，先来看下，listenfd回调函数
```
void
ngx_event_accept(ngx_event_t *ev)
{
    //......
    do {
        socklen = NGX_SOCKADDRLEN;
        //......
        s = accept(lc->fd, (struct sockaddr *) sa, &socklen);
        //.......
         ngx_accept_disabled = ngx_cycle->connection_n / 8
                              - ngx_cycle->free_connection_n;

        c = ngx_get_connection(s, ev->log);
        //.......
         if (ngx_add_conn && (ngx_event_flags & NGX_USE_EPOLL_EVENT) == 0) {
            if (ngx_add_conn(c) == NGX_ERROR) {
                ngx_close_accepted_connection(c);
                return;
            }
        }
        log->data = NULL;
        log->handler = NULL;

        ls->handler(c);
        //.....
    }
}  
```

当客户端连接服务器时，首先listenfd回调函数先是调用accept函数接收客户端请求，然后从对象池中获取一个封装客户端socket连接对象，如果目前使用的是epoll事件监听器，则调用ngx\_add\_conn(c)放入事件监听，最后调用ngx\_listening\_t的回调函数，对客户端连接进一步操作；ok，这个ls->handler(c)是个啥？我在第一次看代码时，一脸懵逼！！！还记得之前说的吗？模块之间的衔接，几乎都是在模块初始化或者调用模块一些设置函数时设置的，因此接下来，就来看看http模块初始化时做了什么。http模块并没有在模块初始化函数中设置ls->handler(c)，而是在当读取到"http"命令时，执行命令函数ngx\_http\_block中设置；
```
static char *
ngx_http_block(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    //......
    if (ngx_http_optimize_servers(cf, cmcf, cmcf->ports) != NGX_OK) {
        return NGX_CONF_ERROR;
    }
    //......
}
------------------------------------------------------------------------
static ngx_int_t
ngx_http_optimize_servers(ngx_conf_t *cf, ngx_http_core_main_conf_t *cmcf,
    ngx_array_t *ports)
{
    //........
     if (ngx_http_init_listening(cf, &port[p]) != NGX_OK) {
            return NGX_ERROR;
    }
    //.........
}
--------------------------------------------------------------------------
static ngx_int_t
ngx_http_init_listening(ngx_conf_t *cf, ngx_http_conf_port_t *port)
{
    //.........
      ls = ngx_http_add_listening(cf, &addr[i]);
        if (ls == NULL) {
            return NGX_ERROR;
        }
    //.........
}
------------------------------------------------------------------
static ngx_listening_t *
ngx_http_add_listening(ngx_conf_t *cf, ngx_http_conf_addr_t *addr)
{
    //........................
     ls->handler = ngx_http_init_connection;
     //.........................
}
```
真是藏的够深，经历了四个函数，终于看到ls-handler设置函数了，即为ngx\_http\_init\_connection函数，而这个函数在http模块，为客户端http请求处理的入口函数；到此为止，我们可以知道服务器在接收到客户端之后，首先将客户端封装成ngx\_connection\_t结构体，然后交给http模块执行http请求。

# 3. nginx处理http请求

----

nginx处理http的请求是nginx最重要的职能，也是最复杂的一部分。可以大概说下执行流程：
1. 读取解析请求行；
2. 读取解析请求头；
3. 开始最重要的部分，即多阶段处理；nginx把请求处理划分成了11个阶段，也就是说当nginx读取了请求行和请求头之后，将请求封装了结构体ngx\_http\_request\_t，然后每个阶段的handler都会根据这个ngx\_http\_request\_t，对请求进行处理，例如重写uri，权限控制，路径查找，生成内容以及记录日志等等；
4. 将结果返回给客户端；

多阶段处理是nginx模块最重要的部分，因为第三方模块也是注册在这；例如有人写了一个利用nginx和memcache做页面缓存的第三方模块，也可以把memcache换成redis集群等等；而且nginx多阶段处理有点类似python和golang　web框架的中间件，后者主要是用装饰器模式，对handler一层一层封装，而nginx是用数组（链表）形式组合多阶段handler，然后按handler链表执行即可；

因为多阶段这块内容还没完全看懂，所以跟着网上教程，写了个最简单的第三方模块，用于设置定点调试，观察http阶段函数执行过程，步骤如下：
1. 在nginx目录下新建一个目录thm（third mudole），在新建一个foo目录（foo模块），然后在foo目录下新建ngx\_http\_foo\_module.c
```
#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

static ngx_int_t ngx_http_foo_init(ngx_conf_t *cf);

static ngx_int_t ngx_http_foo_handler(ngx_http_request_t *r);

static ngx_http_module_t ngx_http_foo_module_ctx = {
    NULL,                              /* preconfiguration */
    ngx_http_foo_init,                 /* postconfiguration */

    NULL,                              /* create main configuration */
    NULL,                              /* init main configuration */

    NULL,                              /* create server configuration */
    NULL,                              /* merge server configuration */

    NULL,                              /* create location configuration */
    NULL                               /* merge location configuration */
};

ngx_module_t  ngx_http_foo_module = {
    NGX_MODULE_V1,
    &ngx_http_foo_module_ctx,                      /* module context */
    NULL,                                          /* module directives */
    NGX_HTTP_MODULE,                               /* module type */
    NULL,                                          /* init master */
    NULL,                                          /* init module */
    NULL,                                          /* init process */
    NULL,                                          /* init thread */
    NULL,                                          /* exit thread */
    NULL,                                          /* exit process */
    NULL,                                          /* exit master */
    NGX_MODULE_V1_PADDING
};
static ngx_int_t
ngx_http_foo_handler(ngx_http_request_t *r)
{
    ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
            "#### hello, this FOO module");

    return NGX_DECLINED;
}

static ngx_int_t
ngx_http_foo_init(ngx_conf_t *cf)
{
    ngx_http_handler_pt               *h;

    ngx_http_core_main_conf_t         *cmcf;

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);

    h = ngx_array_push(&cmcf->phases[NGX_HTTP_CONTENT_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }

    *h = ngx_http_foo_handler;

    return NGX_OK;
}
```
然后同样是在foo目录下新建一个配置文件config
```
ngx_addon_name=ngx_http_foo_module
HTTP_MODULES="$HTTP_MODULES ngx_http_foo_module"
NGX_ADDON_SRCS="$NGX_ADDON_SRCS $ngx_addon_dir/ngx_http_foo_module.c"
```
这样，一个最简单的第三方模块就编写完成，上述两个函数很好理解，一个是初始化函数，将这个模块的handler注册到某个阶段中，这个例子是在阶段NGX\_HTTP\_CONTENT\_PHASE，然后当程序执行到上述阶段时，即可执行foo模块；最后重新编译生成可执行文件即可。

接下来，利用gdb来看下http执行过程，把定点设置在
```
(gdb) b ngx_http_foo_handler
Breakpoint 1 at 0x47617e: file ./thm/foo/ngx_http_foo_module.c, line 41.
(gdb) c
Continuing.

Breakpoint 1, ngx_http_foo_handler (r=0x175bf70) at ./thm/foo/ngx_http_foo_module.c:41
41	    ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
(gdb) bt
#0  ngx_http_foo_handler (r=0x175bf70) at ./thm/foo/ngx_http_foo_module.c:41
#1  0x0000000000435f76 in ngx_http_core_content_phase (r=0x175bf70, ph=0x176f408) at src/http/ngx_http_core_module.c:1377
#2  0x0000000000430f43 in ngx_http_core_run_phases (r=r@entry=0x175bf70) at src/http/ngx_http_core_module.c:847
#3  0x000000000043105c in ngx_http_handler (r=r@entry=0x175bf70) at src/http/ngx_http_core_module.c:830
#4  0x0000000000438d66 in ngx_http_process_request (r=r@entry=0x175bf70) at src/http/ngx_http_request.c:1910
#5  0x000000000043add5 in ngx_http_process_request_headers (rev=rev@entry=0x1776590) at src/http/ngx_http_request.c:1342
#6  0x000000000043b083 in ngx_http_process_request_line (rev=rev@entry=0x1776590) at src/http/ngx_http_request.c:1022
#7  0x000000000043b767 in ngx_http_wait_request_handler (rev=0x1776590) at src/http/ngx_http_request.c:499
#8  0x000000000042de5c in ngx_epoll_process_events (cycle=<optimized out>, timer=<optimized out>, flags=<optimized out>)
    at src/event/modules/ngx_epoll_module.c:822
#9  0x0000000000426225 in ngx_process_events_and_timers (cycle=cycle@entry=0x1751110) at src/event/ngx_event.c:242
#10 0x000000000042c15a in ngx_worker_process_cycle (cycle=0x1751110, data=<optimized out>) at src/os/unix/ngx_process_cycle.c:753
#11 0x000000000042ac46 in ngx_spawn_process (cycle=cycle@entry=0x1751110, proc=proc@entry=0x42c0d9 <ngx_worker_process_cycle>, data=data@entry=0x0, 
    name=name@entry=0x47a4cf "worker process", respawn=respawn@entry=-3) at src/os/unix/ngx_process.c:198
#12 0x000000000042c2b7 in ngx_start_worker_processes (cycle=cycle@entry=0x1751110, n=1, type=type@entry=-3) at src/os/unix/ngx_process_cycle.c:358
#13 0x000000000042cb13 in ngx_master_process_cycle (cycle=cycle@entry=0x1751110) at src/os/unix/ngx_process_cycle.c:130
#14 0x000000000040c83d in main (argc=<optimized out>, argv=<optimized out>) at src/core/nginx.c:367
```
简要说明下上述函数，我阅读的版本和运行版本不一样，因此上述仅供参考:
1. 当有客户端发送tcp连接请求时，ngx\_epoll\_process\_events返回listenfd可读事件，调用ngx\_event\_accept函数接收客户端请求，然后将请求封装成ngx\_connection\_t结构体，最后调用ngx\_http\_init\_connection函数进入http处理；
2. 在新版nginx中，并没有看到ngx\_http\_wait\_request\_handler,而是改成了ngx\_http\_init\_connection(ngx_connection_t *c)函数，然后在这个函数内部调用ngx\_http\_init\_request函数初始化请求结构体ngx\_http\_request\_t以及调用ngx\_http\_process\_request\_line函数；
3. ngx\_http\_process\_request\_line函数内部先是调用ngx\_http\_read\_request\_header函数将请求行读取到缓存中，然后调用ngx\_http\_parse\_request\_line函数解析出请求行信息，最后调用ngx\_http\_process\_request\_header处理请求头；
4. 在函数ngx\_http\_process\_request\_header内部先是调用函数ngx\_http\_read\_request\_header读取请求头，然后调用ngx\_http\_parse\_header\_line函数解析出请求头，接着调用ngx\_http\_process\_request\_header函数对请求头进行必要的验证，最后调用ngx\_http\_process\_request函数处理请求；
5. 在ngx\_http\_process\_request函数内部调用ngx\_http\_handler(ngx\_http\_request\_t *r)函数，而在ngx\_http\_handler(ngx\_http\_request\_t *r)函数内部调用
函数ngx\_http\_core\_run\_phases进行多阶段处理；
6. 我们来看下多阶段处理函数ngx\_http\_core\_run\_phases
```
void
ngx_http_core_run_phases(ngx_http_request_t *r)
{
    ngx_int_t                   rc;
    ngx_http_phase_handler_t   *ph;
    ngx_http_core_main_conf_t  *cmcf;

    cmcf = ngx_http_get_module_main_conf(r, ngx_http_core_module);

    ph = cmcf->phase_engine.handlers;

    while (ph[r->phase_handler].checker) {

        rc = ph[r->phase_handler].checker(r, &ph[r->phase_handler]);

        if (rc == NGX_OK) {
            return;
        }
    }
}
```
http多阶段处理，每个阶段可能对应一个handler，也可能对应多个handler，而每个阶段对应同一个checker，因此上述while循环中，迭代所有http模块handler，然后在handler函数中根据请求结构体ngx\_http\_request\_t做出相应的处理；上述gdb调试结果，可以看出NGX\_HTTP\_CONTENT\_PHASE阶段的checker函数为ngx\_http\_core\_content\_phase，然后再在这个checker函数内部执行foo模块的handler（ngx\_http\_foo\_handler）。

等到多阶段处理结束之后，最后再将response返回给客户端。


# 4. 总结

这篇文章主要就是宏观分析下nginx整体运行流程，因为第一次看nginx时，有很多看不懂的地方，所以这篇文章也算是做笔记吧。后续还需认真看多阶段处理，因为第三方开发模块也是注册在多阶段过程，以及熟悉ngx+lua模块开发。



























