#pragma once

#include <functional>
#include <mutex>
#include <condition_variable>
#include <thread>
#include <chrono>
#include <list>
#include <vector>
#include <algorithm>
#include <assert.h>

#define THRPOOL_INITIALIZED 1
#define THRPOOL_EXITING 2
#define THRPOOL_MAX_THREADS 1024
#define TASKTHREAD_FLAG_CREATED 1
#define TASKTHREAD_FLAG_SHOULD_EXIT 2
#define FINISH_FLAG_WAIT_NORMAL_TASK 1
#define FINISH_FLAG_WAIT_DELAYED_TASK 2

class ThreadPool {
public:
  enum class TaskOp {
    DOING,
    DONE,
    DISCARD
  };
  typedef std::function<void()> TaskFunc;
  ///\param op  DOING 任务执行中
  ///           DONE 任务执行完成
  ///           DISCARD 任务放弃
  typedef std::function<void(TaskOp op)> TaskCallback;
  /// 每个线程启动时执行的函数, 由用户指定
  typedef std::function<void()> ThreadOnceFunc;

private:
  class TaskInfo {
  public:
    TaskInfo() {}

    TaskInfo(TaskFunc f, TaskCallback c) : func(f), cb(c) {}

    TaskInfo(TaskFunc f, std::chrono::steady_clock::time_point& t, TaskCallback c)
      : func(f), tp(t), cb(c) {}

    TaskFunc func;
    std::chrono::steady_clock::time_point tp;
    TaskCallback cb;
  };

  class TaskThread {
  public:
    TaskThread() {
    }

    TaskThread(const TaskThread&) {
    }

    void init(ThreadPool *pool, std::mutex& mut, ThreadOnceFunc func) {
      thePool = pool;
      thrMutex = &mut;
      onceFunc = func;
    }

    void arise() {
      if ((flags & TASKTHREAD_FLAG_CREATED) == 0
          && (flags & TASKTHREAD_FLAG_SHOULD_EXIT) == 0) {
        // init
        thr = std::thread([this]() { run(); });
        flags |= TASKTHREAD_FLAG_CREATED;
      }
    }

    void work() {
      thrCond.notify_one();
    }

    void rip() {
      flags |= TASKTHREAD_FLAG_SHOULD_EXIT;
      if (thr.joinable())
        thrCond.notify_one();
    }

    void waitExit() {
      if (thr.joinable())
        thr.join();
      flags = 0;
    }

  private:
    void run() {
      if (onceFunc != nullptr)
        onceFunc();

      std::unique_lock<std::mutex> locker(*thrMutex);
      TaskInfo task;

      while (true) {
        if(flags & TASKTHREAD_FLAG_SHOULD_EXIT)
          break;
        if (thePool->getPendingTask(task)) {
          locker.unlock();
          if (task.cb)
            task.cb(TaskOp::DOING);
          if (task.func)
            task.func();
          if (task.cb)
            task.cb(TaskOp::DONE);
          locker.lock();
          continue;
        }
        auto r = thePool->getDelayedTask();
        if (r == 0)
          continue;
        thePool->pushIdleThread(this);
        if (r > 0) {
          // 等待delayed task执行时间
          thrCond.wait_for(locker, std::chrono::milliseconds{r});
        } else {
          thrCond.wait(locker);
        }
      }
    }

  private:
    ThreadPool* thePool{nullptr};
    std::thread thr;
    std::mutex* thrMutex{nullptr};
    std::condition_variable thrCond;
    uint32_t flags{0};
    ThreadOnceFunc onceFunc{nullptr};
  };

public:
  ThreadPool() {
  }

  explicit ThreadPool(uint32_t max) {
    init(max);
  }

  ~ThreadPool() {
    finish();
  }

  ///\brief 初始化, 设置线程池最大线程数
  /// 设置线程启动执行一次的函数
  void init(uint32_t max, ThreadOnceFunc func = nullptr) {
    std::lock_guard<std::mutex> locker(poolMutex);
    if (max == 0 || max > THRPOOL_MAX_THREADS || status & THRPOOL_INITIALIZED)
      return;
    status |= THRPOOL_INITIALIZED;
    threadArray.resize(max);

    uint32_t i;
    for (i = 0; i < max; ++i) {
      threadArray[i].init(this, poolMutex, func);
    }
    initDeadThreads();
  }

  ///\brief 向线程池中添加待执行任务
  ///\param delay  任务延时执行，等待时间，毫秒
  ///\param cb  任务执行事件回调, 可为空
  void push(TaskFunc task, uint32_t delay = 0, TaskCallback cb = nullptr) {
    std::lock_guard<std::mutex> locker(poolMutex);
    if (status & THRPOOL_EXITING)
      return;
    if (delay == 0) {
      enqueueTask(task, cb);
      // 新增task，唤醒idle线程执行任务
      if (awakeIdleThread()) {
        // idle线程被唤醒去执行task了，没有idle线程剩下
        // delayedTasks非空, 需要再arise一个新线程等待delay task
        if (idleThreads.empty() && !delayedTasks.empty())
          ariseThread();
      } else
        ariseThread();
    } else {
      enqueueDelayedTask(task, delay, cb);
      // 新增了delay task，唤醒idle线程，更新此线程的wait时间
      if (!awakeIdleThread())
        ariseThread();
    }
  }

