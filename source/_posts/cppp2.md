title: C++智能指针
date: 2015-09-24 14:57:07
tags:
- C/C++
categories:
- C/C++
toc: true
---

最近楼主在深入学习C++，发现智能指针和句柄类挺有意思的，而且也有点难度，所以就写下来，日后可以回顾．
这篇博文先介绍智能指针，下篇介绍句柄类．

C++中，如果类中有指针类型的数据成员，则很容易出现悬垂指针，即一个指向无效内存的地址．如下：

<!--more-->

```
#include <iostream>
class HasPtr{
public:
    HasPtr(int *p):ptr(p){}
    HasPtr(const HasPtr& hptr):ptr(hptr.ptr){}
    HasPtr& operator=(const HasPtr& hptr)
    {
        ptr=hptr.ptr;
        return *this;
    }
    ~HasPtr(){
        delete ptr;
    }
    void print()
    {
        std::cout<<"The value of ptr is: "<<*ptr<<std::endl;
    }
private:
    int *ptr;
};
```

这里定义了一个简单类，公有成员有构造函数，复制构造函数，赋值重载操作符和简单输出指针值．

下面代码简单调用这个类：

```
#include "HasPtr.h"
#include <iostream>

int main(void)
{
    int *ip=new int(42);
　　HasPtr ptr(ip);
　　 ptr.print();
    return 0;
}
```

这个函数输出如下：

![](http://img.blog.csdn.net/20150901210652405?watermark/2/text/aHR0cDovL2Jsb2cuY3Nkbi5uZXQv/font/5a6L5L2T/fontsize/400/fill/I0JBQkFCMA==/dissolve/70/gravity/Center "")

接下来，我new一个HasPtr，复制ptr，然后把这个新生产的HasPtr给delete掉，则输出发生了变化，代码如下：

```
#include "HasPtr.h"
#include <iostream>

int main(void)
{
    int *ip=new int(42);
    HasPtr ptr(ip);
    HasPtr *new_ptr=new HasPtr(ptr);
    delete new_ptr;
    ptr.print();
    return 0;
}
```

输出为：

![](http://img.blog.csdn.net/20150901172457459?watermark/2/text/aHR0cDovL2Jsb2cuY3Nkbi5uZXQv/font/5a6L5L2T/fontsize/400/fill/I0JBQkFCMA==/dissolve/70/gravity/Center "")

问题来了，为什么ptr的输出值为０了？

原来这是因为new_ptr在复制ptr时，只是简单的指针值赋值，也就是说这两个对象的ptr指向的是堆中的
同一个变量，当new_ptr销毁时，把ptr的指针指向的成员都销毁了，这样的输出是没定义的，因为ptr的
指针指向的时一块无效的内存．有没解决的办法了？有，这时智能指针的就派上用场了．

智能指针主要思想就是添加一个计数成员变量（＜＜C++ Primer＞＞用的时技术类，思想一样），
当进行类复制或赋值时，这时类计数成员变量要加１，表示有多少个类引用指针变量，当销毁一个类时，
要判断计数成员是否为０，如果为０，则表示没有对象引用该指针指向的内存，可以delete，
如果不为０，则析构函数啥都不做．代码如下：

```
#include <iostream>
class HasPtr{
public:
    HasPtr(int *p):ptr(p),use(new std::size_t(1)){}
    HasPtr(const HasPtr& hptr):ptr(hptr.ptr),use(hptr.use){ ++*use;}
    HasPtr& operator=(const HasPtr& hptr)
    {
        ++*hptr.use;
        decr_use();//这个过程主要是删除被复制对象的自身成员，防止内存泄露
        ptr=hptr.ptr;
        use=hptr.use;
        return *this;
    }
    ~HasPtr(){
        decr_use();
    }
    void print()
    {
        std::cout<<"The value of ptr is: "<<*ptr<<std::endl;
    }
private:
    int *ptr;
    std::size_t *use;
    void decr_use()
    {
        if (--*use==0)//判断是否是最后一个引用指针指向的内存
        {
            delete ptr;
            delete use;
        }
    }
};
```

这样改变之后，输出的结果就还是42，而不是０．

![](http://img.blog.csdn.net/20150901172350764?watermark/2/text/aHR0cDovL2Jsb2cuY3Nkbi5uZXQv/font/5a6L5L2T/fontsize/400/fill/I0JBQkFCMA==/dissolve/70/gravity/Center "")

