title: 用gdb反汇编理解c函数栈调用过程．
date: 2015-10-07 20:05:08
tags:
- gdb
- 反汇编
- 函数栈
categories:
- Gdb
- C/C++

---

今天在研究C++虚继承内存布局时，一直不能输出虚基类的虚函数指针，所以想通过gdb反汇编看看代码是什么问题，然后就看了一些这方面的知识．真是获益匪浅．之前写了一篇关于C程序函数栈的分配方式<http://luodw.github.io/2015/09/28/cmemory/>，这篇博客将从汇编的角度解释函数栈分配方式．这里也附上之前那附图：
![c函数栈布局](http://7xjnip.com1.z0.glb.clouddn.com/C运行环境.jpg "")

首先编写一个非常简单的程序：
```
#include<stdio.h>
int sum(int x, int y)
{
	 int accum = 0; 
	 int t;
	 t = x + y;
	 accum += t;
	 return accum;
}
int main( int argc, char **argv)
{
	   int x = 1, y = 2;
	   int result = sum( x, y );
	   printf("\n\n     result = %d \n\n", result);
	   return 0;
}
```
首先堆程序进行编译，加-g，可以得到带调试信息的可执行程序，然后在gdb程序中,
```
disas main或者disas sum查看这两个函数的汇编代码
```
main函数的汇编代码如下，没有进行优化的代码(-O2,-O3)：
```
(gdb) disas main
Dump of assembler code for function main:
   0x0000000000400554 <+0>:	push   %rbp //寄存器rbp指向一个函数栈的栈底，这句代码将调用函数的rbp压入新函数栈的栈底，腾出rbp给新函数使用．
   0x0000000000400555 <+1>:	mov    %rsp,%rbp //寄存器rsp，指向函数栈的栈顶，将寄存器rsp的值赋值给rbp，因为执行push %rbp之后，rsp就指向了rbp，所以此时rbp就指向了main函数的栈底．
   0x0000000000400558 <+4>:	sub    $0x20,%rsp //将rsp栈顶指针向下移动20个字节，即用于开辟内存，存储该函数的局部变量
   0x000000000040055c <+8>:	mov    %edi,-0x14(%rbp)
   0x000000000040055f <+11>:	mov    %rsi,-0x20(%rbp)
   0x0000000000400563 <+15>:	movl   $0x1,-0xc(%rbp)//将1存储在rbp位置-12偏移量的位置，即x的值
   0x000000000040056a <+22>:	movl   $0x2,-0x8(%rbp)//将2存储在rbp位置-8偏移量的位置，即y的值
   0x0000000000400571 <+29>:	mov    -0x8(%rbp),%edx//把y值存储在寄存器edx
   0x0000000000400574 <+32>:	mov    -0xc(%rbp),%eax//把x值存储在寄存器eax
   0x0000000000400577 <+35>:	mov    %edx,%esi//把ｙ存储在esi，即sum参数y
   0x0000000000400579 <+37>:	mov    %eax,%edi//把x存储在eax，即sum参数x
   0x000000000040057b <+39>:	callq  0x40052d <sum>//call命令，跳转到sum函数，
   0x0000000000400580 <+44>:	mov    %eax,-0x4(%rbp)//将eax值（即sum函数返回值）存入rbp－4偏移量的内存位置．
   0x0000000000400583 <+47>:	mov    -0x4(%rbp),%eax//把result值放在eax，
   0x0000000000400586 <+50>:	mov    %eax,%esi//把result值放在esi，即printf参数
   0x0000000000400588 <+52>:	mov    $0x400624,%edi//0x400624为字符串的地址，将给地址存储在edi，printf函数的参数．
   0x000000000040058d <+57>:	mov    $0x0,%eax
   0x0000000000400592 <+62>:	callq  0x400410 <printf@plt>//调用printf函数
   0x0000000000400597 <+67>:	mov    $0x0,%eax//返回值为0．
   0x000000000040059c <+72>:	leaveq 
   0x000000000040059d <+73>:	retq   
End of assembler dump.
```
一些指令需要解释下，否则很难和之前那篇文章的那个图联系起来．
1. mian函数是c或c++函数的入口地址，但是不是汇编的入口地址，汇编入口地址为_start，所以main函数也是和普通函数一样入栈出栈． 
2. rbp和rsp为一个函数栈的边界，rbp指向栈底，rsp指向栈顶．
3. call 指令调用一函数时，调用函数先将参数存入esi和sdi，然后将返回地址压入栈，main函数即将0x400580压入栈，最后跳转到被调用函数执行，main函数中即地址0x40052d．
4. leaveq指令用于释放函数栈，相当于执行movl %ebp,%esp和popl %ebp即和创建栈相反过程．第一句将esp栈顶值替换为ebp的值，即将被调用函数的栈销毁，然后第二句将esp指向的调用函数的ebp值弹出，存入ebp，这时，ebp即为还原为调用函数的栈底,esp减一，指向返回地址．
5. retq指令将esp指向的返回地址弹出，存入eip寄存器中，自从调用函数栈完全销毁，程序从call指令下一条指令开始执行．

接下来是sum函数的汇编代码:
```
(gdb) disas sum
Dump of assembler code for function sum:
   0x000000000040052d <+0>:	push   %rbp//将main函数的rbp压入栈
   0x000000000040052e <+1>:	mov    %rsp,%rbp//
   0x0000000000400531 <+4>:	mov    %edi,-0x14(%rbp)//参数值x存入sum函数栈底偏移量14的位置
   0x0000000000400534 <+7>:	mov    %esi,-0x18(%rbp)//参数值y存入sum函数栈底偏移量18的位置
   0x0000000000400537 <+10>:	movl   $0x0,-0x8(%rbp)//初始化accum的值，为0
   0x000000000040053e <+17>:	mov    -0x18(%rbp),%eax
   0x0000000000400541 <+20>:	mov    -0x14(%rbp),%edx将x,y分别存入eax和edx，用于计算
   0x0000000000400544 <+23>:	add    %edx,%eax//x+y
   0x0000000000400546 <+25>:	mov    %eax,-0x4(%rbp)//将t的值存入rbp偏移量－４的位置
   0x0000000000400549 <+28>:	mov    -0x4(%rbp),%eax//把t存入eax，用于计算
   0x000000000040054c <+31>:	add    %eax,-0x8(%rbp)//将t的值和rbp偏移量为-8的值，即accum的值相加，存入accum．
   0x000000000040054f <+34>:	mov    -0x8(%rbp),%eax//将accum值存入eax，用于返回值，main函数从eax中获取该值
   0x0000000000400552 <+37>:	pop    %rbp//将main函数的rbp值存入rbp
   0x0000000000400553 <+38>:	retq   //程序指令回到main函数call指令的下一条指令执行．
End of assembler dump.
```
有几点需要说明下:
1. 因为sum函数没有在调用其他函数，所以在sum函数内部没有将esp向下移动．esp还是指向sum函数ebp处．


