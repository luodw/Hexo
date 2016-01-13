title: memcache源码分析之状态机
date: 2016-01-12 20:47:41
tags:
- memcache
categories:
- memcache
toc: true

---

上一篇文章分析了memcache的启动过程以及线程模型。稍微回顾下，首先主线程的libevent实例负责监听服务器listenfd，当有客户端connect时，主线程调用listenfd事件监听回调函数dispatch_conn_new将这个clientfd发送给空闲的子线程，子线程则调用管道读端的回调函数thread_libevent_process将这个clientfd放进自己的libevent事件循环中，之后这个子线程就负责这个clientfd的事务处理。

接来主要是分析客户端发送命令之后，服务器是如何处理这个命令，这就涉及到服务器端的状态机，状态机就是一个巨大的switch，针对客户端不同的状态，执行不同的程序。先来看下都有哪些状态了：
```
enum conn_states {
    conn_listening,  /**< the socket which listens for connections */
    conn_new_cmd,    /**< Prepare connection for next command */
    conn_waiting,    /**< waiting for a readable socket */
    conn_read,       /**< reading in a command line */
    conn_parse_cmd,  /**< try to parse a command from the input buffer */
    conn_write,      /**< writing out a simple response */
    conn_nread,      /**< reading in a fixed number of bytes */
    conn_swallow,    /**< swallowing unnecessary bytes w/o storing */
    conn_closing,    /**< closing this connection */
    conn_mwrite,     /**< writing out many items sequentially */
    conn_closed,     /**< connection is closed */
    conn_max_state   /**< Max state value (used for assertion) */
};
```
在这些状态中主线程的listenfd永远处于conn_listening中，用于接收客户端请求；刚连上的客户端总是conn_new_cmd状态，等待接收用户命令。其他状态很多是从conn_new_cmd开始演变的。先来看下conn_listening状态下的执行：
```
  case conn_listening:
            addrlen = sizeof(addr);
#ifdef HAVE_ACCEPT4
            if (use_accept4) {//accept4这个版本主要可以设置套接字非阻塞
                sfd = accept4(c->sfd, (struct sockaddr *)&addr, &addrlen, SOCK_NONBLOCK);
            } else {
                sfd = accept(c->sfd, (struct sockaddr *)&addr, &addrlen);
            }
#else
            //接受客户端请求
            sfd = accept(c->sfd, (struct sockaddr *)&addr, &addrlen);
#endif
            if (sfd == -1) {//accept接收错误，返回-1
                if (use_accept4 && errno == ENOSYS) {
                    use_accept4 = 0;
                    continue;
                }//如果是因为调用accept4出错，则从头开始继续执行conn_listening,第二次调用accept版本
                perror(use_accept4 ? "accept4()" : "accept()");//判断是哪个版本的accept
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    /* these are transient, so don't log anything */
                    stop = true;
                } else if (errno == EMFILE) {
                    if (settings.verbose > 0)
                        fprintf(stderr, "Too many open connections\n");
                    accept_new_conns(false);//如果连接的客户端太多，则把所有listenfd的监听事件清空，
//也就是不再接受请求
                    stop = true;
                } else {
                    perror("accept()");
                    stop = true;
                }
                break;
            }
            if (!use_accept4) {//如果调用的是accept，则将套接字设为非阻塞
                if (fcntl(sfd, F_SETFL, fcntl(sfd, F_GETFL) | O_NONBLOCK) < 0) {
                    perror("setting O_NONBLOCK");
                    close(sfd);
                    break;
                }
            }

            //如果接收了客户端套接字，发现套接字过多，则把刚接收的客户端关闭
            if (settings.maxconns_fast &&
                stats.curr_conns + stats.reserved_fds >= settings.maxconns - 1) {
                str = "ERROR Too many open connections\r\n";
                res = write(sfd, str, strlen(str));
                close(sfd);
                STATS_LOCK();
                stats.rejected_conns++;
                STATS_UNLOCK();
            } else {
                //最终没问题的话，将这个客户端分配一个空闲的子线程
                dispatch_conn_new(sfd, conn_new_cmd, EV_READ | EV_PERSIST,
                                     DATA_BUFFER_SIZE, tcp_transport);
            }

            stop = true;//设置退出while循环
            break;//退出状态机
```
这个conn_listening状态下，主要是先接收客户端的套接字，然后判断函数调用是否出错以及这个进程的文件描述符是否过多，并做相应的处理。最后都没有问题后，再将客户端的套接字发给空闲的子线程。

