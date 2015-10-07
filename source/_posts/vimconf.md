title: vim安装vundle和powerline
date: 2015-10-05 20:52:14
tags:
- Configure
- Vim
categories:
- Configure
- Vim

---

上次写了一篇关于在vim下配置markdown语法高亮配置,这篇文章主要是讲如何安装Vundle和Powerline插件,这篇文章实为markdown配置高亮之前的配置,相对较简单.
* Vundle主要是vim用于管理插件的插件,有了它之后,安装,更新插件将变的非常简单.
* Powerline主要是用于打造华丽状态栏的插件.

### 安装Vundle

1. 首先创建目录~/.vim/bundle/vundle,系统默认是没有这个目录的,可运行如下命令:
```
mkdir -p ~/.vim/bundle/vundle
```

2. 接着从github上下载插件
```
git clone http://github.com/gmarik/vundle.git ~/.vim/bundle/vundle
```

3. 配置.vimrc文件

系统默认也是没有该文件所以先创建.vimrc文件,然后访问网页<https://github.com/VundleVim/Vundle.vim>,查找到配置文件,但是该配置文件是教导如何在.vimrc配置安装插件,所以把其他Plugin都删除了,只留Vundle即可.
如下所以:
```
set nocompatible              " be iMproved, required
filetype off                  " required

" set the runtime path to include Vundle and initialize
set rtp+=~/.vim/bundle/Vundle.vim
call vundle#begin()
" alternatively, pass a path where Vundle should install plugins
"call vundle#begin('~/some/path/here')

" let Vundle manage Vundle, required
Plugin 'VundleVim/Vundle.vim

" All of your Plugins must be added before the following line
call vundle#end()            " required
filetype plugin indent on    " required
" To ignore plugin indent changes, instead use:
"filetype plugin on
"
" Brief help
" :PluginList       - lists configured plugins
" :PluginInstall    - installs plugins; append `!` to update or just :PluginUpdate
" :PluginSearch foo - searches for foo; append `!` to refresh local cache
" :PluginClean      - confirms removal of unused plugins; append `!` to auto-approve removal
"
" see :h vundle for more details or wiki for FAQ
" Put your non-Plugin stuff after this line

```
4. 运行vim,在普通模式下输入:PluginInstall,即可安装vundle插件.

vundle下插件可以是plugin抑或bundle,所以在配置文件中将plugin改成bundle,然后在vim时输入BundleInstall也是可以安装插件的.

补充下配置文件几个说明:
1. set nocompatible 不要使用vi的键盘模式,而是使用vim自己的.
2. filetype on 检查文件类型.
3. filetype plugin on 载入文件类型插件.
4. filetype indent on 为特定文件类型载入相关缩进文件.

Bundle几个常用命令:
1. 更新插件 :BundleUpdate
2. 清除不再使用的插件 :BundleClean
3. 列出所有的插件 :BundleList
4. 查找插件 :BundleSearch

### 安装Powerline插件

平常使用vim时,大家可能习惯状态栏了,不知道原来状态栏是可以打扮的那么华丽.
系统默认状态栏为:
![系统默认的状态栏](http://7xjnip.com1.z0.glb.clouddn.com/选区_001.png "")
使用Powerline插件之后:
![华丽的状态栏](http://7xjnip.com1.z0.glb.clouddn.com/选区_002.png "")
状态栏不仅可以显示彩色,还可以根据不同的状态进行颜色的转换.

1. 安装Powerline插件
```
Bundle 'git@github.com:Lokaltog/vim-powerline.git'
```
然后运行vim,输入:BundleInstall即可安装Powerline插件.

2. 配置.vimrc文件
在.vimrc文件中输入以下设置
```
set laststatus=2
set t_Co=256
let g:Powerline_symbols= 'unicode'
set encoding=utf8
```

就这么简单几步,就将vim的状态栏打造为华丽的状态栏了.






