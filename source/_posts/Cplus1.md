title: C++对象模型之内存布局一
date: 2015-10-06 19:18:52
tags:
- C/C++
- 对象内存模型
categories:
- C/C++
toc: true

---

如果想学习在linux或者在linux平台下开发，学习C/或C++是非常好的选择．俗话说，术业有专攻，学一门技术，就尽量学得深，也可以作为行走江湖，混口饭吃的一项本领．

对于C，当初我是看了**C与指针**这门书，这本书讲解了很多我没有了解过的知识点，特别是指针讲解的很到位．最后还设计了C运行时内存模型．

对于C++的学习，我看了**C++ Primer**之后，进阶的书为**深入理解C++对象模型**，这本书讲解了C++类在内存中是如何布局以及成员函数是怎么调用，有助于理解C++多态是如何实现的．总之，受益匪浅．

接下来，我将用几篇博客聊聊C++对象模型．

## 无多态的对象布局
### 单个类
假设有以下一个类的定义：
```
class A
{
public:
	A(int a1=0,int a2=0);
	void A1();
protected:
	int a1;
	int a2;
};
```
如果类没有虚函数，那么class的布局和c语言的struct布局一样，只有成员变量．对象内存布局如图１所示．

### 继承类
有一个类B继承A，定义如下：
```
class B :public  A
{
public:
	B(int a1=0,int a2=0,int b1=0);
	void B1();
protected:
	int b1;
};
```
子类的构造函数是先构造父类，在构造子类，所以类B对象内存布局只要在A成员之后加上B的成员即可，示意图如图１：
![图１　无多态下类内存布局](http://7xjnip.com1.z0.glb.clouddn.com/C++内存模型1.jpg "")

## 多态下对象内存布局
### 单个类
首先定义一个类，带有虚函数：
```
class A
{
public:
	A(int a1=0,int a2=0);
	virtual void A1();
	virtual void A2();
	virtual void A3();
protected:
	int a1;
	int a2;
};
```
因为class A带有虚函数，所以A对象的内存布局就要增加一个指针，指向类A的虚函数表．对象模型如图２所示.**深入理解C++对象模型**将指针放在了对象的末尾，但是现在主流的编译器都将指针放在了对象的首位置．
![图２ 单继承下的对象模型](http://7xjnip.com1.z0.glb.clouddn.com/C++内存布局2.jpg "")

### 单继承
单继承类的定义如下：
```
class B :public  A
{
public:
	B(int a1=0,int a2=0,int b1=0);
	virtual void B1();
	virtual void A2();
	virtual void B2();
protected:
	int b1;
};
```
当父类有虚函数时，子类继承父类的虚函数表，而且虚函数的顺序是先父类的虚函数，再子类的虚函数；当父类的虚函数被子类重写时，则虚函数表中的父类虚函数指针要替换为子类的虚函数指针，示意图如图２．

### 实例验证
为了验证之前的对象模型是否正确，我写了如下程序进行验证：
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
	virtual void A2(){cout<<"A::A2()"<<endl;}
	virtual void B2(){cout<<"B::B2()"<<endl;}
protected:
	int b1;
};

typedef void (*pfun)();//定义函数指针
int main(void)
{
	B *bp=new B;
	pfun fun=NULL;//函数指针变量，用于循环迭代虚函数表
	for(int i=0;i<5;i++)
	{
		fun=(pfun)*((long*)*(long*)bp+i);//因为我的ubuntu是64位的，所以用long类型．如果是32位的系统，可以用int类型．
		fun();
	}
	cout<<*((long*)*(long*)bp+5)<<endl;//输出虚函数表的结束符
	return 0;
}
```
稍微解释下
```
fun=(pfun)*((long*)*(long*)bp+i)
```
+ (long\*)bp，将对象的指针类型转换为(long*)类型，用于取出虚函数表的地址．
+ \*(long\*)bp，＊为取出指针指向的值．此式子即虚函数表的地址，也就是第一个虚函数的地址．
+ (long\*)\*(long*)bp，将虚函数表的地址指针转换为(long\*)，用于后续迭代．
+ \*(long\*)\*(long*)bp，＊求指针值，即为第一个虚函数的地址，最后转换为pfun指针.

该程序输出结果为：
![验证C++内存模型程序输出](http://7xjnip.com1.z0.glb.clouddn.com/选区_006.png "")

输出顺序和我上述一样．

多重继承，多继承以及菱形继承留在下一篇博客．
