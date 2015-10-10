title: C++多态实现原理
date: 2015-10-09 21:34:04
tags:
- C/C++
- 多态
categories:
- C/C++

---

对C++有一定了解的人，都知道虚函数机制是实现C++多态重要条件。但是，不知道大家有没想过一个问题，提出问题之前，我先说说我对C++指针的理解。

### C++指针
> C++中某种类型的指针表示内存中某一个地址以及其大小。

关键点有两个：
1. 某一个地址：即指针的值
2. 大小：指针的类型限定了指针能表示的大小。

例如char *指针，它在内存中就表示一个字节的大小。int *指针，在内存中就表示4个字节的大小。
```
struct test
{
	char a;
	int b;
};
```
struct test*型指针就表示8个字节的大小，因为还有a之后要填充3个字节，为了内存对齐

但是对于由父类的指针指向子类的对象时，就会出现字段切割。例如：
```
class A
{
public:
	int a;
};
class B:public A
{
public:
	int b;
};
```
如果A *ap=new B;这行代码首先在堆中申请一块sizeof(B)=8字节大小的内存，然后把内存地址赋给ap。但是ap的类型是A，sizeof(A)=4,所以ap只能表示B对象的前四个字节，这就出现内存切割了。

对于学习C/C++的工程师，一定要好好理解指针表示的意义，才能很好的掌握好C/C++这门语言。

### C++多态原理
编写以下测试代码：
```
#include <iostream>
using namespace std;

class A
{
public:
	A(){}
	virtual void a1()=0;
	virtual void a2()=0;
};

class B:public A
{
public:
	virtual void a1()
	{
		//cout<<sizeof(*this)<<endl;
		a=1;
	}
	virtual void a2()
	{
		cout<<a<<endl;
	}
private:
	int a;
};
int main(void)
{
	A* a=new B();
	a->a1();
	a->a2();
	return 0;
}
```
A* a=new B();这行代码，大家都知道是指针a指向堆中12（虚函数表指针8字节+a4字节）字节大小的B对象。但是a是A类型的指针，只能表示8(虚函数表指针)个字节，那么在调用a->a1()函数时，是怎么设置a值的了？因为a并不能取到8字节外的值。

> 某个对象在调用自己的非static成员函数时，会将这个对象的指针作为this传进成员函数，这样才能操作这个对象的成员。

为了上述答案，我又看了这个小程序的反汇编代码，如下：
main函数调用a1的反汇编代码：
```
29		a->a1();
   0x00000000004009cd <+48>:	mov    -0x18(%rbp),%rax//将a放入rax寄存器
   0x00000000004009d1 <+52>:	mov    (%rax),%rax//虚函数表地址放入rax
   0x00000000004009d4 <+55>:	mov    (%rax),%rax//a1函数地址放入rax
   0x00000000004009d7 <+58>:	mov    -0x18(%rbp),%rdx在把a放入rdx
   0x00000000004009db <+62>:	mov    %rdx,%rdi//把a放入rdi，rdi寄存器在调用函数时，作为传入参数只用，这句代码，其实就是成员函数传入this
---Type <return> to continue, or q <return> to quit---
   0x00000000004009de <+65>:	callq  *%rax//调用a1函数
```
这是进入a1函数的反汇编代码：
```
(gdb) b 17//先进入a1函数
Breakpoint 1 at 0x400a74: file duotai.cc, line 17.
(gdb) r
Starting program: /home/charles/mydir/paper_project/duotai 

Breakpoint 1, B::a1 (this=0x603010) at duotai.cc:17
17			a=1;
(gdb) disas//查看a1函数的反汇编代码
Dump of assembler code for function B::a1():
   0x0000000000400a6c <+0>:	push   %rbp
   0x0000000000400a6d <+1>:	mov    %rsp,%rbp
   0x0000000000400a70 <+4>:	mov    %rdi,-0x8(%rbp)//rdi就是main函数传进来的参数，也就是this指针
=> 0x0000000000400a74 <+8>:	mov    -0x8(%rbp),%rax//this放入rax
   0x0000000000400a78 <+12>:	movl   $0x1,0x8(%rax)//将1存入this指针+8字节偏移量的位置，这句代码就是a=1
   0x0000000000400a7f <+19>:	pop    %rbp
   0x0000000000400a80 <+20>:	retq   
End of assembler dump.
```
从反汇编代码，我们知道，在调用a1函数时，传入的是a指针，而且在设置a时，直接将a指针+8.这样就可以操作B的成员了。但是a是A类型的指针，在a1里面怎么就知道可以+8来操作B成员a了。

后来我就加了注释那句，在B成员函数里面输出this指针都是等于16(8字节虚函数表指针+4字节a+4字节填充)。说明编译器做了如下规定：
> 不管是父类还是子类，只要是调用子类的成员方法，在子类成员方法里面，都把传入的this指针的大小设为子类对象的大小。

这样就可以解释之前的问题了。











