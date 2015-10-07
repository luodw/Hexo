title: C++对象模型之内存布局二
date: 2015-10-07 09:49:00
tags:
- C/C++
- C++对象内存模型
categories:
- C/C++
toc: true

---

上篇文章讲了无多态和有多态下的单继承的对象内存布局，这篇文章将深入讲解多重继承和多继承．

### 多重继承
#### 理论讲解
多重继承，顾名思义，就是继承关系大于２，即至少有父类，子类，孙子类三代关系，先定义以下三个类：
```
class A
{
public:
	A(int a1=0,int a2=0){}
	virtual void A1(){cout<<"A::A1()"<<endl;}
	virtual void A2(){cout<<"A::A2()"<<endl;}
	virtual void A3(){cout<<"A::A3()"<<endl;}
protected:
	int a1;
	int a2;
};

class B :public  A
{
public:
	B(int a1=0,int a2=0,int b1=0){}
	virtual void B1(){cout<<"B::B1()"<<endl;}
	virtual void A2(){cout<<"B::A2()"<<endl;}
	virtual void B2(){cout<<"B::B2()"<<endl;}
protected:
	int b1;
};

class C:public B
{
public:
	C(int a1=0,int a2=0,int b1=0,int c1=0){}
	virtual void C1(){cout<<"C::C1()"<<endl;}
	virtual void A1(){cout<<"C::A1()"<<endl;}
	virtual void B2(){cout<<"C::B2()"<<endl;}
protected:
	int c1;
};
```
类B公有继承A，类C公有继承B，图一是类C的内存布局
![图一　多重继承内存布局](http://7xjnip.com1.z0.glb.clouddn.com/C++内存布局3.jpg "")

其实多重继承和单继承很类似，就是在父类的基础上添加成员变量和更新虚函数表．
#### 实例讲解
编写了以下程序进行验证:
```
#include <iostream>
using namespace std;
class A
{
public:
	A(int a1=0,int a2=0){}
	virtual void A1(){cout<<"A::A1()"<<endl;}
	virtual void A2(){cout<<"A::A2()"<<endl;}
	virtual void A3(){cout<<"A::A3()"<<endl;}
protected:
	int a1;
	int a2;
};

class B :public  A
{
public:
	B(int a1=0,int a2=0,int b1=0){}
	virtual void B1(){cout<<"B::B1()"<<endl;}
	virtual void A2(){cout<<"B::A2()"<<endl;}
	virtual void B2(){cout<<"B::B2()"<<endl;}
protected:
	int b1;
};

class C:public B
{
public:
	C(int a1=0,int a2=0,int b1=0,int c1=0){}
	virtual void C1(){cout<<"C::C1()"<<endl;}
	virtual void A1(){cout<<"C::A1()"<<endl;}
	virtual void B2(){cout<<"C::B2()"<<endl;}
protected:
	int c1;
};

typedef void (*pfun)();
int main(void)
{
	C *bp=new C;
	pfun fun=NULL;
	for(int i=0;i<6;i++)
	{
		fun=(pfun)*((long*)*(long*)bp+i);
		fun();
	}
	cout<<*((long*)*(long*)bp+6)<<endl;
	return 0;
}
```
该程序的输出结果为：
![多重继续的程序验证](http://7xjnip.com1.z0.glb.clouddn.com/选区_007.png "")
程序的输出顺序和上述给出的图一样，这就证明了我给出的内存布局图是正确的．

### 多继承
#### 理论讲解
多继承，顾名思义就是说一个子类的父类不止一个．定义以下三个类，以及他们的继承关系：
```
class A
{
public:
	A(int a1=0,int a2=0){}
	virtual void A1(){cout<<"A::A1()"<<endl;}
	virtual void A2(){cout<<"A::A2()"<<endl;}
protected:
	int a1;
	int a2;
};

class B 
{
public:
	B(int b1=0){}
	virtual void B1(){cout<<"B::B1()"<<endl;}
	virtual void B2(){cout<<"B::B2()"<<endl;}
protected:
	int b1;
};

class C:public A,public B
{
public:
	C(int a1=0,int a2=0,int b1=0,int c1=0){}
	virtual void C1(){cout<<"C::C1()"<<endl;}
	virtual void A2(){cout<<"C::A2()"<<endl;}
	virtual void B2(){cout<<"C::B2()"<<endl;}
protected:
	int c1;
};
```
定义了三个类，类C分别继承类A和类B，类C的内存布局图二所示：
![图二　多继承下的内存布局](http://7xjnip.com1.z0.glb.clouddn.com/C++内存布局4.jpg "")

多继承的内存布局和单继承和多重继承不一样，子类继承一个父类，子类就有一个虚函数表，当子类继承两个父类时，子类就有两个虚函数表；而且子类自己定义的虚函数，放在了第一个继承类的虚函数表里．

#### 程序验证
编写以下程序来验证上述理论：
```
#include <iostream>
using namespace std;
class A
{
public:
	A(int a1=0,int a2=0){}
	virtual void A1(){cout<<"A::A1()"<<endl;}
	virtual void A2(){cout<<"A::A2()"<<endl;}
protected:
	int a1;
	int a2;
};

class B 
{
public:
	B(int b1=0){}
	virtual void B1(){cout<<"B::B1()"<<endl;}
	virtual void B2(){cout<<"B::B2()"<<endl;}
protected:
	int b1;
};

class C:public A,public B
{
public:
	C(int a1=0,int a2=0,int b1=0,int c1=0){}
	virtual void C1(){cout<<"C::C1()"<<endl;}
	virtual void A2(){cout<<"C::A2()"<<endl;}
	virtual void B2(){cout<<"C::B2()"<<endl;}
protected:
	int c1;
};

typedef void (*pfun)();
int main(void)
{
	C *bp=new C;
	pfun fun=NULL;
	cout<<"The A's virtual table->"<<endl;
	for(int i=0;i<3;i++)
	{
		fun=(pfun)*((long*)*(long*)bp+i);
		fun();
	}
	cout<<"The B's virtual table->"<<endl;
	int* p=(int*)bp+4;//因为bp是指向C的第一个字节，也就是A的虚函数表地址，如果要获得B的虚函数地址，需要将该指针移到B的虚函数表地址，A的虚函数表地址(8字节)＋a1(4字节)+a2(4字节)=16字节，所以把bp转换为int*指针再加４．
	for(int i=0;i<2;i++)
	{
		fun=(pfun)*((long*)*(long*)p+i);
		fun();
	}
	cout<<*((long*)*(long*)p+2)<<endl;//输出最后虚函数结束符．
	return 0;
}
```
该程序输出的结果为：
![图二　多继承的验证程序输出](http://7xjnip.com1.z0.glb.clouddn.com/选区_008.png "")

程序的输出和上述理论给出的一样．

还有虚拟继承和菱形继承，留在最后一篇文章讲解．

