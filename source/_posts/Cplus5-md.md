title: C++赋值操作符和析构函数语义学
date: 2015-10-12 21:14:47
tags:
- C++
- 赋值操作符
- 析构函数
- 对象模型
categories:
- C/C++
toc: true

---

赋值操作符和复制构造函数语义学几乎一样，我只列出展示Memberwise Copy语义。
1. 当class内含一个member object，而其class有一个copy assignment operator时。
2. 当一个class的base class有一个copy assignment operator时。
3. 当一个class声明了任何virtual functions（我们一定不要拷贝右端class的vptr地址，因为它可能是一个derived class object）时。
4. 当class继承自一个virtual base class(不论此base class 有没有copy operator)时。

### 析构函数语义学
析构函数也并不是默认会自动生成的。析构函数在以下两种情况下由编译器合成。
1. 这个class含有member object，这个object有析构函数。
2. 这个类的基类有析构函数。

编写以下例子测试：
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
class A :public B
{
public:
        A(){
        	cout<<"A()"<<endl;
        }
        virtual void test()
        {
                cout<<"test()"<<endl;
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
该程序的汇编代码如下：
```
(gdb) disas main
Dump of assembler code for function main():
   0x000000000040092d <+0>:	push   %rbp
   0x000000000040092e <+1>:	mov    %rsp,%rbp
   0x0000000000400931 <+4>:	sub    $0x10,%rsp
   0x0000000000400935 <+8>:	lea    -0x10(%rbp),%rax
   0x0000000000400939 <+12>:	mov    %rax,%rdi
   0x000000000040093c <+15>:	callq  0x4009bc <A::A()>
   0x0000000000400941 <+20>:	lea    -0x10(%rbp),%rax
   0x0000000000400945 <+24>:	mov    %rax,%rdi
   0x0000000000400948 <+27>:	callq  0x400a1c <A::test()>
   0x000000000040094d <+32>:	mov    $0x0,%eax
   0x0000000000400952 <+37>:	leaveq 
   0x0000000000400953 <+38>:	retq   
End of assembler dump.
```
并没有析构函数，因为B没有析构函数，当我给B加一个什么都不做的析构函数时，反汇编代码如下：
```
31	        return 0;
   0x0000000000400a2e <+33>:	mov    $0x0,%ebx
   0x0000000000400a33 <+38>:	lea    -0x20(%rbp),%rax
   0x0000000000400a37 <+42>:	mov    %rax,%rdi
   0x0000000000400a3a <+45>:	callq  0x400b96 <A::~A()>
```
在return语句之后，编译器生成了一个析构函数。



