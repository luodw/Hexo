title: 聊聊golang的前身libtask
date: 2016-06-21 19:43:13
tags:
- libtask
categories:
- libtask
toc: true

---

在实习期间，由于项目需要，接触了golang这门语言；经过一段时间的学习使用，我发现golang语言语法简单，有C/C++基础的同学，一个星期即可上手，当然要深入理解golang，还是要多使用，多学习底层机制；goroutine的引入，使得golang非常适合并发程序的开发；而我了，在学习一门语言或技术的时候，是一定要理解底层的实现原理，否则我会用的很盲目或者说难受．所以有了这篇文章．

之前，在没接触golang时，在我的认知范围内，服务器开发架构大体就是类似redis的单线程，memcache多线程，ngnix多进程；在接触golang之后，我认识了协程这么一个概念，可以说这是我知识体系非常大的补充，因为服务器开发还可以采用协程实现；接下来，先简要介绍下协程的概念，然后在介绍golang前身libtask的实现原理；

# 协程是什么

协程，其实就是轻量级线程，粒度比线程还小，通俗点说就是用户态的一个函数块；一个进程或线程如果内存够大，就可以创建足够多的协程，但是在在内核层面，还是只有一个进程描述符，也就是说内核并不知道协程的存在，所以协程的调度执行完全需要用户态调度器来调度执行；协程有也有自己的栈，也有自己的上下文，所以协程可以在执行到一半的时候让出cpu，同时保存上下文，切换到其他协程，待其他协程执行结束之后，再切回来继续执行；

对于Linux，
1. 进程切换是个耗时的工作，因为首先要程序要先嵌入到内核，保存当前进程的上下文到任务段，然后进程调度算法选择一个就绪进程，将这个就绪进程任务段保存的寄存器值恢复到CPU，切换页表，切换堆栈，刷新cpu中TLB和Cache缓存等；
2. 线程就是轻量级的进程，因为线程在内核里面也有进程描述符，也有内核堆栈；所以线程的切换，也需要嵌入内核，执行上下文切换以及堆栈切换等，但是同个进程中的线程切换不需要切换页表，不要刷新TLB，所以在一定程度上，线程切换代价是小于进程切换；
3. 协程的切换比进程，线程切换代价都小；linux下面，CPU调度最小的单位是线程(因为内核调度需要task_struct嘛)，所以对于一个进程或线程上的所有协程只能在同一个CPU上调度执行，而且只能一个协程执行结束之后再执行其他线程，除非某个协程显式让出CPU；因此，协程的调度不需要内核调度，而是由用户态调度器调度，而且只需要切换CPU硬件上下文，代价相对于进程线程是非常低的．

当前，支持协程的语言越来越多，主流的有lua,golang,python,Erlang等；当然在远古时代，那时没有语言支持协程，有些大佬就用C语言自己封装实现用户态任务调度库，比较有代表性的就是golang的前身libtask，所以学习golang，libtask一定要看看，对于理解golang有很大的帮助．

# 说说libtask

libtask是一套用c语言编写的任务调度库，实现很简单，将创建的任务存入一个队列中，然后main函数主线程在一个for循环中，不断从队列头部开始调度任务，直到任务队列为空，直到所有任务调度完毕，进程退出；

## libtask简单例子程序

这里先给个例子简单说明下libtask使用:
```
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <task.h>

void
counttask1(void *arg)
{
    int i;
    for( i = 0; i < 5; i++) {
        printf("task1: %d\n", i);
        taskyield();
    }
}

void
counttask2(void *arg)
{
    int i;
    for( i = 5; i < 10; i++) {
        printf("task2: %d\n", i);
        taskyield();
    }
}

void
taskmain(int argc, char **argv)
{
    taskcreate(counttask1, NULL, 32768);
    taskcreate(counttask2, NULL, 32768);
}

```
编译这段代码时，需要加入动态链接库
> gcc example.c -o example -ltask

最后执行结果如下:
```
charles@charles-Lenovo:~/libtask$ gcc example.c -o example -ltask
charles@charles-Lenovo:~/libtask$ ./example
task1: 0
task2: 5
task1: 1
task2: 6
task1: 2
task2: 7
task1: 3
task2: 8
task1: 4
task2: 9
```
这个例子很简单，通过在taskmain函数中调用taskcreate创建两个任务，然后taskmain任务退出，开始执行counttask1和counttask2两个任务，并通过taskyield函数实现任务切换，主要就是让出CPU，实现交替执行，最终打印如上结果．

