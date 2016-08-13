title: 从内核源码聊聊pipe实现
date: 2016-08-13 16:42:50
tags:
- pipe
categories:
- pipe

toc: true

---

用linux也有两年多了，从命令，系统调用，到内核原理一路学过来，我发现我是深深喜欢上这个系统；使用起来就是一个字“爽”；当初在看linux内核原理时，对linux内核源码有种敬畏的心理，不敢涉入，主要是看不懂，直到最近实习的时候，在某次分享会上，某位老师分享了OOM机制，我很感兴趣，就去看内核代码，发现，原来我能看懂了；所以想写篇博客，分享下从内核代码分析pipe的实现；

![厦大上弦场](http://7xjnip.com1.z0.glb.clouddn.com/ldw-39310_2010129_676673.jpg)

这部分内容说简单也很简单，说难也难，其实就是需要了解linux内核一些原理，例如系统调用嵌入内核，虚拟文件系统等等；

接下来，我会从以下小点介绍管道

- 用户态管道的使用；
- 虚拟文件系统
- 内核态管道的实现原理；
- fifo命名管道实现
- 总结；

# 管道的使用

---

一开始接触linux，相信很多人都是从命令开始；当一个命令的输出，需要作为另一个命令的输入时，我们就会使用管道来实现这个功能；例如，我们经常需要在某个文档中查找是否存在某个单词，我们就可以用如下方式:

> cat test.txt | grep 'hello'

这行命令表示在test.txt文件中查找包含单词'hello'的句子。我们先解释下这行命令是怎么实现的；

我们知道终端也是一个进程，当我们输入一个命令执行时，其实是终端程序调用fork和exec产生一个子进程执行命令程序；当终端在执行这行命令时，会先解析输入的参数，当发现输入的命令行中有‘|’符号时，就会知道在命令行中包含了管道，因此，在终端程序中，

- 会先fork出一个子进程，并执行exec将cat载入内存；
- 接着在cat程序中，用函数pipe定义出管道;
- 在定义出管道之后，再调用fork，生成一个子进程；
- 在父进程cat中关闭管道读端，将cat进程的标准输出重定向到管道的写端；
- 在子进程中将管道的写端关闭，将标准输入重定向到管道的读端，再调用exec将grep进程载入内存；
- 最后，cat的输出就可以最为grep的输入了；

这里需要说明的是，父进程cat对管道的操作必须在fork之前，否则父进程cat对管道的操作会继承到子进程，这样会导致子进程无法读取父进程的数据；我们可以用一个简单的程序来模拟上述过程，为了简单起见，例子简单地将字符串从小写转为大写；程序如下:
```
#include<stdio.h>
#include<stdlib.h>
#include<unistd.h>

int main(void)
{
  int fd[2];
  int ret=pipe(fd);//创建管道
  if (ret==-1)
  {
    fprintf(stderr, "%s\n", "pipe error!");
    exit(-1);
  }
  int pid=fork();
  if (pid<0)
  {
    fprintf(stderr, "%s\n", "fork error!");
    exit(-1);
  }
  if(pid==0){//在子进程中
      close(fd[1]);
      dup2(fd[0],STDIN_FILENO);//将子进程的标准输入重定向到fd[0]
      ret=execl("./toUpper","toUpper", "",NULL);//执行子进程
      if(ret==-1){
        fprintf(stderr, "%s\n", "execl error!");
        exit(-1);
      }
  }

  // 以下是父进程
  close(fd[0]);
  dup2(fd[1],STDOUT_FILENO);// 将父进程的标准输出重定向到fd[1]
  char buf[1024];
  int n=read(STDIN_FILENO,buf,1024);// 从标准输入读取数据
  if (n<0) {
    fprintf(stderr, "%s\n", "read error!");
    exit(-1);
  }// 将数据写入管道缓冲区中
  write(STDOUT_FILENO, buf,n);
  sleep(1);
  return 0;
}
```

上述为主程序；在主程序中通过fork函数创建出一个子进程；在父进程中关闭管道读端，将标准输出重定向到管道写端；当在父进程有数据输出到标准输出时，就可以输出到管道的缓冲区；在子进程中，关闭管道写端，将标准输入重定向到管道读端，这样子进程从标准输入读取时，就可以从管道缓冲区读取；
```
#include<stdio.h>
#include<stdlib.h>
#include<unistd.h>

#define BUFSIZE 1024

char chartoUp(char ch) {
  if (ch>'a' && ch <'z') {
    ch = ch - 32;
  }else {
    ch = ch;
  }
  return ch;
}

int main() {
  char buf[BUFSIZE];
  // 从标准输入读取数据，其实就是从管道缓冲区读取数据
  int n=read(STDIN_FILENO,buf,BUFSIZE);
  if (n<0) {
    fprintf(stderr, "%s\n", "read error!");
    exit(-1);
  }
  for (;i<n;i++)
  {
      buf[i]=toUp(buf[i]);
  }
  printf("%s\n", buf);
  return 0;
}
```

上述程序为父进程调用的子程序，先从管道缓冲区读取数据，然后将每个字母转换为大写字母，最后输出到标准输出；例子很简单，当然，也可以使用C语言io库封装好的popen函数来实现上述功能;

# 虚拟文件系统

---

在讲管道之前，必须先介绍下linux虚拟文件系统，否则很难说清楚在这里；虚拟文件系统是linux内核四大模块之一，我们知道linux下面everything is file。例如磁盘文件，管道，套接字，设备等等；我们都可以通过read和write函数来读取上述文件的数据；为了支持这一特性，linux引入虚拟文件系统，就是通过一层文件系统虚拟层，屏蔽不同文件系统的差异，实现相同的函数接口操作；linux支持非常多的文件系统，我们可以通过查看

> cat /proc/filesystems

包括基于磁盘的文件ext4,ext3等，基于内存的文件系统proc,pipefs,sysfs,ramf以及tmpfs,和套接字文件系统sockfs;

当我们在用户态调用read函数读取一个文件描述符时，主要过程如下:


1. 首先通过软中断嵌入内核，调用系统相应服务例程sys_read,sys_read函数如下:
```
asmlinkage ssize_t sys_read(unsigned int fd, char __user * buf, size_t count)
{
    struct file *file;
    ssize_t ret = -EBADF;
    int fput_needed;
    // fget_light函数从当前进程的文件描述符表中，通过文件描述符，
    //　获取file结构体
    file = fget_light(fd, &fput_needed);
    if (file) {
    	loff_t pos = file_pos_read(file);//获取读取文件的偏移量
        ret = vfs_read(file, buf, count, &pos);//调用虚拟文件系统调用层
    	file_pos_write(file, pos);//　更新当前文件的偏移量
    	fput_light(file, fput_needed);//　更新文件的引用计数
    }
    return ret;
}
```
  
我们可以看到sys_read服务例程的参数和系统调用read的参数是一样的，首先通过fd从当前的文件数组中获取file实例，接着获取当前的读偏移量，然后进入虚拟文件系统vfs_read调用;

2. 接下来看看vf_read虚拟层调用的过程:
```
ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)
{
	struct inode *inode = file->f_dentry->d_inode;
	ssize_t ret;
 	if (!(file->f_mode & FMODE_READ))
    		return -EBADF;
  	if (!file->f_op || (!file->f_op->read && !file->f_op->aio_read))
    		return -EINVAL;
  	ret = locks_verify_area(FLOCK_VERIFY_READ, inode, file, *pos, count);
  	if (!ret) {
    		ret = security_file_permission (file, MAY_READ);
    	if (!ret) {
      		if (file->f_op->read)
        		// 进入具体文件系统
        		ret = file->f_op->read(file, buf, count, pos);
      		else
        		ret = do_sync_read(file, buf, count, pos);
        	if (ret > 0)
			 dnotify_parent(file->f_dentry, DN_ACCESS);
	}
  }
  return ret;
}
```

在这个函数中，一开始先属性检查以及安全性检查，然后通过下面代码进入具体的文件系统

> ret = file->f_op->read(file, buf, count, pos);

每种文件系统的file->f_op->read是不一样的，像基于磁盘的文件系统，file->f_op->read函数是先到缓存缓存获取数据，如果缓存没有数据，则到磁盘获取；基于内存的文件系统，file->f_op->read则是直接在内核缓存获取数据，而不会到磁盘获取数据;

所以虚拟文件系统类似于面向对象多态的实现，首先设计好接口，不同的文件系统分别实现这些接口，这样就可以调用相同的接口，实现不同的操作;

而这个file->f_op主要是从inode->i_fop中获得，因此对于不同的文件系统，inode也结构也是有区别的．当创建一个inode时，针对不同的文件系统需要设置不同的属性，最主要就是各种操作函数指针结构体，例如inode->i_op和inode->i_fop；这样不同的文件系统，就可以在f->f_op->read调用中，实现不同的操作.

# 内核管道的实现

---

上面给出了管道简单的操作以及稍微介绍了虚拟文件系统，pipefs主要的系统调用就是pipe，read和write. 下面来分析内核是怎么实现管道的；linux下的进程的用户态地址空间都是相互独立的，因此两个进程在用户态是没法直接通信的，因为找不到彼此的存在；而内核是进程间共享的，因此进程间想通信只能通过内核作为中间人，来传达信息. 下图显示了两个进程间通过内核缓存进行通信的过程:

``` 
                             写 | 入         +-------+
                 +--------------+------------<       |
                 |              |            | 进程1 |
             +---v----+         |            |       |
             |        |         |            +-------+
             | 缓 存  |     内  |  用
             | (page) |     核  |  户
             |        |         |  态
             +---v----+         |            +-------+
                 |              |            |       |
                 |              |            | 进程2 |
                 +--------------+------------>       |
                             读 | 取         +-------+
                                |                                                         
```
pipe的实现就是和上述图示一样，在pipefs文件系统的inode中有一个属性

> struct pipe_inode_info	*i_pipe;


这个结构体定义如下:

```
//pipe_fs_i.h
struct pipe_inode_info {
    wait_queue_head_t wait;
    char *base;//指向管道缓存首地址
    unsignedint len;//管道缓存使用的长度
    unsignedint start;//读缓存开始的位置
    unsignedint readers;
    unsignedint writers;
    unsignedint waiting_writers;
    unsignedint r_counter;
    unsignedint w_counter;
    struct fasync_struct *fasync_readers;
    struct fasync_struct *fasync_writers;
}
```

这个结构体定义了管道的缓存，由base指向，缓存大小为一个内存页，有如下定义

> #define PIPE_SIZE		PAGE_SIZE

其实到现在我们大概可以猜得到管道的是实现原理，在一个进程中，向管道中写入数据时，其实就是写入这个缓存中；然后在另一个进程读取管道时，其实就是从这个缓存读取，实现进程的通信．

这个缓存也可以解释为什么管道是单通道的：

> 因为只有一个缓存，如果是双通道，那么两个进程同时向这块缓存写数据时，这样会导致数据覆盖，即一个进程的数据被另一个进程的数据覆盖．而向套接字有读写缓存，因此套接字是双通道的．

ok，接下来，从pipe函数开始，看看内核是如何创建管道的．pipe系统调用在内核对应的服务例程为sys_pipe，在sys_pipe函数中，接着调用do_pipe创建两个管道描述符，一个用于写，另一个用于读；我们来看下do_pipe都做了什么．

## do_pipe函数

一开始先获得两个空file实例，一个对应管道读描述符，另一个对应管道写描述符

```
error = -ENFILE;
f1 = get_empty_filp();
if (!f1)
	goto no_files;
f2 = get_empty_filp();
if (!f2)
	goto close_f1;
```

接着通过调用get_pipe_inode来实例化一个带有pipe属性的inode

```
structinode* pipe_new(structinode* inode)
{
	unsigned long page;
	// 申请一个内存页，作为pipe的缓存
	page = __get_free_page(GFP_USER);
	if (!page)
		return NULL;
	// 为pipe_inode_info结构体分配内存
	inode->i\_pipe = kmalloc(sizeof(structpipe_inode\_info), GFP_KERNEL);
	if (!inode->i_pipe)
		goto fail_page;	
	// 初始化pipe_inode_info属性
	init_waitqueue_head(PIPE_WAIT(*inode));
	PIPE_BASE(*inode) = (char*) page;
	PIPE_START(*inode) = PIPE_LEN(*inode) = 0;
	PIPE_READERS(*inode) = PIPE_WRITERS(*inode) = 0;
	PIPE_WAITING_WRITERS(*inode) = 0;
	PIPE_RCOUNTER(*inode) = PIPE_WCOUNTER(*inode) = 1;
	*PIPE_FASYNC_READERS(*inode) = *PIPE_FASYNC_WRITERS(*inode) = NULL;
	return inode;
	fail_page:
		free_page(page);
	return NULL;
}
//----------------------------------------------------------------
static struct inode * get_pipe_inode(void)
{
	//　从pipefs超级块中分配一个inode
	struct	inode *inode = new_inode(pipe_mnt->mnt_sb);
	if (!inode)
		goto fail_inode;
	// pipe_new函数主要用来为这个inode初始化pipe属性，就是pipe_inode_info结构体
	if(!pipe_new(inode))
		goto fail_iput;
	PIPE_READERS(*inode) = PIPE_WRITERS(*inode) = 1;
	inode->i_fop = &rdwr_pipe_fops;//设置pipefs的inode操作函数集合，rdwr_pipe_fops
	// 为结构体，包含读写管道所有操作

	inode->i_state = I_DIRTY;
	inode->i_mode = S_IFIFO | S_IRUSR | S_IWUSR;
	inode->i_uid = current->fsuid;
	inode->i_gid = current->fsgid;
	inode->i_atime = inode->i_mtime = inode->i_ctime = CURRENT_TIME;
	inode->i_blksize = PAGE_SIZE
	return inode;
}
```

然后，在当前进程的files_struct结构中获取两个空的文件描述符，分别存储在i和j

```
error = get_unused_fd();
if (error < 0)
	goto close_f12_inode;
i = error;
error = get_unused_fd();
if (error < 0)
	goto close_f12_inode_i;
j = error;
```

下一步就是为这个inode分配dentry目录项，dentry主要用于将file和inode连接起来,以及设置f1和f2的vfsmnt,dentry,mapping属性

```
sprintf(name, "[%lu]", inode->i_ino);
this.name = name;
this.len = strlen(name);
this.hash = inode->i_ino; /* will go */
dentry = d_alloc(pipe_mnt->mnt_sb->s_root, &this);
if (!dentry)
	goto close_f12_inode_i_j;
dentry->d\_op = &pipefs_dentry_operations;
d_add(dentry, inode);
f1->f\_vfsmnt = f2->f\_vfsmnt = mntget(mntget(pipe_mnt));
f1->f\_dentry = f2->f_dentry = dget(dentry);
f1->f\_mapping = f2->f\_mapping = inode->i_mapping;
```

最后，针对读写file实例设置不同的属性，并且将两个fd和两个file实例关联起来

```
/* read file */
f1->f\_pos = f2->f_pos = 0;
f1->f\_flags = O_RDONLY;//f1这个file实例只可读
f1->f\_op = &read_pipe_fops;//这是这个可读file的操作函数集合结构体
f1->f\_mode = FMODE_READ;
f1->f_version = 0;

/* write file */
f2->f_flags = O_WRONLY;//f2这个file实例只可写
f2->f_op = &write_pipe_fops;//这是这个只可写的file操作函数集合结构体
f2->f_mode = FMODE_WRITE;
f2->f_version = 0;

fd_install(i, f1);//将i(fd)和f1(file)关联起来
fd_install(j, f2);// 将j(fd)和f2(file)关联起来
fd[0] = i;
fd[1] = j;
return 0;
```

到这里，do_pipe函数就算结束了，并且用i和j文件描述符填充了fd[2]数组，最后在sys_pipe函数中通过copy_to_user将fd[2]数组返回给用户程序；

总结下do_pipe函数的执行过程:

1. 实例化两个空file结构体；
2. 创建带有pipe属性的inode结构；
3. 在当前进程文件描述符表中找出两个未使用的文件描述符;
4. 为这个inode分配dentry结构体，关联file和inode;
5. 针对可读和可写file结构，分别设置相应属性，主要是操作函数集合属性；
6. 关联文件描述符和file结构
7. 将两个文件描述符返回给用户;

## pipe读操作

当通过pipe函数获取到两个文件描述符，即可使用read和write函数分别对这两个描述符进行读写;我们先来看下read操作;

有之前虚拟文件系统知道，当用户态调用read函数时，对应于内核态sys_read，然后在sys_read函数中调用vfs_read函数，在vfs_read函数中调用file->f_op->read，由上述do_pipe函数可以知道，pipefs的read(file)实例对应的file->f_op为read_pipe_fpos，这个read_pipe_fpos结构体定义如下:

```
struct file_operations read_pipe_fops = {
	.llseek		= no_llseek,
	.read		= pipe_read,
	.readv		= pipe_readv,
	.write		= bad_pipe_w,
	.poll		= pipe_poll,
	.ioctl		= pipe_ioctl,
	.open		= pipe_read_open,
	.release	= pipe_read_release,
	.fasync		= pipe_read_fasync,
}
```

因此，在vfs_read函数中调用的(pipe)file->f_op->read即为pipe_read函数，这个函数定义在fs/pipe.c文件中,

```
static ssize_t
pipe_read(structfile *filp, char __user *buf, size_t count, loff_t *ppos)
{
  structiovec iov = &#123; .iov\_base = buf, .iov_len = count &#125;;
  return pipe_readv(filp, &iov, 1, ppos);
}
```

pipe_read函数将用户程序的接收数据缓冲区和大小转换为iovec结构，然后调用pipe_readv函数从缓冲区获取数据;在pipe_readv函数中，最主要部分如下:

```
intsize = PIPE_LEN(*inode);
if (size) {
  // 获取管道缓冲区读首地址
  char *pipebuf = PIPE_BASE(*inode) + PIPE_START(*inode);
  // 缓冲区可读最大值=PIPE\_SIZE - PIPE\_START(inode)
  ssize_t chars = PIPE_MAX_RCHUNK(*inode);

  // 下面两个if语句用于比较缓冲区可读最大值，缓冲区数据长度以及
  // 用户态缓冲区的长度，取最小值
  if (chars > total_len)
  	chars = total_len;
  if (chars > size)
  	chars = size;
  // 调用如下函数把数据拷贝到用户态
  if (pipe_iov_copy_to_user(iov, pipebuf, chars)) {
    if (!ret) ret = -EFAULT;
      break;
  }
  ret += chars;
  // 更新缓冲区读首地址
  PIPE_START(*inode) += chars;
  // 对缓冲区长度取模
  PIPE_START(*inode) &= (PIPE_SIZE - 1);
  // 更新缓冲区数据长度
  PIPE_LEN(*inode) -= chars;
  // 更新用户态缓冲区长度
  total_len -= chars;
  do_wakeup = 1;
  if (!total_len)
    break;	/* 如果用户态缓冲区已满，则读取成功 */
}    
```

上述代码是在一个循环中，直到用户态缓冲区已满，或者管道缓冲区全部数据读取完毕；当然这还涉及到如果缓冲区为空，则当前进程阻塞(切换到其他进程)等等；我们来看下pipe_iov_copy_to_user函数

```
static inline int
pipe_iov_copy_to_user(struct iovec *iov, constvoid *from, unsignedlong len)
{
    unsignedlongcopy;

    while (len > 0) {
      while (!iov->iov_len)
      	iov++;
      copy = min_t(unsignedlong, len, iov->iov_len);

      if (copy_to_user(iov->iov_base, from, copy))
          return -EFAULT;
      from += copy;
      len -= copy;
      iov->iov_base += copy;
      iov->iov_len -= copy;
    }
    return0;
}
```

这个函数很简单，其实就是在一个循环中，将缓冲区中数据通过copy_to_user函数写到用户态空间缓冲区中。最后在用户态read函数返回之后，即可在缓冲区中读取到管道中数据。

pipe的写过程其实就是和read的过程相反，首先也是通过系统调用嵌入内核write->sys_write->vfs_write,在vfs_write函数中调用file->f_op->write函数，而这个函数对应管道写file实例的pipe_write函数。后面的过程就是将用户态缓冲区的数据拷贝到内核管道缓冲区，不再叙述；

# fifo命名管道的实现

---

因为pipe只能用在两个有亲缘关系的进程上，例如父子进程；如果要在两个没有关系的进程上用管道通信时，这时pipe就派不上用场了。我们可以思考一个问题，如何让两个不相干的进程找到带有pipe属性的inode了？我们自然就想到利用磁盘文件。因为linux下两个进程访问同一个文件时，虽然各自的file是不一样的，但是都是指向同一个inode节点。所以将pipe和磁盘文件结合，就产生了fifo命名管道；

fifo的实现原理和pipe一样，我们可以看下fifo和pipe的read函数操作集合:

```
//read_fifo_fpos
struct file_operations read_fifo_fops = {
	.read		= pipe_read,
	.readv		= pipe_readv,
	.write		= bad_pipe_w,
	.poll		= fifo_poll,
	.ioctl		= pipe_ioctl,
	.open		= pipe_read_open,
	.release	= pipe_read_release,
	.fasync		= pipe_read_fasync,
}
// read_pipe_fops
struct file_operations read_pipe_fops = {
	.llseek		= no_llseek,
	.read		= pipe_read,
	.readv		= pipe_readv,
	.write		= bad_pipe_w,
	.poll		= pipe_poll,
	.ioctl		= pipe_ioctl,
	.open		= pipe_read_open,
	.release	= pipe_read_release,
	.fasync		= pipe_read_fasync,
}
```

可以看出来，二者操作函数一样，说明对fifo的读写操作也是对管道缓冲区进行读写；唯一不同点是轮询函数，其实fifo_poll和pipe_poll也是一样的

> #define fifo_poll pipe_poll

而fifo创建的文件只是让读写进程能找到相同的inode，进而操作相同的pipe缓冲区。

# 总结

---

这篇文章，主要从内核代码介绍了pipe的实现，总结一点就是两个进程对同一块内存的操作，和进程内部多个线程操作同一个块内存类似。我这只是简单的说明pipe的实现原理，当然，实际上还有许多内容，例如管道阻塞和非阻塞，管道轮询等等。此外还介绍了fifo命名管道的实现原理。

在准备写这篇文章时，我也看了些关于文件系统的资料以及内核其他文件系统的代码，我加深了对linux虚拟文件系统的实现机理。

接下来文章，要开始分析了golang的底层实现了，因为在使用过程中，发现golang是一门非常好用的系统级语言，越来越多的公司引入了golang语言进行项目开发，知其然而不知所以然是一件很痛苦的事。