  ///\brief 停止线程池运行, 根据flags等待任务完成或丢弃任务
  ///\param flag  0 不等待队列中的任务完成
  ///             FINISH_FLAG_WAIT_NORMAL_TASK 等待普通任务完成
  ///             FINISH_FLAG_WAIT_DELAYED_TASK 等待普通和延时任务完成
  void finish(uint32_t flag = FINISH_FLAG_WAIT_NORMAL_TASK) {
    std::unique_lock<std::mutex> locker(poolMutex);
    if ((status & THRPOOL_INITIALIZED) == 0 || status & THRPOOL_EXITING)
      return;
    status |= THRPOOL_EXITING;
    if (flag == FINISH_FLAG_WAIT_DELAYED_TASK && !delayedTasks.empty())
      delayedTaskCleared.wait(locker);
    if (flag >= FINISH_FLAG_WAIT_NORMAL_TASK) {
      while (!pendingTasks.empty()) {
        tasksDone.wait(locker);
      }
    }
    std::list<TaskInfo> tasks;
    std::list<TaskInfo> dtasks;
    clearNoLock(tasks, dtasks);
    locker.unlock();
    discardTasks(tasks);
    discardTasks(dtasks);
    threadsExit();
    locker.lock();
    status &= (~THRPOOL_EXITING);
    initDeadThreads();
  }

private:
  void initDeadThreads() {
    size_t sz = threadArray.size();
    size_t i;
    deadThreads.clear();
    for (i = 0; i < sz; ++i) {
      deadThreads.push_back(threadArray.data() + i);
    }
  }

  ///\brief 获取待执行的任务信息
  ///\return  true  获取成功
  ///         false 无待执行的任务
  bool getPendingTask(TaskInfo& task) {
    if (!pendingTasks.empty()) {
      task = pendingTasks.front();
      pendingTasks.pop_front();
      return true;
    }
    task.func = nullptr;
    task.cb = nullptr;
    tasksDone.notify_one();
    return false;
  }

  ///\return  -1  没有delayed task
  ///          0  有delayed task到达执行时间
  ///         >0  离当前时间最近的delayed task需要等待的时间，毫秒
  int32_t getDelayedTask() {
    auto now = std::chrono::steady_clock::now();
    if (evalDelayedTasksNoLock(now))
      return 0;
    if (delayedTasks.empty())
      return -1;
    auto dur = std::chrono::duration_cast<std::chrono::milliseconds>(delayedTasks.front().tp - now);
    // 多加1毫秒，避免wait结束时，离真正的任务执行时间点还差N微秒
    return dur.count() + 1;
  }

  void pushIdleThread(TaskThread* thr) {
    idleThreads.push_back(thr);
  }

  void enqueueTask(TaskFunc task, TaskCallback cb) {
    pendingTasks.emplace_back(task, cb);
  }

  void enqueueDelayedTask(TaskFunc task, uint32_t delay, TaskCallback cb) {
    auto tp = std::chrono::steady_clock::now() + std::chrono::milliseconds{delay};
    auto it = delayedTasks.begin();
    while (it != delayedTasks.end()) {
      if (tp < it->tp)
        break;
      ++it;
    }
    delayedTasks.emplace(it, task, tp, cb);
  }

  bool awakeIdleThread() {
    if (!idleThreads.empty()) {
      auto thr = idleThreads.front();
      idleThreads.pop_front();
      thr->work();
      return true;
    }
    return false;
  }

  void ariseThread() {
    if (!deadThreads.empty()) {
      auto thr = deadThreads.front();
      deadThreads.pop_front();
      thr->arise();
    }
  }

  bool evalDelayedTasksNoLock(std::chrono::steady_clock::time_point& now) {
    if (delayedTasks.empty())
      return false;
    bool ret = false;
    auto it = delayedTasks.begin();
    while (it != delayedTasks.end()) {
      if (it->tp > now)
        break;
      pendingTasks.emplace_back(it->func, it->cb);
      it = delayedTasks.erase(it);
      ret = true;
    }
    if (delayedTasks.empty())
      delayedTaskCleared.notify_one();
    return ret;
  }

  void clearNoLock(std::list<TaskInfo>& out1, std::list<TaskInfo>& out2) {
    size_t sz = threadArray.size();
    size_t i;
    for (i = 0; i < sz; ++i)
      threadArray[i].rip();
    out1 = std::move(pendingTasks);
    out2 = std::move(delayedTasks);
    idleThreads.clear();
  }

  void discardTasks(std::list<TaskInfo>& tasks) {
    for_each(tasks.begin(), tasks.end(), [](TaskInfo& task) {
      if (task.cb)
        task.cb(TaskOp::DISCARD);
    });
  }

  void threadsExit() {
    size_t sz = threadArray.size();
    size_t i;
    for (i = 0; i < sz; ++i)
      threadArray[i].waitExit();
  }

private:
  // 待执行任务
  std::list<TaskInfo> pendingTasks;
  // 延时任务
  // 延时任务等待时间到达后，会进入pendingTasks
  std::list<TaskInfo> delayedTasks;
  // 没有任务执行，空闲中的线程
  std::list<TaskThread*> idleThreads;
  // 未真正启动系统线程的TaskThread对象
  // 线程空闲时间过长时，TaskThread对象对应系统线程退出，TaskThread对象加入deadThreads列表
  std::list<TaskThread*> deadThreads;
  std::mutex poolMutex;
  std::condition_variable tasksDone;
  std::condition_variable delayedTaskCleared;
  std::vector<TaskThread> threadArray;
  uint32_t status{0};

  friend TaskThread;
};
