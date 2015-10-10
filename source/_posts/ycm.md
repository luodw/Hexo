title: vim大杀器YouCompleteMe
date: 2015-10-06 10:51:00
tags:
- Configure
- Vim
categories:
- Configure 
- Vim 
toc: true

---

之前看了知乎上一篇文章，如何把vim打造成IDE，看了之后，真是大开眼界，突然觉得自己一点都不懂vim了，要成为一名称职的IDE，首先智能补全是要有的，那YouCompleteMe就派上用场了．

YouCompleteMe是在clang/llvm基础上构建起来的．它整合了多种插件：
* clang_complete
* AutoComplPop
* Supertab
* neocomplcache
* Syntastic(类似功能,仅仅针对c/c++/obj-c代码)

支持语言有：C,C++,obj-c,C#,python.

### ycm安装
在vimrc中添加代码
```
Bundle 'Valloric/YouCompleteMe'
```
保存退出，打开vim，在正常模式下输入
```
:BundleInstall
```
等待vundle将YouCompleteMe安装完成．时间较长，请耐心等待．

然后编译安装
```
cd ~/.vim/bundle/YouCompleteMe
./install.py --clang-completer
```

安装结束之后，打开vim，如果没有提示报错或提示，则说明安装成功了．

### 配置ycm:
ycm安装成功后，还不能代码补全提示，需要配置.ycm_extra_conf.py．之前我都是直接用网上教程的配置文件，结果都不能很好的智能提示，最好的方法还是用ycm自带的.ycm_extra_conf.py文件．
```
cp third_party/ycmd/examples/.ycm_extra_conf.py ~/
```
此时在home目录下就有.ycm_extra_conf.py文件．顺带提一下，ycm会从项目的文件开始，一步一步往上查找配置文件，如果没找到，就用.vimrc里的指明的全局文件．

配置.vimrc文件．在Bundle 'Valloric/YouCompleteMe'这句话之后添加
```
let g:ycm_global_ycm_extra_conf='~/.ycm_extra_conf.py'
```
接着打开一个c或c++文件，即可看到代码提示了．但是还不是很智能，所以待我深入学习之
后，在补充．

> 补充一

按上述的配置还不能对C++智能补充，还需要在.ycm_extra_conf.py文件中的flags中添加C++头文件索引．
```
'-isystem',
'/usr/include/c++/4.8.2'
```
cpp文件可以智能提示补充了．

> 补充二　

在使用ycm时，但代码出现错误时，我们可以在普通模式下输入
```
:YcmDiags
```
然后会出现Quickfix窗口，里面罗列了代码的错误．这时当光标指向错误列表某一个时，按回车键，即可跳转到错误处．

问题是跳转过去之后，怎么定位下一个错误了？quickfix帮助文档是说用ln，网上教程是cn但是，我这都不行，只能用鼠标点了．

那么怎么设置vim支持鼠标操作了．即：
```
:set mouse=a　即可
```
说明下：

'mouse' 选项的字符决定 Vim 在什么场合下会使用鼠标:
+   n       普通模式
+   v       可视模式
+   i       插入模式
+   c       命令行模式
+   h       在帮助文件里，以上所有的模式
+   a       以上所有的模式
+   r       跳过 |hit-enter| 提示
+   A       在可视模式下自动选择

缺省情况下'mouse'为空，即不适用鼠标．set mouse=a 等价与set mouse=nvich表示任何场合都用鼠标．




