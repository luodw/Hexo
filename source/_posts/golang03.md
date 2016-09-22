title: 从汇编角度理解golang多值返回和闭包
date: 2016-09-04 15:48:16
tags:
- golang
categories:
- golang
toc: true

---

今天聊两个轻松的话题，golang相比与之前学习的C/C++，有很多新颖的特性，不知道大家的使用的时候，有没想过，这些特性是如何实现的？当然你可能会说，不了解这些特性好像也不影响自己使用golang；对，你说的也有道理；但是，多了解底层的实现原理，对于在使用golang时的眼界是完全不一样的，就类似于看过http的实现之后，再来使用http框架，和未看过http框架时的眼界是不一样的，当然，你如果是一名it爱好者，求知欲自然会引导你去学习；知其然而不知其所以然，是很可怕的；

![厦门世贸中心](http://7xjnip.com1.z0.glb.clouddn.com/ldw-0033033999475765_b.jpg "")

相对于C/C++，golang有很多新颖的特性，例如goroutine,channel,defer,reflect,interface{}等等；这些特性其实从golang源码是可以理解其实现的原理；今天这篇文章主要来分析下golang多值返回以及闭包的实现，因为这两个实现golang源码中并不存在，我们必须从汇编的角度来窥探二者的实现；

这篇文章主要就分析两点:
1. golang多值返回的实现;
2. golang闭包的实现;
3. 总结;

# golang多值返回的实现

----

我们在学C/C++时，很多人应该有了解过C/C++函数调用过程，参数是通过寄存器di和si(假设就两个参数)传递给被调用的函数，被调用函数的返回结果只能是通过eax寄存器返回给调用函数，因此C/C++函数只能返回一个值，那么我们是不是可以想象，golang的多值返回是否可以通过多个寄存器来实现的，正如用多个寄存器来传参一样？

这也是一种办法，但是golang并没有采用；我的理解是引入多个寄存器来存储返回值，会引起多个寄存器用途的重新约定，这无疑增加了复杂度；可以这么说，golang的ABI与C/C++非常不一样；

在从汇编角度分析golang多值返回之前，需要先熟悉golang汇编代码的一些约定，[golang官网](https://golang.org/doc/asm "")有说明，这里重点说明四个symbols，需要注意的是这里的寄存器是伪寄存器：
1. FP　栈底寄存器，指向一个函数栈的顶部；
2. PC  程序计数器，指向下一条执行指令;
3. SB　指向静态数据的基指针，全局符号;
4. SP　栈顶寄存器;

这里面最重要的就是FP和SP，FP寄存器主要用于取参数以及存返回值，golang函数调用的实现很大程度上都是依赖这两个寄存器，这里先给出结果，

```
                              
              +-----------+---\
              |  返回值2  |    \
              +-----------+     \
              |  返回值1  |      \
              +---------+-+      
              |  参数2    |      这些在调用函数中
              +-----------+       
              |  参数1    |   　 /
              +-----------+     /
              |  返回地址 |    /
              +-----------+--\/-----fp值
              |  局部变量 |   \
              |    ...    |   被调用数栈祯
              |           |   /
              +-----------+--/+---sp值

```

这个就是golang的一个函数栈，也是说函数传参是通过fp+offset来实现的，而多个返回值也是通过fp+offset存储在调用函数的栈帧中；下面通过一个例子来分析
```
package main

import "fmt"

func test(i, j int) (int, int) {
	a := i + j
	b := i - j
	return a, b
}

func main() {
	a, b := test(2, 1)
	fmt.Println(a, b)
}
```

这个例子很简单，主要是为了说明golang多值返回的过程；我们通过下面命令编译该程序
> go tool compile -S test.go > test.s

然后，就可以打开test.s，来看下这个小程序的汇编代码。首先来看下test函数的汇编代码

```
"".test t=1 size=32 value=0 args=0x20 locals=0x0
        0x0000 00000 (test.go:5)        TEXT    "".test(SB), $0-32//栈大小为32字节
        0x0000 00000 (test.go:5)        NOP
        0x0000 00000 (test.go:5)        NOP
        0x0000 00000 (test.go:5)        MOVQ    "".i+8(FP), CX//取第一个参数i
        0x0005 00005 (test.go:5)        MOVQ    "".j+16(FP), AX//取第二个参数j
        0x000a 00010 (test.go:5)        FUNCDATA        $0, gclocals·a8eabfc4a4514ed6b3b0c61e9680e440(SB)
        0x000a 00010 (test.go:5)        FUNCDATA        $1, gclocals·33cdeccccebe80329f1fdbee7f5874cb(SB)
        0x000a 00010 (test.go:6)        MOVQ    CX, BX//将i放入bx
        0x000d 00013 (test.go:6)        ADDQ    AX, CX//i+j放入cx
        0x0010 00016 (test.go:7)        SUBQ    AX, BX//i-j放入bx
						//将返回结果存入调用函数栈帧
        0x0013 00019 (test.go:8)        MOVQ    CX, "".~r2+24(FP)
						//将返回结果存入调用函数栈帧
        0x0018 00024 (test.go:8)        MOVQ    BX, "".~r3+32(FP)
        0x001d 00029 (test.go:8)        RET
```

由这个汇编代码可以看出来，在test函数内部，是通过fp+8取第一个参数，fp+16取第二个参数；然后将返回的第一个值存入fp+24,返回的第二个值存入fp+32，和我上述所说完全一致；golang函数调用过程，是通过fp+offset来实现传参和返回值，而不像C/C++都是通过寄存器实现传参和返回值；

但是，这里有个问题，我的变量都是int类型，为啥分配的都是8字节，这有待考证；

本来想通过查看main函数的栈帧来验证之前的结论，但是golang对小函数自动转为内联函数，因此你们可以自己编译出来看看，main函数内部是没有调用test函数的，而是将test函数的汇编代码直接拷贝进main函数执行了；

# golang闭包的实现

-----

之前有去看了下C++11的lambda函数的实现，其实实现原理就是仿函数；编译器在编译lambda函数时，会生成一个匿名的仿函数类，然后执行这个lambda函数时，会调用编译生成的匿名仿函数类重载函数调用方法，这个方法也就是lambda函数中定义的方法；其实golang闭包的实现和这个类似，我们通过例子来说明
```
package main

import "fmt"

func test(a int) func(i int) int {
	return func(i int) int {
		a = a + i
		return a
	}
}

func main() {
	f := test(1)
	a := f(2)
	fmt.Println(a)
	b := f(3)
	fmt.Println(b)
}
```

这个例子程序很简单，test函数传入一个整型参数a，返回一个函数类型；这个函数类型传入一个整型参数以及返回一个整型值；main函数调用test函数，返回一个闭包函数；ok，来看下test函数的汇编代码:

```
"".test t=1 size=160 value=0 args=0x10 locals=0x20
        0x0000 00000 (test.go:5)        TEXT    "".test(SB), $32-16
        0x0000 00000 (test.go:5)        MOVQ    (TLS), CX
        0x0009 00009 (test.go:5)        CMPQ    SP, 16(CX)
        0x000d 00013 (test.go:5)        JLS     142
        0x000f 00015 (test.go:5)        SUBQ    $32, SP
        0x0013 00019 (test.go:5)        FUNCDATA        $0, gclocals·8edb5632446ada37b0a930d010725cc5(SB)
        0x0013 00019 (test.go:5)        FUNCDATA        $1, gclocals·008e235a1392cc90d1ed9ad2f7e76d87(SB)
        0x0013 00019 (test.go:5)        LEAQ    type.int(SB), BX
        0x001a 00026 (test.go:5)        MOVQ    BX, (SP)
        0x001e 00030 (test.go:5)        PCDATA  $0, $0
					//生成一个int型对象，即a
        0x001e 00030 (test.go:5)        CALL    runtime.newobject(SB)
					//8(sp)即生成的a的地址，放入AX
        0x0023 00035 (test.go:5)        MOVQ    8(SP), AX
					//将a的地址存入sp+24的位置
        0x0028 00040 (test.go:5)        MOVQ    AX, "".&a+24(SP)
					//取出main函数传入的第一个参数，即a
        0x002d 00045 (test.go:5)        MOVQ    "".a+40(FP), BP
					//将a放入(AX)指向的内存，即上述新生成的int型对象
        0x0032 00050 (test.go:5)        MOVQ    BP, (AX)
        0x0035 00053 (test.go:6)        LEAQ    type.struct { F uintptr; a *int }(SB), BX
        0x003c 00060 (test.go:6)        MOVQ    BX, (SP)
        0x0040 00064 (test.go:6)        PCDATA  $0, $1
        0x0040 00064 (test.go:6)        CALL    runtime.newobject(SB)
					//8(sp)这就是上述生成的struct对象地址
        0x0045 00069 (test.go:6)        MOVQ    8(SP), AX
        0x004a 00074 (test.go:6)        NOP
					//test内部匿名函数地址存入BP
        0x004a 00074 (test.go:6)        LEAQ    "".test.func1(SB), BP
					//将匿名函数地址放入(AX)指向的地址，即给上述
					//F uintptr赋值
        0x0051 00081 (test.go:6)        MOVQ    BP, (AX)
        0x0054 00084 (test.go:6)        MOVQ    AX, "".autotmp_0001+16(SP)
        0x0059 00089 (test.go:6)        NOP	
					//将上述生成的整型对象a的地址存入BP
        0x0059 00089 (test.go:6)        MOVQ    "".&a+24(SP), BP
        0x005e 00094 (test.go:6)        CMPB    runtime.writeBarrier(SB), $0
        0x0065 00101 (test.go:6)        JNE     $0, 117
					//将a地址存入AX指向内存+8，
					//即为上述结构体a *int赋值
        0x0067 00103 (test.go:6)        MOVQ    BP, 8(AX)
					//将上述结构体的地址存入main函数栈帧中；
        0x006b 00107 (test.go:9)        MOVQ    AX, "".~r1+48(FP)
        0x0070 00112 (test.go:9)        ADDQ    $32, SP
        0x0074 00116 (test.go:9)        RET

```

之前有看到一句话，很形象地描述了闭包
> 类是有行为的数据，而闭包是有数据的行为；

也就是说闭包是有上下文的，我们以测试例子为例，通过test函数生成的闭包函数，都有各自的a，这个a就是闭包的上下文数据，而且这个a一直伴随着他的闭包函数，每调用一次，a都会发生变化；

我们分析了上述汇编代码，来看下闭包实现原理；在这个测试例子中，由于a是闭包的上下文数据，因此a必须在堆上分配，如果在栈上分配，函数结束，a也被回收了；然后会定义出一个匿名结构体:

```
type.struct { 
	F uintptr//这个就是闭包调用的函数指针 
	a *int //这就是闭包的上下文数据
}
```

接着生成一个该对象，并将之前在堆上分配的整型对象a的地址赋值给结构体中的a指针，接下来将闭包调用的func函数地址赋值给结构体中F指针；这样，每生成一个闭包函数，其实就是生成一个上述结构体对象，每个闭包对象也就有自己的数据a和调用函数F；最后将这个结构体的地址返回给main函数；

ok，来看下main函数获取闭包的过程；

```
"".main t=1 size=528 value=0 args=0x0 locals=0x88
        0x0000 00000 (test.go:12)       TEXT    "".main(SB), $136-0
        0x0000 00000 (test.go:12)       MOVQ    (TLS), CX
        0x0009 00009 (test.go:12)       LEAQ    -8(SP), AX
        0x000e 00014 (test.go:12)       CMPQ    AX, 16(CX)
        0x0012 00018 (test.go:12)       JLS     506
        0x0018 00024 (test.go:12)       SUBQ    $136, SP
        0x001f 00031 (test.go:12)       FUNCDATA        $0, gclocals·f5be5308b59e045b7c5b33ee8908cfb7(SB)
        0x001f 00031 (test.go:12)       FUNCDATA        $1, gclocals·9d868b227cedd8dd4b1bec8682560fff(SB)
       					//将参数1(f:=test(1))放入main函数栈顶
	0x001f 00031 (test.go:13)       MOVQ    $1, (SP)
        0x0027 00039 (test.go:13)       PCDATA  $0, $0
					//调用main函数生成闭包对象
        0x0027 00039 (test.go:13)       CALL    "".test(SB)
					//将闭包对象的地址放入DX
        0x002c 00044 (test.go:13)       MOVQ    8(SP), DX
       					//将参数2(a:=f(2))放入栈顶
	0x0031 00049 (test.go:14)       MOVQ    $2, (SP)
        0x0039 00057 (test.go:14)       MOVQ    DX, "".f+56(SP)
					//将闭包对象的函数指针赋值给BX
        0x003e 00062 (test.go:14)       MOVQ    (DX), BX
        0x0041 00065 (test.go:14)       PCDATA  $0, $1
					//这里调用闭包函数，并且将闭包对象的地址也传进
					//闭包函数，为了修改a嘛
        0x0041 00065 (test.go:14)       CALL    DX, BX
        0x0043 00067 (test.go:14)       MOVQ    8(SP), BX

```

很明显，main函数调用test函数获取的是闭包对象的地址，通过这个闭包对象地址找到闭包函数，然后执行这个闭包函数，并且把闭包对象的地址传进函数，这点和C++传this指针原理一样，为了修改成员变量a；

最后看下test内部的匿名函数(闭包函数实现):

```
"".test.func1 t=1 size=32 value=0 args=0x10 locals=0x0
        0x0000 00000 (test.go:6)        TEXT    "".test.func1(SB), $0-16
        0x0000 00000 (test.go:6)        NOP
        0x0000 00000 (test.go:6)        NOP
        0x0000 00000 (test.go:6)        FUNCDATA        $0, gclocals·23e8278e2b69a3a75fa59b23c49ed6ad(SB)
        0x0000 00000 (test.go:6)        FUNCDATA        $1, gclocals·33cdeccccebe80329f1fdbee7f5874cb(SB)
   					//DX是闭包对象的地址，+8即a的地址
	0x0000 00000 (test.go:6)        MOVQ    8(DX), AX
					//AX为a的地址，(AX)即为a的值
        0x0004 00004 (test.go:7)        MOVQ    (AX), BP
					//将参数i存入R8
        0x0007 00007 (test.go:7)        MOVQ    "".i+8(FP), R8
					//a+i的值存入BP
        0x000c 00012 (test.go:7)        ADDQ    R8, BP
					//将a+i存入a的地址
        0x000f 00015 (test.go:7)        MOVQ    BP, (AX)
					//将a地址最新数据存入BP
        0x0012 00018 (test.go:8)        MOVQ    (AX), BP
					//将a最新值作为返回值放入main函数栈中
        0x0015 00021 (test.go:8)        MOVQ    BP, "".~r1+16(FP)
        0x001a 00026 (test.go:8)        RET
```

闭包函数的调用过程:
1. 通过闭包对象地址获取闭包上下文数据a的地址;
2. 接着通过a的地址获取到a的值，并与参数i相加；
3. 将a+i作为最新值存入a的地址；
4. 将a最新值返回给main函数；

# 总结

----

这篇文章简单地从汇编角度分析了golang多值返回和闭包的实现；
* 多值返回主要是通过fp寄存器+offset获取参数以及存入返回值实现；
* 闭包主要是通过在编译时生成包含闭包函数和闭包上下文数据的结构体实现；

有什么不对的地方，希望各位能指出来，谢谢~







































