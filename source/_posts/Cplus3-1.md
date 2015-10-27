title: C++构造函数语义学
date: 2015-10-11 19:54:24
tags:
- C++
- 构造函数
- 对象模型
categories:
- C/C++
toc: true 

---
**深度探索C++对象模型**一书，第二章讲解了C++构造函数以及复制构造函数语义学，第五章讲解了C++赋值构造函数和析构函数语义学。特别是复制和赋值函数讲解了Bitwise Copy Semantics和Memberwise Copy Semantics。接下来几篇文章，我将总结这些知识点。

### 构造函数
首先给出两个常见的误解：
1. 任何class如果没有定有default constructor，就会被合成出来
2. 编译器合成出来的default construct会显示设定“class 内每个data member的默认值”

刚接触C++不久的用户估计都有上述的幻觉吧，我们姑且写为“C++对象两大幻觉”。然后看过对象模型这本书之后，完全颠覆你之前的想法。

当我们设计一个类的时候，如果没有显示的定义一个构造函数，那么编译器有可能为这个类产生一个构造函数，也有可能不产生。书中称不产生的构造函数为trivial(没啥用的)，称产生出来的构造函数为nontrivial。

书中总结了会产生nontrivial构造函数的4中情况：
1. 当类的对象成员（类的成员是个对象），有默认构造函数时。因为对于成员是普通的变量类型（相当与C语言struct结构，俗称POD(Plain Old Data））是生成trivial构造函数，啥都不做，所以变量是没有初始化。但是如果类成员是一个对象，必须要有个构造函数类初始化这个对象成员，那么这个类必须要有个构造函数，用户没有定义的话，编译器生成一个。
2. 带有默认构造函数的基类。因为在定义子类的时候，是先调用父类的构造函数。所以如果父类有默认构造函数，子类页必须有。
3. 带有虚函数的类。很简单嘛，因为由虚函数指针，必须有默认构造函数。
4. 带有一个虚基类的class。因为虚基类在子类的上面，需要一种机制使子类能调用虚基类的成员函数，所以必须有默认构造函数。

#### 实例验证
我用一个例子来验证第一条是否正确。其他就不一一验证了。需要用到反汇编。
```
#include <cstdio>
#include <cstdlib>
#include <iostream>
using namespace std;

class A
{
public:
	
private:
	 int a;
};

int main(void)
{
	A a;
	return 0;
}
```
然后编译链接，用gdb查看main函数的汇编代码：
```
(gdb) disas main
Dump of assembler code for function main():
   0x000000000040085d <+0>:	push   %rbp
   0x000000000040085e <+1>:	mov    %rsp,%rbp
   0x0000000000400861 <+4>:	sub    $0x10,%rsp
   0x0000000000400865 <+8>:	lea    -0x10(%rbp),%rax
   0x0000000000400869 <+12>:	mov    %rax,%rdi
   0x000000000040086c <+15>:	callq  0x4008ca <A::test()>
   0x0000000000400871 <+20>:	mov    $0x0,%eax
   0x0000000000400876 <+25>:	leaveq 
   0x0000000000400877 <+26>:	retq   
End of assembler dump.
```
该汇编程序很简单，只是简单将a的地址传入test函数中，并没有调用构造函数。
当我改造这个程序，将A的成员变量改成某个类，如下:
```
#include <cstdio>
#include <cstdlib>
#include <iostream>
using namespace std;
class B
{
public:
	B(int i=0):b(i){}
private:
	int b;
};

class A
{
public:
	void test()
	{
		cout<<"test"<<endl;
	}
private:
	B b;
};

int main(void)
{
	A a;
	a.test();
	return 0;
}

```
main反汇编代码如下:
```
(gdb) disas main
Dump of assembler code for function main():
   0x000000000040085d <+0>:	push   %rbp
   0x000000000040085e <+1>:	mov    %rsp,%rbp
   0x0000000000400861 <+4>:	sub    $0x10,%rsp
   0x0000000000400865 <+8>:	lea    -0x10(%rbp),%rax
   0x0000000000400869 <+12>:	mov    %rax,%rdi
   0x000000000040086c <+15>:	callq  0x400916 <A::A()>
   0x0000000000400871 <+20>:	lea    -0x10(%rbp),%rax
   0x0000000000400875 <+24>:	mov    %rax,%rdi
   0x0000000000400878 <+27>:	callq  0x4008ec <A::test()>
   0x000000000040087d <+32>:	mov    $0x0,%eax
   0x0000000000400882 <+37>:	leaveq 
   0x0000000000400883 <+38>:	retq   
End of assembler dump.
```
看到汇编代码那个醒目的<A::A()>了吗？

当我自定义一个构造函数，然后啥也不做时，
```
A(){

}
```
此时,A a会调用默认构造函数，即上述那个，A()函数反汇编代码如下：
```
(gdb) disas
Dump of assembler code for function A::A():
   0x00000000004008ec <+0>:	push   %rbp
   0x00000000004008ed <+1>:	mov    %rsp,%rbp
   0x00000000004008f0 <+4>:	sub    $0x10,%rsp
   0x00000000004008f4 <+8>:	mov    %rdi,-0x8(%rbp)
   0x00000000004008f8 <+12>:	mov    -0x8(%rbp),%rax
   0x00000000004008fc <+16>:	mov    $0x0,%esi
   0x0000000000400901 <+21>:	mov    %rax,%rdi
   0x0000000000400904 <+24>:	callq  0x4008d6 <B::B(int)>
=> 0x0000000000400909 <+29>:	leaveq 
   0x000000000040090a <+30>:	retq   
End of assembler dump.
```

看到醒目的B::B(int)了吗？说明:
1. 当在类由某个对象成员变量时，如果该类没有构造函数，则编译器帮忙生成一个构造函数；
2. 如果自己定义了一个构造函数，则编译器将B的构造函数代码加在自定义代码之后。











