title: C++之柔性数组
date: 2015-10-22 21:24:38
tags:
- C/C++
- 柔性数组
categories:
- C/C++

---

当初在看redis源码时，发现SDS定义如下：
```
struct sdshdr
{
	int len;
	int free;
	char buf[];
};
```
有没发现char buf[]这个定义，不对，不能称为定义，因为数组的长度未知，称为声明吧。如果单独定义char buf[]是会报错的，因为长度未知，那么为什么放在结构体里面就可以了。今天在看STL源码解析时，看到内存配置器有个联合体的定义把我迷惑迷惑的是不要不要的，在百度过程中发现了**柔性数组**这个东西。

先介绍柔性数组这个东西，再来看STL里的联合体。

如果在一个结构体里面放置一个一个动态分配的字符串，我们可以在结构体里面放置一个指向动态分配的内存指针，如下定义：
```
struct test
{
	int a;
	char *p;
};
```
但是如果这样，会造成结构体和字符串的分离，可以把结构体和字符串放在一起效果会更好，例如
```
char ch[]="hello world!";
struct test* p=(struct test*)malloc(sizeof(struct test)+sizeof(ch)+1);
strcpy(p+1,ch);
```
这样一来，就可以通过(char*)(p+1)来访问字符串了。但是老是这样的话，不是很方便。如果能在结构体里放置一个指针又不占用内存，那将会非常完美。柔性数组就这样出来了。且看如下定义：
```
struct test
{
        int a;
        char buf[];
};
```
没错，就是和SDS定义一样的，因为这个数组没有指定长度，所以这个数组并不占用内存，大家都知道这个数组名代表这个数组的首位置，所以在这个结构体里，这个buf只是指向成员a的下一个地址而已。我们还是可以如下定义这个结构体。
```
char ch[]="hello world!";
struct test* p=(struct test*)malloc(sizeof(struct test)+sizeof(ch)+1);
strcpy(p->buf,ch);
```
这时，当p指向的内存空间当做一个整体时，buf指向的就是一块动态长度的内存，柔性一词来源于此。这样的做法有以下几个好处:
1. 首先柔性数组不占内存，值代表地址；
2. 可以通过p->buf来访问字符串，符合常规用法。
3. 字符串长度为动态分配。

接下来，我就要讲解困惑我的那个联合体了。
首先来看下定义：
```
union obj{
	union obj *free_list_link;
	char client_data[1];
};
```
首先要知道这个联合体的大小=联合体里最大的数据类型的大小，所以这个联合体的大小为8字节（我系统64位）；我今天的困惑是啥了？先看下如下代码：
```
#include <iostream>

using namespace std;

union obj
{
    union obj *free_list_link;
    char client_data[1];
};
    
int main(int argc, char const *argv[])
{
    //假设这两个是要分配出去的内存。
    char mem[100] = { 0 };
    char mem1[100] = { 0 };
    
    //现在是每一块内存的开始均是一个union node结构
    //----------------------------------
    //| union obj | ....................
    // ----------------------------------  
    union obj *p1 = (union obj *)mem; //用一个变量表示这个结构
    
   //p1->free_list_link 设置为下一个内存的起始段
    p1->free_list_link = (union obj *)mem1 ;
    
    //可以看到mem和client_data 两个指针值是一致的
    cout <<"mem             = " << (void *)mem << endl;
    cout <<"p1->client_data = " << (void *)p1->client_data << endl;

    //client_data只是为了简化本段内存的定义的，只是方便一些，
    //可以使用(void *)p1表示本段内存，但是每次要转换，可能不方便吧，
    //实际中可能也用不到

    return 0;
}
```
这个程序是CSDN上的一个验证程序，最后输出两个值相等。我今天很困惑，因为union的所有成员变量共享同一块内存，那么对p1->free_list_link赋值为什么没有破坏掉pi->client_data的值？

看了柔性数组之后，才解开了我的困惑，因为虽然给client_data分配了一个字符的内存，但是client_data始终指向的是内存的首地址。如果说要覆盖client_data的值，那么也要先给client_data赋初值，这时，client_data的数据就占有了这个8字节内存，如果再给free_list_link赋值，那么这时就真正破坏了client_data的数据，但是client_data还是指向这内存的首地址。这也是用一指针大小的内存，实现着两个功能，太妙了。

柔性指针有参考梦中乐园的博客<http://www.cppblog.com/Dream5/articles/148386.html>，特别指出下。