可能有小伙伴会有疑问，怎么这段小程序没有main函数？因为开始学编程的时候，老师就说main函数是程序入口．带着疑问，查看源码发现，main函数已经集成在libtask库，在task.c文件中；我刚开始看时，也有疑惑，为什么不把main函数交给用户？通过查看源码，我的理解是，因为在main函数中，需要实现任务调度功能，如果把main函数交个用户，那就需要再提供一个接口给用户注册调度模块，这就无疑增加代码难度以及暴露太多的内部细节，例如任务队列以及任务结构等等；所以libtask库干脆封装main函数，并在main函数中实现调度器，这样只需提供创建任务的接口即可，内部实现细节全都隐藏了．

## libtask实现原理

这里先给出如下图示说明libtask的执行过程，我以上述example.c为例
```
                             +------------+
                             |  Scheduler +--->主线程
                             +------------+
                             /      |     \
                            /       |      \
                           /        |       \
                          /         |        \
               +----------+     +-------+    ++------+
               | taskmain +---->| task1 +--->| task2 +---> .......
               +----------+     +-------+    +-------+

```

1. 在task.c文件main函数中，首先会创建taskmain任务，并放入任务队列中；
2. 接着mian函数主程序进入任务调度循环中，不断迭代并执行任务队列中的任务，直到任务队列为空；一开始只有taskmain任务，因此执行taskmain任务函数；
3. 一般情况下，我们会在taskmain任务函数中创建其他任务，并放入任务中；此时tasmain任务结束退出；
4. 此时任务队列中只有task1和task2，task1在队首，所以先执行，当遇到taskyield函数时，此时task1自愿放弃cpu，把自身放入任务队列末尾；执行任务切换，切换到调度器；
5. 此时调度器取出位于队首的task2执行，同样，遇到taskyield，放弃cpu,自身存入任务队列末尾，切换到调度器；
6. 调度器执行task1...

以上就是例子example.c的执行过程，从中我们可以知道，libtask把真正的main函数隐藏了，也就是说调度器对用户是透明的，但是给用户提供了另一个main函数taskmain；因此我们在使用libtask时只需要把taskmain当做main函数即可，在libtask的真正main函数中会为这个taskmain创建一个任务并调度执行；所以除了调度器外，taskmain永远是第一个任务，后面的任务需要从taskmain任务创建衍生．

## libtask源码解析

要实现任务切换，就必须能够保存当前任务的上下文，这样再次切回当前任务时，可以继续执行当前任务；在linux平台下面，主要用的就是ucontext.h，提供的getcontext,setcontext,swapcontext和makecontext函数，具体的上下文有结构体ucontext_t指定，包括任务的栈的大小，栈顶指针以及cpu内寄存器信息；简要介绍下四个函数，具体如何使用可以谷歌之．
1. int getcontext(ucontext_t *ucp);函数用于获取当前任务的上下文，并存入ucp中；
2. int setcontext(const ucontext_t *ucp);用于实现任务切换，即设置当前执行的上下文；
3. void makecontext(ucontext_t \*ucp, void (\*func)(), int argc, ...);用于创建一个上下文，存入ucp中，当执行这个上下文时，会跳转到func函数中执行；
4. int swapcontext(ucontext\_t *oucp, const ucontext\_t *ucp);这个函数可以看成是setcontext好绕getcontext函数的合成，先保存当前上下文在oucp，然后跳转到ucp指定的上下文；当ucp任务执行结束之后，会回到swapcontext函数的下一行代码继续执行(实现可以思考uc_link)．