接下来看子线程如何处理客户发来的请求，首先进入的是状态conn_new_cmd
```
 case conn_new_cmd:
            /* 客户端每一次执行命令，最多可执行nreqs个命令，防止其他命令饥饿 */
            --nreqs;
            if (nreqs >= 0) {
                reset_cmd_handler(c);
            } else {
            
           }
            break;
```
因为首次进入这个状态，nreqs肯定大于0，所以就把else后面给删了。因为客户端一次连接可能有多条命令执行，为了防止其他连接得不到处理机会，所以限制一个客户端最多可以执行nreqs个命令。默认20条，可以通过-R设置。接下来看下reset_cmd_handler函数:
```
static void reset_cmd_handler(conn *c) {
    c->cmd = -1;
    c->substate = bin_no_state;
    if(c->item != NULL) {//这个item主要是用来存放set/add/replace命令生成的item结构
        item_remove(c->item);//所以先清空，给下一个命令
        c->item = NULL;
    }
    conn_shrink(c);//判断这个客户端连接缓冲区是否过大，是，则要缩小缓冲区
    if (c->rbytes > 0) {
        conn_set_state(c, conn_parse_cmd);
    } else {
       //因为一开始时，没有读取客户端数据，所以c->rbytes为0
        conn_set_state(c, conn_waiting);
    }
}
```
c->rbytes为客户端缓冲区中还没有被解析的缓冲区空间，除了在conn\_new中被设置为0 外，就没有被设置，所以接下来执行的是conn\_set_state(c,conn_waiting)，这函数就是简单的把状态改为了conn_waiting，好，接下来看下conn_waiting执行过程。
```
        case conn_waiting:
            if (!update_event(c, EV_READ | EV_PERSIST)) {
                if (settings.verbose > 0)
                    fprintf(stderr, "Couldn't update event\n");
                conn_set_state(c, conn_closing);
                break;
            }//将这个客户端更新为可读事件
            conn_set_state(c, conn_read);//状态更新为conn_read
            stop = true;
            break;//退出状态机
```
很多奇怪，都没读取客户端的数据，怎么退出这个状态机了。到底是怎么回事了？原来是libevent的epoll默认使用的是“水平触发”，即只要有数据在接收缓冲区中，就会通知读事件。所以在下一个libevent事件轮询中，这个clientfd又触发可读事件，这时的状态为conn_read，来看下这个conn_read是怎么执行的。
```
   case conn_read:
            res = IS_UDP(c->transport) ? try_read_udp(c) : try_read_network(c);

            switch (res) {
            case READ_NO_DATA_RECEIVED:
                conn_set_state(c, conn_waiting);
                break;
            case READ_DATA_RECEIVED:
                conn_set_state(c, conn_parse_cmd);
                break;
            case READ_ERROR:
                conn_set_state(c, conn_closing);
                break;
            case READ_MEMORY_ERROR: /* Failed to allocate more memory */
                /* State already set by try_read_network */
                break;
            }
            break;
```
进入conn_read之后才开始从套接字读取set xxx\r\n。
```
static enum try_read_result try_read_network(conn *c) {
    enum try_read_result gotdata = READ_NO_DATA_RECEIVED;//默认返回的状态为没有取到数据
    int res;
    int num_allocs = 0;
    assert(c != NULL);

    if (c->rcurr != c->rbuf) {
        if (c->rbytes != 0) /* c->rbuf中还有数据未处理 */
            memmove(c->rbuf, c->rcurr, c->rbytes);//将未处理数据移至c->rbuf起始处
        c->rcurr = c->rbuf;
    }

    while (1) {
        if (c->rbytes >= c->rsize) {//读buffer空间扩充
            if (num_allocs == 4) {
                return gotdata;
            }
            ++num_allocs;
            char *new_rbuf = realloc(c->rbuf, c->rsize * 2);
            if (!new_rbuf) {
                STATS_LOCK();
                stats.malloc_fails++;
                STATS_UNLOCK();
                if (settings.verbose > 0) {
                    fprintf(stderr, "Couldn't realloc input buffer\n");
                }
                c->rbytes = 0; /* ignore what we read */
                out_of_memory(c, "SERVER_ERROR out of memory reading request");
                c->write_and_go = conn_closing;
                return READ_MEMORY_ERROR;
            }
            c->rcurr = c->rbuf = new_rbuf;//指向新的缓存空间
            c->rsize *= 2;//缓存大小翻倍
        }

        int avail = c->rsize - c->rbytes;//读buffer中可用的空间
        res = read(c->sfd, c->rbuf + c->rbytes, avail);//读取数据
        if (res > 0) {
            pthread_mutex_lock(&c->thread->stats.mutex);
            c->thread->stats.bytes_read += res;
            pthread_mutex_unlock(&c->thread->stats.mutex);
            gotdata = READ_DATA_RECEIVED;
            c->rbytes += res;//已分配使用的内存+res
            if (res == avail) {
                continue;
            } else {
                break;
            }
        }
        if (res == 0) {
            return READ_ERROR;//表明客户端断开连接，所以服务器将关闭这个客户端连接
        }
        if (res == -1) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                break;
            }
            return READ_ERROR;
        }
    }
    return gotdata;
}
```
这个读取数据函数，如果c-rbytes>=r->rsize，说明客户端的读buffer缓存已满，这时要进行buffer扩充，然后再读取数据。读取数据之后，还有判断是否还有数据可读，即判断读buffer是否已满，如果是，则还要进行第二次读buffer扩容，最多执行4次扩容。好，假设数据已经读取到读buffer里了，接来返回的是READ_DATA_RECEIVED，这个值所处的代码区将客户端状态改为conn_parse_cmd：
```
  case conn_parse_cmd :
            if (try_read_command(c) == 0) {
                /* wee need more data! */
                conn_set_state(c, conn_waiting);
            }

            break;
```
因为客户端读buffer中数据可能还不是一条完整的命令，所以这里也只是try_read_command,如果真的返回0，则重新进入conn_waiting状态，等待下一次轮询中读取数据。假设读buffer中已经有一条完整的命令，接下来看下是如何读取这个命令的。这里把主要代码摘过来
```
static int try_read_command(conn *c) {
         char *el, *cont;

        if (c->rbytes == 0)//没有数据，则直接返回0退出
            return 0;

        el = memchr(c->rcurr, '\n', c->rbytes);//找到第一条命令结尾，'\n'
        if (!el) {
           //.....
           /*
           如没有没有找到换行符，则说明读buffer中还不是一条完整的命令，则返回0
           */
            return 0;
        }
        cont = el + 1;//cont为下一条命令第一个字节
        /*
        下面这个if的作用就是把命令中的\r换成'\0'，这样在读取c->rcurr时，就
        可以读取完整的一条命令
        */
        if ((el - c->rcurr) > 1 && *(el - 1) == '\r') {
            el--;
        }
        *el = '\0';

        assert(cont <= (c->rcurr + c->rbytes));

        c->last_cmd_time = current_time;
        process_command(c, c->rcurr);//执行命令，详见process_command函数

        c->rbytes -= (cont - c->rcurr);//读buffer还没被解析的字节数
        c->rcurr = cont;//把c->rcurr指向下一个命令开头

        assert(c->rcurr <= (c->rbuf + c->rsize));
    }

    return 1;
}
```
这个函数先将命令的的\r替换成\0，这样在读取c->rcurr时，可以整体命令，然后调用process_command处理命令，最后更新c->rbytes和c->rcurr指向下一条命令。

