## Background
我在做完课程 [6.824: Distributed Systems Spring 2021](http://nil.csail.mit.edu/6.824/2021/) lab1-lab3的之后，实现了一个真正可持久化的[Fault-tolerant Key/Value Service](https://github.com/chong-chonga/FaultTolerantKVService)。
这个系统主要涉及lab2、lab3的内容，因此在这个过程中，我尝试对**raft**和**server**做了许多’优化‘。为了确保这些’**优化**‘不会出现bug， 我将优化也同样地应用在了lab上，并使用测试脚本进行了多次测试。
能够稳定通过测试的’**优化**‘得以保留，其他的则予以淘汰。

我会在这里分享关于lab2、lab3的一些思考，并提供lab实现思路。为了防止抄袭代码从而影响课程的学生，我只会结合部分代码进行讲解，
不提供完整的lab代码！！！

## Contents
- ### Lab 2: Raft
    - #### 优化一：利用`sync.Cond`，将`applyLog`方法由轮询改为条件变量等待
    - #### 优化二：利用计时器，更严格地控制`leader`发送`heartbeat`和`follower`开始`election`的间隔
    - #### 优化三：利用公平锁机制，在`InstallSnapshot`方法里直接安装`snapshot`，`CondInstallSnapshot`方法永远返回`true`
- ### Lab 3: Fault-tolerant Key/Value Service
    - #### 思考1：server如何知晓命令已经达成共识？
    - #### 思考2：多个client提交raft的命令得到的`commandIndex`在什么情况下会相同？
- ### lab的题外话
    - #### 1：server是否需要进行重复命令的检测？
    - #### 2：server如何生成唯一的分布式标识？
    - #### 3: 代码如何更简洁？

## Maintainers
[@Yoimbi](https://github.com/chong-chonga)

## Contributing
如果你对这两个实验有自己的思考或者思路存在一定的bug等，欢迎加入讨论！
