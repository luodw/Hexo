title: C++句柄类
date: 2015-09-24 15:05:38
tags:
- C/C++
categories:
- C/C++
toc: true
---

假设有一个父类base，然后从base继承了多个子类base1，base2等等，C++句柄类主要是用来管理
多个子类，统一个的接口，不同的操作．句柄类需要智能指针的基础知识和多态的知识，句柄类其实
就是智能指针＋多态知识．如果，对智能指针不是很了解，可以查看我上篇博客．

<!--more-->

　　直接看代码如下:
```
#include <iostream>
#include <string>
class animal
{
public:
    virtual animal* clone() const=0;
    virtual void eat() const = 0;
    virtual void haul() const = 0;
};

class cat:public animal
{
public:
    cat(std::string n):name(n){
        std::cout<<"create cat:"<<name<<std::endl;
    }
    ~cat(){}
    virtual animal* clone() const
    {
        return new cat(*this);
    }
    virtual void eat() const
    {
        std::cout<<name<<" \teat"<<std::endl;
    }
    virtual void haul() const
    {
        std::cout<<name <<" \thaul"<<std::endl;
    }
private:
    std::string name;
};

class dog:public animal
{
public:
    dog(std::string n):name(n){
        std::cout<<"create dog:"<<name<<std::endl;
    }
    ~dog(){}
    virtual animal* clone() const
    {
        return new dog(*this);
    }
    virtual void eat() const
    {
        std::cout<<name<<" \teat"<<std::endl;
    }
    virtual void haul() const
    {
        std::cout<<name <<" \thaul"<<std::endl;
    }
private:
    std::string name;
};

class handle
{
public:
    handle():an(NULL),use(new std::size_t(1)){}
    handle(const animal&);
    handle(const handle& h):an(h.an),use(h.use){++*use;}
    handle& operator=(const handle&);
    ~handle(){decr_use();}
    const animal* operator->()const {
        if(an) 
            return an;
        else
            return (animal*)-1;}
    const animal* operator*() const {
        if(an) 
            return an;
        else
            return (animal*)-1;
    }
private:
    animal *an;
    std::size_t *use;
    void decr_use()
    {
        if (--*use==0) {
            //std::cout<<"use is = "<<*use<<std::endl;
            delete an;
            delete use;
        }
    }
};

handle::handle(const animal &an):an(an.clone()),use(new std::size_t(1)){    }

handle& handle::operator=(const handle& h)
{
    ++*h.use;
    decr_use();
    an=h.an;
    use=h.use;
    return *this;
}



以下是测试函数，

#include "smart_ptr.h"
#include <iostream>

int main(void)
{
    cat c("tom");
    dog d("jim");
    handle h(c);
    h->eat();//通过重载->操作符实现
    (*h)->haul();//通过重载*操作符实现

    handle h1(d);
    h1->eat();
    (*h1)->haul();
    // handle *h2=new handle(h);
    // delete h2;
    return 0;
}
```

输出结果为：

![](http://img.blog.csdn.net/20150901172818103?watermark/2/text/aHR0cDovL2Jsb2cuY3Nkbi5uZXQv/font/5a6L5L2T/fontsize/400/fill/I0JBQkFCMA==/dissolve/70/gravity/Center "")

可以看到通过传给句柄类不同的子类，同样的接口却调用不同的子类的函数，实现了多态．我注释掉的那两行，
主要时用来验证智能指针的，因为有指针成员，必须使用智能指针，保证指针安全．