这里科普下memcache的set命令协议，一条完整的set命令需要两行，也就是需要按两次回车换行“\r\n”，第一行叫“命令行”，格式是SET key flags exptime bytes\r\n，如SET name 0 0 5\r\n， 键为name，flags标志位可暂时不管，超时设为0，value的字节长度是4。然后才有第二行叫“数据行”，格式为：value\r\n，例如：calix\r\n。这两行分别敲下去，SET命令才算完成。

下面看下process_command是如何处理命令的。
```
static void process_command(conn *c, char *command) {

    token_t tokens[MAX_TOKENS];
    size_t ntokens;
    int comm;
    assert(c != NULL);
    //将命令行分割成一个一个字符串
    ntokens = tokenize_command(command, tokens, MAX_TOKENS);
    if (ntokens >= 3 &&
        ((strcmp(tokens[COMMAND_TOKEN].value, "get") == 0) ||
         (strcmp(tokens[COMMAND_TOKEN].value, "bget") == 0))) {
        //执行get命令函数
        process_get_command(c, tokens, ntokens, false);

    } else if ((ntokens == 6 || ntokens == 7) &&
               ((strcmp(tokens[COMMAND_TOKEN].value, "add") == 0 && (comm = NREAD_ADD)) ||
                (strcmp(tokens[COMMAND_TOKEN].value, "set") == 0 && (comm = NREAD_SET)) ||
                (strcmp(tokens[COMMAND_TOKEN].value, "replace") == 0 && (comm = NREAD_REPLACE)) ||
                (strcmp(tokens[COMMAND_TOKEN].value, "prepend") == 0 && (comm = NREAD_PREPEND)) ||
                (strcmp(tokens[COMMAND_TOKEN].value, "append") == 0 && (comm = NREAD_APPEND)) )) {
        //执行set命令函数
        process_update_command(c, tokens, ntokens, comm, false);
        return;
```
这个process_command这个函数就是根据不同的命令执行不同的函数，我们针对set命令，介绍下procee_update_command函数：
```
static void process_update_command(conn *c, token_t *tokens, const size_t ntokens, int comm, bool handle_cas) {
    //分配一个item结构，存储数据
    it = item_alloc(key, nkey, flags, realtime(exptime), vlen);

    if (it == 0) {//没有分配到item
        if (! item_size_ok(nkey, flags, vlen))//item数据太大
            out_string(c, "SERVER_ERROR object too large for cache");
        else
            out_of_memory(c, "SERVER_ERROR out of memory storing object");
        /* swallow the data line */
        c->write_and_go = conn_swallow;
        c->sbytes = vlen;

        /* Avoid stale data persisting in cache because we failed alloc.
         * Unacceptable for SET. Anywhere else too? */
        if (comm == NREAD_SET) {
            it = item_get(key, nkey);
            if (it) {
                item_unlink(it);
                item_remove(it);
            }
        }

        return;
    }
    ITEM_set_cas(it, req_cas_id);

    c->item = it;//item指向这个It
    c->ritem = ITEM_data(it);//ritem指向it的数据部分
    c->rlbytes = it->nbytes;//这个item数据长度
    c->cmd = comm;//命令类型
    conn_set_state(c, conn_nread);
}
```
这个函数主要是调用调用item_alloc分配内存，这时的item还是由client的conn管理，而且此时还未存入数据，并把ritem指向这个item的数据部分，等有读取数据之后，再将数据拷贝到ritem。接来下，看下conn_nread读取数据行部分
```
  case conn_nread:
            if (c->rlbytes == 0) {
                complete_nread(c);
                break;
            }
            /*
	    因为conn中的读buffer还不一定保存有所有数据行需要的数据，所以
            读取rbytes(读buffer还未解析的数据长度)和rlbytes(这个item的数据
            部分长度)的最小值。           
 	    */
             if (c->rbytes > 0) {
                int tocopy = c->rbytes > c->rlbytes ? c->rlbytes : c->rbytes;
                if (c->ritem != c->rcurr) {
                    memmove(c->ritem, c->rcurr, tocopy);//将数据拷贝之item数据部分
                }
                c->ritem += tocopy;
                c->rlbytes -= tocopy;
                c->rcurr += tocopy;
                c->rbytes -= tocopy;
                if (c->rlbytes == 0) {//数据部分全部读取完毕，则退出这个状态
                    break;
                }
            }

            /*  now try reading from the socket */
            res = read(c->sfd, c->ritem, c->rlbytes);//从socket缓冲区中读取数据剩余部分
            if (res > 0) {
                pthread_mutex_lock(&c->thread->stats.mutex);
                c->thread->stats.bytes_read += res;
                pthread_mutex_unlock(&c->thread->stats.mutex);
                if (c->rcurr == c->ritem) {
                    c->rcurr += res;
                }
                c->ritem += res;
                c->rlbytes -= res;
                break;
            }
            if (res == 0) { /* end of stream */
                conn_set_state(c, conn_closing);
                break;
            }
```
当把数据行部分全部读进item的数据部分之后，则调用complete_nread执行一些扫尾工作
```
static void complete_nread(conn *c) {
    assert(c != NULL);
    assert(c->protocol == ascii_prot
           || c->protocol == binary_prot);

    if (c->protocol == ascii_prot) {
        complete_nread_ascii(c);
    } else if (c->protocol == binary_prot) {
        complete_nread_binary(c);
    }
}
```
我们调用的是ascii协议，所以接下来执行的是complete_nread_ascii函数：
```
static void complete_nread_ascii(conn *c) {
    assert(c != NULL);

    item *it = c->item;
    int comm = c->cmd;
    enum store_item_type ret;
    ret = store_item(it, comm, c);
    //。。。。
	 switch (ret) {
      case STORED:
          out_string(c, "STORED");
          break;
```
这个函数主要是将conn上的item存入LRU和哈希表中，然后判断返回的存储结果，并向客户端输出结果
```
static void out_string(conn *c, const char *str) {
    size_t len;
    c->msgused = 0;
    c->iovused = 0;
    add_msghdr(c);

    len = strlen(str);
    if ((len + 2) > c->wsize) {
        /* ought to be always enough. just fail for simplicity */
        str = "SERVER_ERROR output line too long";
        len = strlen(str);
    }

    memcpy(c->wbuf, str, len);//将输出字符串存入wbuf中，
    memcpy(c->wbuf + len, "\r\n", 2);//输出字符串结尾加回车换行
    c->wbytes = len + 2;
    c->wcurr = c->wbuf;

    conn_set_state(c, conn_write);//设置状态为conn_write
    c->write_and_go = conn_new_cmd;//conn_write处理之后的状态
    return;
}
```
这个函数将需要返回给客户端的数据存入wbuf中，然后将状态改为conn_write,准备输出
```
        case conn_write:
	   {
             //....
            }
        case conn_mwrite:
          //。。。。
          switch (transmit(c)) 
         static enum transmit_result transmit(conn *c) {
               //。。。。
               res = sendmsg(c->sfd, m, 0);
               //。。。
         }
```
最后先是在conn_write程序段中，将返回消息封装称msghdr，然后在transmit函数中调用sendmsg将消息发送给客户端。最后给张状态机的状态转换图，图片来自[Calix 善于总结](http://calixwu.com/2014/11/memcached-yuanmafenxi-qingqiuchuli-zhuangtaiji.html "")
![状态机转换](http://7xjnip.com1.z0.glb.clouddn.com/选区_053.png "")。

总结下，本文章，分析了服务器接收一个客户端发送的命令，处理命令以及返回给客户端信息的整个过程，本过程以set命令为例，其他命令类似，只要跟着状态机状态变化走即可，单要注意libevent的epoll是水平触发的，所以状态机在没有读取客户端数据时可以先退出，然后重新得到通知。
























