title: 写MyDB收获的经验和遇到的坑
date: 2016-04-09 14:52:27
tags:
- mydb
categories:
- mydb
toc: true

---

之前在用C++写NoSQL时,收获了一些经验也遇到了一些坑;今天想总结下这些经验和坑,避免以后重走弯路;mydb github地址为:[https://github.com/luodw/MyDB](https://github.com/luodw/MyDB "")

# 为什么要写NoSQL?

----

首先说明下为什么要写这个NoSQL了.因为研一开始,我就给自己定下了三步走计划,操作系统+编程语言+开源软件;因为了所有软件都是用某种编程语言编写,运行在某个操作系统之上,所以先学好操作系统特别关键,我推荐的是linux系统;

操作系统要学哪些了?我当初是从基本的linxu命令开始,书本推荐的是**Linux Shell脚本攻略**和**鸟哥的私房菜**;然后看关于系统调用的书籍,如果是C++后台编程,系统调用是免不了的,入门级看,**LINUX系统编程**,然后才是apue和unp1,2.不推荐直接apue,过来人的忠告.最后看内核的东西,这是必须看的,否则对linux很多东西是理解不透彻.例如平时用的管道,了解管道是怎么实现的吗(pipefs)?fork子进程copy on write机制是什么?动态链接库是怎么实现的等等;理解这些原理,对实际的应用非常有帮助,可以说是得心应手;我推荐的书是**Linux内核设计与实现**,还有本厚的**深入理解Linux内核**,我看了部分.还有[Gustavo Duarte的博客](http://duartes.org/gustavo/blog/archives/ "")和[Intel 80386编程手册](https://pdos.csail.mit.edu/6.828/2008/readings/i386/toc.htm ""),内核主要研究的就是文件系统,内存管理(虚拟地址和物理地址的映射非常重要,很多东西的理解都需要这块知识),进程调度,网络模块;

编程语言,我选择的是C/C++;主要是这两门语言接近底层,可以控制内存,可以给用户编程极大的灵活性;就像当初选择linux编程学习而不是window一样;**C++primer** ,**深入理解C++对象模型**和**STL源码剖析**没看完这三本书,真得不敢说自己会C++.我不多说这个,看了都说好.

还有开源软件,我目前有看源码的是leveldb,memcache和redis大部分;我推荐的就是这三个.leveldb整体的设计中包含了很多学习的亮点:内存池arena,缓存的设计,内存屏障,迭代器的设计等等;memcache学习的亮点最重要的就是多线程下的编程模型,当然还有slab内存池;redis这个真推荐,这是我觉得这三个框架里面,代码写的最优雅,思路最清晰,高度模块化；底层用C with class写，而且都是多态类型；事件驱动模块mainae(libevent针对不同平台的封装，代码量太长)，还有主从复制原理，心跳机制等等，看redis收获非常大．

之前在知乎上看到陈硕大哥说的一句话：单进程单线程编程模型的巅峰是redis；单进程多线程编程模型的巅峰是memcache；多进程编程模型的ngnix；说的还是有点道理的；

现在要说下为什么写NoSQL了．因为之前提到的都是看书得到，但是没有实战，很多东西理解的不够透彻；就像没有装个linux双系统来学习，命令很快就忘了．所以我必须将我所学的理论知识，通过实践转化为自己的能力；当然实践会遇到很多问题，这就需要记录下来，避免重蹈覆辙；

# 一些经验

---

1. 使用C++11的function类来实现回调函数声明．一开始时，我在纳闷，C++怎么实现回调函数，用函数指针吧，感觉没脱离C的影子；用函数对象吧，感觉挺麻烦的，啥事都要写个类，所以最后选择了C++11function类；而且function类可以结合bind函数以及lambda函数非常灵活实用，我在给事件注册回调函数时，使用的就是lambda函数注册．
2. 使用nocopyable类来实现避免函数复制，这在**Effective C++**中也有提及，就是定义一个类，将复制构造函数和赋值操作符声明为private，其他类继承nocopyable即可实现避免函数复制；在C++11中可以使用=delete来实现类避免复制．
3. 使用C++ string而不是c字符数组．因为string使用的是copy on write机制，每次复制时，只是简单的复制成员变量，并没有重新开辟一块内存，而是当要更新字符串时，才重新分配内存，达到复制时间复杂度为常数时间．而且不用担心内存泄露(暂时没考虑return或者sigjmp造成的对象没有析构问题，即使有还可以使用智能指针)．相反，使用c字符数组时时都要想着内存有没释放，啥时释放；
```
clients[connfd].outbuf=string("usage:del key\r\n");
```
单看这行代码，等号右边生成一个临时string对象，然后左边的字符串调用赋值操作符，用右边临时字符串给自己赋值．而output并没有为字符串重新开辟内存，而是接管了临时string对象的字符串指针，临时string在这句代码之后就被回收了．而且之后每次给clients[connfd].outbuf赋值时，会先析构原先的字符串，然后才是指向新的字符串，所以不存在内存泄露的问题．
4. 避免vector类型复制(赋值)．当vector存储大量拥有nontrival构造函数对象时，如果vector进行复制或赋值，那么每个对象都要执行构造函数生成对象，将会是非常耗时．所以一般采取的办法是先生成一个新的空的vector，然后新的空的vector调用swap函数与旧的vector进行交换，这样就可以避免新的vector存储对象执行构造函数，也可避免旧的vector存储的对象执行析构函数．如果是情况一个vector，也很适合用swap函数；
5. 在不需要排序的情况，尽量使用unordered_map，而不是map．因为unordered_map底层是用哈希表实现的，负载因子和哈希函数设计的好，则可实现查找操作在常数时间以内，而map底层是红黑树实现的，查找操作则需要O(logn)．
6. STL函数库和lambda函数二者的集合，代码更加简练；原先为了输出一个vector中所有的变量，需要写一个输出仿函数
```
#include <iostream>
#include <vector>
#include <algorithm>
using namespace std;

class output
{
public:
    void operator()(const int& x)
    {
        cout<<x<<" ";
    }
};
int main(void)
{
    vector<int> v={5,2,4,1,7,8,3};
    for_each(v.begin(),v.end(),output());
    cout<<endl;
}
```
但是C++11引入lambda函数之后，代码如下:
```
int main(void)
{
    vector<int> v={5,2,4,1,7,8,3};
    for_each(v.begin(),v.end(),[](const int& x)
    {
        cout<<x<<" ";
    });
    cout<<endl;
    return 0;
}
```
还有很多太细微的经验没列出来，而且我发现我在使用过程中，C++11真的带来了很多优秀的特性，给代码编写带来极大的便利．

# 一些坑

----

说是一些坑，但是我映像最深的还是segmentation fault (core dumped)，太可怕了，因为其他很多系统调用返回的错误，可以通过函数的返回值判断错误的类型，但是出现段错误之后，就直接退出了，经常是不好看出到底是哪行出现问题；我在写MyDB过程中，出现最多的就是段错误，不外乎就是内存访问错误，包括没有给数组分配内存，就访问更新数组元素；访问越界数组元素等等；

数组没有分配内存，程序访问数组元素；例如原先我在定义Client这个结构时，没有给参数数组分配内存，因为后面在分解参数时，需要将每个参数赋给参数数组，就必须访问参数数组，这样就出现段错误了．
```
struct Client
    {
        int fd;//这个客户端的fd
        std::string outbuf;//存储回复客户端的数据
        std::vector<std::string> args;//存储用户输入的命令
    };//客户端结构体

```
因为目前暂时还不需要客户端对象执行函数，所以暂时使用了struct．结构体中的args只是调用默认构造函数，此时不含有任何对象；当解析出各个命令参数，使用索引下标存储时，则出现了段错误,如下：
```
➜  mydb ./mydb
2016-04-10 15:47:16 360 ./net/Ionet.cc line=240 [TRACE] Ionet: mydb init successfully!
2016-04-10 15:47:18 360 ./net/Ionet.cc line=173 [TRACE] Ionet: Accept a clientfd=5
[1]    360 segmentation fault (core dumped)  ./mydb
```
而且错误提示很不友好，只是说明了出现了段错误，并没有具体指出哪出现问题了．所以调试代码也是一项能力，我原本对于小型的程序习惯用输出即可解决，但是对于大点的程序，逻辑稍微复杂点，输出调试就没那么简单了，所以这时就必须使用gdb了．

我用gdb运行程序，然后出现错误之后，输出如下:
```
(gdb) r
Starting program: /home/charles/mydir/mywork/mydb/mydb 
2016-04-10 15:54:59 2638 ./net/Ionet.cc line=240 [TRACE] Ionet: mydb init successfully!
2016-04-10 15:55:05 2638 ./net/Ionet.cc line=173 [TRACE] Ionet: Accept a clientfd=5

Program received signal SIGSEGV, Segmentation fault.
0x00007ffff7b8f7e0 in std::string::swap(std::string&) () from /usr/lib/x86_64-linux-gnu/libstdc++.so.6
(gdb) 
```
看吧，这样虽然看出来是什么段错误，调用std::string::swap(std::string&)函数出现了错误，我们可以猜测是由于std::string对象在调用swap函数时，原对象没有分配内存，但是从gdb目前提示的错误还看不出问题具体出在哪．

所以这时就需要用到where或bt命令，输出调用的函数栈，可以看出问题出现在哪个函数调用上，如下:
```
(gdb) bt
#0  0x00007ffff7b8f7e0 in std::string::swap(std::string&) () from /usr/lib/x86_64-linux-gnu/libstdc++.so.6
#1  0x00007ffff7b8f829 in std::string::operator=(std::string&&) ()
   from /usr/lib/x86_64-linux-gnu/libstdc++.so.6
#2  0x00000000004101a5 in ionet::Parse::parseArgs(ionet::Client&) ()
#3  0x0000000000408b13 in ionet::Ionet::FdHandler(int) ()
#4  0x000000000040bcb1 in ionet::Ionet::FdAccept(int)::$_2::operator()(int) const ()
#5  0x000000000040ba33 in std::_Function_handler<void (int), ionet::Ionet::FdAccept(int)::$_2>::_M_invoke(std::_Any_data const&, int) ()
#6  0x000000000040821c in std::function<void (int)>::operator()(int) const ()
#7  0x000000000040808a in ionet::Fdevent::handler(int) ()
#8  0x0000000000404751 in ionet::EventLoop::startLoop() ()
#9  0x000000000040b53e in ionet::Ionet::run() ()
#10 0x0000000000402670 in main ()
(gdb) 
```
这个输出从下到上是从最开始的main函数到出现问题的函数的函数栈．第0和第1个都是标准库string的成员函数，第2个才是我自己定义的函数，这样我就定位到错误出现的函数，我们定位到Parse::parseArgs这个函数
```
void Parse::parseArgs(Client &client)
    {
        int i=0; char *q=query;
        const char* delim=" ";
        char *p=strtok(q,delim);
        client.args[i++]=string(p);
        //strtok函数第二次调用时,必须传递NULL值,否则会无限迭代
        while((p=strtok(NULL,delim))!=NULL)
        {
            client.args[i++]=string(p);
        }
        i--;
        size_t pos=client.args[i].find(string("\r\n"));
        client.args[i].erase(pos);
    }
```
有之前的输出，我们知道错误是字符串的赋值错误，而在这个函数内部，就是给client.args参数数组赋值错误，所以我们可以把错误定位在这个client.args这个数组上，再结合段错误的一些原因，即可分析出错误的原因．

如果还是不知道错误，可以在这函数内部采用输出调试或者定点单步调试．

定点调试可以先定位到parse.cc这个文件
```
client.args[i++]=string(p);
```
然后执行程序到此，可以输出client.args[i++]这个变量，看看得出什么结果．
```
(gdb) b parse.cc:27 //定位到赋值语句位置
Breakpoint 1 at 0x40d9e1: file ./util/parse.cc, line 27.
(gdb) r
Starting program: /home/charles/mydir/mywork/mydb/mydb 
2016-04-10 16:35:03 14443 ./net/Ionet.cc line=240 [TRACE] Ionet: mydb init successfully!
2016-04-10 16:35:07 14443 ./net/Ionet.cc line=173 [TRACE] Ionet: Accept a clientfd=5

Breakpoint 1, ionet::Parse::parseArgs (this=0x7fffffffdd68, client=...) at ./util/parse.cc:27
27	        client.args[i++]=string(p);
(gdb)  p  client.args[i++]
$1 = <error reading variable: Cannot access memory at address 0x0>
(gdb) p client
$2 = (ionet::Client &) @0x6183b0: {fd = 5, outbuf = "", args = std::vector of length 0, capacity 0}
(gdb) 
```
当输出client.args[i++]时，输出的错误，没看过vector源码可能理解不是很清楚，我把源码黏贴如下:
```
const_reference operator[](size_type n) const { return *(begin() + n); }
//========================================================================
vector() : start(0), finish(0), end_of_storage(0) {}
```
当调用clients.args[i++]时，会调用重载下标操作符函数，在重载下标函数内部，返回begin()迭代器向前移动n个位置元素的引用，而begin()返回是start迭代器，这个迭代器在没有参数的默认构造函数中初始为0，所以当输出client.args[i++]即输出start指向的值，就是位置0x0．

从输出client也可以看出args长度为0．

其他段错误也可以通过这种方法找出问题所在；如何调试段错误也是我写这篇文章最重要的原因，因为之前我对这不是很在行，所以需要记录下这过程，今后再出现段错误，可以快速解决问题．

# 聊聊gdb原理

---

之前实习面试时，一位面试官问了我gdb设断点的原理，我一下懵了，因为我之前就是使用，没想过这个问题，这激发我极大的好奇心，我通过查找资料，发现gdb的实现主要是靠ptrace这个函数．简单的说gdb ./mydb时，会在gdb程序中fork和execl(./mydb)这个子进程，当我们设置断点时，其实是将原先设置断点处的指令替换为int 3指令，这样当进程运行到断点处时，会给gdb进程发送SIGTRAP信号，子进程则阻塞；父进程接收到此信号之后，则根据用户的输入，做出相应的回答．

ptrace这个系统调用还可以用来输出程序调用的系统调用，strace命令底层使用的就是这个系统调用．

ptrace还可以用来输出函数栈，pstack命令底层就是使用pstrace函数实现的，我之前还一直以为是backtrace函数实现的．但是回过头来想想，backtrace只是个函数，他必须嵌入到程序中才能输出函数栈，所以pstack底层不可能是backtrace函数实现．

理解了gdb的实现原理，再来使用gdb，会更加的得心应手...


















