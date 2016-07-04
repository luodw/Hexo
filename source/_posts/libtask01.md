title: libtask之channel实现机制
date: 2016-06-26 17:19:33
tags:
- libtask
categories:
- libtask
toc: true

---

用过golang语言，都知道golang最吸引人的特性就是goroutine和channel．goroutine可以称呼为go程，其实就是go语言协程；channel即为通道，用于goroutine之间进行通信；比较直观的理解，channel实现可以认为生产者和消费者模型，即一个goroutine写入消息，另一个协程读取消息；当然，具体如何实现，可以看libtask的channel实现，即可略知一二．

libtask的channel模块，理解起来没有task模块轻松，逻辑比较复杂，我在计划写这篇博客时，还是很担心不能够写明白libtask的channel是如何运行的；这篇博客主要是以例子以及解析源码的形式来分析channel的实现；

go  channel分为有有缓存和无缓存，对应于libtask也是如此，我们先来看下无缓存是如何实现的；

## 无缓存channel实现

----

下面是一个简单的例子，用于说明libtask中channel的实现
```
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <task.h>

Channel *c=NULL;

void
counttask1(void *arg)
{
    printf("test3-----\n" );
    unsigned long x = chanrecvul(c);
    printf("%ld\n",x );
    printf("test4-----\n" );
}

void
taskmain(int argc, char **argv)
{
    c = chancreate(sizeof(unsigned long),0);
    taskcreate(counttask1, NULL, 32768);
    printf("test1-----\n" );
    chansendul(c, 1);
    printf("test2-----\n" );
}
```
编译程序
> gcc -g mytest.c -o mytest -ltask

最后得到结果如下:
```
test1-----
test3-----
1
test4-----
test2-----
```

先来分析下结果，当然如果你熟悉golang，这结果是很明显的．
1. 一开始任务队列中只有taskmain任务，所以调度器直接调度taskmain任务；
2. 在taskmain任务中，创建了counttask1任务，然后输出"test1------"，接着向管道中写入一个无符号长整形1，由于是无缓存的channel，所以taskmain任务阻塞并切换到调度器;
3. 此时任务队列只有counttask1，调度器调度counttask1任务执行;
4. 在counttask1任务中，从channel中读取一个元素，因为channel中已经有一个元素，所以直接返回channel中的数值，最后输出"test4----";
5. 调度器切回taskmain执行，最后结束任务队列为空，退出整个程序；

## 源码实现

------

libtask中关于channel的源码实现主要是在文件channel.c中，我在初次看channel的实现时，就三个字＂看不懂＂；主要逻辑在chanalt和altexec函数中，这两个函数最晦涩难懂；最后只能祭出上古神器gdb；跟着gdb，设断点，一步一步跟踪程序，最后终于把channel搞懂了；所以建议从代码字面看不懂的同学，可以和我一样，利用gdb；

好了，不多说，来开始代码之旅；

### 向channel发送数据代码逻辑

测试例子程序中，我们先看下创建channel的代码逻辑
```
Channel*
chancreate(int elemsize, int bufsize)
{
	Channel *c;
	// 为channel分配内存
	c = malloc(sizeof *c+bufsize*elemsize);
	if(c == nil){
		fprint(2, "chancreate malloc: %r");
		exit(1);
	}
	memset(c, 0, sizeof *c);
	c->elemsize = elemsize;// channel中每个元素的大小
	c->bufsize = bufsize;
	c->nbuf = 0;//缓存已使用量
	c->buf = (uchar*)(c+1);//指向缓存首地址
	return c;
}
//--------------------------------------------------------
struct Channel
{
	unsigned int	bufsize;//缓存大小，即缓存元素个数
	unsigned int	elemsize;//channel每个元素的大小
	unsigned char	*buf;//指向缓存的指针
	unsigned int	nbuf;//缓存已使用量
	unsigned int	off;//当前读取的元素个数
	Altarray	asend;//发送队列
	Altarray	arecv;//接收队列
	char		*name;
};
```
从这段代码，我们可以看出来参数elemsize表示channel中每个元素的大小，bufsize表示缓存可以容纳多少个元素，即缓存的size；因此有无缓存，主要是看bufsize的值，如果为0，则无缓存，如果不为0，则有缓存；

创建好channel之后，接下来看下chansendul(c, 1)函数的代码逻辑，这个函数直接调用_chanop函数
```
static int
_chanop(Channel *c, int op, void *p, int canblock)
{
	Alt a[2];

	a[0].c = c;
	a[0].op = op;
	a[0].v = p;
	a[1].op = canblock ? CHANEND : CHANNOBLK;
	if(chanalt(a) < 0)
		return -1;
	return 1;
}
```
第一次看代码的时候，会被这个alt数组给弄混淆了，代码中可以看出其实就是第一个alt存储数据，第二个并没有存储数据；看到后面之后，才会发现其实第二个alt就是用于一些条件的判断；

