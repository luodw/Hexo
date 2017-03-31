title: Lua原来这么好用
date: 2017-03-24 20:34:22
tags:
- lua
categories:
- lua

toc: true

---

【版权声明】博客内容由罗道文的私房菜拥有版权，允许转载，但请标明原文链接[http://luodw.cc/2017/03/24/lua/#more](http://luodw.cc/2017/03/24/lua/#more "")！

今天这篇文章就随意谈谈lua。最近在看nginx+lua，刚好学了lua，就被这门语言的简练给吸引了。lua语言可以大大减轻一个人的心智负担，除了变量，操作符，语句以及函数这些最基础的语言功能外，剩下最重要的就是数据结构table（数组本质上也是table的特例）了。不用去记那么多的语法以及黑魔法，简直大快人心。

我现在对Lua使用感兴趣部分就是nginx+lua和redis内嵌lua；特别是前者，nginx+lua+redis构建高性能应用。lua+nginx可以使nginx不需要重新编译的情况下添加功能，特别是，如果只是修改lua文件，nginx都不需要重新加载配置文件，极大便利了nginx开发；而redis内嵌lua，让redis服务器有了计算能力，而且减小带宽传输（多个命令）以及原子执行多个命令达到cas效果。

下面就说说最近的一些内容和心得，主要以下三部分：
1. 通过lua脚本操作redis；
2. nginx+lua示例；
3. lua面向对象实现；
4. 总结；

# 通过lua脚本操作redis

----

之前在学习redis以及看源码时，由于不懂lua，所以redis内嵌Lua模块就跳过去了，如今学了Lua，因此想把这块知识补上。redis对Lua的支持，主要有以下以下７个命令，
1. EVAL
2. EVALSHA
3. SCRIPT DEBUG
4. SCRIPT EXISTS
5. SCRIPT FLUSH
6. SCRIPT KILL
7. SCRIPT LOAD
具体这些命令怎么使用，以及实现原理如何，可以看链接[Lua脚本-Redis设计与实现](http://redisbook.readthedocs.io/en/latest/feature/scripting.html "")和[redis官网](https://redis.io/commands/eval "")。这里主要介绍下EVAL命令。

EVAL命令格式为
> EVAL script numkeys key [key ...] arg [arg ...]

这里的
1. script即为lua脚本或lua脚本文件;
2. key一般指lua脚本操作的键，在lua脚本文件中，通过KEYS[i]获取;
3. arg指外部传递给lua脚本的参数，可以通过ARGV[i]获取；

下面通过两个简单的示例展示eval命令的用法。首先是脚本语句，来自redis官网，如下
```
127.0.0.1:6379>  eval "return {KEYS[1],KEYS[2],ARGV[1],ARGV[2]}" 2 key1 key2 first second
1) "key1"
2) "key2"
3) "first"
4) "second"
```
这个示例中lua脚本为一个return语句，返回了lua一个数组，这个数组四个元素分别是通过外部传入lua脚本。因为redis内嵌了Lua虚拟机，因此redis接收到这个lua脚本之后，然后交给lua虚拟机执行。当lua虚拟机执行结束，即将执行结果返回给redis，redis将结果按自己的协议转换为返回给客户端的回复，最后再通过TCP将回复发回给客户端。

通过这个例子也可以看出，在lua脚本中可以通过KEYS[i]来获取外部传入的键值，通过ARGV[i]来获取外部传入的参数。

下面给出一个复杂点的lua脚本，在给出脚本之前，先看下redis中有哪些需要的数据
```shell
127.0.0.1:6379> zrange people 0 3
1) "jom"
2) "lily"
3) "tom"
127.0.0.1:6379> hgetall jom
1) "sex"
2) "boy"
3) "age"
4) "12"
127.0.0.1:6379> hgetall lily
1) "age"
2) "15"
3) "sex"
4) "girl"
127.0.0.1:6379> hgetall tom
1) "sex"
2) "boy"
3) "girl"
4) "13"
```

下面lua脚本的作用就是通过一次网络请求获取'jom'，'lily'，'tom'三个人的个人信息
```lua
--[[
--Keys[1] is the key
--argv[1] is the offset
--argv[2] is the limit
--]]

-- 获取外部传入的命令
local key,offset,limit = KEYS[1], ARGV[1], ARGV[2]
-- 通过ZRANGE获取键为key的有序集合元素，偏移量为offset，个数为limit，即所有人名字
local names = redis.call('ZRANGE', key, offset, limit)
-- infos存储所有个人信息
local infos = {}
-- 遍历所有名字
for i=1,#names do
	local ck = names[i]
    -- 通过HGETALL命令获取每个人的个人信息
	local info = redis.call('HGETALL',ck)
    -- 并且在个人信息中插入姓名
	table.insert(info,'name')
	table.insert(info,names[i])

    -- 插入infos中
	infos[i] = info
end
-- 将结果返回给redis
return infos
```

在命令行上执行eval命令，即可以得到结果，如下：
```shell
$ ../redis/src/redis-cli --eval redlua.lua people , 0 2
1) 1) "sex"
   2) "boy"
   3) "age"
   4) "12"
   5) "name"
   6) "jom"
2) 1) "age"
   2) "15"
   3) "sex"
   4) "girl"
   5) "name"
   6) "lily"
3) 1) "sex"
   2) "boy"
   3) "girl"
   4) "13"
   5) "name"
   6) "tom"
```
试想，如果没有使用lua脚本，那么上述功能需要在应用程序中先发送ZRANGE命令，获取所有姓名；获取到所有姓名之后，在遍历所有姓名，针对每个姓名访问redis获取给人信息，至少四次网络IO。而管道在这种场景上也派不上用场。由此可知，lua脚本在这种场景下提高redis性能是有多大的帮助了。

> 需要特别注意的是people（键）后面的逗号左右都要留空格，不然会报错！

# ngx+lua示例

----

ngx+lua是我最近非常感兴趣的一门技术，因为在带来高性能的同时，并没有提高编程的复杂性。如果是用c语言开发nginx第三方模块，需要了解nginx内部的数据结构以及接口，难度和心智上都有挑战。本小节也是通过简单的ngx+lua示例来展示在lua是如何在nginx中使用的。

开发环境可以通过[极客学院教程](http://wiki.jikexueyuan.com/project/nginx-lua/development-environment.html "")安装。即安装OpenResty框架。安装的目录在/usr/servers，测试目录在/usr/example。

第一个示例展示如何获在lua脚本中获取http请求所有信息，这个示例来自[开涛的博客](http://jinnianshilongnian.iteye.com/blog/2186448 "")，可以很好理解在lua中如何获取nginx请求信息。在example.conf中添加如下路径映射
```shell
 location ~/lua_test/(\d+)/(\d+)$ {
    set $a $1;
    set $b $host;
    default_type 'text/html';
    lua_code_cache on;
    content_by_lua_file /usr/example/lua/lua_test.lua;
 }
```

然后在/usr/example/lua/文件下新建lua_test.lua文件，复制如下代码
```lua
-- nginx变量
local var = ngx.var
ngx.say("ngx.var.a :",var.a,"<br/>")
ngx.say("ngx.var.b :",var.b,"<br/>")
ngx.say("ngx.var[2] :",var[2],"<br/>")

-- 请求头
local headers = ngx.req.get_headers()
ngx.say("headers begin", "<br/>")
ngx.say("Host : ", headers["Host"], "<br/>")
ngx.say("user-agent : ", headers["user-agent"], "<br/>")
for k,v in pairs(headers) do
    if type(v) == "table" then
                ngx.say(k, " : ", table.concat(v, ","), "<br/>")
        else
                        ngx.say(k, " : ", v, "<br/>")
        end
end

ngx.say("headers end", "<br/>")
ngx.say("<br/>")

--get请求uri参数  
ngx.say("uri args begin", "<br/>")
local uri_args = ngx.req.get_uri_args()

for k,v in pairs(uri_args) do
        if type(v) == "table" then
                ngx_say(k, " : ", table.concat(v, ". "),"<br/>")
        else
                ngx.say(k, ": ", v, "<br/>")
        end
end

--post请求参数  
ngx.req.read_body()
ngx.say("post args begin", "<br/>")
local post_args = ngx.req.get_post_args()
for k, v in pairs(post_args) do
    if type(v) == "table" then
                ngx.say(k, " : ", table.concat(v, ", "), "<br/>")
        else
                ngx.say(k, ": ", v, "<br/>")
        end
end

ngx.say("post args end", "<br/>")
ngx.say("<br/>")
--请求的http协议版本  
ngx.say("ngx.req.http_version : ", ngx.req.http_version(), "<br/>")
--请求方法  
ngx.say("ngx.req.get_method : ", ngx.req.get_method(), "<br/>")
--原始的请求头内容  
ngx.say("ngx.req.raw_header : ",  ngx.req.raw_header(), "<br/>")
--请求的body内容体  
ngx.say("ngx.req.get_body_data() : ", ngx.req.get_body_data(), "<br/>")
ngx.say("<br/>")
```
由代码可以看出，lua脚本中主要信息来自于ngx.var和ngx.req这两个属性。在执行程序之前，先nginx需要先reload一次，最后我们就可以通过curl命令来访问nginx
```shell
$curl -XPOST -d 'name=json&age=26' 'http://127.0.0.1:80/lua_test/1/2?token=ds43klk54fd'
ngx.var.a :1<br/>
ngx.var.b :127.0.0.1<br/>
ngx.var[2] :2<br/>
headers begin<br/>
Host : 127.0.0.1<br/>
user-agent : curl/7.35.0<br/>
host : 127.0.0.1<br/>
content-type : application/x-www-form-urlencoded<br/>
accept : */*<br/>
content-length : 16<br/>
user-agent : curl/7.35.0<br/>
headers end<br/>
<br/>
uri args begin<br/>
token: ds43klk54fd<br/>
post args begin<br/>
age: 26<br/>
name: json<br/>
post args end<br/>
<br/>
ngx.req.http_version : 1.1<br/>
ngx.req.get_method : POST<br/>
ngx.req.raw_header : POST /lua_test/1/2?token=ds43klk54fd HTTP/1.1
User-Agent: curl/7.35.0
Host: 127.0.0.1
Accept: */*
Content-Length: 16
Content-Type: application/x-www-form-urlencoded

<br/>
ngx.req.get_body_data() : name=json&age=26<br/>
<br/>
```
通过代码和结果一一比对，可以看出已经正确获取请求信息。我觉得这是一个很好的入门示例，因为处理http请求，获取http请求头信息是非常有必要的，而上述例子则展示接口信息。

下面另一个示例是展示ngx+lua存取redis。同样在example.conf添加路径映射
```
 location ~/redis_test/(\d+)$ {
        default_type 'text/html';
        charset utf-8;
        lua_code_cache on;
        content_by_lua_file /usr/example/lua/redis.lua;
}
```

然后在/usr/example/lua/文件夹下新建redis.lua，复制如下代码:
```lua
local json = require("cjson")
local redis = require("resty.redis")

local red = redis:new()
red:set_timeout(1000)

local ip = "127.0.0.1"
local port = 6379

local ok, err = red:connect(ip, port)
if not ok then
        ngx.say("connect to redis error : ", err)
        return ngx.exit(500)
end


local id = ngx.var[1]
local value = "value-"..id

red:set(id,value)

local resp, err = red:get(id)
if not resp then
        ngx.say("get from redis error : ", err)
        return ngx.exit(500)
end

red:close()

ngx.say(json.encode({content=resp}))
```

OpenResty将常用的lua包都已经打包好，包括redis客户端，memcache客户端，mysql客户端以及cjson等等，非常方便ngx+lua的开发。在执行程序之前，先reload一次配置文件，执行结果如下：
```shell
$ curl http://127.0.0.1:80/redis_test/1
{"content":"value-1"}
$ curl http://127.0.0.1:80/redis_test/2
{"content":"value-2"}
$ curl http://127.0.0.1:80/redis_test/3
{"content":"value-3"}
```
最后可以通过redis-cli客户端验证上述三个键值对是否插入成功。由这个例子可以展开讨论，如下
1. 因为OpenResty提供了redis，mysql以及模板渲染，因此利用ngx+lua可以直接部署一个小型网站；
2. 可以在nginx本地搭一个redis缓存；当数据请求时，先访问本地的redis缓存，如果redis缓存需要的数据，直接直接在nginx层返回；如果redis没有缓存需要的数据，则转向web服务器。这样可以减轻后端服务器和数据库的压力，以及缩短请求时间。

# lua面向对象实现

----

lua没有提供面像对象的实现，但是可以通过table来模拟。所以可知table在lua中是多么核心的数据结构。这里，我用redis客户端来说明lua是如何模拟面像对象的实现。
```lua
----引入table.new函数，兼容版本恩体
local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
----如果还没有table.new接口，则自定义一个函数，返回一个空表格
    new_tab = function (narr, nrec) return {} end
end
-----------------------------------------------------
--新建一个表格
 local _M = new_tab(0, 155)
 _M._VERSION = '0.24'
-----------------------------------------------------
local mt = { __index = _M }
function _M.new(self)
    local sock, err = tcp()
    if not sock then
        return nil, err
    end
    --设置返回表的元表
    return setmetatable({ sock = sock }, mt)
end
```

上述new方法即相当于类的构造函数，因此，我们可以通过如下方式新建一个对象
```lua
-----此时require返回的redis即为模块中的_M
local redis = require("resty.redis")
local red = redis:new()
```
通过redis:new()方法返回一个{sock=sock}表格，然后设置这个表格的元表为resty.redis模块中的_M表格；__index元表格的意思就是当在red中访问一个不存在的属性时，则可以到元表中查询；因此当red调用下述函数时:
```lua
red:connect('127.0.0.1',9999)
--------------------------------------------------
function _M.connect(self, ...)
----如果是red调用改方法，则self即为red
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    self.subscribed = nil

    return sock:connect(...)
end
```
因为red中并不存在connect方法，因此red到它的\_M中查找connect方法，并执行；其实\_M和red在lua中是两个不同的对象，就是因为red的元表为\_M，因此可以把\_M当作是对象red的模板，也就是类的概念。

# 总结

-----

本文主要介绍了lua在redis和nginx的应用，以及lua面向对象的实现。多了解一些编程语言，可以更好对编程语言的理解。后面还是深入再看看ngx+lua的开发。