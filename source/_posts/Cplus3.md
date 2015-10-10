title: C++对象模型之内存布局三
date: 2015-10-08 20:27:12
tags:
- C/C++
- 对象模型
categories:
- C/C++

---

经过两天的摸索，今天终于搞清楚C++对象模型．前两篇已经讲解了单继承，多重继承和多继承的对象模型．今天讲解菱形继承，虽然过程艰难，但是收获丰富．

### 简单虚继承对象模型
首先编写如下的测试程序：
```
#include <iostream>
using namespace std;
class A
{
public:
    A(int a1=0,int a2=0):a1(a1),a2(a2){}
     virtual void f(){cout<<"A::f()"<<endl;}
     virtual void af(){cout<<"A::af()"<<endl;}
    int a1;
    int a2;
};

class C: virtual public A
{
public:
    C(int a1=1,int a2=2,int c1=4):A(a1,a2),c1(c1){

    }
    virtual void f1(){cout<<"C::f1()"<<endl;}
    virtual void cf(){cout<<"C::cf()"<<endl;}
    int c1;
};

typedef void (*pfun)();
int main(void)
{
     C *cp=new C;
    pfun fun=NULL;
    cout<<"The C's virtual table->"<<endl;
    for(int i=0;i<2;i++)
    {
        fun=(pfun)*((long*)*(long*)cp+i);
        fun();
    }
    cout<<"c1="<<*((int*)cp+2)<<endl;
      cout<<"The A's virtual table->"<<endl;
     long* p=(long*)cp+2;
    for(int i=0;i<2;i++)
    {
        fun=(pfun)*((long*)*(long*)p+i);
        fun();
    }  
        cout<<"a1="<<*((int*)p+2)<<endl;
         cout<<"a2="<<*((int*)p+3)<<endl;
    return 0;
}
```
上述程序的输出如下：
![简单虚基类验证程序输出](http://7xjnip.com1.z0.glb.clouddn.com/选区_014.png "")
简单解释下：
1. 当存在虚基类时，先是子类的成员，然后才是虚基类的成员．

以下是C对象的对象模型：
![简单虚继承对象模型](http://7xjnip.com1.z0.glb.clouddn.com/C++虚拟继承1.jpg "")

通过在gdb下，输入指令:
```
set p obj on
set p pretty on 
p *this(要运行到成员函数里面)
```
也可以输出C对象的对象模型．截图如下：
![通过gdb显示C对象模型](http://7xjnip.com1.z0.glb.clouddn.com/选区_015.png "")

> 我在理解这个的时候，有分析过c对象调用虚基类的成员方法．通过反汇编代码，我发现当cp调用A中方法时，它先从C类的虚函数表首地址-24字节处获取Ａ子对象相对于cp的偏移量16．所以C的虚函数表首地址负方向的空间还是有研究的地方。．

当我把Ｃ对象的函数f1改成f时，即重写A中的f方法，这时cp中A的子对象中f方法将被C的f方法替换，但是程序输出有错，原因不明。如下：
![C重写A的f方法](http://7xjnip.com1.z0.glb.clouddn.com/C++虚拟继承2.jpg "")

### 菱形继承下的对象模型
编写如下程序：
```
#include <iostream>
using namespace std;
class A
{
public:
	A(int a1=0,int a2=0):a1(a1),a2(a2){}
	 virtual void f(){cout<<"A::f()"<<endl;}
	 virtual void Af(){cout<<"A::Af()"<<endl;}
	int a1;
	int a2;
};
class B1:virtual public A
{
public:
	B1(int a1=0,int a2=0,int b1=0):A(a1,a2),b1(b1){}
	 virtual void f(){cout<<"B1::f()"<<endl;}
	 virtual void f1(){cout<<"B1::f1()"<<endl;}
	 virtual void Bf1(){cout<<"B1::Bf1()"<<endl;}
	int b1;
};
class B2:virtual public A
{
public:
	B2(int b2=0):b2(b2){}
	 virtual void f(){cout<<"B2::f()"<<endl;}
	 virtual void f2(){cout<<"B2::f2()"<<endl;}
	 virtual void Bf2(){cout<<"B2::Bf2()"<<endl;}
	int b2;
};


class C:  public B1,public B2
{
public:
	C(int a1=0,int a2=0,int b1=0,int b2=0,int c1=0):B1(1,2,3),B2(6),c1(7){}
	virtual void f(){cout<<"C::f()"<<endl;}
	virtual void f1(){cout<<"C::f1()"<<endl;}
	 virtual void f2(){cout<<"C::f2()"<<endl;}
	virtual void Cf(){cout<<"C::Cf()"<<endl;}
	int c1;
};

typedef void (*pfun)();
int main(void)
{
	C *cp=new C;
	cout<<sizeof(*bp)<<endl;
	pfun fun=NULL;
	cout<<"The B1's virtual table->"<<endl;
	for(int i=0;i<5;i++)
	{
		fun=(pfun)*((long*)*(long*)cp+i);
		fun();
	}
	long* p=(long*)cp+2;
	cout<<"The B2's virtual table->"<<endl;
	for(int i=0;i<3;i++)
	{
		fun=(pfun)*((long*)*(long*)p+i);
		fun();
	}
	cout<<"The A2's virtual table->"<<endl;
	A *ap=reinterpret_cast<A*>((long*)cp+4);
	for(int i=0;i<2;i++)
	{
		fun=(pfun)*((long*)*(long*)ap+i);
		fun();
	}
	return 0;
}
```
此时程序输出仍然有错，因为c重写了A中的方法。原因不明。c对象模型为：
![菱形虚继承的对象模型](http://7xjnip.com1.z0.glb.clouddn.com/虚拟继承3.jpg "")

如果c不重写A的f方法，即将A的f方法改为f0，则程序输出如下：
![将A的f方法改为f0](http://7xjnip.com1.z0.glb.clouddn.com/选区_016.png "")

我都实在ubuntu下，g++编译器实现的。但是vs的编译器实现是不同，大家可以看陈皓大哥的博客，附上陈皓大哥的博客。
> 陈皓专栏<http://blog.csdn.net/haoel/article/details/3081328/>






