# 2026-10-24：重载后快捷键逐渐失效

## 现象与范围

用户报告 Hammerspoon Reload Config 后快捷键暂时可用，过一会再次失效。此次检查时，桥接认证、MRU 快照和预览消息都正常，不能沿用前一次“扩展 token 不匹配”的诊断。

## 原因与复现

键盘事件监听器、应用切换监听器和睡眠唤醒监听器只保存在配置文件的顶层局部变量中。配置执行完毕后，缺少一个持久的对象所有者。

Hammerspoon 1.1.1 在原生注册表中保留回调函数，但不会因此自动保留对应的 Lua watcher userdata。userdata 被垃圾回收时，原生析构函数会停止监听。应用和唤醒 watcher 先被释放，也会解除间接保留键盘监听器的回调引用，随后键盘监听器也可能被回收。这解释了为何重载能短暂恢复、运行一段时间后又失效。

新增的生命周期测试模拟原生回调注册表，以弱引用观察监听对象，并连续执行完整垃圾回收。修复前明确失败：`keyboard listener disappeared after garbage collection`。修复后，键盘、应用和唤醒监听器全部保留；释放所有者后则可以正常回收，没有永久引用循环。

此前的行为测试直接保存回调函数并调用它们，没有模拟原生监听对象被回收后停止工作的过程，因此未覆盖这个问题。

## 修复

- 使用一个名为 `EdgeRecentTabs` 的全局所有者，保留三个长期运行的监听对象。
- `hs.reload()` 更换整个 Lua 状态时，旧所有者随旧状态释放。
- 没有新增键盘监听器、后台轮询或重复启动定时器；只增加三个对象引用。
- `/status` 增加 `keyboardTapEnabled` 和 `secureInputEnabled`，把键盘链路问题与扩展认证问题分开诊断。
- 保留已有 Edge 焦点限制、即时 Option 释放、导航、MRU、预览和唤醒恢复逻辑。

## 验证

- 生命周期测试：旧代码失败，新代码通过，包括对象释放检查。
- 原有 Lua 行为与认证/MRU 测试通过。
- 扩展与安装生成器回归测试通过。
- Hammerspoon 1.1.1 实机：安装修复后，以临时一次性探针强制执行五轮完整垃圾回收；`keyboardEnabledBeforeGC` 与 `keyboardEnabledAfterGC` 均为 true，应用和唤醒 watcher 的弱引用仍可访问，Secure Input 为 false。
- 同次实机检查中，`/status` 显示键盘监听启用、桥接认证成功、MRU 快照已收到、预览计数为 6。探针结束后清理测试定时器，磁盘配置恢复为正式生成文件。

首次临时探针没有生成结果，因此没有将它记为通过。改用明确保留的一次性测试定时器后取得了上述实机结果。该测试定时器不属于正式运行配置，也没有留下后台轮询。

## 依据

- [Hammerspoon 1.1.1 eventtap implementation](https://github.com/Hammerspoon/hammerspoon/blob/1.1.1/extensions/eventtap/libeventtap.m)：回调注册、系统超时后的自动重启及 userdata 析构。
- [Application watcher implementation](https://github.com/Hammerspoon/hammerspoon/blob/1.1.1/extensions/application/libapplication_watcher.m)。
- [Wake watcher implementation](https://github.com/Hammerspoon/hammerspoon/blob/1.1.1/extensions/caffeinate/libcaffeinate_watcher.m)。

macOS Secure Input 仍可能阻止事件监听器收取键盘事件，这是独立的系统限制，不能通过保留对象引用解决。