ok，接下来，到最重要的函数chanalt，省去一些无关紧要的代码,
```
int
chanalt(Alt *a)
{
	/* 省去一些代码 */
	/* 此时n=1 */
	ncan = 0;
	for(i=0; i<n; i++){
		c = a[i].c;
		if(altcanexec(&a[i])){
				ncan++;
		}
	}
	/* ......  */
	for(i=0; i<n; i++){
		if(a[i].op != CHANNOP)
			altqueue(&a[i]);
	}
	taskswitch();
//------------------------------------------------
static int
altcanexec(Alt *a)
{
	Altarray *ar;
	Channel *c;

	if(a->op == CHANNOP)
		return 0;
	c = a->c;
	if(c->bufsize == 0){
		ar = chanarray(c, otherop(a->op));
		return ar && ar->n;
	}else{
		...............
	}
}
```
在chanalt函数中，首先是判断这个alt是否可执行；在判断函数altcanexec内部，因为此时是无缓存版本，因此代码逻辑就在if语句内部；
> otherop(a->op)函数返回当前操作的相反队列；例如如果此时是一个发送操作，那么这个otherop函数返回的是接收队列

> chanarray函数返回通道c(channel)中，otherop(a->op)类型的队列，此时返回的是接收队列，因为ar->n为当前通道队列中元素的个数，此时接收队列为空，所以此时为ar->n为0

因此这个判断函数altcanexec返回false，代码就直接来到了altqueue函数中，这个alt加入队列函数很简单，就是简单的将alt放入相应队列中，此时alt加入的是发送队列;

最后执行taskswitch函数，执行任务调度，切换到调度器；要注意的是，此时taskmain是没有放入任务队列的(调用taskyield函数才是让出当前CPU，并把自身放入任务队列末尾)，因此后面需要有个函数将这个taskmain放入队列中，等待调度，那这个函数是谁了?后面再揭晓

### 从channel接收代码逻辑

taskmain任务切换到调度器之后，此时任务队列中只有counttask1任务，因此调度器切换counttask1任务执行，我们直接看函数chanrecvul(c)逻辑，这个函数也是调用_chanop函数，最后到达chanalt函数;在chanalt函数中，代码逻辑主要是下面这些:
```
int
chanalt(Alt *a)
{
	/* ...... */
	ncan = 0;
	for(i=0; i<n; i++){
		c = a[i].c;
		if(altcanexec(&a[i])){
				ncan++;
		}
	}
	if(ncan){
		j = rand()%ncan;
		for(i=0; i<n; i++){
			if(altcanexec(&a[i])){
				if(j-- == 0){
					altexec(&a[i]);
					return i;
				}
			}
		}
	}
	/* ....... */
}
//------------------------------------------------
static int
altcanexec(Alt *a)
{
        Altarray *ar;
        Channel *c;

        if(a->op == CHANNOP)
                return 0;
        c = a->c;
        if(c->bufsize == 0){
                ar = chanarray(c, otherop(a->op));
                return ar && ar->n;
        }else{
                ...............
        }
}
```
在判断函数altcanexec函数内部，因为a->op为接收，所以ar为发送队列，因为之前已经存入一个元素，因此ar->n不为0，所以判断为真，此时ncan加1；转入执行下面if语句，最后执行altexec函数；
```
static void
altexec(Alt *a)
{
	int i;
	Altarray *ar;
	Alt *other;
	Channel *c;

	c = a->c;
	ar = chanarray(c, otherop(a->op));//取出channel中的发送队列
	if(ar && ar->n){
		i = rand()%ar->n;//i=0
		other = ar->a[i];//取出发送队列第一个alt
		altcopy(a, other);//将发送队列第一个alt中携带的数据拷贝到a
		altalldequeue(other->xalt);//删除发送队列第一个alt
		other->xalt[0].xalt = other;
		taskready(other->task);// 将other的宿主任务放入调度队列中
	}else
		altcopy(a, nil);
}
```
这个函数很重要，可以说是理解channel接收逻辑的重点；解释如下
1. 一开始，取出发送队列第一个alt；
2. 将发送队列第一个alt的数据拷贝至接收alt中；
3. 删除发送队列中的第一个alt，因为已经被处理了;
4. 调用taskready将taskmain任务放入任务队列中，等待调度；

最后在chanrecvul函数中，将val，即接收alt->v中存储的值，返回给用户；

当counttask1任务结束时，调度器调度taskmain执行，taskmain输出一句"test2----"，也结束运行

最后，调度任务队列为空，调度循环退出，整个进程也就退出了

因此到目前为止，channel的发送接收逻辑已经很清楚了
>taskmain任务向channel发送数据时，将alt放入channel的发送队列；阻塞切换；然后counttask1任务从channel接收数据时，将发送队列第一个alt携带数据拷贝至接收队列的alt中，并将taskmain放入任务队列末尾，等待调度；在chanrecvul将数据返回给用户

libtask无缓存的channel暂时分析到这；对于有缓存的的channel，代码逻辑和这下相似，只是用到了buf，我相信看懂无缓存channel的代码逻辑之后，再跟着gdb单步调试肯定也能看懂有缓存channel逻辑；

有时间在分析有缓存channel逻辑吧．











































































