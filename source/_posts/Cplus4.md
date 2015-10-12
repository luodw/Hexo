title: C++复制构造函数语义学
date: 2015-10-12 19:04:22
tags:
- C++
- 复制构造函数
categories:
- C/C++

toc: true

---

上篇讲了C++构造函数语义学，这篇文章接着将C++复制构造函数语义学，也属于构造函数。
C++有三种情况会用到C++复制构造函数
1. 直接用一个类对象类初始化另一个类对象
2. 类变量作为函数参数时，此时如果传进对象实参，形参将会用实参显试初始化。
3. 类变量作为函数返回值时。

C++复制构造函数和构造函数一样，也是需要的时候才会产生。什么情况下会产生复制构造函数了？

C++有分Bitwise Copy Semantics和Memberwise Copy Semantics。默认情况下，C++用的是Bitwise Copy Semantics，即一个个bit拷贝复制。但是在以下情况下，必须用Memberwise Copy Semantics，即成员变量为单位复制。
1. 当class内含一个member object，而后者的class声明有一个copy constructor时（不论是用户自己定义的，还是编译器生成的）。
2. 当class继承自一个base class而后者存在一个copy constructor时（再次强调，不论是显示声明或编译器合成）
3. 当class声明了一个或多个virtual functions时。
4. 当class派生自一个继承串链时，其中有一个或多个virtual base classes时。


前两个相对较简单，我用一个例子来测试第三条。
```
#include <cstdio>
#include <cstdlib>
#include <iostream>
using namespace std;

class A 
{
public:
	A(int a=0):a(a){
	}
	void test()
	{
		cout<<"test"<<endl;
	}
private:
	int a;
};

int main(void)
{
	A a;
	A a1=a;
	a1.test();
	return 0;
}
```
main函数反汇编代码如下：
```
(gdb) disas main
Dump of assembler code for function main():
   0x000000000040085d <+0>:	push   %rbp
   0x000000000040085e <+1>:	mov    %rsp,%rbp
   0x0000000000400861 <+4>:	sub    $0x20,%rsp
   0x0000000000400865 <+8>:	lea    -0x20(%rbp),%rax
   0x0000000000400869 <+12>:	mov    $0x0,%esi
   0x000000000040086e <+17>:	mov    %rax,%rdi
   0x0000000000400871 <+20>:	callq  0x4008e2 <A::A(int)>
   0x0000000000400876 <+25>:	mov    -0x20(%rbp),%eax
   0x0000000000400879 <+28>:	mov    %eax,-0x10(%rbp)
   0x000000000040087c <+31>:	lea    -0x10(%rbp),%rax
   0x0000000000400880 <+35>:	mov    %rax,%rdi
   0x0000000000400883 <+38>:	callq  0x4008f8 <A::test()>
   0x0000000000400888 <+43>:	mov    $0x0,%eax
   0x000000000040088d <+48>:	leaveq 
   0x000000000040088e <+49>:	retq   
End of assembler dump.
```
并没有调用复制构造函数。

当我把**test函数改成virtual**时，汇编代码如下：
```
(gdb) disas main
Dump of assembler code for function main():
   0x00000000004008cd <+0>:	push   %rbp
   0x00000000004008ce <+1>:	mov    %rsp,%rbp
   0x00000000004008d1 <+4>:	sub    $0x20,%rsp
   0x00000000004008d5 <+8>:	lea    -0x20(%rbp),%rax
   0x00000000004008d9 <+12>:	mov    $0x0,%esi
   0x00000000004008de <+17>:	mov    %rax,%rdi
   0x00000000004008e1 <+20>:	callq  0x40095e <A::A(int)>
   0x00000000004008e6 <+25>:	lea    -0x20(%rbp),%rdx
   0x00000000004008ea <+29>:	lea    -0x10(%rbp),%rax
   0x00000000004008ee <+33>:	mov    %rdx,%rsi
   0x00000000004008f1 <+36>:	mov    %rax,%rdi
   0x00000000004008f4 <+39>:	callq  0x4009aa <A::A(A const&)>
   0x00000000004008f9 <+44>:	lea    -0x10(%rbp),%rax
   0x00000000004008fd <+48>:	mov    %rax,%rdi
   0x0000000000400900 <+51>:	callq  0x400980 <A::test()>
   0x0000000000400905 <+56>:	mov    $0x0,%eax
   0x000000000040090a <+61>:	leaveq 
   0x000000000040090b <+62>:	retq   
End of assembler dump.
```
我们可以看到调用**callq  0x4009aa <A::A(A const&)>**复制构造函数。跟进到这个复制构造函数时，可以看到这个函数只是简单的将虚拟函数表复制给对象的首8个字节，因为没有用户其他代码。

当我再一次改造这个程序时，即用子类来初始化父类时：
```
#include <cstdio>
#include <cstdlib>
#include <iostream>
using namespace std;
class B
{
public:
	B(int i=0):b(i){}
	B(B const& b)
	{
		
	}
	virtual void test1()
	{
		cout<<"test"<<endl;
	}
private:
	int b;
 };

class A :public B
{
public:
	A(int a=0,int b=0):B(b),a(a){
	}
	virtual void test2()
	{
		cout<<"test"<<endl;
	}
private:
	int a;
};

int main(void)
{
	A a;
	B b=a;
	b.test1();
	return 0;
}
```
这时我深入到B的复制构造函数中，即断点在B(B const& b)函数里，该函数的汇编代码为：
```
(gdb) disas
Dump of assembler code for function B::B(B const&):
   0x00000000004009e6 <+0>:	push   %rbp
   0x00000000004009e7 <+1>:	mov    %rsp,%rbp
   0x00000000004009ea <+4>:	mov    %rdi,-0x8(%rbp)
   0x00000000004009ee <+8>:	mov    %rsi,-0x10(%rbp)
   0x00000000004009f2 <+12>:	mov    -0x8(%rbp),%rax
   0x00000000004009f6 <+16>:	movq   $0x400b70,(%rax)
=> 0x00000000004009fd <+23>:	pop    %rbp
   0x00000000004009fe <+24>:	retq   
End of assembler dump.
(gdb) x /x $rdi
0x7fffffffd710:	0x00400b70
(gdb) x /x $rsi
0x7fffffffd700:	0x00400b50
(gdb) 
```
0x00400b70这是B的虚函数地址，0x00400b50这是A的虚函数地址，由汇编可以看出，B b=a，调用的是B的复制构造函数，在复制构造函数内，直接把B的虚函数地址复制给b。所以类里面有虚函数必须合成默认构造函数，否则用子类的的对象来初始化父类对象时，如果采用bitwise复制，那么复制的是子类的虚函数表，这显然是错误的。

### 编译器优化
当有以下代码时，
```
A foo()
{
	A a;
	a.test();
	return a;
}
 
A a=foo();
```
按正常理解，最后一句是会调用复制构造函数，然而编译器会做出优化，编译器正真做的就和我普通想得不一样了。

编译器会改写这个函数，这样以来就不用调用复制构造函数了，因为当类成员很多很大时，复制操作是很耗时的。
```
void foo(A &_result)
{
	_result.test();
}
A a;
foo(a);
```
通过查看反汇编也可以看出编译器这样的改写。
 