接下来，从main函数开始，源码解析(省去一些不影响分析的代码)
```
static int taskargc;//为了将用户输入的参数传进taskmain函数中
static char **taskargv//所以设置了这两个变量
int mainstacksize;// taskmain任务栈的大小

// taskmain主协程
static void
taskmainstart(void *v)
{
	taskname("taskmain");
	taskmain(taskargc, taskargv);
}

int
main(int argc, char **argv)
{
	/*
	  省去对信号处理函数
	*/
	argv0 = argv[0];
	taskargc = argc;
	taskargv = argv;

	if(mainstacksize == 0)
		mainstacksize = 256*1024;//设置taskmain栈大小

    　　/* 创建taskmain协程 */
	taskcreate(taskmainstart, nil, mainstacksize);
        /* 进入协程调度 */
	taskscheduler();
	fprint(2, "taskscheduler returned in main!\n");
	abort();
	return 0;
}
```
libtask代码写的很清晰，主程序主要是执行taskmain任务创建，接着进入任务调度模块；接下来先看下任务创建函数taskcreate
```
nt
taskcreate(void (*fn)(void*), void *arg, uint stack)
{
	int id;
	Task *t;
	/*　taskalloc函数主要执行任务结构体Task内存分配以及创建，初始化
	　　任务栈信息，创建任务上下文　*/
	t = taskalloc(fn, arg, stack);
	taskcount++;
	id = t->id;
	if(nalltask%64 == 0){//nalltask变量标识所有任务的个数，如果任务超出64个
				//则需要重新分配内存，把任务数组大小增加64
		alltask = realloc(alltask, (nalltask+64)*sizeof(alltask[0]));
		if(alltask == nil){
			fprint(2, "out of memory\n");
			abort();
		}
	}

	t->alltaskslot = nalltask;
	alltask[nalltask++] = t;
	taskready(t);//taskready将任务t标为就绪状态，并加入任务队列中
	return id;
}
//----------------------------------------------------------------------
void
taskready(Task *t)
{
	t->ready = 1;
	addtask(&taskrunqueue, t);//将任务t加入taskrunqueue队列中
}
```
经过taskcreate函数创建maintask任务，并且放入任务队列taskrunqueue队列中之后，接下来，程序进入taskscheduler()调度函数中，我们直接看任务调度循环部分
```
for(;;){

	if(taskcount == 0)
		exit(taskexitval);
	/* 取出队首的任务 */
	t = taskrunqueue.head;
	if(t == nil){
		fprint(2, "no runnable tasks! %d tasks stalled\n", taskcount);
		exit(1);
	}
	/* 从任务队列中删除该任务 */
	deltask(&taskrunqueue, t);
	t->ready = 0;
	taskrunning = t;/* 设置全局任务运行变量为当前执行任务t */
	tasknswitch++; /* 任务切换次数+1 */
	taskdebug("run %d (%s)", t->id, t->name);
	/* 执行任务切换 */
	contextswitch(&taskschedcontext, &t->context);
	taskrunning = nil;

	if(t->exiting){//如果任务t执行完毕，即可在全局任务数组中删除
		if(!t->system)
			taskcount--;

		i = t->alltaskslot;
		alltask[i] = alltask[--nalltask];
		alltask[i]->alltaskslot = i;
		free(t);
	}
}
```
在contextswitch函数中，执行swapcontext函数进行任务切换；在上述example.c例子中，由于一开始任务队列中只有taskmain任务，因此执行contextswitch之后，切换到taskmain任务执行；在taskmain函数中，创建两个任务task1和task2，并加入到taskrunqueue队列中，taskmain即运行结束，在任务启动函数taskstart函数的结尾，有个退出函数taskexit(0)，这个函数执行如下操作:
```
void
taskexit(int val)
{
	taskexitval = val;
	taskrunning->exiting = 1;
	taskswitch();
}
// -----------------------------------------
void
taskswitch(void)
{
	needstack(0);
	contextswitch(&taskrunning->context, &taskschedcontext);
}
```
从这两个函数，我们可以看出在某个任务退出之后，会进行任务切换，将控制权交给任务调度器，然后由调度器调度队列中的下一个任务；因此，到目前为止，libtask的架构更加清晰明了，
>由调度器调度队首任务，并从任务队列中删除队首任务；队首任务执行结束之后，会切回调度器，接着由调度器调度新的队首任务，直到任务队列为空．

>当然有一种情况是遇到taskyield函数，这时当前任务会让出cpu，切换到调度器，并将自身放入任务队列末尾，等待调度器的再次调度．调度器即执行新的队首任务．


这篇文章主要是分析了golang的前身libtask的实现原理，多多少少都有着golang的影子，当然听说golang改进了libtask任务调度机制，因为libtask每次某个任务执行结束都需要切换到调度器，再由调度器调度新的任务，显然，切换到调度器这过程是多余了；具体golang怎么实现，待我后续研究...

下篇文章分析下libtask的channel的实现．











































