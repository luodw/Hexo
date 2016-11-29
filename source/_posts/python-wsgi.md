title: python之wsgiref模块
date: 2016-11-12 19:34:43
tags:
- python
- wsgiref
- wsgi
categories:
- python
toc: true

---

之前写了python的http原生模块，分析了原生http模块的实现原理以及不足;而实际使用过程中，用的比较多的是python的wsgi server和wsgi application; 关于什么是wsgi协议，简单的来说，就是wsgi server调用wsgi application接口的约定，即当有个请求到达wsgi server时，wsgi server通过调用wsgi application提供的接口来处理这个请求;其实，看过python wsgiref模块，也就能理解什么是wsgi模块。

![圆明园遗址(时光相册制作)](http://7xjnip.com1.z0.glb.clouddn.com/ldw-1970767937.jpg "")

现在比较流行的wsgi application有bottle, flask,django等，比较流行的wsgi server有werkzeug,gunicorn,gevent等;今天这篇文章主要分析下python自带的wsgiref模块，以这个为模板，可以理解下wsgi协议；

这篇文章主要有以下两部分：
1. wsgiref简单示例
2. wsgiref实现原理
3. 原理解释示例程序
4. 总结

## wsgiref简单示例

----

这里先给出wsgiref模块的简单示例，有个感性的认识，后续在分析实现原理；代码如下:
```
from wsgiref.simple_server import make_server

def application(environ, start_response):
    start_response('200 OK', [('Content-Type', 'text/html')])
    return [b'<h1>Hello, web!</h1>']

if __name__ == '__main__':
    httpd = make_server('', 9999, application)
    print("Serving HTTP on port 9999...")
    httpd.serve_forever()
```
这个示例程序很简单，创建一个httpd服务器，并监听9999端口，当有客户端请求时，在浏览器显示Hello, web字符串；

上述例子中的application就是wsgiref application，当然也可以一个类，平时常见的也是类，例如flask,bottle等，这些类实现__call__方法，并且该方法参数为environ, start_response即可，environ为一个字典，保存系统变量以及请求相关属性，例如请求路径，请求参数，请求方法等等；start_response为函数，设置response的状态码和header，然后application函数的返回值为response的body；因此上述例子程序，设置response状态码为200，表示请求成功，在headers添加返回数据类型为text/html，以及返回的response body为[b'<h1>Hello, web!</h1>']

## wsgiref实现原理

----

wsgiref模块也是由server和handler组成，server用于监听端口，接收请求；handler用于处理请求；先来看下server
```
class WSGIServer(HTTPServer):

    """BaseHTTPServer that implements the Python WSGI protocol"""

    application = None

    def server_bind(self):
        """Override server_bind to store the server name."""
        HTTPServer.server_bind(self)
        self.setup_environ()

    def setup_environ(self):
        # Set up base environment
        env = self.base_environ = {}
        env['SERVER_NAME'] = self.server_name
        env['GATEWAY_INTERFACE'] = 'CGI/1.1'
        env['SERVER_PORT'] = str(self.server_port)
        env['REMOTE_HOST']=''
        env['CONTENT_LENGTH']=''
        env['SCRIPT_NAME'] = ''

    def get_app(self):
        return self.application

    def set_app(self,application):
        self.application = application
```
WSGIServer继承自HTTPServer，并重载来server\_bind方法，同时提供注册和获取server application的接口；其中set\_environ函数设置了该web应用程序的环境变量，例如服务器名称，服务器端口等等；

ok，了解来WSGIServer之后，来看下handler是如何实现；WSGIRequestHandler类继承自BaseHTTPRequestHandler，并且重载handle方法，即处理请求的方法；

我们来看下WSGIRequestHandler的handle方法：
```
def handle(self):
        """Handle a single HTTP request"""
	# 读取客户端发送的请求行
        self.raw_requestline = self.rfile.readline(65537)
        if len(self.raw_requestline) > 65536:
            self.requestline = ''
            self.request_version = ''
            self.command = ''
            self.send_error(414)
            return
	# 解析客户端的请求行和请求头
        if not self.parse_request(): # An error code has been sent, just exit
            return

        # Avoid passing the raw file object wfile, which can do partial
        # writes (Issue 24291)
        stdout = BufferedWriter(self.wfile)
        try:
	　　# 用于调用wsgi application的handler
            handler = ServerHandler(
                self.rfile, stdout, self.get_stderr(), self.get_environ()
            )
            handler.request_handler = self      # backpointer for logging
            handler.run(self.server.get_app())
        finally:
            stdout.detach()

```
handle函数首先解析请求行和请求头，然后实例化ServerHandler类，用该类来调用wsgi application；

ServerHandler类接受参数为socket读端，输出端，错误输出端以及一个包含请求信息的字典；self.get_environ()函数返回包含web应用程序的环境变量和请求的环境变量的字典；

最后再来看下ServerHandler;ServerHandler继承自SimpleHandler,SimpleHandler继承自BaseHandler；我们直接看下ServerHandler的run方法；
```
def run(self, application):
	try:
            self.setup_environ()
            self.result = application(self.environ, self.start_response)
            self.finish_response()
        except:
            try:
                self.handle_error()
            except:
                # If we get an error handling an error, just give up already!
                self.close()
                raise   # ...and let the actual server figure it out.

```
1. self.setup\_environ函数用于建立每次请求的相关信息，并存储在self.environ；
2. self.start\_response为该handler函数，用于设置response的状态码和header；
3. self.result为response body；
4. self.finish\_response用于将response返回给客户端；

这个handler类就不一一分析了，详情可以看wsgiref/handlers.py模块；

## 原理解释示例程序

---

了解了wsgiref模块之后．从原理层面来解释上述例子程序；再次粘帖程序代码如下:
```
from wsgiref.simple_server import make_server

def application(environ, start_response):
    start_response('200 OK', [('Content-Type', 'text/html')])
    return [b'<h1>Hello, web!</h1>']

if __name__ == '__main__':
    httpd = make_server('', 9999, application)
    print("Serving HTTP on port 9999...")
    httpd.serve_forever()
```
示例程序先是调用wsgiref模块的make_server方法，可以看下该方法如下：
```
def make_server(
    host, port, app, server_class=WSGIServer, handler_class=WSGIRequestHandler
):
    """Create a new WSGI server listening on `host` and `port` for `app`"""
    server = server_class((host, port), handler_class)
    server.set_app(app)
    return server
```
可以看到wsgiref默认的server_class为WSGIServer，handler_class为WSGIRequestHandler；先是实例化一个WSGIServer，然后注册application，最后返回该server实例；

在示例程序中，最后调用httpd.server_forever()方法开启事件监听循环；

当某个请求到来之后，先是实例化一个WSGIRequestHandler，并在该WSGIRequestHandler的handle方法内部解析请求参数，以及实例化一个ServerHandler，以及调用ServerHandler的run方法来处理请求；

在ServerHandler的run方法内部先是建立环境变量字典environ，然后调用wsgi application设置resopnse的状态码和headers，以及返回response body；最后调用finish_response()方法将response返回给客户端；

上述即为一次请求全过程；

## 总结

----

这篇文章分析了python的wsgiref模块，解释了wsgiref模块一次请求的过程；当然实际应用中，wsgi application可不是示例程序中那么简单的返回一个字符串，因为一个web应用程序需要根据路由来调用相应的view函数以及一些其他特性，这等到分析bottle时再来分析；

wsgi server和wsgi application分离的设计，使python web的开发非常灵活，在部署python web应用程序时，可以根据性能的需求，选择合适的wsgi server；例如flask自带的wsgi server不适合在正式工业环境中使用，因此flask经常的搭配是nginx+gunicorn+flask，而不是用自带的werkzeug；

不同的wsgi server，区别主要是在并发模型的选择上，有单线程，多进程，多线程，协程；而wsgi application主要功能相近，无非就是根据请求路由，执行相应的view函数，当然有一些特性上的不同；

今天就先写到这，下篇文章分析bottle的实现；





































