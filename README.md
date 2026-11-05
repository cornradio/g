# g

一个超级简单的终端 Git 浏览器。和 [y](https://github.com/cornradio/y) 一样，就是一个 PowerShell 函数。

新开一个终端，输入 `g` 回车。它列出当前目录里的文件夹。仓库没有改动是绿色，有改动是黄色。比远程超前写成 `+1`，落后写成 `-1`。

最上面是选中仓库实际会用的用户名和邮箱。

| 按键 | 作用 |
|---|---|
| `↑` `↓` 或 `j` `k` | 移动 |
| `←` `→` | 返回上级 / 进入文件夹 |
| `l` | 拉取当前分支 |
| `r`（macOS） | 刷新当前目录的文件列表、仓库状态和忽略标记，保留搜索和筛选条件。不会执行 fetch 或 pull |
| `Enter` | 看这个仓库的 `git status`。在这个画面里按 `r` 会丢掉全部改动（已跟踪的改动和未跟踪的新文件），要再确认一次 |
| `c` | 直接用 `update` 提交并刷新列表，不进入画面 |
| `Shift+C` | 进入编辑。说明已经写好 `update`，可以改，回车提交 |
| `i` | 标记或取消标记当前文件夹。记在 `ignore.json`。标记后名字前有 `*`，并且一直是绿色 |
| `y` | 只显示不干净的仓库：状态是数字，或者 `clean` 旁边有 `+1` / `-1`。再按一次恢复全部。页码后面会出现 `dirty` |
| `/` | 按名字搜索。空着回车就清除。有搜索词时按 `Esc` 先清除搜索 |
| `p` | 推送当前分支。没有上游就推到 `origin` 的同名分支 |
| `g` | 用 GitHub Desktop 打开选中的文件夹 |
| `v` | 用 VS Code 打开选中的文件或文件夹 |
| `d` | 把选中的文件或文件夹移到回收站。直接回车就是确认，`Shift+D` 不再询问 |
| `q` | 退出，并把终端目录留在当前浏览位置 |

在上级目录选中一个仓库文件夹，直接按 `c` 或 `p`，不用先进去。

## Windows 安装

打开 PowerShell，输入：

```powershell
code $PROFILE
```

把 [g.win.ps1](g.win.ps1) 里的 `function g` 整段贴到最后，保存。新开一个终端，输入 `g`。

## macOS 安装

先确认已安装 Git 和 Python 3。然后按下面步骤操作：

1. 打开“终端”。
2. 输入下面这行并按回车，打开 zsh 配置文件：

   ```sh
   nano ~/.zshrc
   ```

3. 用键盘方向键移到文件末尾，另起一行，粘贴下面这行：

   ```sh
   source /Users/kasusa/Documents/GitHub/g/g.mac.zsh
   ```

   如果你把仓库放在别的地方，请把上面的路径改成你的 `g.mac.zsh` 文件实际位置。

4. 按 `Control + O` 保存，按回车确认文件名，再按 `Control + X` 退出。
5. 回到终端，输入 `g` 并按回车即可启动。

退出时，终端会切换到浏览器当前所在的目录。

macOS 版保留 Windows 版的主要快捷键和 Git 操作。按 `d` 会通过 Finder 将文件或文件夹移到废纸篓；VS Code 和 GitHub Desktop 快捷键分别使用 `code` 命令和应用程序名称打开。

macOS 版按 `r` 可手动刷新。pull、push、提交后，在结果画面按回车返回时会自动刷新列表；失败后也会重新读取状态。注意：`r` 只读取本地状态，远程超前/落后数量以最近一次 fetch 或 pull 得到的信息为准。在 `git status` 画面中，`r` 仍然是丢弃改动，需要再次确认。

### pull / push 的认证提示

macOS 版 pull / push 会继续使用 Git 已配置的凭据助手，但禁止 Git 弹出 `Username for 'https://github.com':` 或密码输入提示。认证失败时会显示原始错误，并在终端结果画面给出配置命令；不会自动修改你的登录配置。

如果你已经通过 GitHub CLI（`gh`）登录，退出 `g` 后在终端依次执行，先检查并复用现有登录：

```sh
gh auth status
gh auth setup-git
```

只有 `gh auth status` 提示尚未登录时，才需要：

```sh
gh auth login --hostname github.com --git-protocol https --web
gh auth setup-git
```

没有安装 `gh` 时，也可以选择 macOS 钥匙串方式。在对应仓库目录下执行：

```sh
git config --global credential.helper osxkeychain
git pull
```

这次手动 `git pull` 可能要求输入 GitHub 用户名和个人访问令牌（不是账户密码），成功后保存在钥匙串。不要把令牌写进远程 URL 或发到聊天中。SSH 地址使用 SSH 密钥认证，和 HTTPS 登录是两套配置；程序显示的指南也会提示检查远程地址与仓库权限。
