title: C++成员变量指针和成员函数指针
date: 2015-10-10 19:12:08
tags:
- C++
- 成员变量指针
- 成员函数指针
categories:
- C/C++

---
**深度探索C++对象模型**这本书还有提到C++类的成员变量指针和成员函数指针，虽然在实际开发中用的不多，但是还是需要理解下。

## 成员变量指针
### 非静态成员指针

类成员变量指针，实际上并不是真正意义上的指针，即它并不是指向内存中某个地址，而是该成员变量与对象指针的偏移量。该偏移量只有附着在某个具体对象，才能指向对象成员变量的具体地址。

如下程序:
```
#include <cstdio>
#include <cstdlib>
#include <iostream>
using namespace std;
class A
{
public:
	A(int a=0,int b=0):a(a),b(b){}
	void print()
	{
		cout<<"a="<<a<<"  "<<"b="<<b<<endl;
	}
public:
	int a;
	int b;
};
typedef void (A::*pFun)(void);
int main(void)
{
	A ap;
	ap.print();//输出a和b的默认值
	int A::*aptr=&A::a;//aptr为A这个类中，a的成员指针
	int A::*bptr=&A::b;////aptr为A这个类中，a的成员指针

	printf("aptr=%d,bptr=%d\n",aptr,bptr);//输出两个指针值
	ap.*bptr=5;通过成员指针修改成员的值
	ap.print();
	return 0;
}
```
该程序的输出如下:
```
a=0  b=0
aptr=0,bptr=4
a=0  b=5
```
由结果可以看出，指向a的指针值为0,指向b的指针值为4，刚好都是这两个变量在类A实例对象中，与对象指针的偏移量。然后通过将该指针绑定到一个对象，修改该对象的值，也是可以成功的。因为平时，我们用ap.a访问变量a时，编译器就是将ap+a的偏移量来访问的。

### 静态成员
对于C++静态成员的指针，其值就是指向内存中数据区某个地址，就是真正意义上的指针，因为静态成员属于类范围，不属于某个对象。

编写如下程序验证：
```
#include <cstdio>
#include <cstdlib>
#include <iostream>
using namespace std;
class A
{
public:
	A(){}
	void print()
	{
		cout<<"a="<<a<<endl;
	}
public:
	 static int a;
};

int A::a=1;
typedef void (A::*pFun)(void);

int main(void)
{
	const int *p=&A::a;
	printf("p=%p\n",p);
	return 0;
}
```
该程序输出如下：
```
p=0x601058
```
说明下：C++类的静态成员必须在类外初始化，而且初始化一次。如果是
```
const static int a即可在类里面初始化
```
## 成员函数指针
### 非静态函数指针
C++非静态成员函数的指针，其值就是指向一块内存地址。但是指针不能直接调用，它需要绑定到一个对象才能调用。
例子程序如下：
```
#include <cstdio>
#include <cstdlib>
#include <iostream>
using namespace std;
class A
{
public:
	A(int i=3):a(i){}
	void test()
	{
		cout<<"a="<<a<<endl;
	}
public:
	  int a;
};
typedef void (A::*pFun)(void);
int main(void)
{
	A ap;
	pFun fun=&A::test;
	printf("%p\n",&A::test);
	//fun();
	(ap.*fun)();
	return 0;
}

```
该程序的输出如下：
```
0x4009d8
a=3
```
由输出可以看出的确是一个真正意义上的地址指针。但是为什么一定要绑定一个对象了？我的猜想是因为该函数可能会修改成员变量，而修改成员变量必须传入对象指针，所以必须与对象绑定在一起。

### 虚拟成员函数指针
虚拟成员函数指针的值表示该函数在虚函数表中，离表头的偏移量+1。因为在通过反汇编代码知道当一个对象调用虚拟函数时，主要是通过
```
1. 获取指向虚函数表指针的值。
2. 指向虚函数表指针的值加上虚函数离表头的偏移量即为该函数的地址。
```
所以虚函数表示虚函数在虚函数表的偏移量+1，在、再绑定到一个对象，即可调用这个虚函数。
实例程序如下：
```
#include <cstdio>
#include <cstdlib>
#include <iostream>
using namespace std;
class A
{
public:
	A(int i=3):a(i){}
	virtual void test1()
	{
		cout<<"a="<<a<<endl;
	}
	virtual void test2()
	{
		cout<<"a="<<a<<endl;
	}
	virtual void test3()
	{
		cout<<"a="<<a<<endl;
	}
public:
	  int a;
};
typedef void (A::*pFun)(void);
int main(void)
{
	A ap;
	pFun fun=&A::test3;
	printf("%p\n",&A::test1);
	printf("%p\n",&A::test2);
	printf("%p\n",&A::test3);
	(ap.*fun)();
	return 0;
}
```
该程序输出如下：
```
0x1
0x9
0x11//十进制数为17
a=3
```
因为我这是在64位系统下跑的，所以指针大小为8字节，三个虚函数，所以输出三个地址，他们之间相差8个字节，即指针的大小.

### 静态函数
静态函数的指针的值，和静态成员指针的值一样，也是真正意义上的指针，指向内存中某个地址。

实例程序如下：
```
#include <cstdio>
#include <cstdlib>
#include <iostream>
using namespace std;
class A
{
public:
	A(){}
	static void test()
	{
		cout<<"a="<<a<<endl;
	}
public:
	  static int a;
};

int A::a=1;
typedef void (*pFun)(void);
int main(void)
{
	A ap;
	pFun fun=&A::test;
	printf("%p\n",&A::test);
	fun();//opt不需要绑定到一个对象
	return 0;
}
```
该程序输出如下：
```
0x400986
a=1
```

*谈谈我对这些指针本质上的理解。*
> 一个类，当它编译，运行，实例化一个对象时，在内存中总是可以找到该对象的所有成员变量和函数地址。

1. 非静态成员通过对象指针+偏移量访问。
2. 虚函数可以通过对象指针加偏移量得到。
3. 静态成员，非静态函数，静态函数可以通过链接时获得。

所以：
1. 非静态成员指针表示一个偏移量，因为通过对象可以访问到。
2. 虚函数指针表示虚函数地址在虚函数表中的偏移量。
3. 静态成员，非静态函数和静态函数不能通过对象指针直接访问到，所以这三个的指针类型必须是具体的函数地址。

> C++类访问成员的方式决定了该成员指针的类型。




