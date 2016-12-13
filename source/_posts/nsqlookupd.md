title: NSQ源码分析之nsqlookupd
date: 2016-12-13 10:58:30
tags:
- nsq
- nsqlookupd
categories:
- nsq

toc: true

---

上篇文章介绍了NSQ整体概述以及拓扑结构；这篇文章开始分析下NSQ源码；NSQ主要由三个部分nsqd,nsqlookupd,nsqadmin以及一些工具组成，我们从简单的nsqlookupd开始分析源码；nsqlookupd是nsq管理集群拓扑信息以及用于注册和发现nsqd服务；所以，也可以把nsqlookupd理解为注册发现服务；当nsq集群中有多个nsqlookupd服务时，因为每个nsqd都会向所有的nsqlookupd上报本地信息，因此nsqlookupd具有最终一致性；

![厦门狮山](http://7xjnip.com1.z0.glb.clouddn.com/ldw-IMG_0718.JPG "")

这篇文章主要从以下几个方面来分析下nsqlookupd源码：
1. nsqlookupd运行过程；
2. nsqlookupd优秀设计；
3. 总结；

# nsqlookupd运行过程

----

## NSQ目录结构
 
在看nsqlookupd源码之前，先来看下NSQ的目录结构；NSQ目录结构设计也很清晰，从目录就可以看出各个模块什么意思；
1. apps　目录存放了nsqd, nsqlookupd, nsqadmin和一些工具的main函数文件；
2. internal　目录存放了NSQ内部使用的一些函数，例如三大组件通用函数；
3. nsqadmin　目录存放了关于nsqadmin源码；
4. nsqd　目录存放了关于nsqd源码；
5. nsqlookupd　目录存放了　nsqlookupd的源码；

因此如果看nsqlookupd源码的话，我们首先需要看apps/nsqlookupd目录下的nsqlookupd.go文件；

## nsqlookupd启动函数

NSQ的nsqd和nsqlookupd组件都使用了开源组件
> "github.com/judwhite/go-svc/svc"

来管理进程的初始化，启动和关闭；我们先来看下main函数
```golang
type program struct {
	nsqlookupd *nsqlookupd.NSQLookupd
}//nsqlookupd启动服务实例

func main() {
	prg := &program{}
	if err := svc.Run(prg, syscall.SIGINT, syscall.SIGTERM); err != nil {
		log.Fatal(err)
	}
}
```
svc.run方法接收一个实现了init,start和stop方法的服务实例，以及若干信号；信号用于控制该服务的优雅终止，而服务实例用于开启nsqlookupd服务；

我们来看下program的start方法；
```golang
func (p *program) Start() error {
	flagSet.Parse(os.Args[1:])

	if *showVersion {
		fmt.Println(version.String("nsqlookupd"))
		os.Exit(0)
	}//如果只是查看版本号，则显示版本号并退出

	var cfg map[string]interface{}
	if *config != "" {
		_, err := toml.DecodeFile(*config, &cfg)
		if err != nil {
			log.Fatalf("ERROR: failed to load config file %s - %s", *config, err.Error())
		}
	}//从配置文件解析配置信息

	opts := nsqlookupd.NewOptions()
	options.Resolve(opts, flagSet, cfg)
	//实例化一个nsqlookupd实例
	daemon := nsqlookupd.New(opts)
	//调用nsqlookupd的Main方法
	daemon.Main()
	p.nsqlookupd = daemon
	return nil
}
```
这个函数用于调用nsqlookupd的Main函数，而Main函数才是nsqlookupd模块启动的主体函数；当这个Start函数返回之后，整个程序阻塞在svc.Run方法内部的信号channel上；当我们向这个程序发送SIGINT和SIGTERM信号时，svc.Run函数调用program.Stop方法终止nsqlookupd进程。

## nsqlookupd模块之Main函数

之前的分析都还是在apps/nsqlookupd目录下，通过之前调用nsqlookupd.Main方法，将代码切换到了nsqlookupd目录下；ok，我们直接找到nsqlookupd/nsqlookupd.Main方法；
```golang
func (l *NSQLookupd) Main() {
	//整个nsqlookupd模块上下文
	ctx := &Context{l}

	tcpListener, err := net.Listen("tcp", l.opts.TCPAddress)
	if err != nil {
		l.logf("FATAL: listen (%s) failed - %s", l.opts.TCPAddress, err)
		os.Exit(1)
	}
	l.Lock()
	l.tcpListener = tcpListener
	l.Unlock()
	tcpServer := &tcpServer{ctx: ctx}
	//开启nsqlookupd的tcp服务
	l.waitGroup.Wrap(func() {
		protocol.TCPServer(tcpListener, tcpServer, l.opts.Logger)
	})

	httpListener, err := net.Listen("tcp", l.opts.HTTPAddress)
	if err != nil {
		l.logf("FATAL: listen (%s) failed - %s", l.opts.HTTPAddress, err)
		os.Exit(1)
	}
	l.Lock()
	l.httpListener = httpListener
	l.Unlock()
	httpServer := newHTTPServer(ctx)
	//开启nsqlookupd的http服务
	l.waitGroup.Wrap(func() {
		http_api.Serve(httpListener, httpServer, "HTTP", l.opts.Logger)
	})
}
```

其中，l.waitGroup是sync.WaitGroup的子类，该类的Wrap方法用于在新的goroutine调用参数func函数；因此在执行Main方法之后，此时nsqlookupd进程就另外开启了两个goroutine，一个用于执行tcp服务，一个用于执行http服务；我们分别来看下；

## nsqlookupd之tcp服务；

上篇文章有说道，nsqlookupd的tcp服务是用于处理nsqd上报信息的；我们顺着之前的Main方法，找到开启tcp服务的代码internal/protocol/tcp_server.go，如下:
```golang
type TCPHandler interface {
	Handle(net.Conn)
}

func TCPServer(listener net.Listener, handler TCPHandler, l app.Logger) {
	l.Output(2, fmt.Sprintf("TCP: listening on %s", listener.Addr()))

	for {
		clientConn, err := listener.Accept()
		if err != nil {
			if nerr, ok := err.(net.Error); ok && nerr.Temporary() {
				l.Output(2, fmt.Sprintf("NOTICE: temporary Accept() failure - %s", err))
				runtime.Gosched()
				continue
			}
			// theres no direct way to detect this error because it is not exposed
			if !strings.Contains(err.Error(), "use of closed network connection") {
				l.Output(2, fmt.Sprintf("ERROR: listener.Accept() - %s", err))
			}
			break
		}
		go handler.Handle(clientConn)
	}

	l.Output(2, fmt.Sprintf("TCP: closing %s", listener.Addr()))
}
```
这个TCPServer函数是公共函数部分，因此这个函数也用于nsqd的tcp服务；这个函数和平时见到的golang网络编程模型一样，在一个for循环中，接收一个客户端，并开启一个新的goroutine来处理这个客户端；

接下来，看下这个TCPHandler，这是个接口，这个接口包含Handle(net.Conn)方法，从Main方法可以看出，传入的TCPHandler是类tcpServer；我们接下来看下，在文件nsqlookupd/tcp.go:
```golang
type tcpServer struct {
	ctx *context
func (p *tcpServer) Handle(clientConn net.Conn) {
	......
	var prot protocol.Protocol
	switch protocolMagic {
	case "  V1":
		prot = &LookupProtocolV1{ctx: p.ctx}
	default:
		protocol.SendResponse(clientConn, []byte("E_BAD_PROTOCOL"))
		clientConn.Close()
		p.ctx.nsqlookupd.logf("ERROR: client(%s) bad protocol magic '%s'",
			clientConn.RemoteAddr(), protocolMagic)
		return
	}

	err = prot.IOLoop(clientConn)
	if err != nil {
		p.ctx.nsqlookupd.logf("ERROR: client(%s) - %s", clientConn.RemoteAddr(), err)
		return
	}
	......
```

这个tcpServer只有一个成员ctx，之前在Main函数有看到，这个context只有一个成员，即这个nsqlookupd实例的地址；这个context其实主要作用就是在各模块间传递nsqlookupd这个实例，便于访问nsqlookupd地址；nsq协议有默认(其实就是v0)和v1，因此代码有根据协议的版本执行不同的代码；我们以协议v1为例；这个Handle方法最后调用了LookupProtocolV1.IOLoop方法；由名字可以看出这个IOLoop函数是一个循环，我们来看下:
```golang
	...........//省去一些代码
	client := NewClientV1(conn)
	reader := bufio.NewReader(client)
	for {
		//读取用户的请求命令
		line, err = reader.ReadString('\n')
		if err != nil {
			break
		}

		line = strings.TrimSpace(line)
		//按空格切割用户请求，params存储的就是用户请求命令以及参数
		params := strings.Split(line, " ")

		var response []byte
		//执行请求并返回结果
		response, err = p.Exec(client, reader, params)
		if err != nil {
			ctx := ""
			if parentErr := err.(protocol.ChildErr).Parent(); parentErr != nil {
				ctx = " - " + parentErr.Error()
			}
			p.ctx.nsqlookupd.logf("ERROR: [%s] - %s%s", client, err, ctx)

			_, sendErr := protocol.SendResponse(client, []byte(err.Error()))
			if sendErr != nil {
				p.ctx.nsqlookupd.logf("ERROR: [%s] - %s%s", client, sendErr, ctx)
				break
			}

			// errors of type FatalClientErr should forceably close the connection
			if _, ok := err.(*protocol.FatalClientErr); ok {
				break
			}
			continue
		}

		if response != nil {
			_, err = protocol.SendResponse(client, response)
			if err != nil {
				break
			}
		}
	}
```
最后这个客户端的goroutine就在这个循环中不断执行用户(其实就是nsqd服务)请求；过程如下:
1. 读取用户请求；
2. 将用户请求字符串按空格切割成字符串数组；
3. 调用LookupProtocolV1.Exec方法，执行具体请求；

最后来看下LookupProtocolV1.Exec方法;
```golang
func (p *LookupProtocolV1) Exec(client *ClientV1, reader *bufio.Reader, params []string) ([]byte, error) {
	switch params[0] {
	case "PING":
		return p.PING(client, params)
	case "IDENTIFY":
		return p.IDENTIFY(client, reader, params[1:])
	case "REGISTER":
		return p.REGISTER(client, reader, params[1:])
	case "UNREGISTER":
		return p.UNREGISTER(client, reader, params[1:])
	}
	return nil, protocol.NewFatalClientErr(nil, "E_INVALID", fmt.Sprintf("invalid command %s", params[0]))
}
```
从这个函数可以看出，nsqd向nsqlookupd发送的信息只有上述四个命令，我分别说明下:
1. PING nsqd每隔一段时间都会向nsqlookupd发送心跳，表明自己还活着；
2. IDENTITY 当nsqd第一次连接nsqlookupd时，发送IDENTITY，验证自己身份；
3. REGISTER 当nsqd创建一个topic或者channel时，向nsqlookupd发送REGISTER请求，在nsqlookupd上更新当前nsqd的topic或者channel信息；
4. UNREGISTER 当nsqd删除一个topic或者channel时，向nsqlookupd发送UNREGISTER请求，在nsqlookupd上更新当前nsqd的topic或者channel信息；
具体各个命令怎么执行，这里就不去分析了；需要提一点是，nsqd的信息是保存在registration_db这样的实例里面的；

我们来总结下nsqlookupd的tcp执行流程:
1. 首先在Main函数开启一个goroutine来开启一个tcp循环，接收nsqd连接请求；
2. 当接收到一个nsqd接请求时，开启一个goroutine来处理这个nsqd；
3. 这个nsqd先是经历tcpServer.Handle函数，然后到LookupProtocolV1.IOLoop函数，并阻塞在此函数中；
4. 当nsqd发送请求时，LookupProtocolV1.IOLoop函数先是读取该请求，并调用LookupProtocolV1.Exec函数执行具体请求；

## nsqlookupd之http服务

nsqlookupd的http服务是用于向nsqadmin提供查询接口的，本质上，就是一个web服务器，提供http查询接口；我们顺着Main函数，来看下http是怎么运行的，在文件internel/http_api/http_server.go中
```golang
func Serve(listener net.Listener, handler http.Handler, proto string, l app.Logger) {
	l.Output(2, fmt.Sprintf("%s: listening on %s", proto, listener.Addr()))

	server := &http.Server{
		Handler:  handler,
		ErrorLog: log.New(logWriter{l}, "", 0),
	}
	err := server.Serve(listener)
	// theres no direct way to detect this error because it is not exposed
	if err != nil && !strings.Contains(err.Error(), "use of closed network connection") {
		l.Output(2, fmt.Sprintf("ERROR: http.Serve() - %s", err))
	}

	l.Output(2, fmt.Sprintf("%s: closing %s", proto, listener.Addr()))
}
```
这个函数也很简单，实例化http.Server模块，然后调用server.Server(listner)函数开启http服务；如果之前有看过golang的http模块，应该知道http模块最重要的就是http.Handler，因为http.Handler提供了路由查询，视图函数执行功能；在Main函数看到传入的http.Handler是newHTTPServer这个类，我们来看下:
```golang
type httpServer struct {
	ctx    *Context
	router http.Handler
}

func newHTTPServer(ctx *Context) *httpServer {
	log := http_api.Log(ctx.nsqlookupd.opts.Logger)
	//实例化一个httprouter
	router := httprouter.New()
	router.HandleMethodNotAllowed = true
	//设置panic时的处理函数
	router.PanicHandler = http_api.LogPanicHandler(ctx.nsqlookupd.opts.Logger)
	//设置not found处理函数
	router.NotFound = http_api.LogNotFoundHandler(ctx.nsqlookupd.opts.Logger)
	//当请求方法不支持时的处理函数
	router.MethodNotAllowed = http_api.LogMethodNotAllowedHandler(ctx.nsqlookupd.opts.Logger)
	s := &httpServer{
		ctx:    ctx,
		router: router,
	}

	router.Handle("GET", "/ping", http_api.Decorate(s.pingHandler, log, http_api.PlainText))
	//省略后续路由定义
}

func (s *httpServer) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	s.router.ServeHTTP(w, req)
}
```
nsqlookupd的http服务路由使用的是开源框架httprouter；httprouter路由使用radix树来存储路由信息，路由查找上效率高，同时提供一些其他优秀特性，因此很受欢迎，gin web框架使用的就是httprouter路由；

这个httpServer有两个成员属性，一个是context，用于传递nsqlookupd地址，一个是httprouter实例，用于定义路由以及提供路由查找入口；这个httpServer.ServerHTTP函数内部调用httprouter.ServerHTTP来处理http请求；

针对这个函数，我们最后再来看下路由定义中的http_api.Decorate函数，在文件internal/http_api/api_response.go
```golang
func Decorate(f APIHandler, ds ...Decorator) httprouter.Handle {
	decorated := f
	for _, decorate := range ds {
		decorated = decorate(decorated)
	}
	return func(w http.ResponseWriter, req *http.Request, ps httprouter.Params) {
		decorated(w, req, ps)
	}
}
```
这个函数其实就是一个装饰器，第一个参数为需要被装饰的视图函数，从第二参数开始，都是装饰函数，最后返回装饰好的视图函数；http模块比较简单，和其他的web服务一样，很容易看懂；每个路由以及对应的视图函数比较多，这里就不一一解释了；

# nsqlookupd优秀设计

---------

上部分主要分析了nsqlookupd执行过程，主要有两个方面，一个是tcp，另一个是http；这部分，我将根据自己的理解，写下我认为nsqlookupd优秀设计；学习开源框架，除了使用和了解原理外，我觉得学习开源框架优秀设计以及代码技巧也是非常有意义的一件事；

## 优雅的代码启动方式和退出方式

nsqlookupd模块使用开源框架svc来开启进程以及控制进程的退出；本人也一直很喜欢使用信号的方式来退出进程，这样可以在进程收到信号时，可以做一些扫尾操作；虽然svc也是用信号来控制进程退出，但是使用svc，使代码看起来更简介优雅；

## context的使用

nsqlookupd服务使用context来保存上下文(nsqlookupd实例地址)，这样在每个模块就可以很方便地访问nsqdlookupd实例；这有点类似与golang1.7正式引入的context；

## 代码复用

接口的使用，使代码复用更加容易；而且golang的继承是非浸入式的，即不需要显示声明某结构体继承自某个接口，只要该结构体实现了接口定义的函数即可；例如internal/protocol/tcp_server.go
```
type TCPHandler interface {
	Handle(net.Conn)
}
func TCPServer(listener net.Listener, handler TCPHandler, l app.Logger)
```
这个函数是用于开启tcp服务，nsqd和nsqlookupd都有使用，这里的TCPHandler就是一个接口，nsqd和nsqlookupd服务分别有相应的结构体实现了TCPHandler，然后传入这个函数中；

## 视图函数封装

在web开发过程中，每个路由都有对应的视图函数，当我们在执行一个视图函数时，我们有打印日志(例如请求执行时间)或者判断权限等需求；如果在写每个视图函数时，都手动添加日志打印，第一是麻烦，第二是代码冗余；如果用装饰器模式将会非常方便；nsqlookupd的http服务针对每个视图函数都进行了装饰；如果所有视图函数的装饰函数是一样，那么我们可以直接装饰在http.handler上，这样可以简化代码；python的bottle也提供了类似功能，但是bottle是以插件的形式引入装饰器；

# 总结

这篇文章分析了nsqlookupd服务执行过程以及分享了我自认为一些好的代码设计；nsqlookupd对golang主要特性channel使用比较少，我们将会在nsqd中看到NSQ是如何优雅使用goroutine和channel.




































