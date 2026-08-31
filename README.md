# QB远程（QBRemote）— iOS 手机 App

一个简单的 iOS App：打开就是 **qBittorrent Web UI** 的全屏界面。配合你 qB 服务器上已部署的触屏版预览脚本（custom-preview.js），在手机上**单击任务下方的文件即可全屏预览图片/视频**，像原生 App 一样，不需要在浏览器里操作。

## 功能

- 打开 App 直接进入 qB 网页（默认 `http://sdcs.asuscomm.com:8085/`）
- 全屏网页、隐藏地址栏，像原生 App
- 单击文件 → 全屏预览（图片/视频/音频）；单击文件夹 → 打开 FileBrowser
- 底部工具条：后退 / 前进 / 刷新 / 设置 / 用 Safari 打开
- 登录状态保存在手机本地，下次打开不用重新登录
- 支持横竖屏、支持侧滑前进/后退
- 可在设置里修改地址（外网 DDNS 或局域网 IP 都行）

## 安装步骤（不用 Mac，用 GitHub 云端编译）

### 1. 准备 GitHub 账号
- 打开 https://github.com 注册（免费）。已有账号跳过。

### 2. 创建仓库并上传代码
1. 登录 GitHub，点右上角「+」→「New repository」
2. 仓库名填 `QBRemoteApp`，选 **Public**（公开，免费版也能用 Actions），勾选「Add a README file」
3. 点「Create repository」
4. 进入仓库后，点「Add file」→「Upload files」
5. 把下面这些文件/文件夹**原样拖拽上传**（保持目录结构）：

```
QBRemote/            （文件夹，里面有 3 个文件）
project.yml
.github/workflows/build-ipa.yml
```

> 注意：`.github` 是隐藏文件夹，拖拽上传时要把整个 `.github` 文件夹一起拖进去。

6. 点「Commit changes」上传

### 3. 触发编译
- 上传代码后，GitHub 会自动开始编译
- 打开仓库顶部的 **Actions** 标签页，能看到一个叫「编译 IPA」的任务在跑
- 等它跑完（约 5~10 分钟），任务显示绿色 ✓

> 如果没自动跑：在 Actions 页点「编译 IPA」→ 右侧「Run workflow」→ 绿色按钮手动触发一次。

### 4. 下载 IPA
1. 任务跑完后，点击那个绿色任务
2. 页面底部有 **Artifacts** 区域，点「**QBRemote-ipa**」下载
3. 得到一个 `QBRemote-ipa.zip`，解压出 `QBRemote.ipa`

### 5. 用巨魔安装
1. 把 `QBRemote.ipa` 传到手机（微信文件传输 / iCloud / 浏览器下载都行）
2. 用「文件」App 找到它，点「共享」→「用 TrollStore 打开」
3. 巨魔会自动安装，安装完桌面出现「QB远程」图标

## 使用

1. 打开「QB远程」，进入 qB 登录页
2. 输入 qB 用户名密码登录（登录状态会记住）
3. 上方点选一个任务 → 下方「内容」标签页 → **单击文件**即可全屏预览

## 修改地址

- 打开 App 后点底部「齿轮」图标 → 修改地址 → 保存
- 地址会自动补全 `http://` 前缀
- 例如局域网地址改成：`192.168.x.x:8085`

## 常见问题

**Q: 编译失败怎么办？**
A: 打开 Actions 里的失败任务，点开「编译（无签名）」这步看红色报错。最常见的是代码传错了目录结构，检查 `QBRemote` 文件夹是否在仓库根目录。

**Q: 巨魔安装时提示不支持？**
A: 确认你的 iOS 版本在巨魔支持范围内（TrollStore 2 支持 iOS 14.0 ~ 16.6.1）。

**Q: 预览功能没生效？**
A: 确认 qB 服务器上 `webui-chinese/private/custom-preview.js` 是最新的触屏适配版，且替代 Web UI 已启用。可在电脑上先验证 qB 网页单击预览正常。
