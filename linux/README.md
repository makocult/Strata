# Strata Linux（原生桌面预览版）

Linux 版使用 Qt Widgets，不是网页套壳；与现有 Swift/macOS 版并存。
导图使用相同的原始 JSON 根节点结构，可互相打开。Linux 快捷键采用
`Ctrl`，对应 macOS 的 `Command`。

## 安装

发行包面向 **x86_64 Ubuntu 24.04 或更新的兼容系统**（glibc >= 2.39）。
不支持 ARM、旧版 Ubuntu 或 Alpine/musl；其他发行版尚未逐一验证。

推荐下载 GitHub Release 中的 `.deb`，通过系统软件安装器打开；也可以：

```sh
sudo apt install ./strata_1.0.0~linux.1_amd64.deb
```

安装后在应用列表找到 **Strata**。卸载用 `sudo apt remove strata`，不会
删除个人导图、素材库或密钥。包自带 Python/Qt，无需自行安装 Python 包。

便携 `.tar.gz` 解压后运行 `Strata/strata`；仍需要发行版提供桌面图形库，
依赖列表见 `linux/build.py` 的 Debian `Depends`。Wayland 桌面可使用 XWayland；
发布验收使用 X11 虚拟桌面，不等于已验证每种桌面或输入法。

## 交互与数据

- 键盘编辑、子节点/同级创建、删除子树、多选、折叠、方向键导航、撤销/重做。
- 自动水平/垂直布局；滚轮以鼠标为中心缩放；空白拖动平移。
- 节点拖放采用前/内/后三段语义，禁止拖进自身后代。
- 显式 JSON 保存/打开，Markdown 文本预览与复制。
- 本地素材库支持搜索、增删改；插入的是正文副本，不是标题或动态引用。
- 可选 OpenAI 兼容 AI 整理/优化；默认不上传现有导图，优化操作才发送当前树。
  取消、错误或文档已改变时，不应用过期结果。

默认数据目录：`${XDG_DATA_HOME:-~/.local/share}/Strata/`。
`material-library.json` 与 macOS 素材库结构一致；`ai-settings.json` 仅保存地址、
模型和代理，不含密钥。API 密钥仅通过 Linux **Secret Service** 保存（例如
GNOME Keyring / 兼容的 KWallet 服务），需安装 `libsecret-tools` 并在桌面中解锁。
没有可用密钥服务时会明确报错，不回退为明文文件。默认网络代理遵循环境变量；
也可显式填写 HTTP 代理。远程 API 必须使用 HTTPS。

Linux 配置与 macOS 钥匙串不会自动同步。AI 请求兼容性以本地 HTTP 测试夹具验证，
未代表任何真实模型账号、费用或模型输出质量已经验收。

## 从源代码运行

```sh
python3 -m venv .build/linux-venv
.build/linux-venv/bin/pip install -r linux/requirements-build.txt
PYTHONPATH=linux .build/linux-venv/bin/python -m strata_linux
PYTHONPATH=linux QT_QPA_PLATFORM=offscreen .build/linux-venv/bin/python -m unittest discover -s linux/tests -v
```

## 在 Smartation 隔离构建

只通过 `ssh smartation` 访问。使用独立工作目录
`~/.cache/strata-linux-build` 和 CPU 限制的临时 Docker 容器；不要重启或改动
该主机上的模型、GPU 或其他服务。`CHANGELOG.md` 记录变更与验收，本文记录流程。

```sh
docker build --pull=false -t strata-linux-builder:ubuntu24.04 linux
docker run --rm --cpus=4 --memory=4g \
  -v "$PWD:/work" -w /work strata-linux-builder:ubuntu24.04 \
  python linux/build.py --output /work/.build/linux-release
```

依赖锁定在 `requirements-build.txt`；基础镜像锁定摘要。输出 `.deb`、便携包和
`SHA256SUMS`。打包前运行全部测试，打包后在隔离容器安装 `.deb`，使用非 root
用户和 `xvfb-run` 启动已安装的真实程序，验证文件/素材读写与截图。
不把测试素材写进用户真实数据目录。

Qt、Python 与打包器许可证见 `THIRD_PARTY_NOTICES.md` 和包内 `licenses/`。
Qt 为动态链接，允许替换兼容库或直接运行已发布源码；没有静态锁定。
