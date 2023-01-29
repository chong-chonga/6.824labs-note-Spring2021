## Background
我在做完课程 [6.824: Distributed Systems Spring 2021](http://nil.csail.mit.edu/6.824/2021/) lab1-lab3的之后，实现了一个真正可持久化的[Fault-tolerant Key/Value Service](https://github.com/chong-chonga/FaultTolerantKVService)。
这个系统主要涉及lab2、lab3的内容，因此在这个过程中，我尝试对**raft**和**server**做了许多’优化‘。为了确保这些’**优化**‘不会出现bug， 我将优化也同样地应用在了lab上，并使用测试脚本进行了多次测试。
能够稳定通过测试的’**优化**‘得以保留，其他的则予以淘汰。

我会在这里分享关于lab2、lab3的一些思考，并提供lab实现思路。为了防止抄袭代码从而影响课程的学生，我只会结合部分代码进行讲解，
不提供完整的lab代码！！！

## Contents
- ### Lab 2: Raft
  - #### [优化一：利用sync.Cond，将applyLog方法由轮询改为条件变量等待](https://github.com/chong-chonga/6.824labs-note-Spring2021/blob/master/note/raft.md#raft%E5%BA%94%E8%AF%A5%E6%80%8E%E6%A0%B7%E5%90%91%E4%B8%8A%E5%B1%82%E7%9A%84service%E5%8F%91%E9%80%81log)
  - #### [优化二：利用公平锁机制，在InstallSnapshot方法里直接安装snapshot，CondInstallSnapshot方法永远返回true](https://github.com/chong-chonga/6.824labs-note-Spring2021/blob/master/note/raft.md#%E4%B8%BA%E4%BB%80%E4%B9%88%E9%9C%80%E8%A6%81condinstallsnapshot)
  - #### [优化三：利用计时器，更严格地控制leader发送heartbeat和follower开始election的间隔](https://github.com/chong-chonga/6.824labs-note-Spring2021/blob/master/note/raft.md#%E8%B0%88%E8%B0%88leader%E5%8F%91%E9%80%81heartbeat%E7%9A%84%E4%BC%98%E5%8C%96)
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
