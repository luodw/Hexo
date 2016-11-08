title: python之HTTP模块
date: 2016-11-05 21:56:48
tags:
- python
- http
categories:
- python

---
挺久没写博客了，因为博主开始了今年另一段美好的实习经历，学习加做项目，时间已排满；很感谢今年这两段经历，让我接触了golang和python，学习不同语言，可以跳出之前学习c/c++思维的限制，学习golang和python的优秀特性以及了解在不同的场景，适用不同的语言；而之前学习linux和c/c++，也使我很快就上手golang和python;

![杭州清河坊](http://7xjnip.com1.z0.glb.clouddn.com/IMG_0361.JPG "")

我学习的习惯，除了学习如何使用，还喜欢研究源码，学习运行机制，这样用起来才会得心应手或者说，使用这些语言或框架，就和平时吃饭睡觉一样，非常自然；因为最近有接触到bottle和flask  web框架，所以想看下这两个的源码，但是这两个框架是基于python自带的http，因此就有了这篇文章；


# python http简单例子
*****
python http框架主要有server和handler组成，server主要是用于建立网络模型，例如利用epoll监听socket；handler用于处理各个就绪的socket；先来看下python http简单的使用：
```
import sys
from http.server import HTTPServer,SimpleHTTPRequestHandler

ServerClass = HTTPServer
HandlerClass = SimpleHTTPRequestHandler

if __name__ == '__main__':
    port = int(sys.argv[2])
    server_address = (sys.argv[1],port)
    httpd = ServerClass(server_address,HandlerClass)

    sa=httpd.socket.getsockname()
    print("Serving HTTP on", sa[0], "port", sa[1], "...")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nKeyboard interrupt received, exiting.")
        httpd.server_close()
        sys.exit(0)
```

运行上述例子，可以得到如下：
> python3 myhttp.py 127.0.0.1 9999

此时如果在当前文件夹新建一个index.html文件，就可以通过[http://127.0.0.1:9999/index.html](http://127.0.0.1:9999/index.html "")访问了index.html页面了。

这个例子的server类用的是HTTPServer，handler类是SimpleHTTPRequestHandler，因此当HTTPServer监听到有request到来时，就把这个request丢给SimpleHTTPRequestHandler类求处理；ok，了解这些之后，我们开始分别分析下server和handler.

# http之server
****
http模块的设计充分利用了面向对象的继承多态，因为之前有看了会tfs文件系统的代码，所以再看python http时，没那么大的压力；先给出server的继承关系
```

                               +------------------+
        +------------+         | tcpserver基类    |
        | BaseServer +-------->| 开启事件循环监听 |
        +-----+------+         | 处理客户端请求   |
              |                +------------------+
              v                +-----------------+
        +------------+         | httpserver基类  |
        | TCPServer  +-------->+  设置监听socket |
        +-----+------+         | 开启监听        |
              |                +-----------------+
              v
        +------------+
        | HTTPServer |           
        +------------+
```
继承关系如上图所示，其中BaseServer和TCPServer在文件socketserver.py，HTTPServer在http/server.py；我们先看下来BaseServer；

## BaseServer
****
因为BaseServer是所有server的基类，因此BaseServer尽可能抽象出所有server的共性，例如开启事件监听循环，这就是每个server的共性，因此这也是BaseServer主要做的使;我们来看下BaseServer主要代码部分
```
def serve_forever(self, poll_interval=0.5):
        self.__is_shut_down.clear()
        try:
            with _ServerSelector() as selector:
                selector.register(self, selectors.EVENT_READ)

                while not self.__shutdown_request:
                    ready = selector.select(poll_interval)
                    if ready:
                        self._handle_request_noblock()

                    self.service_actions()
        finally:
            self.__shutdown_request = False
            self.__is_shut_down.set()
```
代码中的selector其实就是封装了select,poll,epoll等的io多路复用，然后将服务自身监听的socket注册到io多路复用，开启事件监听，当有客户端连接时，此时会调用self.\_handle\_request\_noblock()来处理请求；接下来看下这个处理函数做了啥；
```
def _handle_request_noblock(self):
        try:
            request, client_address = self.get_request()
        except OSError:
            return
        if self.verify_request(request, client_address):
            try:
                self.process_request(request, client_address)
            except:
                self.handle_error(request, client_address)
                self.shutdown_request(request)
        else:
            self.shutdown_request(request)
```
\_handle\_request\_noblock函数是一个内部函数，首先是接收客户端连接请求，底层其实是封装了系统调用accept函数，然后验证请求，最后调用process_request来处理请求；其中get_request是属于子类的方法，因为tcp和udp接收客户端请求是不一样的(tcp有连接，udp无连接)

我们接下来再看下process_request具体做了什么；
```
def process_request(self, request, client_address):
       self.finish_request(request, client_address)
       self.shutdown_request(request)
# -------------------------------------------------
def finish_request(self, request, client_address):
        self.RequestHandlerClass(request, client_address, self)

def shutdown_request(self, request):
    self.close_request(request)
```
process_request函数先是调用了finish_request来处理一个连接，处理结束之后，调用shutdown_request函数来关闭这个连接；而finish_request函数内部实例化了一个handler类，并把客户端的socket和地址传了进去，说明，handler类在初始化结束的时候，就完成了请求处理，这个等后续分析handler时再细看；

以上就是BaseServer所做的事，这个BaseServer不能直接使用，因为有些函数还没实现，只是作为tcp/udp的抽象层；总结下：
1. 先是调用serve_forever开启事件监听；
2. 然后当有客户端请求到来时，将请求交给handler处理；

## TCPServer
****
由上述BaseServer抽象出的功能，我们可以知道TCPServer或UDPServer应该完成的功能有，初始化监听套接字，并绑定监听，最后当有客户端请求时，接收这个客户端；我们来看下代码
```
BaseServer==>
def __init__(self, server_address, RequestHandlerClass):
        """Constructor.  May be extended, do not override."""
        self.server_address = server_address
        self.RequestHandlerClass = RequestHandlerClass
        self.__is_shut_down = threading.Event()
        self.__shutdown_request = False
#--------------------------------------------------------------------------------
TCPServer==>
def __init__(self, server_address, RequestHandlerClass, bind_and_activate=True):
       BaseServer.__init__(self, server_address, RequestHandlerClass)
       self.socket = socket.socket(self.address_family,
                                   self.socket_type)
       if bind_and_activate:
           try:
               self.server_bind()
               self.server_activate()
           except:
               self.server_close()
               raise
```
TCPServer初始化时先是调用基类BaseServer的初始化函数，初始化服务器地址，handler类等，然后初始化自身的监听套接字，最后调用server_bind绑定套接字，server_activate监听套接字
```
def server_bind(self):
    if self.allow_reuse_address:
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    self.socket.bind(self.server_address)
    self.server_address = self.socket.getsockname()

def server_activate(self):
    self.socket.listen(self.request_queue_size)
```
TCPServer还实现了另一个函数，那就是接收客户端请求，
```
def get_request(self):
        return self.socket.accept()
```
之前如果有学过linux编程，那么看这些代码应该会觉得很熟悉，因为函数名和Linux提供的系统调用名一模一样，这里也不多说了；

TCPServer其实已经把基于tcp的服务器主体框架搭起来了，因此HTTPServer在继承TCPServer基础上，只是重载了server_bind函数，设置reuse_address等；

ok，这里分析下上述例子程序的开启过程；
1. httpd = ServerClass(server_address,HandlerClass)这行代码在初始化HTTPServer时，主要是调用基类TCPServer的初始化方法，初始化了监听的套接字，并绑定和监听；
2. httpd.serve_forever()这行代码调用的是基类BaseServer的serve_forever方法，开启监听循环，等待客户端的连接；

如果有看过redis或者一些后台组件的源码，对这种并发模型应该很熟悉；ok，分析了server之后，接下来看下handler是如何处理客户端请求的。

# http之handler
****
handler类主要分析tcp层的handler和http应用层的handler,tcp层的handler是不能使用的，因为tcp层只负责传输字节，但是并不知对于接收到的字节要如何解析，如何处理等；因此应用层协议如该要使用TCP协议，必须继承TCP handler，然后实现handle函数即可;例如，http层的handler实现handle函数，解析http协议，处理业务请求以及结果返回给客户端；先来看下tcp层的handler

## tcp层handler
****
tcp层handler主要有BaseRequestHandler和StreamRequestHandler(都在socketserver.py文件)，先看下BaseRequestHandler代码，
```
class BaseRequestHandler:
    def __init__(self, request, client_address, server):
        self.request = request
        self.client_address = client_address
        self.server = server
        self.setup()
        try:
            self.handle()
        finally:
            self.finish()

    def setup(self):
        pass

    def handle(self):
        pass

    def finish(self):
        pass

```
之前在看server时，知道处理客户端请求就是在handler类的初始化函数中完成；由这个基类初始化函数，我们知道处理请求大概经历三个过程：
1. setup对客户端的socket做一些设置；
2. handle真正处理请求的函数；
3. finish关闭socket读写请求；

这个BaseRequestHandler是handler top level 基类，只是抽象出handler整体框架，并没有实际的处理；我们看下tcp handler，
```
class StreamRequestHandler(BaseRequestHandler):
    timeout = None
    disable_nagle_algorithm = False

    def setup(self):
        self.connection = self.request
        if self.timeout is not None:
            self.connection.settimeout(self.timeout)
        if self.disable_nagle_algorithm:
            self.connection.setsockopt(socket.IPPROTO_TCP,
                                       socket.TCP_NODELAY, True)
        self.rfile = self.connection.makefile('rb', self.rbufsize)
        self.wfile = self.connection.makefile('wb', self.wbufsize)

    def finish(self):
        if not self.wfile.closed:
            try:
                self.wfile.flush()
            except socket.error:
                pass
        self.wfile.close()
        self.rfile.close()
```
tcp handler实现了setup和finish函数，setup函数设置超时时间，开启nagle算法以及设置socket读写缓存；finish函数关闭socket读写；

由上述两个tcp层的handler可知，要实现一个基于http的服务器handler，只需要继承StreamRequestHandler类，并实现handle函数即可；因此这也是http层handler主要做的事；

## http层handler
****
由之前tcp层handler的介绍，我们知道http层handler在继承tcp层handler基础上，主要是实现了handle函数处理客户端的请求；还是直接看代码吧；
```
def handle(self):
        self.close_connection = True

        self.handle_one_request()
        while not self.close_connection:
            self.handle_one_request()
```
这就是BaseHTTPRequestHandler的handle函数，在handle函数会调用handle_one_request函数处理一次请求；默认情况下是短链接，因此在执行了一次请求之后，就不会进入while循环在同一个连接上处理下一个请求，但是在handle_one_request函数内部会进行判断，如果请求头中的connection为keep_alive或者http版本大于等于1.1，则可以保持长链接；接下来看下handle_one_request函数是如何处理；
```
def handle_one_request(self):
    try:
        self.raw_requestline = self.rfile.readline(65537)
        if len(self.raw_requestline) > 65536:
            self.requestline = ''
            self.request_version = ''
            self.command = ''
            self.send_error(HTTPStatus.REQUEST_URI_TOO_LONG)
            return
        if not self.raw_requestline:
            self.close_connection = True
            return
        if not self.parse_request():
            return
        mname = 'do_' + self.command
        if not hasattr(self, mname):
            self.send_error(
                HTTPStatus.NOT_IMPLEMENTED,
                "Unsupported method (%r)" % self.command)
            return
        method = getattr(self, mname)
        method()
        self.wfile.flush()
    except socket.timeout as e:
        self.log_error("Request timed out: %r", e)
        self.close_connection = True
        return
```
这个handle_one_request执行过程如下：
1. 先是调用parse_request解析客户端http请求内容
2. 通过"do_"+command构造出请求所对于的函数method
3. 调用method函数，处理业务并将response返回给客户端

这个BaseHTTPRequestHandler是http handler基类，因此也是无法直接使用，因为它没有定义请求处理函数，即method函数；好在python为我们提供了一个简单的SimpleHTTPRequestHandler，该类继承了BaseHTTPRequestHandler，并实现了请求函数；我们看下get函数：
```
# SimpleHTTPRequestHandler
# ---------------------------------------------
def do_GET(self):
      """Serve a GET request."""
      f = self.send_head()
      if f:
          try:
              self.copyfile(f, self.wfile)
          finally:
              f.close()

```
这个get函数先是调用do_GET函数给客户端返回response头部，并返回请求的文件，最后调用copyfile函数将请求文件通过连接返回给客户端；

以上就是http模块最基础的内容，最后，总结下例子程序handler部分：
1. server把请求传给SimpleHTTPRequestHandler初始化函数；
2. SimpleHTTPRequestHandler在初始化部分，对这个客户端connection进行一些设置；
3. 接着调用handle函数处理请求；
4. 在handle函数接着调用handle_one_request处理请求；
5. 在handle_one_request函数内部，解析请求，找到请求处理函数；
6. 我之前的访问属于get访问，因此直接调用do_GET函数将index.html文件返回给客户端；

python http模块到此已经分析结束；不知道大家有没发现，python自带的http模块使用起来不是很方便，因为它是通过请求方法来调用请求函数，这样当同一方法调用次数非常多时，例如get和post方法，会导致这个请求函数异常庞大，代码不好编写，各种情况判断；当然SimpleHTTPRequestHandler只是python提供的一个简单例子而已；

当然，python官方提供了针对http更好用的框架，即wsgi server和wsgi application；接下来文章先分析python自带的wsgiref模块以及bottle，后面再分析flask;
