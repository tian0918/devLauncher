# Dev Launcher

Dev Launcher 是一个 macOS 15+ 的本地 Node.js 和 Python 项目启动器。

1. 打开 `Build/Dev Launcher.app`，点击「添加项目」。选择单个 `package.json`，或选择文件夹并勾选扫描结果。
2. 选中项目，在「启动配置」中编辑 Node 版本和命令。自动模式优先使用最近的 `.nvmrc`，其次使用 nvm 的 `default`。有 `dev` 脚本的项目默认使用 `npm run dev`，有 `start` 脚本时也可以用 `npm run start`。
3. 点击「启动」或按 ⌘↩。每个项目有独立日志，可在 App 内停止或重启。
4. 找不到 nvm 时，项目使用 `PATH` 中的默认 Node。需要切换版本时，可在「设置」中选择 nvm 目录或 `nvm.sh`。启动提示缺少 Node 版本或 npm 依赖时，可以点击「安装并重启」。安装成功后，App 会重新执行项目保存的启动命令。
5. 点击项目详情里的「终端」，可直接在新窗口的项目目录中打开 Terminal / iTerm2，也可以自动检测并启动本机已安装的 AI CLI（如 Claude Code、Codex、Gemini CLI、Antigravity、Kimi 等）。首次使用时，macOS 可能会询问是否允许 Dev Launcher 控制所选终端。

项目列表与启动设置存储于 `~/Library/Application Support/DevLauncher/projects.json`。运行日志保留在本次 App 会话中。

## Python 项目

点击「添加项目」，选择 `pyproject.toml`、`requirements.txt`、`setup.py`、`Pipfile` 或任意 `.py` 脚本，也可以扫描项目目录。每个目录可导入一次。如果同一目录同时包含 Node.js 和 Python 项目文件，首次导入时可直接选择 Python 文件。

项目目录含有 `manage.py` 时，默认命令为 `python3 manage.py runserver`。也会识别 `__main__.py`、`main.py`、`app.py` 或你直接选择的脚本。其他入口可在「编辑启动配置」中填写，例如 `python3 -m uvicorn main:app` 或 `uv run python main.py`。

启动时依次优先使用项目中的 `.venv`、`venv` 和系统 PATH，也可以在命令中指定解释器。请先安装项目依赖。配置完成后按 ⌘↩ 启动，日志、停止和重启都可在 App 内使用。

## 构建与测试

用 Xcode 打开 `DevLauncher.xcodeproj`，选择 DevLauncher scheme 后运行。也可在项目目录执行以下命令。

```sh
xcodebuild -scheme DevLauncher -configuration Release -destination 'generic/platform=macOS' build
Tests/run.sh
```

集成测试需要可用的 Python 3，以及本机 nvm 至少安装两个 Node 版本并设置可用的默认版本。测试使用临时项目验证导入、启动、日志和进程清理。
