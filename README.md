<div align="center">

# 🩺 Win10 Tile Fixer

**Windows 10 开始菜单磁贴修复工具** —— 治"磁贴沉底、上移弹回、幽灵残留、布局不保存"

![Platform](https://img.shields.io/badge/platform-Windows%2010%201709%2B-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-7.0%2B-5391FE)
![License](https://img.shields.io/badge/license-Apache--2.0-green)

</div>

## 它治什么病

| 症状 |
|---|
| 新固定的磁贴跑到最下面，之后**拖不动** |
| 磁贴**上移后被弹回**原位 |
| 取消固定后，最下方还留着一份"**幽灵磁贴**" |
| 磁贴布局改完**不保存**，重启后被**打回原形** |

> 如果你的症状是"把磁贴拖进两个磁贴之间的空隙放不进去"——那是另一个微软从未修复的鼠标拖放 bug，本工具不适用（触屏可以绕过）。

## 为什么网上教程修不好

| | 网上流传的教程 | Win10 Tile Fixer |
|---|---|---|
| 停止写入方 | 只杀 explorer | **先杀承载 `CDPUserSvc_*` / `OneSyncSvc_*` 的 svchost**（真正的写入方） |
| 删除缓存 | 删了 | 删了 |
| 删除后校验 | 无 | **等 1.5 秒确认没有被回写**，被回写自动重杀重删 |
| 备份 | 通常没有 | 修复前自动备份到 `Backups/`，随时可恢复 |
| 体检 | 无 | 数据量健康度 / 策略锁定 / 事件日志 / 同名同目标重复快捷方式 一并检查 |

**原理一句话**：Win10（1709+）的磁贴布局存在注册表 `HKCU\...\CloudStore` 键里（私有二进制格式，每块磁贴有本地/易失/漫游三份属性副本 + 墓碑区）。布局损坏后数据膨胀（实测病灶 7.4 MB，健康仅几十~几百 KB），磁贴网格在"对账"阶段反复被旧副本覆盖——这就是"拖上去又弹回来"的机制。而 `CDPUserSvc` / `OneSyncSvc` 这些按用户服务在 svchost 里攥着旧布局的内存副本，**不杀它们，删了注册表几毫秒内就会被写回**。

本工具于 2026-11 在 Windows 10 22H2 (build 19045) 实机验证：教程式删法被回写、修复无效；先杀写入方再删，`CloudStore 7.4 MB → 74 KB`，拖动/固定/取消固定/重启保留全部恢复正常。

## 快速开始

需要：Windows 10 1709 及以上 + [PowerShell 7](https://aka.ms/powershell)（没有就装：`winget install Microsoft.PowerShell`）

双击 `TileFixer.bat`，或命令行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\TileFixer.ps1 -Action diagnose   # 只读体检
pwsh -NoProfile -ExecutionPolicy Bypass -File .\TileFixer.ps1 -Action fix        # 备份并完整重置
pwsh -NoProfile -ExecutionPolicy Bypass -File .\TileFixer.ps1 -Action fix -Mode safe -WhatIf   # 试运行: 只看会删哪些条目
pwsh -NoProfile -ExecutionPolicy Bypass -File .\TileFixer.ps1 -Action fix -Mode safe            # 保守手术: 保留布局
pwsh -NoProfile -ExecutionPolicy Bypass -File .\TileFixer.ps1 -Action restore -BackupFile .\Backups\CloudStore-backup-xxxx.reg
```

不需要管理员权限。

## 两种修复模式

| | 完整重置 (`-Mode full`，默认) | 保守手术 (`-Mode safe`，实验) |
|---|---|---|
| 删除范围 | 整个 CloudStore 键 | 只删 3 类冲突源条目：漫游属性副本 (`roamedtilepropertiesmap`)、本地易失副本 (`localstartvolatiletilepropertiesmap`)、建议流 (`start.suggestions`) |
| 磁贴布局 | **重置为出厂默认**，需重新摆放 | **原样保留**（主布局 `start.tilegrid`、本地属性表、墓碑区一律不碰） |
| 确定性 | 高 | 取决于坏副本是谁：若对账时赢的是漫游/易失副本 → 痊愈；否则无效（无损，可再用完整重置收尾） |
| 适用场景 | 布局已乱到没法看 / 保守手术无效 | 布局还想保住，想先试试不重置 |

原理：每块磁贴有本地/易失/漫游三份属性副本，"拖动被弹回"是坏副本在**对账（reconciliation）**阶段赢过了你的新写入。保守手术把两个最可能的坏副本（漫游、易失）切掉，逼对账只用干净的本地主数据。**墓碑区（graveyard）绝不能删**——删了墓碑，对账机制会把之前取消固定的磁贴"复活"，幽灵磁贴反而加重。

先用 `-WhatIf` 试运行，看清自己机器上会删哪些条目再决定。

## 修复时会做什么（完整重置模式）

1. 备份 CloudStore 注册表键（+ 磁盘缓存文件夹，如存在）到 `Backups/`
2. 终止写入方：承载 `CDPUserSvc_*` / `OneSyncSvc_*` / `UserDataPlatformSvc_*` 的 svchost 进程（这些服务之后会按需自动重启，无需手动处理）
3. 终止 `StartMenuExperienceHost` / `ShellExperienceHost` / `explorer`
4. 删除 `HKCU\...\CloudStore`，等 1.5 秒校验未被回写（被回写则重杀重删一次）
5. 重启 `explorer`，Windows 用干净数据重建默认布局

**代价**：磁贴布局重置为出厂默认，需要重新固定、摆放一次（"所有应用"列表不受影响）。换来的是从此拖动、固定、取消固定都真正生效。

## 健康指标解读（diagnose 输出）

| CloudStore 二进制数据量 | 判定 |
|---|---|
| < 300 KB | 健康（实测正常值 74–106 KB） |
| 300 KB – 2 MB | 警惕，观察磁贴行为 |
| > 2 MB | 膨胀，大概率已损坏（实测病灶 7.4 MB） |

## 常见问题

**Q: 修复会丢什么？**
A: 只丢磁贴布局（重置为默认）。已安装程序、"所有应用"列表、任务栏固定项都不动。

**Q: 修复后过一段时间又复发了？**
A: 再跑一次 `fix`。频繁复发的话，检查是否用微软账户登录并开启了设置同步——云端可能存有坏布局，会尝试灌回（前提是网络能到达同步端点）。

**Q: 需要管理员吗？**
A: 一般不需要。若提示 svchost 终止失败，用管理员身份重跑即可。

**Q: 恢复备份会把 bug 也恢复吗？**
A: 会。备份用于"修坏了救急"，不是"把 bug 存档"。布局稳定后可以删掉 `Backups/` 目录。

**Q: Win11 能用吗？**
A: Win11 (21H2+) 的固定布局走同一套 CloudStore 机制，理论可用但未充分测试；Win11 本身已没有动态磁贴，一般用不上。

## 实测案例（2026-11，Windows 10 22H2 / 19045）

- 修复前：CloudStore 7.4 MB（含 `$start.tilegrid` / `curatedtilecollection` / roamed 副本 / graveyard）
- 教程式删法（只杀 explorer）：**几毫秒内被回写**，修复无效
- 本工具流程：删后 1.5 秒校验保持已删除状态 ✅
- 重建后：74 KB 干净骨架，拖动 / 固定 / 取消固定 / 重启保留全部正常

## 技术背景（想深挖的看这里）

- [微软官方排错文档：Start menu errors](https://learn.microsoft.com/en-us/troubleshoot/windows-client/shell-experience/troubleshoot-start-menu-errors)
- [ExplorerPatcher 对磁贴引擎 StartTileData.dll 的逆向（Local/Roamed/Graveyard/Reconciliation 机制出处）](https://github.com/ExplorerPatcher/ep_starttiledata)
- [superuser：布局重启后重置的两个实锤根因](https://superuser.com/questions/1212927/windows-10-tile-layout-in-start-menu-resets-after-reboot)
- TileDataLayer 时代（Win10 1507–1607）不适用本工具，官方方案是 `tdlrecover.exe`

## English (short)

**Win10 Tile Fixer** repairs the classic Windows 10 Start-menu tile bugs: new pins stuck at the bottom and immovable, tiles snapping back after being moved, ghost duplicates, and layouts that never persist. Root cause: corruption/bloat of the tile-layout cache in the registry `CloudStore` key. The naive "kill explorer + delete the key" guide fails because per-user services (`CDPUserSvc_*`, `OneSyncSvc_*`) hosted in svchost silently rewrite the stale layout from memory within milliseconds. This tool backs up the key, kills **all** writers, deletes the cache, verifies it *stays* deleted, then restarts the shell. Requires Windows 10 1709+ and PowerShell 7. No admin rights needed. Your tile layout resets to factory default — re-pin once, and it sticks.

## 更新日志

- **v1.1.0**：新增保守手术模式 `-Mode safe`（保留布局只清冲突源，支持 `-WhatIf` 试运行）
- **v1.0.0**：首次发布——完整重置流程（备份 → 全写入方终止 → 删 CloudStore → 回写校验 → 重启 shell）+ 体检诊断

## 免责声明

本工具修改当前用户的注册表（修复前自动备份）。按现状提供，不附带任何担保；使用前请阅读源码。详见 [LICENSE](LICENSE)。

## License

[Apache-2.0](LICENSE)
