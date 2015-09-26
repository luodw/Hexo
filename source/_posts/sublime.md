title: Sublime3支持C++智能提示
date: 2015-09-25 22:05:58
tags:
- Configure
categories:
- Configure
toc: true
---

sublime3是一款非常好的编辑器,用它来敲写代码是一个非常棒的利器. SublimeClang是C++自动补全插件,功能强大.

首先要安装Package Control,一个用于管理插件的好工具,可以用于安装,删除,禁用相应的插件.安装如下:

```
cd ~/.config/sublime-text-3/Packages/
git clone https://github.com/wbond/package_control_channel.git  Package\ Control
```

重新启动SublimeText 3，然后使用快捷键Ctrl + Shift + p，在弹出的输入框中输入Package Control则可以看到Install Package的选项，选择它后一会儿（看左下角的状态）会弹出插件查询及安装窗口，输入想用的插件，选中回车即可。

SublimeClang是Sublime Text中唯一的C/C++自动补全插件，功能强大，自带语法检查功能，不过最近作者已经停止更新了，目前只能在Sublime Text 2的Package Control中可以找到并自动安装，在SublimeText 3中只能手动通过源码安装，其代码线在https://github.com/quarnster/SublimeClang中

```
安装相关软件
sudo apt-get install cmake build-essential clang git
cd ~/.config/sublime-text-3/Packages
git clone --recursive https://github.com/quarnster/SublimeClang SublimeClang
cd SublimeClang
cp /usr/lib/x86_64-linux-gnu/libclang-3.4.so.1 internals/libclang.so   #这一步很重要，如果你的clang库不是3.4版本的话，请将对应版本的库拷贝到internals中
cd src
mkdir build
cd build
cmake ..
make
```

一切成功的话将会在SublimeClang/internals目录中生成libcache.so库文件。重启Sublime Text，然后按快捷键Ctrl + `(Esc下面那个键)打开自带的控制输出，看看有没有错误，如果没有错误就说明一切OK了

>摘自Cynric 的博客 <http://blog.csdn.net/cywosp/article/details/32721011>


> Written with [StackEdit](https://stackedit.io/).

